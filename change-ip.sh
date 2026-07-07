#!/bin/bash
# =============================================================================
# CDPNI — Troca de IP do servidor
# Atualiza a configuração e reaplica apenas os roles afetados.
# Execute como root:  sudo bash change-ip.sh <novo-ip> [nova-mascara]
#
# Exemplo:
#   sudo bash change-ip.sh 10.14.29.8
#   sudo bash change-ip.sh 172.14.29.8 24
#
# Garantias de segurança:
#   - group_vars/all.yml é lido e gravado com YAML de verdade (python3),
#     nunca com grep/sed — se algum valor não puder ser lido, o script
#     ABORTA antes de alterar qualquer coisa.
#   - Gateway é validado dentro da sub-rede nova antes de aplicar.
#   - Se a rede nova não estiver nas redes permitidas do firewall
#     (network_ranges), ela é adicionada automaticamente — sem isso o
#     nftables bloquearia todo o acesso após a troca.
#   - Em sessão SSH o playbook roda via systemd-run, desacoplado da
#     sessão: se o SSH cair na troca de IP, a aplicação CONTINUA até o
#     fim (era exatamente aqui que a versão antiga deixava a máquina
#     sem rede).
# =============================================================================
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

ok()   { echo -e "${GREEN}  ✔ $*${NC}"; }
warn() { echo -e "${YELLOW}  ⚠ $*${NC}"; }
err()  { echo -e "${RED}  ✘ $*${NC}"; exit 1; }
info() { echo -e "${CYAN}  → $*${NC}"; }
step() { echo -e "\n${BOLD}${BLUE}┌─ $* ${NC}"; }

[[ $EUID -ne 0 ]] && err "Execute como root: sudo bash $0 <novo-ip> [mascara]"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VARS_FILE="${SCRIPT_DIR}/group_vars/all.yml"

[[ -f "$VARS_FILE" ]] || err "group_vars/all.yml não encontrado. Rode o bootstrap.sh primeiro."
command -v python3 &>/dev/null         || err "python3 não encontrado."
command -v ansible-playbook &>/dev/null || err "ansible-playbook não encontrado."
python3 -c "import yaml" 2>/dev/null    || err "PyYAML não encontrado (instale: apt-get install python3-yaml)."

NOVO_IP="${1:-}"
NOVA_MASK="${2:-}"

valid_ip() {
    [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
    local IFS='.'; read -ra o <<< "$1"
    for oct in "${o[@]}"; do [[ $oct -le 255 ]] || return 1; done
}

# ── Lê a configuração atual com YAML de verdade (nunca grep/sed) ─────────────
yml_get() {
    VARS_FILE="$VARS_FILE" python3 - "$1" << 'PY'
import os, sys, yaml
d = yaml.safe_load(open(os.environ['VARS_FILE']))
v = d
for k in sys.argv[1].split('.'):
    v = v[k]
print(v)
PY
}

IP_ATUAL=$(yml_get server.ip)         || err "Falha ao ler server.ip do all.yml"
MASK_ATUAL=$(yml_get server.mask)     || err "Falha ao ler server.mask do all.yml"
GW_ATUAL=$(yml_get server.gateway)    || err "Falha ao ler server.gateway do all.yml"
DNS_ATUAL=$(yml_get server.dns)       || err "Falha ao ler server.dns do all.yml"
HOSTNAME=$(yml_get server.hostname)   || err "Falha ao ler server.hostname do all.yml"
DOMAIN=$(yml_get server.domain)       || err "Falha ao ler server.domain do all.yml"
IFACE_ATUAL=$(yml_get server.iface)   || err "Falha ao ler server.iface do all.yml"

for _v in IP_ATUAL MASK_ATUAL GW_ATUAL HOSTNAME DOMAIN IFACE_ATUAL; do
    [[ -n "${!_v}" ]] || err "Valor vazio no all.yml: ${_v} — corrija o arquivo antes de continuar."
done

echo ""
echo -e "${CYAN}  ╔══════════════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}  ║          CDPNI — Troca de IP do servidor             ║${NC}"
echo -e "${CYAN}  ╚══════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "  Servidor    : ${BOLD}${HOSTNAME}.${DOMAIN}${NC}"
echo -e "  IP atual    : ${YELLOW}${IP_ATUAL}/${MASK_ATUAL}${NC}  (gw ${GW_ATUAL}, dns ${DNS_ATUAL}, ${IFACE_ATUAL})"

# ── Novo IP ───────────────────────────────────────────────────────────────────
if [[ -z "$NOVO_IP" ]]; then
    while true; do
        echo -e "${BOLD}  Novo IP do servidor:${NC}"
        read -rp "  > " NOVO_IP
        valid_ip "$NOVO_IP" && break
        warn "IP inválido"
    done
else
    valid_ip "$NOVO_IP" || err "IP inválido: $NOVO_IP"
fi

# ── Nova máscara ──────────────────────────────────────────────────────────────
if [[ -z "$NOVA_MASK" ]]; then
    echo -e "${BOLD}  Nova máscara CIDR [${MASK_ATUAL}]:${NC}"
    read -rp "  > " _IN
    NOVA_MASK="${_IN:-$MASK_ATUAL}"
fi
[[ "$NOVA_MASK" =~ ^[0-9]+$ ]] && [[ $NOVA_MASK -ge 1 ]] && [[ $NOVA_MASK -le 30 ]] \
    || err "Máscara inválida: $NOVA_MASK"

REDE_NOVA=$(python3 -c "import ipaddress; print(ipaddress.ip_network('${NOVO_IP}/${NOVA_MASK}', strict=False))")

gw_na_rede() {
    python3 -c "import ipaddress, sys
sys.exit(0 if ipaddress.ip_address('$1') in ipaddress.ip_network('${REDE_NOVA}') else 1)" 2>/dev/null
}

# ── Gateway (validado dentro da sub-rede nova) ────────────────────────────────
GW_SUG="${NOVO_IP%.*}.1"
gw_na_rede "$GW_SUG" || GW_SUG=""
while true; do
    echo -e "${BOLD}  Gateway${GW_SUG:+ [${GW_SUG}]}:${NC}"
    read -rp "  > " _IN; NOVO_GW="${_IN:-$GW_SUG}"
    if ! valid_ip "$NOVO_GW"; then warn "Gateway inválido"; continue; fi
    if ! gw_na_rede "$NOVO_GW"; then
        warn "O gateway ${NOVO_GW} está FORA da rede ${REDE_NOVA} — isso deixaria o servidor sem rota no boot."
        continue
    fi
    break
done

# ── DNS ───────────────────────────────────────────────────────────────────────
echo -e "${BOLD}  DNS (Enter = gateway) [${NOVO_GW}]:${NC}"
read -rp "  > " _IN; NOVO_DNS="${_IN:-$NOVO_GW}"
valid_ip "$NOVO_DNS" || err "DNS inválido: $NOVO_DNS"

# ── Interface (validada no kernel) ────────────────────────────────────────────
while true; do
    echo -e "${BOLD}  Interface de rede [${IFACE_ATUAL}]:${NC}"
    read -rp "  > " _IN; NOVA_IFACE="${_IN:-$IFACE_ATUAL}"
    ip link show "$NOVA_IFACE" &>/dev/null && break
    warn "Interface '${NOVA_IFACE}' não existe neste servidor. Interfaces disponíveis:"
    ip -o link show | awk -F': ' '{print "      " $2}' | grep -Ev '^\s+lo$'
done

# ── A rede nova está coberta pelas redes permitidas do firewall? ──────────────
REDE_COBERTA=$(VARS_FILE="$VARS_FILE" REDE_NOVA="$REDE_NOVA" python3 << 'PY'
import os, yaml, ipaddress
d = yaml.safe_load(open(os.environ['VARS_FILE']))
net = ipaddress.ip_network(os.environ['REDE_NOVA'])
ranges = d.get('network_ranges') or []
print('sim' if any(net.subnet_of(ipaddress.ip_network(r)) for r in ranges) else 'nao')
PY
)

# ── Confirmação ───────────────────────────────────────────────────────────────
echo ""
echo -e "${YELLOW}  IP antigo : ${IP_ATUAL}/${MASK_ATUAL}${NC}"
echo -e "${YELLOW}  IP novo   : ${NOVO_IP}/${NOVA_MASK}  (rede ${REDE_NOVA})${NC}"
echo -e "${YELLOW}  Gateway   : ${NOVO_GW}${NC}"
echo -e "${YELLOW}  DNS       : ${NOVO_DNS}${NC}"
echo -e "${YELLOW}  Interface : ${NOVA_IFACE}${NC}"
if [[ "$REDE_COBERTA" == "nao" ]]; then
    warn "A rede ${REDE_NOVA} não está nas redes permitidas do firewall —"
    warn "ela será ADICIONADA a network_ranges automaticamente."
fi
echo ""
if [[ -n "${SSH_CONNECTION:-}" ]]; then
    warn "Você está em uma sessão SSH: a aplicação rodará em segundo plano"
    warn "(systemd-run) e SOBREVIVE à queda da sessão durante a troca."
    warn "Reconecte depois pelo novo IP: ssh root@${NOVO_IP}"
fi
echo ""
read -rp "  Confirmar troca? [s/N]: " _C
[[ "${_C,,}" == "s" ]] || { echo "Cancelado."; exit 0; }

# ── Atualiza group_vars/all.yml (YAML de verdade, com backup) ────────────────
step "Atualizando configuração"

cp "$VARS_FILE" "${VARS_FILE}.bak.$(date +%Y%m%d%H%M%S)"
ok "Backup salvo em ${VARS_FILE}.bak.*"

VARS_FILE="$VARS_FILE" NOVO_IP="$NOVO_IP" NOVA_MASK="$NOVA_MASK" \
NOVO_GW="$NOVO_GW" NOVO_DNS="$NOVO_DNS" NOVA_IFACE="$NOVA_IFACE" \
python3 << 'PY'
import os, yaml, ipaddress

path = os.environ['VARS_FILE']
d = yaml.safe_load(open(path))

s = d['server']
s['ip']      = os.environ['NOVO_IP']
s['mask']    = os.environ['NOVA_MASK']
s['gateway'] = os.environ['NOVO_GW']
s['dns']     = os.environ['NOVO_DNS']
s['iface']   = os.environ['NOVA_IFACE']

# Garante que a rede nova está nas redes permitidas do firewall
net = ipaddress.ip_network(f"{s['ip']}/{s['mask']}", strict=False)
ranges = d.setdefault('network_ranges', [
    '10.0.0.0/8', '172.16.0.0/12', '192.168.0.0/16',
    '172.14.29.0/24', '192.14.29.0/24',
])
if not any(net.subnet_of(ipaddress.ip_network(r)) for r in ranges):
    ranges.append(str(net))
    print(f"  rede {net} adicionada a network_ranges")

with open(path, 'w') as f:
    yaml.safe_dump(d, f, default_flow_style=False, sort_keys=False, allow_unicode=True)
PY
ok "group_vars/all.yml atualizado"

# ── Remove certificado para forçar regeneração com novo IP no SAN ─────────────
step "Renovando certificado SSL"
rm -f /etc/nginx/ssl/cdpni.crt /etc/nginx/ssl/cdpni.key 2>/dev/null || true
ok "Certificado antigo removido (será regenerado com novo IP)"

# ── Reaplica apenas os roles afetados ─────────────────────────────────────────
step "Reaplicando Ansible (network + security + samba)"
echo ""

PLAYBOOK_CMD="cd '${SCRIPT_DIR}' && ansible-playbook -i inventory/hosts.ini site.yml --tags network,security,samba --diff"

if [[ -n "${SSH_CONNECTION:-}" ]]; then
    # Sessão SSH: roda desacoplado — se a conexão cair na troca de IP,
    # o playbook continua até o fim em vez de morrer no meio.
    systemctl reset-failed cdpni-changeip 2>/dev/null || true
    systemd-run --unit=cdpni-changeip --collect \
        --description="CDPNI troca de IP para ${NOVO_IP}" \
        bash -c "${PLAYBOOK_CMD} >> /var/log/cdpni_change_ip.log 2>&1"
    ok "Playbook iniciado em segundo plano (unidade cdpni-changeip)."
    info "Acompanhe : tail -f /var/log/cdpni_change_ip.log"
    info "Status    : systemctl status cdpni-changeip"
    info "Se a sessão cair, reconecte: ssh root@${NOVO_IP}"
else
    bash -c "${PLAYBOOK_CMD}" 2>&1 | tee /var/log/cdpni_change_ip.log
    ok "Log completo em /var/log/cdpni_change_ip.log"
fi

# ── Instruções finais ─────────────────────────────────────────────────────────
echo ""
echo -e "${CYAN}  ╔══════════════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}  ║                  PRÓXIMOS PASSOS                    ║${NC}"
echo -e "${CYAN}  ╠══════════════════════════════════════════════════════╣${NC}"
printf  "${CYAN}  ║${NC}  %-51s${CYAN}║${NC}\n" "No gateway GWOS, atualize o DNS:"
printf  "${CYAN}  ║${NC}  ${BOLD}%-51s${NC}${CYAN}║${NC}\n" "  gwos dns update ${HOSTNAME} ${NOVO_IP}"
printf  "${CYAN}  ║${NC}  %-51s${CYAN}║${NC}\n" ""
printf  "${CYAN}  ║${NC}  %-51s${CYAN}║${NC}\n" "Novo acesso ao servidor:"
printf  "${CYAN}  ║${NC}  ${GREEN}%-51s${NC}${CYAN}║${NC}\n" "  https://${NOVO_IP}"
printf  "${CYAN}  ║${NC}  ${GREEN}%-51s${NC}${CYAN}║${NC}\n" "  https://${HOSTNAME}.${DOMAIN}"
printf  "${CYAN}  ║${NC}  ${GREEN}%-51s${NC}${CYAN}║${NC}\n" "  \\\\\\\\${NOVO_IP}  (Windows)"
echo -e "${CYAN}  ╚══════════════════════════════════════════════════════╝${NC}"
echo ""
