#!/bin/bash
# =============================================================================
#  Atualiza só o firewall — sem reinstalar Samba, RAID ou o portal
# =============================================================================
#  Uso:  sudo bash scripts/atualizar_firewall.sh
#
#  Existe para o caso de um sistema (SGF, um módulo novo do GWOS) ser
#  instalado DEPOIS do Samba nesta máquina: o firewall dele (política DROP)
#  só conhece o que existia quando o bootstrap.sh rodou por último. Repetir
#  o bootstrap.sh inteiro funciona, mas reprocessa pacotes, rede, RAID, Samba
#  e o portal só para trocar duas linhas do group_vars/all.yml — este script
#  faz só a parte que importa: redetecta, atualiza essas duas linhas, e
#  aplica de novo apenas o role de firewall (tag "firewall" do site.yml).
#
#  A detecção é a MESMA usada pelo bootstrap.sh (scripts/detectar_outros_
#  sistemas.sh) — os dois nunca divergem sobre o que cada sistema conhecido
#  precisa.
# =============================================================================

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'
BOLD='\033[1m'; NC='\033[0m'

ok()    { echo -e "${GREEN}  ✔ $*${NC}"; }
warn()  { echo -e "${YELLOW}  ⚠ $*${NC}"; }
erro()  { echo -e "${RED}  ✖ $*${NC}" >&2; exit 1; }
info()  { echo -e "${CYAN}  → $*${NC}"; }
titulo(){ echo -e "\n${BOLD}${CYAN}$1${NC}\n"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

[ "$(id -u)" -eq 0 ] || erro "Execute como root: sudo bash $0"
[ -f "${SCRIPT_DIR}/group_vars/all.yml" ] || erro "group_vars/all.yml não encontrado — rode o bootstrap.sh primeiro."
command -v ansible-playbook >/dev/null 2>&1 || erro "ansible-playbook não encontrado. Este servidor já foi instalado com o bootstrap.sh?"

titulo "── Redetectando outros sistemas nesta máquina ──"

# shellcheck source=scripts/detectar_outros_sistemas.sh
source "${SCRIPT_DIR}/scripts/detectar_outros_sistemas.sh"
detectar_outros_sistemas
for _linha in "${DETECTADOS[@]}"; do
    if [[ "$_linha" == "  →"* ]]; then
        echo "$_linha"
    else
        echo ""
        info "$_linha"
    fi
done
[ ${#DETECTADOS[@]} -eq 0 ] && info "Nada além do Samba detectado nesta máquina."

# ---------------------------------------------------------------------------
# Atualiza só as duas linhas de firewall no all.yml — o resto do arquivo
# (org, server, raid, samba, portal, ssl) fica exatamente como está.
# ---------------------------------------------------------------------------
titulo "── Atualizando group_vars/all.yml ──"

_TCP_ANTES=$(grep -oP '(?<=extra_tcp: \[)[^\]]*' "${SCRIPT_DIR}/group_vars/all.yml" || echo "")
_UDP_ANTES=$(grep -oP '(?<=extra_udp: \[)[^\]]*' "${SCRIPT_DIR}/group_vars/all.yml" || echo "")

_TCP_NOVO=$(IFS=', '; echo "${EXTRA_TCP[*]:-}")
_UDP_NOVO=$(IFS=', '; echo "${EXTRA_UDP[*]:-}")

python3 - "${SCRIPT_DIR}/group_vars/all.yml" "$_TCP_NOVO" "$_UDP_NOVO" <<'PY'
import re, sys
caminho, tcp, udp = sys.argv[1], sys.argv[2], sys.argv[3]
with open(caminho, encoding='utf-8') as f:
    conteudo = f.read()

conteudo, n1 = re.subn(r'extra_tcp: \[[^\]]*\]', f'extra_tcp: [{tcp}]', conteudo, count=1)
conteudo, n2 = re.subn(r'extra_udp: \[[^\]]*\]', f'extra_udp: [{udp}]', conteudo, count=1)
if n1 == 0 or n2 == 0:
    sys.exit("ERRO: não encontrei extra_tcp/extra_udp no all.yml — arquivo fora do formato esperado.")

with open(caminho, 'w', encoding='utf-8') as f:
    f.write(conteudo)
PY

if [ "$_TCP_ANTES" = "$_TCP_NOVO" ] && [ "$_UDP_ANTES" = "$_UDP_NOVO" ]; then
    ok "Nada mudou — TCP: [${_TCP_NOVO}]  UDP: [${_UDP_NOVO}]"
else
    echo "  TCP:  [${_TCP_ANTES}]  →  [${_TCP_NOVO}]"
    echo "  UDP:  [${_UDP_ANTES}]  →  [${_UDP_NOVO}]"
    ok "group_vars/all.yml atualizado."
fi

# ---------------------------------------------------------------------------
# Aplica só o firewall — a tag "firewall" no site.yml é a mesma que cobre
# todo o role 'security' (nftables, fail2ban, smartd, certificado SSL);
# os demais (pacotes, rede, RAID, Samba, portal) não são tocados.
# ---------------------------------------------------------------------------
titulo "── Aplicando (ansible-playbook --tags firewall) ──"

cd "${SCRIPT_DIR}"
ansible-playbook -i inventory/hosts.ini site.yml --tags firewall

echo ""
ok "Firewall atualizado."
echo "   Conferir: sudo nft list ruleset | grep -E 'dport|policy'"
