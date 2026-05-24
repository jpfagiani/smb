#!/bin/bash

# ==============================================================================
# SCRIPT DE IMPLANTAÇÃO — GATEWAY PROXY DEBIAN 13 (TRIXIE) — MÁQUINA FÍSICA
# Squid · BIND9 · nftables · Chrony · Flask/Gunicorn · SSL Bump · WPAD
# Versão 37.1 — Maio 2026
# ==============================================================================

set -euo pipefail

# Valor padrão — sobrescrito pela seleção interativa
MON_ENABLED=0
MON_IP="192.168.1.1"
MON_NET="192.168.1.0/24"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
log()  { echo -e "${GREEN}[*]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
err()  { echo -e "${RED}[ERRO]${NC} $1"; exit 1; }
ok()   { echo -e "${GREEN}[OK]${NC} $1"; }

export SYSTEMD_LOG_LEVEL=warning

[ "$EUID" -ne 0 ] && err "Execute como root: su - && bash gateway.sh"

# Verificar Debian 13
if [ -f /etc/os-release ]; then
    . /etc/os-release
    if [ "${VERSION_CODENAME:-}" != "trixie" ] && [ "${VERSION_ID:-}" != "13" ]; then
        warn "Este script foi otimizado para Debian 13 (Trixie). Detectado: ${PRETTY_NAME:-desconhecido}"
        warn "Pode funcionar em outras versões, mas não foi testado."
        read -rp "$(echo -e "${YELLOW}[?]${NC} Continuar mesmo assim? [s/N]: ")" CONFIRM_OS
        [[ ! "${CONFIRM_OS:-N}" =~ ^[SsYy]$ ]] && err "Abortado pelo operador."
    fi
fi

echo -e "${CYAN}"
echo "=============================================================================="
echo " INICIANDO IMPLANTAÇÃO DO SERVIDOR GATEWAY — DEBIAN 13"
echo "=============================================================================="
echo -e "${NC}"

# ==============================================================================
# 1. CONFIGURAÇÃO DE REDE — INTERATIVA
# ==============================================================================
log "Iniciando configuração interativa das interfaces de rede..."

echo ""
echo -e "${CYAN}Interfaces de rede disponíveis no sistema:${NC}"
ip -o link show | awk -F': ' '{print $2}' | grep -v '^lo$' \
    | grep -Ev '^(docker|veth|virbr|br-|bond|dummy|tun|tap)' \
    | nl -w2 -s') '
echo ""

# ─── Escolha das interfaces WAN e LAN (sempre necessário) ────────────────────
WAN_IF_DEFAULT=$(ip -o -4 route show to default 2>/dev/null | awk '{print $5}' | head -n1)
while true; do
    read -rp "$(echo -e "${YELLOW}[?]${NC} Interface WAN (externa) [padrão: ${WAN_IF_DEFAULT:-eth0}]: ")" WAN_IF_INPUT
    WAN_IF="${WAN_IF_INPUT:-${WAN_IF_DEFAULT:-eth0}}"
    if ip link show "$WAN_IF" &>/dev/null; then break
    else warn "Interface '$WAN_IF' não encontrada. Tente novamente."; fi
done

LAN_IF_DEFAULT=$(ip -o link show | awk -F': ' '{print $2}' | grep -v '^lo$' \
    | grep -v "$WAN_IF" \
    | grep -Ev '^(docker|veth|virbr|br-|bond|dummy|tun|tap)' \
    | head -n1)
LAN_IF_DEFAULT="${LAN_IF_DEFAULT:-eth1}"
while true; do
    read -rp "$(echo -e "${YELLOW}[?]${NC} Interface LAN (interna)  [padrão: ${LAN_IF_DEFAULT}]: ")" LAN_IF_INPUT
    LAN_IF="${LAN_IF_INPUT:-${LAN_IF_DEFAULT}}"
    if [ "$LAN_IF" = "$WAN_IF" ]; then
        warn "LAN e WAN não podem ser a mesma interface. Tente novamente."
    elif ip link show "$LAN_IF" &>/dev/null; then break
    else warn "Interface '$LAN_IF' não encontrada. Tente novamente."; fi
done

# ─── Modo de configuração da WAN: DHCP ou Estático ───────────────────────────
echo ""
echo -e "${CYAN}──────────────────────────────────────────────────────────${NC}"
echo -e " ${YELLOW}WAN selecionada:${NC} $WAN_IF   ${YELLOW}LAN selecionada:${NC} $LAN_IF"
echo -e "${CYAN}──────────────────────────────────────────────────────────${NC}"
echo ""
echo -e "${CYAN}Como deseja configurar a interface WAN (${WAN_IF})?${NC}"
echo -e "  ${GREEN}1)${NC} DHCP     — IP obtido automaticamente pelo provedor/roteador"
echo -e "  ${GREEN}2)${NC} Estático — IP fixo configurado manualmente"
echo ""

WAN_MODE=""
while true; do
    read -rp "$(echo -e "${YELLOW}[?]${NC} Modo WAN [1=DHCP / 2=Estático]: ")" WAN_MODE_INPUT
    case "${WAN_MODE_INPUT:-}" in
        1|dhcp|DHCP|d|D)             WAN_MODE="dhcp";   break ;;
        2|static|STATIC|s|S|e|E)     WAN_MODE="static"; break ;;
        *) warn "Digite 1 para DHCP ou 2 para Estático." ;;
    esac
done

# ─── DHCP: usar IP atual como referência para os serviços ────────────────────
if [ "$WAN_MODE" = "dhcp" ]; then
    warn "DHCP selecionado — recomendado IP fixo para gateway."
    echo ""

    # Capturar IP atual da interface WAN (se já houver)
    WAN_IP=$(ip -o -4 addr show dev "$WAN_IF" 2>/dev/null | awk 'NR==1{print $4}' | cut -d/ -f1)
    WAN_PREFIX=$(ip -o -4 addr show dev "$WAN_IF" 2>/dev/null | awk 'NR==1{print $4}' | cut -d/ -f2)
    WAN_GW=$(ip -o -4 route show to default dev "$WAN_IF" 2>/dev/null | awk '{print $3}' | head -n1)

    # Fallbacks caso interface ainda não tenha IP (DHCP pendente)
    WAN_IP="${WAN_IP:-0.0.0.0}"
    WAN_PREFIX="${WAN_PREFIX:-24}"
    WAN_GW="${WAN_GW:-0.0.0.0}"

    ok "IP atual detectado na WAN: ${WAN_IP}/${WAN_PREFIX}  GW: ${WAN_GW}"
    echo ""

# ─── Estático: perguntar IP, prefixo e gateway ───────────────────────────────
else
    WAN_IP_DEFAULT="10.14.29.10"
    read -rp "$(echo -e "${YELLOW}[?]${NC} IP da WAN (ex: 10.14.29.10/24) [padrão: ${WAN_IP_DEFAULT}/24]: ")" WAN_IP_INPUT
    WAN_IP_CIDR="${WAN_IP_INPUT:-${WAN_IP_DEFAULT}/24}"
    WAN_IP=$(echo "$WAN_IP_CIDR" | cut -d/ -f1)
    WAN_PREFIX=$(echo "$WAN_IP_CIDR" | cut -d/ -f2)
    [ "$WAN_PREFIX" = "$WAN_IP" ] && WAN_PREFIX="24"

    WAN_GW_DEFAULT=$(ip -o -4 route show to default 2>/dev/null | awk '{print $3}' | head -n1)
    WAN_GW_DEFAULT="${WAN_GW_DEFAULT:-10.14.29.1}"
    read -rp "$(echo -e "${YELLOW}[?]${NC} Gateway da WAN             [padrão: ${WAN_GW_DEFAULT}]: ")" WAN_GW_INPUT
    WAN_GW="${WAN_GW_INPUT:-${WAN_GW_DEFAULT}}"
fi

# ─── LAN sempre Estática ─────────────────────────────────────────────────────
LAN_IP_DEFAULT="192.168.0.1"
read -rp "$(echo -e "${YELLOW}[?]${NC} IP da LAN (ex: 192.168.0.1/24) [padrão: ${LAN_IP_DEFAULT}/24]: ")" LAN_IP_INPUT
LAN_IP_CIDR="${LAN_IP_INPUT:-${LAN_IP_DEFAULT}/24}"
LAN_IP=$(echo "$LAN_IP_CIDR" | cut -d/ -f1)
LAN_PREFIX=$(echo "$LAN_IP_CIDR" | cut -d/ -f2)
[ "$LAN_PREFIX" = "$LAN_IP" ] && LAN_PREFIX="24"

LAN_NET=$(python3 -c "import ipaddress; n=ipaddress.ip_interface('${LAN_IP}/${LAN_PREFIX}').network; print(n)" 2>/dev/null || \
    ipcalc -n "${LAN_IP}/${LAN_PREFIX}" 2>/dev/null | awk -F= '/^NETWORK/{print $2"/"'"${LAN_PREFIX}"'}' || \
    awk -v ip="${LAN_IP}" -v prefix="${LAN_PREFIX}" 'BEGIN{
        split(ip,o,"."); mask=0;
        for(i=1;i<=prefix;i++) mask+=2^(32-i);
        for(i=1;i<=4;i++) net=(i==1?int(o[i])and(int((mask%(2^(32-8*(i-1))))/(2^(32-8*i)))):net"."int(o[i])and(int((mask%(2^(32-8*(i-1))))/(2^(32-8*i)))));
        printf "%s.%s.%s.%s/%s\n", and(o[1],int(mask/16777216)),and(o[2],int(mask/65536)%256),and(o[3],int(mask/256)%256),and(o[4],mask%256),prefix}' 2>/dev/null || \
    echo "${LAN_IP%.*}.0/${LAN_PREFIX}")

# ─── Resumo e confirmação ─────────────────────────────────────────────────────
echo ""
echo -e "${CYAN}──────────────────────────────────────────────────────────${NC}"
if [ "$WAN_MODE" = "dhcp" ]; then
    echo -e " ${GREEN}WAN:${NC} $WAN_IF  →  DHCP  (IP atual: ${WAN_IP}/${WAN_PREFIX}  GW: ${WAN_GW})"
else
    echo -e " ${GREEN}WAN:${NC} $WAN_IF  →  Estático  ${WAN_IP}/${WAN_PREFIX}  |  GW: ${WAN_GW}"
fi
echo -e " ${GREEN}LAN:${NC} $LAN_IF  →  Estático  ${LAN_IP}/${LAN_PREFIX}  |  Rede: ${LAN_NET}"

# Rede de monitoramento (opcional — 192.168.1.0/24)
echo ""
echo -e "${CYAN}Rede de monitoramento 192.168.1.0/24${NC}"
echo -e "  Essa rede recebe acesso irrestrito ao proxy e à internet."
echo -e "  Pode ser uma segunda sub-rede na mesma interface LAN (roteada pelo switch)"
echo -e "  ou um alias IP na interface LAN existente."
read -rp "$(echo -e "${YELLOW}[?]${NC} Configurar IP 192.168.1.1/24 como alias na LAN ($LAN_IF)? [S/n]: ")" MON_CONFIRM
MON_CONFIRM="${MON_CONFIRM:-S}"
if [[ "${MON_CONFIRM}" =~ ^[SsYy]$ ]]; then
    MON_ENABLED=1
    MON_IP="192.168.1.1"
    MON_NET="192.168.1.0/24"
    echo -e " ${GREEN}Monitoramento:${NC} $LAN_IF alias → $MON_IP/24  |  Rede: $MON_NET"
else
    MON_ENABLED=0
    echo -e " ${YELLOW}Rede de monitoramento não configurada.${NC}"
fi
echo -e "${CYAN}──────────────────────────────────────────────────────────${NC}"
echo ""
read -rp "$(echo -e "${YELLOW}[?]${NC} Confirmar e aplicar configuração de rede? [S/n]: ")" CONFIRM_NET
CONFIRM_NET="${CONFIRM_NET:-S}"
[[ ! "$CONFIRM_NET" =~ ^[SsYy]$ ]] && err "Instalação cancelada pelo operador."

# ─── Detectar gerenciador de rede ativo ──────────────────────────────────────
NET_MANAGER="ifupdown"
if systemctl is-active --quiet NetworkManager 2>/dev/null; then
    NET_MANAGER="NetworkManager"
elif systemctl is-active --quiet systemd-networkd 2>/dev/null; then
    NET_MANAGER="systemd-networkd"
elif ! command -v ifup &>/dev/null; then
    NET_MANAGER="systemd-networkd"
fi
log "Gerenciador de rede detectado: $NET_MANAGER"

WAN_MASK=$(python3 -c "import ipaddress; print(ipaddress.IPv4Network('0.0.0.0/${WAN_PREFIX}').netmask)" 2>/dev/null || \
    awk -v p="${WAN_PREFIX}" 'BEGIN{m=0;for(i=1;i<=p;i++)m+=2^(32-i);printf "%d.%d.%d.%d\n",int(m/16777216),int(m/65536)%256,int(m/256)%256,m%256}')
LAN_MASK=$(python3 -c "import ipaddress; print(ipaddress.IPv4Network('0.0.0.0/${LAN_PREFIX}').netmask)" 2>/dev/null || \
    awk -v p="${LAN_PREFIX}" 'BEGIN{m=0;for(i=1;i<=p;i++)m+=2^(32-i);printf "%d.%d.%d.%d\n",int(m/16777216),int(m/65536)%256,int(m/256)%256,m%256}')

# ─── Aplicar via NetworkManager ──────────────────────────────────────────────
if [ "$NET_MANAGER" = "NetworkManager" ]; then
    log "Configurando rede via NetworkManager (nmcli)..."
    nmcli con delete "$WAN_IF"     2>/dev/null || true
    nmcli con delete "$LAN_IF"     2>/dev/null || true
    nmcli con delete "gateway-wan" 2>/dev/null || true
    nmcli con delete "gateway-lan" 2>/dev/null || true

    if [ "$WAN_MODE" = "dhcp" ]; then
        nmcli con add type ethernet con-name "gateway-wan" ifname "$WAN_IF" \
            ipv4.method auto \
            connection.autoconnect yes
    else
        nmcli con add type ethernet con-name "gateway-wan" ifname "$WAN_IF" \
            ipv4.method manual \
            ipv4.addresses "${WAN_IP}/${WAN_PREFIX}" \
            ipv4.gateway "$WAN_GW" \
            ipv4.dns "10.14.8.20 10.14.8.16 10.1.6.222" \
            connection.autoconnect yes
    fi

    nmcli con add type ethernet con-name "gateway-lan" ifname "$LAN_IF" \
        ipv4.method manual \
        ipv4.addresses "${LAN_IP}/${LAN_PREFIX}" \
        ipv4.dns "" \
        connection.autoconnect yes
    nmcli con up "gateway-wan" 2>/dev/null || true
    nmcli con up "gateway-lan" 2>/dev/null || true
    systemctl disable NetworkManager --quiet 2>/dev/null || true
    systemctl stop NetworkManager 2>/dev/null || true
    warn "NetworkManager desabilitado — usando ifupdown/ip direto para gateway."
    # Proteger resolv.conf: NM ao parar pode apagar ou invalidar o arquivo
    # Garantir DNS público funcional para o apt-get update que vem a seguir
    if [ -L /etc/resolv.conf ] || [ ! -s /etc/resolv.conf ]; then
        rm -f /etc/resolv.conf
        printf 'nameserver 10.14.8.20\nnameserver 10.14.8.16\nnameserver 10.1.6.222\nnameserver 8.8.8.8\nnameserver 1.1.1.1\n' > /etc/resolv.conf
    fi
    # Após parar NM, reaplica IPs manualmente pois NM os remove ao ser parado
    if [ "$WAN_MODE" = "dhcp" ]; then
        dhclient "$WAN_IF" 2>/dev/null || true
    else
        ip addr flush dev "$WAN_IF" 2>/dev/null || true
        ip addr add "${WAN_IP}/${WAN_PREFIX}" dev "$WAN_IF" 2>/dev/null || true
        ip link set "$WAN_IF" up
        ip route replace default via "$WAN_GW" dev "$WAN_IF" 2>/dev/null || true
    fi
    ip addr flush dev "$LAN_IF" 2>/dev/null || true
    ip addr add "${LAN_IP}/${LAN_PREFIX}" dev "$LAN_IF" 2>/dev/null || true
    ip link set "$LAN_IF" up
fi

# ─── Aplicar via systemd-networkd ────────────────────────────────────────────
if [ "$NET_MANAGER" = "systemd-networkd" ]; then
    log "Configurando rede via systemd-networkd..."
    mkdir -p /etc/systemd/network

    if [ "$WAN_MODE" = "dhcp" ]; then
        cat <<NETDEOF > /etc/systemd/network/10-gateway-wan.network
[Match]
Name=${WAN_IF}

[Network]
DHCP=yes
DNS=10.14.8.20
DNS=10.14.8.16
DNS=10.1.6.222
DNS=8.8.8.8
DNS=1.1.1.1
NETDEOF
    else
        cat <<NETDEOF > /etc/systemd/network/10-gateway-wan.network
[Match]
Name=${WAN_IF}

[Network]
Address=${WAN_IP}/${WAN_PREFIX}
Gateway=${WAN_GW}
DNS=10.14.8.20
DNS=10.14.8.16
DNS=10.1.6.222
DNS=8.8.8.8
DNS=1.1.1.1
DHCP=no
NETDEOF
    fi

    cat <<NETDEOF > /etc/systemd/network/20-gateway-lan.network
[Match]
Name=${LAN_IF}

[Network]
Address=${LAN_IP}/${LAN_PREFIX}
DHCP=no
NETDEOF
    systemctl enable systemd-networkd --quiet
    systemctl restart systemd-networkd
fi

# ─── ifupdown já instalado antes do apt-get update (ver seção 2) ─────────────

# ─── Gravar /etc/network/interfaces ──────────────────────────────────────────
log "Gravando /etc/network/interfaces..."
{
cat <<NETEOF
# Gerado automaticamente pelo gateway em $(date '+%Y-%m-%d %H:%M:%S')
# WAN_MODE=${WAN_MODE}
# As configurações adicionais são carregadas automaticamente pelo ifupdown

auto lo
iface lo inet loopback

NETEOF

if [ "$WAN_MODE" = "dhcp" ]; then
cat <<NETEOF
auto ${WAN_IF}
iface ${WAN_IF} inet dhcp

NETEOF
else
cat <<NETEOF
auto ${WAN_IF}
iface ${WAN_IF} inet static
    address ${WAN_IP}
    netmask ${WAN_MASK}
    gateway ${WAN_GW}
    dns-nameservers 10.14.8.20 10.14.8.16 10.1.6.222

NETEOF
fi

cat <<NETEOF
auto ${LAN_IF}
iface ${LAN_IF} inet static
    address ${LAN_IP}
    netmask ${LAN_MASK}
    # Rota para rede WAN 10.14.29.0/24 — necessária para resposta DNS e tráfego de retorno
    post-up   ip route add 10.14.29.0/24 via ${WAN_GW} dev ${WAN_IF} 2>/dev/null || true
    pre-down  ip route del 10.14.29.0/24 via ${WAN_GW} dev ${WAN_IF} 2>/dev/null || true
NETEOF
} > /etc/network/interfaces

# ─── Aplicar IPs imediatamente (apenas se não foi feito pelo bloco NM acima) ──
if [ "$NET_MANAGER" != "NetworkManager" ]; then
if [ "$WAN_MODE" = "dhcp" ]; then
    log "WAN em DHCP — solicitando endereço via dhclient..."
    dhclient "$WAN_IF" 2>/dev/null || true
    # Aguardar até 15s para obter IP
    for _i in $(seq 1 15); do
        _IP=$(ip -o -4 addr show dev "$WAN_IF" 2>/dev/null | awk 'NR==1{print $4}' | cut -d/ -f1)
        if [ -n "$_IP" ] && [ "$_IP" != "0.0.0.0" ]; then
            WAN_IP="$_IP"
            WAN_PREFIX=$(ip -o -4 addr show dev "$WAN_IF" 2>/dev/null | awk 'NR==1{print $4}' | cut -d/ -f2)
            WAN_GW=$(ip -o -4 route show to default dev "$WAN_IF" 2>/dev/null | awk '{print $3}' | head -n1)
            WAN_GW="${WAN_GW:-0.0.0.0}"
            ok "DHCP obtido: ${WAN_IP}/${WAN_PREFIX}  GW: ${WAN_GW}"
            break
        fi
        sleep 1
    done
    if [ "$WAN_IP" = "0.0.0.0" ]; then
        warn "DHCP não respondeu em 15s. Continuando sem IP na WAN."
        warn "Após a instalação, execute: dhclient ${WAN_IF}"
    fi
else
    ip addr flush dev "$WAN_IF" 2>/dev/null || true
    ip addr add "${WAN_IP}/${WAN_PREFIX}" dev "$WAN_IF" 2>/dev/null || true
    ip link set "$WAN_IF" up
    ip route replace default via "$WAN_GW" dev "$WAN_IF" 2>/dev/null || true
fi

ip addr flush dev "$LAN_IF" 2>/dev/null || true
ip addr add "${LAN_IP}/${LAN_PREFIX}" dev "$LAN_IF" 2>/dev/null || true
ip link set "$LAN_IF" up
fi # fim do bloco não-NetworkManager

if [ "$WAN_MODE" = "dhcp" ]; then
    ok "Rede configurada → WAN: ${WAN_IF} DHCP (${WAN_IP}) | LAN: ${LAN_IP}/${LAN_PREFIX}"
else
    ok "Rede configurada → WAN: ${WAN_IP}/${WAN_PREFIX} via ${WAN_GW} | LAN: ${LAN_IP}/${LAN_PREFIX}"
fi

# ==============================================================================
# 2. ATUALIZAÇÃO DO SISTEMA E INSTALAÇÃO DOS PACOTES
# ==============================================================================

# ─── Configurar repositórios APT (sources.list) ───────────────────────────────
# Em instalações mínimas do Debian 13 o sources.list pode estar apontando para
# o DVD/ISO local ou vazio — o apt-get update roda mas não encontra pacotes.
# Aqui garantimos os repositórios oficiais corretos antes de qualquer apt.
log "Configurando repositórios APT do Debian 13 (Trixie)..."

# Desabilitar repositórios de CD/DVD se existirem (causam erros no apt)
if grep -qE '^\s*deb\s+cdrom' /etc/apt/sources.list 2>/dev/null; then
    warn "Repositório de CD/DVD detectado — comentando para evitar erros no apt..."
    sed -i 's|^\s*deb\s\+cdrom|# deb cdrom|g' /etc/apt/sources.list
fi

# Verificar se já existem repositórios HTTP/HTTPS válidos configurados
# Nota: grep -c com múltiplos arquivos retorna "arquivo:N" — usar grep -h + wc -l
_VALID_REPOS=$(grep -hE '^\s*deb\s+https?://' /etc/apt/sources.list /etc/apt/sources.list.d/*.list 2>/dev/null | wc -l || echo 0)
_VALID_REPOS=$(echo "$_VALID_REPOS" | tr -d '[:space:]')
[ -z "$_VALID_REPOS" ] && _VALID_REPOS=0

# No Debian 13 (Trixie), trixie-updates ainda NÃO existe como repositório oficial
# (Trixie ainda é testing). Forçar reescrita sempre no Debian 13 para remover
# entradas inválidas (trixie-updates, trixie-backports) que causam erro no apt.
_FORCE_REWRITE=0
if [ "${VERSION_ID:-0}" = "13" ] || [ "${VERSION_CODENAME:-}" = "trixie" ]; then
    # Verificar se há entradas inválidas (trixie-updates, trixie-backports)
    if grep -rqE 'trixie-updates|trixie-backports' \
            /etc/apt/sources.list /etc/apt/sources.list.d/ 2>/dev/null; then
        warn "Repositórios inválidos para Trixie detectados (trixie-updates/backports não existem ainda)."
        warn "Forçando reescrita dos repositórios APT..."
        _FORCE_REWRITE=1
    fi
fi

if [ "${_VALID_REPOS}" -lt 2 ] 2>/dev/null || [ "$_VALID_REPOS" = "0" ] || [ "$_FORCE_REWRITE" = "1" ]; then
    [ "$_FORCE_REWRITE" = "1" ] || warn "Repositórios insuficientes detectados ($_VALID_REPOS). Configurando sources.list oficial..."

    # Fazer backup do sources.list atual
    cp /etc/apt/sources.list /etc/apt/sources.list.bak.$(date +%Y%m%d%H%M%S) 2>/dev/null || true

    # Remover arquivos .list e .sources antigos que possam conter entradas inválidas
    # (trixie-updates, trixie-backports, referências a cdrom, etc.)
    for _f in /etc/apt/sources.list.d/*.list /etc/apt/sources.list.d/*.sources; do
        [ -f "$_f" ] || continue
        if grep -qE 'trixie-updates|trixie-backports|cdrom:' "$_f" 2>/dev/null; then
            warn "Removendo $_f (contém repositórios inválidos para Trixie)..."
            mv "$_f" "${_f}.bak.$(date +%Y%m%d%H%M%S)" 2>/dev/null || true
        fi
    done

    # Usar formato DEB822 (.sources) se disponível (Debian 13 padrão)
    # Caso contrário usar sources.list clássico
    if [ -d /etc/apt/sources.list.d ] && dpkg --compare-versions "$(apt --version 2>/dev/null | awk '{print $2}')" ge "2.5" 2>/dev/null; then
        # Remover sources.list clássico para evitar duplicatas
        cat <<'EOF' > /etc/apt/sources.list
# Gerenciado pelo gateway — ver /etc/apt/sources.list.d/debian.sources
EOF
        # Apenas trixie (main) e trixie-security são repositórios válidos no Debian 13
        # trixie-updates NÃO existe ainda (Trixie ainda é testing/unstable)
        cat <<'EOF' > /etc/apt/sources.list.d/debian.sources
Types: deb
URIs: http://deb.debian.org/debian
Suites: trixie
Components: main contrib non-free non-free-firmware
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg

Types: deb
URIs: http://security.debian.org/debian-security
Suites: trixie-security
Components: main contrib non-free non-free-firmware
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg
EOF
        ok "Repositórios configurados em /etc/apt/sources.list.d/debian.sources (DEB822)"
    else
        cat <<'EOF' > /etc/apt/sources.list
# Repositórios oficiais Debian 13 (Trixie) — configurado pelo gateway
# NOTA: trixie-updates não existe ainda (Trixie ainda é testing)
deb http://deb.debian.org/debian trixie main contrib non-free non-free-firmware
deb http://security.debian.org/debian-security trixie-security main contrib non-free non-free-firmware
EOF
        ok "Repositórios configurados em /etc/apt/sources.list (clássico)"
    fi
else
    ok "Repositórios APT já configurados ($_VALID_REPOS entradas válidas) — mantendo."
fi

# Garantir resolv.conf funcional antes do apt-get update
log "Verificando resolv.conf antes do apt-get update..."
if [ -L /etc/resolv.conf ] || [ ! -s /etc/resolv.conf ]; then
    warn "resolv.conf ausente ou symlink — recriando com DNS públicos para apt..."
    rm -f /etc/resolv.conf
    printf 'nameserver 8.8.8.8\nnameserver 8.8.4.4\nnameserver 1.1.1.1\n' > /etc/resolv.conf
elif grep -q '127\.0\.0\.' /etc/resolv.conf 2>/dev/null && \
     ! systemctl is-active --quiet systemd-resolved 2>/dev/null; then
    warn "resolv.conf aponta para loopback mas resolved está parado — corrigindo..."
    printf 'nameserver 8.8.8.8\nnameserver 8.8.4.4\nnameserver 1.1.1.1\n' > /etc/resolv.conf
fi
ok "resolv.conf pronto para apt: $(head -1 /etc/resolv.conf)"


if ! command -v ifup &>/dev/null; then
    log "Instalando ifupdown (pré-requisito de rede)..."
    apt-get install -y -q ifupdown2 2>/dev/null || apt-get install -y -q ifupdown 2>/dev/null || true
fi

log "Atualizando repositórios e pacotes do sistema..."
export DEBIAN_FRONTEND=noninteractive


APT_UPDATE_OK=false
for _apt_try in 1 2 3; do
    if apt-get update -q 2>&1 | tee /tmp/apt-update.log; then
        APT_UPDATE_OK=true
        break
    fi
    warn "apt-get update falhou (tentativa ${_apt_try}/3). Aguardando 5s..."
    cat /tmp/apt-update.log | grep -i 'err\|fail\|could not' | head -5 || true
    sleep 5
done
if [ "$APT_UPDATE_OK" = "false" ]; then
    warn "apt-get update não concluiu após 3 tentativas."
    warn "Verifique conectividade e repositórios. Continuando com cache existente..."
fi

apt-get dist-upgrade -y -q -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" || \
    warn "dist-upgrade retornou erro (pode ser inofensivo). Continuando..."


DEBIAN_VER=$(. /etc/os-release; echo "${VERSION_ID:-12}")
PAM_DEV_PKG="libpam0g-dev"
[ "${DEBIAN_VER}" -ge 13 ] 2>/dev/null && PAM_DEV_PKG="libpam-dev"


log "Instalando pacotes base do gateway..."
apt-get install -y -q \
    -o Dpkg::Options::="--force-confdef" \
    -o Dpkg::Options::="--force-confold" \
    nftables chrony bind9 bind9utils curl wget \
    gnupg udev cron sudo psmisc iproute2 iputils-ping conntrack logrotate \
    python3 python3-venv python3-full \
    libpam-runtime "${PAM_DEV_PKG}" openssl ssl-cert ipcalc \
    ifupdown2 2>/dev/null || \
apt-get install -y -q \
    -o Dpkg::Options::="--force-confdef" \
    -o Dpkg::Options::="--force-confold" \
    nftables chrony bind9 bind9utils curl wget \
    gnupg udev cron sudo psmisc iproute2 iputils-ping conntrack logrotate \
    python3 python3-venv python3-full \
    libpam-runtime libpam0g-dev openssl ssl-cert ipcalc \
    ifupdown || \
    err "Falha crítica ao instalar pacotes base. Verifique apt-get update e conectividade."

# --- Instalação do Squid com suporte a SSL Bump ---
# No Debian 12+, squid-openssl foi removido. O pacote 'squid' padrão pode não
# ter SSL Bump compilado. Detectamos a versão disponível e instalamos a correta.
log "Verificando suporte a SSL Bump no Squid disponível nos repositórios..."
SQUID_NO_SSL=false
if apt-cache show squid-openssl &>/dev/null 2>&1; then
    apt-get install -y -q squid-openssl
    ok "Instalado: squid-openssl (com SSL Bump nativo)."
else
    apt-get install -y -q squid
    # Squid 6.x (Debian 13) usa --with-openssl na saída de squid -v
    # Também verificar presença do helper ssl_crtd/security_file_certgen
    if squid -v 2>&1 | grep -qi 'with-openssl\|enable-ssl\|ssl' || \
       [ -f /usr/lib/squid/security_file_certgen ] || \
       [ -f /usr/lib/squid/ssl_crtd ]; then
        ok "Squid instalado com suporte SSL nativo (Squid 6.x / Debian 13)."
    else
        warn "Squid instalado SEM suporte a SSL Bump neste repositório."
        warn "Inspeção HTTPS (SSL Bump) será desabilitada automaticamente."
        SQUID_NO_SSL=true
    fi
fi

# ==============================================================================
# 3. OTIMIZAÇÕES DE KERNEL (SYSCTL)
# ==============================================================================
log "Otimizando parâmetros de rede e ativando IP Forwarding..."
cat <<EOF > /etc/sysctl.d/99-gateway.conf
net.ipv4.ip_forward=1
net.ipv4.conf.all.forwarding=1
net.ipv4.conf.all.accept_redirects=0
# send_redirects desabilitado só na WAN — desabilitar em 'all' quebra roteamento LAN
net.ipv4.conf.all.send_redirects=0
net.ipv4.conf.${WAN_IF}.send_redirects=0
net.ipv4.conf.${LAN_IF}.send_redirects=1
net.ipv4.conf.default.rp_filter=2
net.ipv4.conf.all.rp_filter=2
net.ipv4.tcp_max_syn_backlog=8192
net.ipv4.tcp_fin_timeout=15
net.ipv4.tcp_tw_reuse=1
net.core.rmem_max=16777216
net.core.wmem_max=16777216
net.core.netdev_max_backlog=5000
net.netfilter.nf_conntrack_max=131072
net.netfilter.nf_conntrack_tcp_timeout_established=3600
fs.file-max=2097152
EOF

modprobe nf_conntrack 2>/dev/null || true
sysctl --system -q 2>/dev/null || sysctl --system
ok "Parâmetros de kernel aplicados."

# ==============================================================================
# 4. CONFIGURAÇÃO DO CHRONY (NTP)
# ==============================================================================
# Configurar alias de monitoramento se solicitado
if [ "${MON_ENABLED:-0}" = "1" ]; then
    log "Configurando alias de monitoramento (${MON_IP}/24 em ${LAN_IF})..."
    ip addr add ${MON_IP}/24 dev "$LAN_IF" label "${LAN_IF}:mon" 2>/dev/null || \
        warn "Alias ja existe ou erro — verifique: ip addr show $LAN_IF"
    # Garantir rota da rede de monitoramento via interface LAN
    ip route add 192.168.1.0/24 dev "$LAN_IF" src ${MON_IP} 2>/dev/null || true
    # Habilitar ip_forward também para a interface de alias
    echo 1 > /proc/sys/net/ipv4/conf/${LAN_IF}/proxy_arp 2>/dev/null || true
    # Persistir alias de monitoramento conforme gerenciador de rede ativo
    if [ "$NET_MANAGER" = "systemd-networkd" ]; then
        mkdir -p /etc/systemd/network
        cat <<MONEOF > /etc/systemd/network/20-gateway-mon.network
[Match]
Name=${LAN_IF}

[Network]
Address=${MON_IP}/24
MONEOF
    else
        mkdir -p /etc/network/interfaces.d/
        cat <<MONEOF > /etc/network/interfaces.d/gateway-mon
auto ${LAN_IF}:mon
iface ${LAN_IF}:mon inet static
    address ${MON_IP}
    netmask 255.255.255.0
    post-up ip route add 192.168.1.0/24 dev ${LAN_IF} src ${MON_IP} 2>/dev/null || true
MONEOF
    fi
    ok "Alias de monitoramento: ${MON_IP}/24 em ${LAN_IF}:mon"
    # Ativar proxy_arp para que o gateway responda por IPs da rede de monitoramento
    # Isso permite que dispositivos na LAN 192.168.0.x cheguem a 192.168.1.x
    echo 1 > /proc/sys/net/ipv4/conf/all/proxy_arp 2>/dev/null || true
    echo 1 > /proc/sys/net/ipv4/conf/${LAN_IF}/proxy_arp 2>/dev/null || true
    # Persistir proxy_arp via sysctl
    grep -q 'proxy_arp' /etc/sysctl.d/99-gateway.conf 2>/dev/null || \
        printf 'net.ipv4.conf.all.proxy_arp=1\nnet.ipv4.conf.%s.proxy_arp=1\n' "$LAN_IF" \
        >> /etc/sysctl.d/99-gateway.conf
fi

log "Configurando servidor NTP (Chrony)..."
cat <<EOF > /etc/chrony/chrony.conf
# Servidor NTP interno — preferencial (resolução via DNS 10.14.8.20)
# IMPORTANTE: este servidor só é alcançável pelo DNS interno 10.14.8.20
server 10.14.8.20 iburst prefer minpoll 4 maxpoll 6

# Servidores NTP públicos — fallback caso o interno esteja indisponível
pool pool.ntp.br    iburst
pool a.ntp.br       iburst
server time.cloudflare.com iburst

driftfile /var/lib/chrony/drift
makestep 1.0 3
rtcsync
allow ${LAN_NET}
allow 192.168.1.0/24
EOF
# Debian 13: chrony.service pode ser symlink — usar --force no enable
# e detectar nome real via systemctl status antes de operar
CHRONY_SVC="chrony"
if systemctl cat chronyd.service &>/dev/null 2>&1; then
    CHRONY_SVC="chronyd"
fi
# --force: permite enable em unit files que são symlinks (Debian 13)
systemctl enable --force "$CHRONY_SVC" 2>/dev/null || \
    systemctl enable "$CHRONY_SVC" 2>/dev/null || true
systemctl restart "$CHRONY_SVC" 2>/dev/null || \
    systemctl start  "$CHRONY_SVC" 2>/dev/null || \
    warn "Chrony não iniciou — verifique: systemctl status $CHRONY_SVC"
ok "Chrony configurado."

# ==============================================================================
# 5. CONFIGURAÇÃO DO BIND9 (DNS CACHE + FORWARDER)
# ==============================================================================
log "Configurando servidor DNS (BIND9)..."


LAN_REV_ZONE=$(echo "$LAN_IP" | awk -F. '{print $3"."$2"."$1}')
LAN_REV_FILE="db.$(echo "$LAN_IP" | awk -F. '{print $1"."$2"."$3}')"
LAN_HOST_OCTET=$(echo "$LAN_IP" | awk -F. '{print $4}')

# Debian 13 físico: systemd-resolved ativo por padrão (usa stub 127.0.0.53)
# BIND9 precisa da porta 53 livre — desativar resolved e configurar resolv.conf
if systemctl is-active --quiet systemd-resolved 2>/dev/null; then
    warn "systemd-resolved ativo. Desativando para liberar porta 53 para BIND9..."
    systemctl disable --now systemd-resolved 2>/dev/null || true
fi
# /etc/resolv.conf pode ser symlink para resolved stub — remover e recriar
if [ -L /etc/resolv.conf ] || [ ! -f /etc/resolv.conf ]; then
    rm -f /etc/resolv.conf
    echo "nameserver 127.0.0.1"  > /etc/resolv.conf
    echo "nameserver 10.14.8.20" >> /etc/resolv.conf
    echo "nameserver 10.14.8.16" >> /etc/resolv.conf
    echo "nameserver 10.1.6.222" >> /etc/resolv.conf
fi
# Garantir que resolved não reinicie (pode ser ativado por socket)
systemctl mask systemd-resolved 2>/dev/null || true

cat <<EOF > /etc/bind/named.conf.options
// ACLs — definidas aqui para ficarem disponíveis globalmente
acl "rede_lan"  { 127.0.0.1; ${LAN_NET}; 192.168.1.0/24; };
acl "rede_wan"  { 10.14.29.0/24; };
acl "rede_all"  { 127.0.0.1; ${LAN_NET}; 192.168.1.0/24; 10.14.29.0/24; };

options {
    directory "/var/cache/bind";

    // Forwarders corporativos — consultados em paralelo pelo BIND9
    // 10.14.8.20 e 10.1.6.222: DNS corporativos internos (sites que só resolvem em um deles)
    // forward first: tenta forwarders; se todos falharem, resolve via raiz (fallback seguro)
    forwarders {
        10.14.8.20;   // DNS corporativo primário
        10.1.6.222;   // DNS corporativo secundário
        10.14.8.16;   // DNS corporativo terciário
    };
    forward first;

    // Timeout e tentativas — garante que ambos os DNS sejam consultados rapidamente
    // Se o primário não responder em ~1s, o BIND tenta o próximo em paralelo
    resolver-query-timeout 10000;  // 10 segundos total por query

    recursion yes;
    allow-recursion  { rede_all; };
    allow-query      { rede_all; };
    allow-transfer   { none; };
    listen-on { 127.0.0.1; $LAN_IP; 192.168.1.1; };
    listen-on-v6 { none; };
    version "none"; hostname "none"; server-id none;
    allow-query-cache { rede_all; };
    dnssec-validation no;
    max-cache-size 128m;
    max-ncache-ttl 60;
    lame-ttl 0;
};
EOF

# Neutralizar arquivos de zona global — conflitam com views
cat <<'EOF' > /etc/bind/named.conf.root-hints
// Root hints neutralizado — zona "." declarada dentro de cada view em named.conf.local
// (BIND9 exige que todas as zonas estejam em views quando se usa view statements)
EOF


if [ -f /etc/bind/named.conf.default-zones ]; then
    cat <<'EOF' > /etc/bind/named.conf.default-zones
// Default zones neutralizadas — localhost e zonas locais declaradas dentro de cada view
// em named.conf.local para compatibilidade com view statements.
EOF
fi

# named.conf.local — views: wan_view e lan_view
cat <<EOF > /etc/bind/named.conf.local
// =============================================================================
// View WAN: rede 10.14.29.0/24 — forwarders exclusivos internos
// =============================================================================
view "wan_view" {
    match-clients { rede_wan; };
    recursion yes;
    forwarders { 10.14.8.20; 10.1.6.222; 10.14.8.16; };
    forward first;
    allow-query { rede_wan; };
    allow-query-cache { rede_wan; };

    zone "." { type hint; file "/usr/share/dns/root.hints"; };
};

// View LAN
view "lan_view" {
    match-clients { rede_lan; };
    recursion yes;
    // Consulta ambos os DNS corporativos — cada um resolve domínios diferentes
    // BIND9 tenta todos em paralelo; se nenhum resolver, usa recursão própria
    forwarders { 10.14.8.20; 10.1.6.222; 10.14.8.16; };
    forward first;
    allow-query { rede_lan; };
    allow-query-cache { rede_lan; };

    zone "." { type hint; file "/usr/share/dns/root.hints"; };

    // Zonas localhost
    zone "localhost" {
        type master;
        file "/etc/bind/db.local";
    };
    zone "127.in-addr.arpa" {
        type master;
        file "/etc/bind/db.127";
    };
    zone "0.in-addr.arpa" {
        type master;
        file "/etc/bind/db.0";
    };
    zone "255.in-addr.arpa" {
        type master;
        file "/etc/bind/db.255";
    };

    // Zona reversa da LAN
    zone "${LAN_REV_ZONE}.in-addr.arpa" {
        type master;
        file "/etc/bind/zones/db.${LAN_REV_ZONE}";
        allow-query { rede_lan; };
    };

    // Zona WPAD — autodetecção do proxy pelos clientes
    zone "wpad.lan" {
        type master;
        file "/etc/bind/zones/db.wpad.lan";
        allow-query { rede_lan; };
    };

    // Zona CDPNI — resolve cdpni.local para o servidor Samba (192.168.0.11)
    // Permite que os clientes acessem https://cdpni.local sem conhecer o IP
    zone "cdpni.local" {
        type master;
        file "/etc/bind/zones/db.cdpni.local";
        allow-query { rede_lan; };
    };

    // Servidor de Backup (192.168.0.12) — reservado para uso futuro
    zone "backup.local" {
        type master;
        file "/etc/bind/zones/db.backup.local";
        allow-query { rede_lan; };
    };

    // Servidor futuro 192.168.0.13
    zone "srv13.local" {
        type master;
        file "/etc/bind/zones/db.srv13.local";
        allow-query { rede_lan; };
    };

    // Servidor futuro 192.168.0.14
    zone "srv14.local" {
        type master;
        file "/etc/bind/zones/db.srv14.local";
        allow-query { rede_lan; };
    };

    // Zonas NCSI — redireciona detectores de internet (Windows/Android/Apple)
    // para o gateway local, evitando falso "sem internet" no ícone de rede.
    zone "msftconnecttest.com" {
        type master;
        file "/etc/bind/zones/db.ncsi";
        allow-query { rede_lan; };
    };
    zone "msftncsi.com" {
        type master;
        file "/etc/bind/zones/db.ncsi";
        allow-query { rede_lan; };
    };
    zone "connectivitycheck.gstatic.com" {
        type master;
        file "/etc/bind/zones/db.ncsi";
        allow-query { rede_lan; };
    };
};
EOF

mkdir -p /etc/bind/zones
cat <<EOF > /etc/bind/zones/${LAN_REV_FILE}
\$TTL    300
@       IN  SOA gateway.lan. root.gateway.lan. (
                  $(date +%Y%m%d01)
                  3600 1800 604800 300 )
@       IN  NS  gateway.lan.
${LAN_HOST_OCTET}       IN  PTR gateway.lan.
EOF

cat <<EOF > /etc/bind/zones/db.wpad.lan
\$TTL    300
@       IN  SOA gateway.lan. root.gateway.lan. (
                  $(date +%Y%m%d01) 3600 1800 604800 300 )
@       IN  NS  gateway.lan.
@       IN  A   ${LAN_IP}
wpad    IN  A   ${LAN_IP}
EOF

# Zona NCSI: aponta todos os subdomínios para o gateway
cat <<EOF > /etc/bind/zones/db.ncsi
\$TTL    60
@       IN  SOA gateway.lan. root.gateway.lan. (
                  $(date +%Y%m%d01) 3600 1800 604800 60 )
@       IN  NS  gateway.lan.
@       IN  A   ${LAN_IP}
*       IN  A   ${LAN_IP}
EOF

# Zona CDPNI: resolve cdpni.local → servidor Samba (192.168.0.11)
cat <<'EOF' > /etc/bind/zones/db.cdpni.local
$TTL    300
@       IN  SOA gateway.lan. root.gateway.lan. (
                  2026052201 3600 1800 604800 300 )
@       IN  NS  gateway.lan.
@       IN  A   192.168.0.11
*       IN  A   192.168.0.11
cdpni   IN  A   192.168.0.11
EOF

# Zona backup.local → 192.168.0.12 (servidor de backup)
cat <<'EOF' > /etc/bind/zones/db.backup.local
$TTL    300
@       IN  SOA gateway.lan. root.gateway.lan. (
                  2026052201 3600 1800 604800 300 )
@       IN  NS  gateway.lan.
@       IN  A   192.168.0.12
*       IN  A   192.168.0.12
backup  IN  A   192.168.0.12
EOF

# Zona srv13.local → 192.168.0.13 (servidor futuro)
cat <<'EOF' > /etc/bind/zones/db.srv13.local
$TTL    300
@       IN  SOA gateway.lan. root.gateway.lan. (
                  2026052201 3600 1800 604800 300 )
@       IN  NS  gateway.lan.
@       IN  A   192.168.0.13
*       IN  A   192.168.0.13
srv13   IN  A   192.168.0.13
EOF

# Zona srv14.local → 192.168.0.14 (servidor futuro)
cat <<'EOF' > /etc/bind/zones/db.srv14.local
$TTL    300
@       IN  SOA gateway.lan. root.gateway.lan. (
                  2026052201 3600 1800 604800 300 )
@       IN  NS  gateway.lan.
@       IN  A   192.168.0.14
*       IN  A   192.168.0.14
srv14   IN  A   192.168.0.14
EOF

chown -R bind:bind /etc/bind/zones
named-checkconf /etc/bind/named.conf 2>&1 | grep -v "^$" || true
named-checkconf /etc/bind/named.conf || err "Erro de sintaxe no named.conf."
# Debian 13: BIND9 pode usar 'named' ou 'bind9' como nome de serviço
NAMED_SVC="named"
systemctl list-unit-files 2>/dev/null | grep -q "^bind9.service" && NAMED_SVC="bind9"
systemctl enable --force "$NAMED_SVC" 2>/dev/null || \
    systemctl enable "$NAMED_SVC" 2>/dev/null || true
systemctl restart "$NAMED_SVC"
ok "BIND9 configurado (cache+forwarder, escutando em $LAN_IP:53)."

# Atualizar systemd-networkd com DNS internos agora que BIND9 está rodando
if [ "$NET_MANAGER" = "systemd-networkd" ]; then
    log "Atualizando systemd-networkd com DNS internos (BIND9 ativo)..."
    if [ "$WAN_MODE" = "dhcp" ]; then
        sed -i '/^DNS=/d' /etc/systemd/network/10-gateway-wan.network 2>/dev/null || true
        printf 'DNS=127.0.0.1\nDNS=10.14.8.20\nDNS=10.14.8.16\n' >> /etc/systemd/network/10-gateway-wan.network
    else
        sed -i '/^DNS=/d' /etc/systemd/network/10-gateway-wan.network 2>/dev/null || true
        printf 'DNS=127.0.0.1\nDNS=10.14.8.20\nDNS=10.14.8.16\n' >> /etc/systemd/network/10-gateway-wan.network
    fi
    systemctl restart systemd-networkd 2>/dev/null || true
fi

# ==============================================================================
# 6. ESTRUTURA DE DIRETÓRIOS E LISTAS DO PROXY SQUID
# ==============================================================================
log "Estruturando arquivos de políticas e ACLs do Squid..."
mkdir -p /etc/squid/

for f in ips_totais.txt ips_parciais.txt ips_bloqueados.txt \
          ips_excecao_horario.txt sites_liberados.txt sites_bloqueados.txt; do
    [ -f "/etc/squid/$f" ] || touch "/etc/squid/$f"
done

# --- Sites do governo (sempre liberados para toda a rede) ---
cat <<'EOF' > /etc/squid/sites_governo.txt
# Sites de governo e OAB - sempre liberados (inclusive para IPs bloqueados)
# .gov.br cobre todos os subdominos *.gov.br - nao repetir subdominos
.gov.br
.sp.br
.oab.org.br
.oabsp.org.br
.cfm.org.br
.tse.jus.br
.tre.jus.br
.stf.jus.br
.stj.jus.br
.tjsp.jus.br
.senado.leg.br
.camara.leg.br
EOF

# --- Sites de bancos (sempre liberados, inclusive para IPs bloqueados) ---
cat <<'EOF' > /etc/squid/sites_bancos.txt
# Bancos e instituições financeiras — liberados inclusive para IPs bloqueados
.bancodobrasil.com.br
.bb.com.br
.itau.com.br
.itaupersonnalite.com.br
.bradesco.com.br
.santander.com.br
.caixa.gov.br
.cef.com.br
.nubank.com.br
.nu.com.br
.inter.co
.bancointer.com.br
.sicoob.com.br
.sicredi.com.br
.safra.com.br
.votorantim.com.br
.btgpactual.com
.btg.com.br
.xpi.com.br
.rico.com.vc
.clear.com.br
.bnb.gov.br
.bndes.gov.br
.banrisul.com.br
.citibank.com.br
.hsbc.com.br
.banese.com.br
.banpara.b.br
.original.com.br
.c6bank.com.br
.pagbank.com.br
.pagseguro.uol.com.br
.mercadopago.com.br
.picpay.com
.stone.com.br
.getnet.com.br
.rede.com.br
.cielo.com.br
.febraban.org.br
.bcb.gov.br
.bvmf.bmfbovespa.com.br
.b3.com.br
EOF

# --- Microsoft Teams e comunicacao corporativa Microsoft ---
# IMPORTANTE: sem subdomínios redundantes (Squid 6 rejeita sobreposições).
# Regra: se .dominio.com ja esta na lista, NAO adicionar .sub.dominio.com
cat <<'EOF' > /etc/squid/sites_teams.txt
# Microsoft Teams - video chamada e chat - liberado para TODOS
# (subdomínios cobertos automaticamente pelas entradas pai)
.microsoft.com
.microsoftteams.com
.microsoftonline.com
.microsoftonline-p.com
.office.com
.office.net
.office365.com
.outlook.com
.officeapps.live.com
.sharepoint.com
.sharepointonline.com
.onedrive.com
.skype.com
.skypeassets.com
.sfbassets.com
.lync.com
.lync.net
.trouter.io
.teams.live.com
.1drv.com
.msecnd.net
.msftidentity.com
.msidentity.com
.msedge.net
.azure.com
.akamaized.net
EOF

# --- Streaming e redes sociais ---
cat <<'EOF' > /etc/squid/streaming_redes.txt
.netflix.com
.nflxvideo.net
.nflximg.com
.youtube.com
.googlevideo.com
.ytimg.com
.ggpht.com
.facebook.com
.fbcdn.net
.instagram.com
.cdninstagram.com
.tiktok.com
.tiktokv.com
.byteoversea.com
.twitter.com
.x.com
.twimg.com
.twitch.tv
.twitchsvc.net
.amazon.com.br
.primevideo.com
.spotify.com
.scdn.co
.globo.com
.disney.com
.disneyplus.com
.hbo.com
.max.com
.paramount.com
.paramountplus.com
EOF

ok "Listas do Squid estruturadas (gov, bancos, teams, streaming)."


# ==============================================================================
# Variáveis de CA (definidas aqui pois são usadas no squid.conf independente do SSL Bump)
CA_DIR="/etc/squid/ssl_cert"
CA_KEY="$CA_DIR/gateway-ca.key"
CA_CERT="$CA_DIR/gateway-ca.crt"
CA_DER="$CA_DIR/gateway-ca.der"
SSL_DB="/var/lib/squid/ssl_db"

if [ "$SQUID_NO_SSL" = "false" ]; then
    # 6b. GERAÇÃO DA CA PRIVADA DO GATEWAY (SSL Bump / HTTPS Inspection)
    # ==============================================================================
    log "Gerando Autoridade Certificadora (CA) privada do Gateway..."

    mkdir -p "$CA_DIR"
    chmod 700 "$CA_DIR"

    # Gerar CA somente se não existir (preserva reinstalações)
    if [ ! -f "$CA_KEY" ] || [ ! -f "$CA_CERT" ]; then
        log "Criando chave e certificado da CA..."
        openssl req -new -newkey rsa:4096 -sha256 -days 3650 -nodes \
            -x509 -extensions v3_ca \
            -keyout "$CA_KEY" \
            -out   "$CA_CERT" \
            -subj  "/C=BR/ST=SP/O=Gateway Local/CN=Gateway CA/emailAddress=admin@gateway.lan" \
            2>/dev/null
        ok "CA gerada: $CA_CERT (validade 10 anos)"
    else
        warn "CA já existe em $CA_DIR — reutilizando (sem regenerar)."
    fi

    # Versão DER para download pelo cliente
    openssl x509 -in "$CA_CERT" -outform DER -out "$CA_DER"

    # Instalar a CA no sistema (trust store do Debian)
    cp "$CA_CERT" /usr/local/share/ca-certificates/gateway-ca.crt
    update-ca-certificates --fresh -q 2>/dev/null || true

    chown -R proxy:proxy "$CA_DIR"
    chmod 640 "$CA_KEY" "$CA_CERT" "$CA_DER"

    # Inicializar o banco de dados de certificados do Squid (ssl_crtd)
    if [ ! -d "$SSL_DB" ]; then
        log "Inicializando banco SSL do Squid (ssl_crtd)..."
        mkdir -p /var/lib/squid
        chown proxy:proxy /var/lib/squid
        /usr/lib/squid/security_file_certgen -c -s "$SSL_DB" -M 16MB 2>/dev/null || \
        /usr/lib/squid/ssl_crtd             -c -s "$SSL_DB" -M 16MB 2>/dev/null || true
        chown -R proxy:proxy "$SSL_DB"
    fi
    ok "Banco SSL do Squid inicializado em $SSL_DB."
else
    warn "SSL Bump desabilitado — pulando geração de CA e banco SSL."
    mkdir -p "$CA_DIR" /var/lib/squid
fi

# ==============================================================================
# 7. CONFIGURAÇÃO DO SQUID
# ==============================================================================
log "Escrevendo configuração principal do Squid..."

TOTAL_RAM_MB=$(awk '/MemTotal/{printf "%d", $2/1024}' /proc/meminfo)
CACHE_MEM_MB=$(( TOTAL_RAM_MB / 4 ))
[ "$CACHE_MEM_MB" -lt 256  ] && CACHE_MEM_MB=256
[ "$CACHE_MEM_MB" -gt 2048 ] && CACHE_MEM_MB=2048

# --- IMPORTANTE: criar arquivos de include ANTES do squid.conf ---
# O Squid valida a existência dos includes ao checar a configuração.
mkdir -p /etc/squid

cat <<'ACLEOF_PRE' > /etc/squid/acl_horarios.conf
# Gerado automaticamente pelo Gateway Control Panel
# NAO edite manualmente; use o painel web.
acl horario_livre time MTWHF 07:00-08:00
acl horario_livre time MTWHF 11:00-13:00
acl horario_livre time MTWHF 17:00-18:00
acl horario_livre time MTWHF 20:00-23:00
acl horario_livre time AS    00:00-23:59
ACLEOF_PRE

cat <<'ACLEOF_PRE' > /etc/squid/acl_streaming_temp.conf
# Liberacoes temporarias de Streaming/Redes Sociais
# Nenhuma liberacao temporaria configurada.
ACLEOF_PRE

# Gerar squid.conf — seção SSL é condicional ao suporte do binário instalado
{
cat <<ACLEOF_PRE_HEADER
# ── Portas ────────────────────────────────────────────────────────────────────
# Porta normal do proxy
http_port 3128
ACLEOF_PRE_HEADER

if [ "$SQUID_NO_SSL" = "false" ]; then
cat <<ACLEOF_PRE_SSL
# SSL Bump: intercepta HTTPS, inspeciona e aplica ACLs
# Os clientes devem configurar proxy para 3128 (não é transparente)
https_port 3129 intercept ssl-bump \
    cert=${CA_DIR}/gateway-ca.crt \
    key=${CA_DIR}/gateway-ca.key \
    generate-host-certificates=on \
    dynamic_cert_mem_cache_size=16MB

# Banco de certificados gerados dinamicamente
sslcrtd_program /usr/lib/squid/security_file_certgen -s ${SSL_DB} -M 16MB
sslcrtd_children 8 startup=4 idle=2

acl step1 at_step SslBump1
acl step2 at_step SslBump2
acl step3 at_step SslBump3
# Sem bump: bancos, gov, NCSI, Samba
acl no_bump_sites ssl::server_name_regex -i \.gov\.br$ \.sp\.br$ \.jus\.br$ \.leg\.br$ \.bcb\.gov\.br$
acl no_bump_sites ssl::server_name_regex -i \.bradesco\.com\.br$ \.itau\.com\.br$ \.bb\.com\.br$ \.caixa\.gov\.br$ \.nubank\.com\.br$
acl no_bump_sites ssl::server_name_regex -i \.santander\.com\.br$ \.bancodobrasil\.com\.br$ \.sicoob\.com\.br$ \.sicredi\.com\.br$
# NCSI / detectores de conectividade — nunca fazer bump (Windows mostraria globinho sem internet)
acl no_bump_sites ssl::server_name_regex -i msftconnecttest\.com$ msftncsi\.com$ connectivitycheck\.gstatic\.com$
acl no_bump_sites ssl::server_name_regex -i connectivitycheck\.android\.com$ captive\.apple\.com$ detectportal\.firefox\.com$
acl no_bump_sites ssl::server_name_regex -i nmcheck\.gnome\.org$ clients3\.google\.com$
# Samba/CDPNI — splice SSL sem interceptação
acl no_bump_samba_ip  dst 192.168.0.11
acl no_bump_samba_ip  dst 192.168.0.12
acl no_bump_samba_ip  dst 192.168.0.13
acl no_bump_samba_ip  dst 192.168.0.14
acl no_bump_samba_dns ssl::server_name_regex -i cdpni\.local$ cdpni$

ssl_bump peek     step1
ssl_bump splice   no_bump_sites
ssl_bump splice   no_bump_samba_ip
ssl_bump splice   no_bump_samba_dns
ssl_bump bump     all
ACLEOF_PRE_SSL
fi

cat <<ACLEOF_PRE
shutdown_lifetime 10 seconds
# Squid resolve nomes usando os DNS corporativos diretamente
# (garante acesso a sites que só existem nesses DNS internos)
dns_nameservers 10.14.8.20 10.1.6.222 10.14.8.16
# Squid tenta os DNS na ordem acima; se um não resolver, tenta o próximo
dns_retransmit_interval 2 seconds
dns_timeout 30 seconds
pid_filename /run/squid/squid.pid

cache_mem ${CACHE_MEM_MB} MB
maximum_object_size_in_memory 512 KB
maximum_object_size 32 MB
cache_dir ufs /var/spool/squid 4000 16 256
coredump_dir /var/spool/squid

access_log daemon:/var/log/squid/access.log squid
cache_log /var/log/squid/cache.log
max_filedescriptors 65535

httpd_suppress_version_string on
forwarded_for delete
request_header_access X-Forwarded-For deny all

tls_outgoing_options min-version=1.2 \
    cipher=HIGH:!aNULL:!MD5:!RC4 \
    options=NO_SSLv3,NO_TLSv1,NO_TLSv1_1

# Redes
acl localnet        src ${LAN_NET}
acl monitoring_net  src 192.168.1.0/24
acl SSL_ports       port 443
acl Safe_ports      port 80 21 443 70 210 1025-65535
acl Safe_ports      port 5000 8080
acl CONNECT         method CONNECT

http_access deny !Safe_ports
http_access deny CONNECT !SSL_ports
http_access allow localhost

# Permitir acesso ao painel e WPAD do próprio gateway (evita erro de proxy no browser)
acl gateway_self dst ${LAN_IP}/32
acl gateway_ports port 5000 8080
http_access allow gateway_self gateway_ports

http_access deny to_localhost

# Horarios livres - gerado dinamicamente pelo painel
include /etc/squid/acl_horarios.conf

# Listas de sites
acl sites_governo       dstdomain "/etc/squid/sites_governo.txt"
acl sites_bancos        dstdomain "/etc/squid/sites_bancos.txt"
acl sites_teams         dstdomain "/etc/squid/sites_teams.txt"
acl sites_liberados     dstdomain "/etc/squid/sites_liberados.txt"
acl sites_bloqueados    dstdomain "/etc/squid/sites_bloqueados.txt"
acl streaming_redes     dstdomain "/etc/squid/streaming_redes.txt"
# Bloquear streaming via HTTPS (SNI) mesmo sem SSL bump completo
acl streaming_redes_ssl ssl::server_name_regex -i     youtube\.com googlevideo\.com ytimg\.com     netflix\.com nflxvideo\.net nflximg\.com     facebook\.com fbcdn\.net instagram\.com cdninstagram\.com     tiktok\.com tiktokv\.com byteoversea\.com     twitter\.com x\.com twimg\.com     twitch\.tv twitchsvc\.net     spotify\.com scdn\.co     globo\.com primevideo\.com amazon\.com\.br

# NCSI — detectores de conectividade
acl ncsi_hosts dstdomain \
    www.msftconnecttest.com \
    ipv6.msftconnecttest.com \
    www.msftncsi.com \
    ipv6.msftncsi.com \
    connectivitycheck.gstatic.com \
    connectivitycheck.android.com \
    clients3.google.com \
    captive.apple.com \
    www.apple.com \
    detectportal.firefox.com \
    nmcheck.gnome.org

# Samba/CDPNI — sempre liberados
acl samba_server_ip  dst 192.168.0.11
acl samba_server_ip  dst 192.168.0.12
acl samba_server_ip  dst 192.168.0.13
acl samba_server_ip  dst 192.168.0.14
acl samba_server_dns dstdomain cdpni.local cdpni

# Grupos de IPs
acl ips_totais          src "/etc/squid/ips_totais.txt"
acl ips_excecao_horario src "/etc/squid/ips_excecao_horario.txt"
acl ips_parciais        src "/etc/squid/ips_parciais.txt"
acl ips_bloqueados      src "/etc/squid/ips_bloqueados.txt"

# Liberacoes temporarias de streaming - gerado pelo painel
# DEVE vir antes das regras de deny streaming_redes
include /etc/squid/acl_streaming_temp.conf

# REGRAS DE ACESSO (primeiro match vence - ordem critica)
# POLÍTICA: somente IPs listados em algum grupo podem acessar a internet.
# IPs não listados em ips_totais, ips_parciais, ips_excecao_horario ou ips_bloqueados
# são negados na regra final. A rede de monitoramento 192.168.1.0/24 tem acesso irrestrito.

# 0. NCSI / detectores de internet — SEMPRE liberados para TODOS (inclusive bloqueados)
#    Sem isso o Windows/Android/iOS mostra "sem internet" mesmo com proxy funcionando.
http_access allow ncsi_hosts

# 0b. Servidor Samba/CDPNI — sempre liberado (acesso à rede de arquivos interna)
http_access allow samba_server_ip
http_access allow samba_server_dns

# 1. IPs BLOQUEADOS - acesso restrito: governo, bancos, OAB, liberados e Teams
http_access allow ips_bloqueados sites_governo
http_access allow ips_bloqueados sites_bancos
http_access allow ips_bloqueados sites_liberados
http_access allow ips_bloqueados sites_teams
# Garantir que bloqueados nunca acessam streaming (HTTP ou HTTPS)
http_access deny  ips_bloqueados streaming_redes
http_access deny  ips_bloqueados streaming_redes_ssl
http_access deny  ips_bloqueados

# 2. Microsoft Teams - liberado para TODOS os grupos listados (video + chat)
http_access allow sites_teams ips_totais
http_access allow sites_teams ips_parciais
http_access allow sites_teams ips_excecao_horario

# 3. Sites do governo, bancos e sites liberados - SEMPRE acessiveis para grupos listados
http_access allow sites_governo ips_totais
http_access allow sites_governo ips_parciais
http_access allow sites_governo ips_excecao_horario
http_access allow sites_bancos  ips_totais
http_access allow sites_bancos  ips_parciais
http_access allow sites_bancos  ips_excecao_horario
http_access allow sites_liberados ips_totais
http_access allow sites_liberados ips_parciais
http_access allow sites_liberados ips_excecao_horario

# 4. Rede de monitoramento 192.168.1.0/24 - acesso IRRESTRITO
http_access allow monitoring_net

# 5. IPs totais - acesso IRRESTRITO
http_access allow ips_totais

# 6. IPs excecao de horario - acesso amplo sem streaming
http_access deny  sites_bloqueados ips_excecao_horario
http_access allow ips_excecao_horario

# 7. IPs parciais: streaming liberado no horário livre, bloqueado fora

# 7a. LIBERAR streaming durante horário livre
http_access allow streaming_redes     ips_parciais horario_livre
http_access allow streaming_redes_ssl ips_parciais horario_livre

# 7b. BLOQUEAR streaming FORA do horário livre para ips_parciais
http_access deny  streaming_redes     ips_parciais
http_access deny  streaming_redes_ssl ips_parciais

# 8. Durante horario livre - ips_parciais (exceto sites_bloqueados)
http_access deny  sites_bloqueados ips_parciais
http_access allow ips_parciais horario_livre

# 9. Fora do horario - ips_parciais: acesso geral sem streaming (ja bloqueado acima)
http_access allow ips_parciais

# 10. DENY GERAL: IPs não listados em nenhum grupo NÃO acessam a internet.
#     Apenas ips_totais, ips_parciais, ips_excecao_horario, ips_bloqueados e
#     monitoring_net têm acesso. Qualquer outro IP é negado aqui.
http_access deny all
ACLEOF_PRE
} > /etc/squid/squid.conf

# --- JSON de horários e streaming (painel) ---

cat <<'JSONEOF' > /etc/squid/horarios_livres.json
[
  {"id": "1", "label": "Manhã · Dias úteis",  "days": "MTWHF", "start": "07:00", "end": "08:00"},
  {"id": "2", "label": "Almoço · Dias úteis", "days": "MTWHF", "start": "11:00", "end": "13:00"},
  {"id": "3", "label": "Tarde · Dias úteis",  "days": "MTWHF", "start": "17:00", "end": "18:00"},
  {"id": "4", "label": "Noite · Dias úteis",  "days": "MTWHF", "start": "20:00", "end": "23:00"},
  {"id": "5", "label": "Fim de semana",        "days": "AS",    "start": "00:00", "end": "23:59"}
]
JSONEOF

cat <<'JSONEOF' > /etc/squid/streaming_temp.json
[]
JSONEOF

# --- Permissoes dos diretorios de log, cache e runtime ---
mkdir -p /var/log/squid /var/spool/squid /run/squid
chown -R proxy:proxy /var/log/squid /var/spool/squid /run/squid
chmod 750 /var/log/squid /var/spool/squid
chmod 755 /run/squid

# Garantir que /run/squid persiste apos reboot (tmpfiles.d)
cat <<'EOF' > /etc/tmpfiles.d/squid.conf
d /run/squid 0755 proxy proxy -
EOF
systemd-tmpfiles --create /etc/tmpfiles.d/squid.conf 2>/dev/null || true
mkdir -p /run/squid
chown proxy:proxy /run/squid
chmod 755 /run/squid


# --- Detectar nome do serviço Squid (antes de qualquer operação) ---
SQUID_SVC="squid"
if systemctl list-unit-files 2>/dev/null | grep -q "^squid6.service"; then
    SQUID_SVC="squid6"
fi

# --- Detectar binário do Squid (DEVE ser antes de squid -k parse e squid -z) ---
SQUID_BIN=$(command -v squid 2>/dev/null || echo "/usr/sbin/squid")

# --- Validar configuração do squid.conf ---
# squid -k parse valida a configuração sem precisar do processo rodando
log "Validando configuração do Squid (squid -k parse)..."
SQUID_PARSE=$("${SQUID_BIN:-squid}" -k parse 2>&1) || true
SQUID_REAL_ERRORS=$(echo "$SQUID_PARSE" \
    | grep -iE '^(FATAL|ERROR)' \
    | grep -ivE 'obsolete|deprecated|DONT_VERIFY_PEER|UPGRADE|Warning') || true
if [ -n "$SQUID_REAL_ERRORS" ]; then
    warn "Saída completa do squid -k parse:"
    echo "$SQUID_PARSE"
    err "Erros reais de configuração do Squid detectados. Corrija antes de continuar."
fi
ok "squid.conf validado com sucesso (avisos de ACLs vazias são normais na instalação inicial)."

# --- Inicializar estrutura de cache ---
if [ ! -d /var/spool/squid/00 ]; then
    log "Inicializando estrutura de cache do Squid..."
    mkdir -p /run/squid && chown proxy:proxy /run/squid
    "${SQUID_BIN:-squid}" -z 2>&1 | tee /tmp/squid-init.log || true
    grep -i 'fatal' /tmp/squid-init.log && warn "Aviso durante squid -z (pode ser inofensivo)" || true
    sleep 3
else
    log "Estrutura de cache do Squid já existe — pulando squid -z."
fi

# --- Iniciar o serviço ---
systemctl enable --force "$SQUID_SVC" 2>/dev/null || systemctl enable "$SQUID_SVC" 2>/dev/null || true
if ! systemctl restart "$SQUID_SVC"; then
    warn "Squid falhou ao iniciar. Diagnóstico:"
    journalctl -xeu "${SQUID_SVC}.service" --no-pager -n 50 || true
    squid -k parse 2>&1 || true
    err "Squid não iniciou. Veja o diagnóstico acima."
fi
[ "$SQUID_NO_SSL" = "true" ] && SQUID_SSL_STATUS="DESABILITADO (sem suporte no binário)" || SQUID_SSL_STATUS="ATIVO (SSL Bump habilitado)"
ok "Squid configurado e iniciado (cache_mem: ${CACHE_MEM_MB} MB, SSL: ${SQUID_SSL_STATUS})."

# ==============================================================================
# 8. CONFIGURAÇÃO DO FIREWALL NFTABLES
# ==============================================================================
log "Criando estrutura do firewall nftables..."
mkdir -p /etc/nftables

[ -f /etc/nftables/nat_1to1.txt ] || cat <<'EOF' > /etc/nftables/nat_1to1.txt
# Mapeamento NAT 1 para 1
# Formato: IP_EXTERNO:IP_INTERNO
EOF

[ -f /etc/nftables/ips_externos_liberados.txt ] || cat <<'EOF' > /etc/nftables/ips_externos_liberados.txt
# IPs externos com acesso direto à LAN (sem NAT)
EOF

# Lista de IPs da rede WAN (10.14.29.x) com acesso bidirecional às LANs internas
[ -f /etc/nftables/ips_rede_wan.txt ] || cat <<'EOF' > /etc/nftables/ips_rede_wan.txt
# IPs da rede WAN (10.14.29.0/24) com acesso bidirecional a 192.168.0.0/24 e 192.168.1.0/24
# Adicione um IP ou CIDR por linha. Exemplo:
# 10.14.29.50
# 10.14.29.100
# 10.14.29.0/24   (libera toda a sub-rede)
EOF

cat <<EOF > /etc/nftables.conf
#!/usr/sbin/nft -f

flush ruleset

table inet filter {

    set ips_externos_liberados {
        type ipv4_addr
        flags interval
    }

    # IPs da rede WAN (10.14.29.x) com acesso bidirecional às LANs internas
    set ips_rede_wan {
        type ipv4_addr
        flags interval
        elements = { 127.0.0.2 }
    }

    chain input {
        type filter hook input priority filter; policy drop;

        iifname "lo" accept
        ct state established,related accept
        ct state invalid drop

        meta nfproto ipv4 icmp type echo-request limit rate 10/second accept
        meta nfproto ipv4 icmp type echo-reply accept
        meta nfproto ipv6 icmpv6 type echo-request limit rate 10/second accept
        meta nfproto ipv6 icmpv6 type echo-reply accept

        iifname "$LAN_IF" tcp dport { 22, 80, 443, 3128, 3129, 5000, 8080 } accept
        iifname "$LAN_IF" udp dport { 53, 123 }        accept
        iifname "$LAN_IF" tcp dport 53                  accept
        iifname "$LAN_IF" icmp type echo-request        accept

        # Rede de monitoramento 192.168.1.0/24 — acesso irrestrito aos serviços do gateway
        ip saddr 192.168.1.0/24 tcp dport { 22, 80, 443, 3128, 3129, 5000, 8080 } accept
        ip saddr 192.168.1.0/24 udp dport { 53, 123 } accept
        ip saddr 192.168.1.0/24 tcp dport 53           accept
        ip saddr 192.168.1.0/24 icmp type echo-request accept

        iifname "$WAN_IF" tcp dport 22 ct state new limit rate 5/minute accept

        # Rede WAN — acesso DNS
        ip saddr 10.14.29.0/24 iifname "$WAN_IF" udp dport 53 accept
        ip saddr 10.14.29.0/24 iifname "$WAN_IF" tcp dport 53 accept
    }

    chain forward {
        type filter hook forward priority filter; policy drop;

        ct state established,related accept
        ct state invalid drop

        # ICMP forward: permite ping LAN→internet e respostas de volta
        iifname "$LAN_IF" oifname "$WAN_IF" icmp type echo-request accept
        iifname "$WAN_IF" oifname "$LAN_IF" icmp type echo-reply   accept

        # Tráfego interno LAN → LAN (sem passar pelo proxy)
        # 192.168.0.x ↔ 192.168.0.x — acesso direto dentro da rede
        ip saddr ${LAN_NET} ip daddr ${LAN_NET} accept

        # 192.168.0.x ↔ 192.168.1.x — acesso direto entre LAN e rede de monitoramento
        # (a rede 192.168.1.x pode não existir ainda; a regra é inofensiva se não existir)
        ip saddr ${LAN_NET}      ip daddr 192.168.1.0/24 accept
        ip saddr 192.168.1.0/24  ip daddr ${LAN_NET}     accept

        # LAN → internet (tráfego externo — clientes devem usar proxy 3128)
        iifname "$LAN_IF" oifname "$WAN_IF" accept
        iifname "$WAN_IF" oifname "$LAN_IF" ip saddr @ips_externos_liberados accept

        # DNS corporativo forward
        ip daddr { 10.14.8.20, 10.1.6.222, 10.14.8.16 } udp dport 53 accept
        ip daddr { 10.14.8.20, 10.1.6.222, 10.14.8.16 } tcp dport 53 accept

        # Bloquear DNS bypass
        iifname "$LAN_IF" oifname "$WAN_IF" udp dport 53 ip daddr != { 10.14.8.20, 10.1.6.222, 10.14.8.16 } drop
        iifname "$LAN_IF" oifname "$WAN_IF" tcp dport 53 ip daddr != { 10.14.8.20, 10.1.6.222, 10.14.8.16 } drop

        # Rede de monitoramento → internet
        ip saddr 192.168.1.0/24 oifname "$WAN_IF" accept

        # Tráfego bidirecional LAN e monitoramento
        iifname "$LAN_IF" ip daddr 192.168.1.0/24 accept
        ip saddr 192.168.1.0/24 iifname "$LAN_IF" accept
        ip saddr 192.168.1.0/24 ip daddr ${LAN_NET} accept
        ip daddr 192.168.1.0/24 ip saddr ${LAN_NET} accept

        # IPs rede WAN — acesso bidirecional
        ip saddr @ips_rede_wan ip daddr ${LAN_NET}        accept
        ip saddr @ips_rede_wan ip daddr 192.168.1.0/24    accept
        ip daddr @ips_rede_wan ip saddr ${LAN_NET}        accept
        ip daddr @ips_rede_wan ip saddr 192.168.1.0/24    accept

        # Rede WAN internet
        ip saddr 10.14.29.0/24 oifname "$WAN_IF" accept
        iifname "$WAN_IF" ip daddr 10.14.29.0/24 ct state established,related accept

        # ── Servidor Samba CDPNI (192.168.0.11) ─────────────────────────────
        # SMB: portas 137-138 UDP e 139,445 TCP — tráfego LAN→Samba e retorno
        ip daddr 192.168.0.11 tcp dport { 139, 445 } accept
        ip daddr 192.168.0.11 udp dport { 137, 138 } accept
        ip saddr 192.168.0.11 ct state established,related accept
        # Painel web Samba (HTTP/HTTPS)
        ip daddr 192.168.0.11 tcp dport { 80, 443 } accept
    }

    chain output {
        type filter hook output priority filter; policy accept;
        # NTP de saída para servidores internos — garantir que não seja bloqueado
        udp dport 123 accept
    }
}

table ip nat {

    set ips_com_nat1to1 {
        type ipv4_addr
        elements = { 127.0.0.2 }
    }

    chain prerouting {
        type nat hook prerouting priority dstnat; policy accept;

        # NCSI: redireciona 443→80 no gateway (Windows connectivity check)
        iifname "$LAN_IF" tcp dport 443 ip daddr ${LAN_IP} redirect to :80

        # Forçar uso dos DNS corporativos — redireciona queries DNS para 10.14.8.20
        # (clientes que apontam para outros DNS são redirecionados automaticamente)
        iifname "$LAN_IF" udp dport 53 ip daddr != { ${LAN_IP}, 10.14.8.20, 10.1.6.222, 10.14.8.16 } dnat to 10.14.8.20
        iifname "$LAN_IF" tcp dport 53 ip daddr != { ${LAN_IP}, 10.14.8.20, 10.1.6.222, 10.14.8.16 } dnat to 10.14.8.20
        ip saddr 192.168.1.0/24 udp dport 53 ip daddr != { ${LAN_IP}, 10.14.8.20, 10.1.6.222, 10.14.8.16 } dnat to 10.14.8.20
        ip saddr 192.168.1.0/24 tcp dport 53 ip daddr != { ${LAN_IP}, 10.14.8.20, 10.1.6.222, 10.14.8.16 } dnat to 10.14.8.20
    }

    chain postrouting {
        type nat hook postrouting priority srcnat; policy accept;
        oifname "$WAN_IF" ip saddr ${LAN_NET} ip saddr != @ips_com_nat1to1 masquerade
        oifname "$WAN_IF" ip saddr 192.168.1.0/24 masquerade
        # Rede WAN 10.14.29.0/24 — masquerade para saída à internet via este gateway
        oifname "$WAN_IF" ip saddr 10.14.29.0/24 masquerade
    }
}
EOF

nft -f /etc/nftables.conf
# Debian 13: garantir que iptables aponta para nftables (não legacy)
if command -v update-alternatives &>/dev/null; then
    update-alternatives --set iptables  /usr/sbin/iptables-nft  2>/dev/null || true
    update-alternatives --set ip6tables /usr/sbin/ip6tables-nft 2>/dev/null || true
fi
systemctl enable --force nftables 2>/dev/null || systemctl enable nftables 2>/dev/null || true
systemctl restart nftables
ok "nftables configurado e carregado."

# ==============================================================================
# 9. SCRIPT DE ATUALIZAÇÃO DINÂMICA NAT 1:1
# ==============================================================================
log "Criando script utilitário update-nat1to1.sh..."

cat <<'SCRIPT' > /usr/local/bin/update-nat1to1.sh
#!/bin/bash
# Não usar set -e aqui: cada bloco deve continuar mesmo se um nft falhar
set -uo pipefail

WAN_IF=$(ip -o -4 route show to default | awk '{print $5}' | head -n1)
[ -z "$WAN_IF" ] && { echo "[ERRO] WAN não detectada."; exit 1; }

LAN_NET_SAVED=$(grep '^LAN_NET=' /etc/gateway-panel.env 2>/dev/null | cut -d= -f2 || echo "192.168.0.0/24")
LAN_IP_SAVED=$(grep '^LAN_IP='  /etc/gateway-panel.env 2>/dev/null | cut -d= -f2 || echo "192.168.0.1")
LAN_IF_SAVED=$(grep '^LAN_IF='  /etc/gateway-panel.env 2>/dev/null | cut -d= -f2 || \
    ip -o link show | awk -F': ' '{print $2}' \
        | grep -v "^lo$\|^${WAN_IF}$" | head -1)

nft flush chain ip nat prerouting  2>/dev/null || true
nft flush chain ip nat postrouting 2>/dev/null || true
nft flush set   ip nat ips_com_nat1to1 2>/dev/null || true
nft flush set   inet filter ips_externos_liberados 2>/dev/null || true
nft flush set   inet filter ips_rede_wan 2>/dev/null || true

# Restaurar masquerade após flush
nft add element ip nat ips_com_nat1to1 { 127.0.0.2 } 2>/dev/null || true
nft add rule ip nat postrouting \
    oifname "$WAN_IF" \
    ip saddr "$LAN_NET_SAVED" \
    ip saddr != @ips_com_nat1to1 \
    masquerade 2>/dev/null || true
nft add rule ip nat postrouting \
    oifname "$WAN_IF" \
    ip saddr 192.168.1.0/24 \
    masquerade 2>/dev/null || true
nft add rule ip nat postrouting \
    oifname "$WAN_IF" \
    ip saddr 10.14.29.0/24 \
    masquerade 2>/dev/null || true

# Restaurar interceptação de DNS
nft add rule ip nat prerouting \
    iifname "$LAN_IF_SAVED" udp dport 53 \
    ip daddr != { "${LAN_IP_SAVED}", 10.14.8.20, 10.1.6.222, 10.14.8.16 } \
    dnat to 10.14.8.20 2>/dev/null || true
nft add rule ip nat prerouting \
    iifname "$LAN_IF_SAVED" tcp dport 53 \
    ip daddr != { "${LAN_IP_SAVED}", 10.14.8.20, 10.1.6.222, 10.14.8.16 } \
    dnat to 10.14.8.20 2>/dev/null || true
# Rede de monitoramento — mesma política
nft add rule ip nat prerouting \
    ip saddr 192.168.1.0/24 udp dport 53 \
    ip daddr != { "${LAN_IP_SAVED}", 10.14.8.20, 10.1.6.222, 10.14.8.16 } \
    dnat to 10.14.8.20 2>/dev/null || true
nft add rule ip nat prerouting \
    ip saddr 192.168.1.0/24 tcp dport 53 \
    ip daddr != { "${LAN_IP_SAVED}", 10.14.8.20, 10.1.6.222, 10.14.8.16 } \
    dnat to 10.14.8.20 2>/dev/null || true

ip -o addr show dev "$WAN_IF" | awk '$3 == "inet" && $NF ~ /^'"$WAN_IF"':nat/ {print $4}' \
    | while read -r old_addr; do
        ip addr del "$old_addr" dev "$WAN_IF" 2>/dev/null || true
    done

HAS_NAT=false
while IFS=':' read -r ip_ext ip_int || [ -n "${ip_ext:-}" ]; do
    ip_ext=$(echo "${ip_ext:-}" | xargs)
    ip_int=$(echo "${ip_int:-}" | xargs)
    [[ -z "$ip_ext" || "$ip_ext" =~ ^# ]] && continue
    if ! echo "$ip_ext" | grep -qE '^([0-9]{1,3}\.){3}[0-9]{1,3}$'; then
        echo "[!] IP externo inválido ignorado: '$ip_ext'"; continue; fi
    if ! echo "$ip_int" | grep -qE '^([0-9]{1,3}\.){3}[0-9]{1,3}$'; then
        echo "[!] IP interno inválido ignorado: '$ip_int'"; continue; fi
    HAS_NAT=true
    # Remover placeholder 127.0.0.2 antes de adicionar IPs reais
    [ "$HAS_NAT" = "true" ] && nft delete element ip nat ips_com_nat1to1 { 127.0.0.2 } 2>/dev/null || true
    ip addr add "${ip_ext}/32" dev "$WAN_IF" label "${WAN_IF}:nat" 2>/dev/null || true
    nft add element ip nat ips_com_nat1to1 { "$ip_int" } 2>/dev/null || true
    nft add rule    ip nat prerouting  ip daddr "$ip_ext" dnat to "$ip_int" 2>/dev/null || true
    nft add rule    ip nat postrouting ip saddr "$ip_int" snat to "$ip_ext" 2>/dev/null || true
done < /etc/nftables/nat_1to1.txt

HAS_EXT=false
while read -r ip_ext_lib || [ -n "${ip_ext_lib:-}" ]; do
    ip_ext_lib=$(echo "${ip_ext_lib:-}" | xargs)
    [[ -z "$ip_ext_lib" || "$ip_ext_lib" =~ ^# ]] && continue
    if ! echo "$ip_ext_lib" | grep -qE '^([0-9]{1,3}\.){3}[0-9]{1,3}(/[0-9]+)?$'; then
        echo "[!] IP/CIDR externo inválido ignorado: '$ip_ext_lib'"; continue; fi
    HAS_EXT=true
    nft add element inet filter ips_externos_liberados { "$ip_ext_lib" } 2>/dev/null || true
done < /etc/nftables/ips_externos_liberados.txt

$HAS_EXT || nft add element inet filter ips_externos_liberados { 127.0.0.2 } 2>/dev/null || true

# Carregar IPs da rede WAN com acesso bidirecional às LANs internas
HAS_WAN=false
while IFS= read -r ip_wan || [ -n "${ip_wan:-}" ]; do
    ip_wan=$(echo "${ip_wan:-}" | xargs)
    [[ -z "$ip_wan" || "$ip_wan" =~ ^# ]] && continue
    if ! echo "$ip_wan" | grep -qE '^([0-9]{1,3}\.){3}[0-9]{1,3}(/[0-9]+)?$'; then
        echo "[!] IP/CIDR WAN inválido ignorado: '$ip_wan'"; continue; fi
    HAS_WAN=true
    nft add element inet filter ips_rede_wan { "$ip_wan" } 2>/dev/null || true
done < /etc/nftables/ips_rede_wan.txt

echo "[+] Tabelas dinâmicas do nftables atualizadas com sucesso!"
SCRIPT

chmod +x /usr/local/bin/update-nat1to1.sh

# ==============================================================================
# 10. SCRIPT DE CORTE DE CONEXÕES — FIX YOUTUBE/FACEBOOK PÓS-HORÁRIO
# ==============================================================================
log "Criando scripts de controle de horário do Squid..."

cat <<'SCRIPT' > /usr/local/bin/squid-force-block.sh
#!/bin/bash
# Encerra horário livre e derruba conexões dos IPs parciais

TS=$(date '+%Y-%m-%d %H:%M:%S')
echo "[$TS] squid-force-block: encerrando horário livre"

SQUID_BIN_RT=$(command -v squid 2>/dev/null || echo /usr/sbin/squid)
SYSTEMCTL_RT=$(command -v systemctl 2>/dev/null || echo /usr/bin/systemctl)
$SQUID_BIN_RT -k reconfigure 2>/dev/null || $SYSTEMCTL_RT restart squid 2>/dev/null || true
echo "[$TS] squid-force-block: Squid reconfigurado — novas conexoes bloqueadas."

# Derrubar conexões dos IPs parciais
PARCIAIS_FILE="/etc/squid/ips_parciais.txt"
KILLED=0

if command -v conntrack &>/dev/null && [ -f "$PARCIAIS_FILE" ]; then
    while IFS= read -r linha || [ -n "${linha:-}" ]; do
        # Ignorar comentários e linhas vazias
        linha=$(echo "${linha:-}" | sed 's/#.*//' | xargs)
        [ -z "$linha" ] && continue

        conntrack -D -s "$linha" --proto tcp --orig-port-dst 443 2>/dev/null && KILLED=$((KILLED+1)) || true
        conntrack -D -s "$linha" --proto tcp --orig-port-dst 80  2>/dev/null && KILLED=$((KILLED+1)) || true
        conntrack -D --src "$linha" -p tcp --dport 443 2>/dev/null || true
        conntrack -D --src "$linha" -p tcp --dport 80  2>/dev/null || true
    done < "$PARCIAIS_FILE"
    echo "[$TS] squid-force-block: $KILLED entradas conntrack removidas para IPs parciais."
else
    if ! command -v conntrack &>/dev/null; then
        echo "[$TS] squid-force-block: conntrack indisponivel — apenas reconfigure aplicado."
        echo "[$TS] AVISO: instale conntrack para encerramento imediato: apt-get install -y conntrack"
    fi
fi


if ! command -v conntrack &>/dev/null; then
    apt-get install -y -q conntrack 2>/dev/null || true  # pacote correto no Debian 13
fi

echo "[$TS] squid-force-block: bloqueio ativo para ips_parciais."
SCRIPT
chmod +x /usr/local/bin/squid-force-block.sh

cat <<'SCRIPT' > /usr/local/bin/squid-open-schedule.sh
#!/bin/bash
TS=$(date '+%Y-%m-%d %H:%M:%S')
echo "[$TS] squid-open-schedule: início do horário livre — reconfigurando Squid..."
SQUID_BIN_RT=$(command -v squid 2>/dev/null || echo /usr/sbin/squid)
SYSTEMCTL_RT=$(command -v systemctl 2>/dev/null || echo /usr/bin/systemctl)
$SQUID_BIN_RT -k reconfigure 2>/dev/null || $SYSTEMCTL_RT restart squid 2>/dev/null || true
echo "[$TS] squid-open-schedule: ACLs atualizadas."
SCRIPT
chmod +x /usr/local/bin/squid-open-schedule.sh

cat <<EOF > /etc/cron.d/squid-schedule
# ── Gateway — Controle de horários do Squid ─────────────────────────────────
# Dias úteis — abrir horários livres
0  7 * * 1-5 root /usr/local/bin/squid-open-schedule.sh >> /var/log/squid-schedule.log 2>&1
0 11 * * 1-5 root /usr/local/bin/squid-open-schedule.sh >> /var/log/squid-schedule.log 2>&1
0 17 * * 1-5 root /usr/local/bin/squid-open-schedule.sh >> /var/log/squid-schedule.log 2>&1
0 20 * * 1-5 root /usr/local/bin/squid-open-schedule.sh >> /var/log/squid-schedule.log 2>&1
# Dias úteis — fechar horários livres (bloquear streaming imediatamente)
0  8 * * 1-5 root /usr/local/bin/squid-force-block.sh   >> /var/log/squid-schedule.log 2>&1
0 13 * * 1-5 root /usr/local/bin/squid-force-block.sh   >> /var/log/squid-schedule.log 2>&1
0 18 * * 1-5 root /usr/local/bin/squid-force-block.sh   >> /var/log/squid-schedule.log 2>&1
0 23 * * 1-5 root /usr/local/bin/squid-force-block.sh   >> /var/log/squid-schedule.log 2>&1
# Fim de semana — bloquear à meia-noite (00:00 = início de segunda)
0  0 * * 1   root /usr/local/bin/squid-force-block.sh   >> /var/log/squid-schedule.log 2>&1
# Reconfigure de segurança a cada 5 min
*/5 * * * *  root /usr/sbin/squid -k reconfigure 2>/dev/null || true
EOF

touch /var/log/squid-schedule.log
# Debian 13: cron service pode ser 'cron' (Debian padrão)
CRON_SVC="cron"
systemctl list-unit-files 2>/dev/null | grep -q "^crond.service" && CRON_SVC="crond"
systemctl enable --force "$CRON_SVC" 2>/dev/null || systemctl enable "$CRON_SVC" 2>/dev/null || true
systemctl restart "$CRON_SVC"

# ==============================================================================
# 11. LOGROTATE
# ==============================================================================
log "Configurando rotação de logs..."
cat <<'EOF' > /etc/logrotate.d/squid-gateway
/var/log/squid/access.log
/var/log/squid/cache.log {
    daily
    rotate 30
    compress
    delaycompress
    missingok
    notifempty
    sharedscripts
    postrotate
        /usr/sbin/squid -k rotate 2>/dev/null || /usr/bin/squid -k rotate 2>/dev/null || true
    endscript
}

/var/log/squid-schedule.log {
    weekly
    rotate 8
    compress
    missingok
    notifempty
}
EOF
ok "Logrotate configurado."


# ==============================================================================
# 11b. SERVIDOR WPAD + DOWNLOAD DA CA (nginx leve na porta 8080)
# ==============================================================================
log "Configurando servidor WPAD e distribuição da CA (nginx porta 8080)..."

# nginx serve: /wpad.dat  /proxy.pac  /ca  (download da CA)
# Debian 13: nginx-light foi descontinuado, usar nginx diretamente
apt-get install -y -q \
    -o Dpkg::Options::="--force-confdef" \
    -o Dpkg::Options::="--force-confold" \
    nginx 2>/dev/null || \
apt-get install -y -q \
    -o Dpkg::Options::="--force-confdef" \
    -o Dpkg::Options::="--force-confold" \
    nginx-light 2>/dev/null || \
    err "Falha ao instalar nginx. Verifique repositórios."

WPAD_ROOT="/var/www/gateway-wpad"
mkdir -p "$WPAD_ROOT"

# --- PAC file — configura automaticamente o proxy nos clientes ---
cat <<PACEOF > "$WPAD_ROOT/proxy.pac"
// Arquivo de Autoconfiguração do Proxy (PAC) — Gateway Local
// Distribua esta URL para os clientes: http://${LAN_IP}:8080/proxy.pac
// Ou configure o DHCP/DNS para WPAD automático

function FindProxyForURL(url, host) {
    // Gateway local — acesso direto sempre (painel :5000, WPAD :8080)
    if (host == "${LAN_IP}") {
        return "DIRECT";
    }
    // Redes internas: acesso direto sem proxy
    if (isPlainHostName(host) ||
        shExpMatch(host, "*.lan") ||
        shExpMatch(host, "*.local") ||
        isInNet(host, "192.168.0.0", "255.255.0.0") ||  // 192.168.0.x e 192.168.1.x
        isInNet(host, "10.0.0.0",   "255.0.0.0")   ||
        isInNet(host, "172.16.0.0", "255.240.0.0") ||
        isInNet(host, "127.0.0.0",  "255.0.0.0")) {
        return "DIRECT";
    }
    // Todo o tráfego para internet passa obrigatoriamente pelo proxy
    // Todo o restante: usar proxy do gateway
    return "PROXY ${LAN_IP}:3128";
}
PACEOF

# wpad.dat é o mesmo arquivo (convenção WPAD)
cp "$WPAD_ROOT/proxy.pac" "$WPAD_ROOT/wpad.dat"

# --- Página de boas-vindas / download da CA ---
cat <<HTMLEOF > "$WPAD_ROOT/index.html"
<!DOCTYPE html>
<html lang="pt-br">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>Gateway — Configuração de Proxy &amp; CA</title>
<style>
*{box-sizing:border-box;margin:0;padding:0}
body{font-family:'Segoe UI',Arial,sans-serif;background:#f0f4f8;color:#1a2332;min-height:100vh;display:flex;align-items:center;justify-content:center;padding:1.5rem}
.wrap{max-width:620px;width:100%}
.header{background:#fff;border:1px solid #dde3ec;border-radius:16px 16px 0 0;padding:1.75rem 2rem 1.25rem;border-bottom:none;text-align:center}
.shield{width:56px;height:56px;background:#3b6ff0;border-radius:14px;display:grid;place-items:center;margin:0 auto .85rem;color:#fff;font-size:1.5rem}
h1{font-size:1.3rem;font-weight:700;color:#1a2332;margin-bottom:.35rem}
.sub{font-size:.9rem;color:#6b7a91}
.card{background:#fff;border:1px solid #dde3ec;border-radius:0 0 16px 16px;padding:1.75rem 2rem;box-shadow:0 4px 24px rgba(0,0,0,.07)}
.step{display:flex;gap:1rem;margin-bottom:1.25rem;padding-bottom:1.25rem;border-bottom:1px solid #f0f0f0;align-items:flex-start}
.step:last-child{margin-bottom:0;padding-bottom:0;border-bottom:none}
.step-num{width:30px;height:30px;background:#3b6ff0;color:#fff;border-radius:50%;display:grid;place-items:center;font-size:.85rem;font-weight:700;flex-shrink:0;margin-top:.1rem}
.step-body h3{font-size:.95rem;font-weight:600;margin-bottom:.35rem;color:#1a2332}
.step-body p{font-size:.85rem;color:#4a5568;line-height:1.6}
.btn{display:inline-flex;align-items:center;gap:.45rem;padding:.55rem 1.1rem;border-radius:8px;font-size:.85rem;font-weight:600;text-decoration:none;margin-top:.65rem;transition:all .18s;cursor:pointer;border:none}
.btn-primary{background:#3b6ff0;color:#fff}
.btn-primary:hover{background:#2d5bd0}
.btn-secondary{background:#f0f4f8;color:#3b6ff0;border:1px solid #c5d5fb}
.btn-secondary:hover{background:#e6eeff}
.btn-group{display:flex;flex-wrap:wrap;gap:.5rem}
code{background:#f0f4f8;border:1px solid #dde3ec;border-radius:5px;padding:1px 6px;font-family:'Consolas','Courier New',monospace;font-size:.84rem;color:#3b6ff0;word-break:break-all}
.info{background:#eef3fe;border:1px solid #c5d5fb;border-radius:8px;padding:.65rem .9rem;font-size:.82rem;color:#185ab0;margin-top:.75rem;line-height:1.55}
.os-tabs{display:flex;gap:.4rem;margin:.6rem 0}
.os-tab{padding:.3rem .75rem;border-radius:6px;font-size:.8rem;font-weight:500;cursor:pointer;border:1px solid #dde3ec;background:#f7f9fc;color:#6b7a91;transition:all .15s}
.os-tab.active{background:#3b6ff0;color:#fff;border-color:#3b6ff0}
.os-block{display:none;background:#f7f9fc;border:1px solid #dde3ec;border-radius:8px;padding:.75rem 1rem;font-size:.82rem;color:#4a5568;line-height:1.65}
.os-block.active{display:block}
.os-block ol{padding-left:1.1rem}
.os-block ol li{margin-bottom:.3rem}
</style>
</head>
<body>
<div class="wrap">
  <div class="header">
    <div class="shield">&#x1F6E1;</div>
    <h1>Configuração do Proxy de Rede</h1>
    <p class="sub">Siga os passos abaixo para configurar seu dispositivo corretamente.</p>
  </div>
  <div class="card">

    <div class="step">
      <div class="step-num">1</div>
      <div class="step-body">
        <h3>Instale o Certificado CA do Gateway</h3>
        <p>O gateway inspeciona o tráfego HTTPS para aplicar as políticas de acesso. Para que seu navegador não exiba erros de segurança, instale o certificado abaixo no seu dispositivo.</p>
        <div class="btn-group">
          <a href="/ca" class="btn btn-primary">&#x2B07; Baixar Certificado (.crt)</a>
          <a href="/ca.der" class="btn btn-secondary">&#x2B07; Baixar .DER (Android/Java)</a>
        </div>
        <div class="info">&#x2139; Arquivo: <code>gateway-ca.crt</code> &mdash; Válido por 10 anos &mdash; Autoridade Certificadora Local</div>
      </div>
    </div>

    <div class="step">
      <div class="step-num">2</div>
      <div class="step-body">
        <h3>Instale o Certificado no seu Sistema Operacional</h3>
        <div class="os-tabs">
          <div class="os-tab active" onclick="showOS('win')">Windows</div>
          <div class="os-tab" onclick="showOS('mac')">macOS</div>
          <div class="os-tab" onclick="showOS('android')">Android</div>
          <div class="os-tab" onclick="showOS('ios')">iPhone/iPad</div>
          <div class="os-tab" onclick="showOS('linux')">Linux</div>
        </div>
        <div class="os-block active" id="os-win">
          <ol>
            <li>Clique duas vezes no arquivo <code>gateway-ca.crt</code> baixado</li>
            <li>Clique em <strong>Instalar Certificado...</strong></li>
            <li>Selecione <strong>Computador Local</strong> &rarr; Avançar</li>
            <li>Selecione <strong>Colocar todos os certificados no repositório a seguir</strong></li>
            <li>Clique em <strong>Procurar</strong> &rarr; selecione <strong>Autoridades de Certificação Raiz Confiáveis</strong></li>
            <li>Clique em <strong>Concluir</strong> &rarr; aceite o aviso de segurança</li>
          </ol>
        </div>
        <div class="os-block" id="os-mac">
          <ol>
            <li>Clique duas vezes em <code>gateway-ca.crt</code> &mdash; o Acesso às Chaves abrirá</li>
            <li>Clique duas vezes no certificado <strong>Gateway CA</strong> na lista</li>
            <li>Expanda <strong>Confiar</strong> &rarr; em "Ao usar este certificado" selecione <strong>Sempre Confiar</strong></li>
            <li>Feche a janela &rarr; confirme com sua senha</li>
          </ol>
        </div>
        <div class="os-block" id="os-android">
          <ol>
            <li>Baixe o arquivo <code>.DER</code> acima</li>
            <li>Vá em <strong>Configurações &rarr; Segurança &rarr; Criptografia e credenciais</strong></li>
            <li>Toque em <strong>Instalar um certificado &rarr; Certificado CA</strong></li>
            <li>Selecione o arquivo baixado &rarr; confirme</li>
          </ol>
        </div>
        <div class="os-block" id="os-ios">
          <ol>
            <li>Baixe o arquivo <code>.crt</code> no iPhone/iPad</li>
            <li>Vá em <strong>Ajustes &rarr; Geral &rarr; VPN e Gerenciamento de Dispositivo</strong></li>
            <li>Toque no perfil do certificado e em <strong>Instalar</strong></li>
            <li>Vá em <strong>Ajustes &rarr; Geral &rarr; Sobre &rarr; Confiar em Certificados</strong></li>
            <li>Ative a confiança para <strong>Gateway CA</strong></li>
          </ol>
        </div>
        <div class="os-block" id="os-linux">
          <ol>
            <li>Copie o certificado: <code>sudo cp gateway-ca.crt /usr/local/share/ca-certificates/</code></li>
            <li>Atualize: <code>sudo update-ca-certificates</code></li>
            <li>Para o Firefox, importe manualmente em: <strong>Preferências &rarr; Privacidade &rarr; Ver Certificados &rarr; Importar</strong></li>
          </ol>
        </div>
      </div>
    </div>

    <div class="step">
      <div class="step-num">3</div>
      <div class="step-body">
        <h3>Configure o Proxy no seu Navegador/Sistema</h3>
        <p>Endereço do proxy: <code>${LAN_IP}</code> &nbsp;|&nbsp; Porta: <code>3128</code></p>
        <p style="margin-top:.5rem">Ou use a configuração automática (PAC):</p>
        <code>http://${LAN_IP}:8080/proxy.pac</code>
        <div class="info">&#x2714; Após instalar o certificado e configurar o proxy, o acesso à internet funcionará normalmente sem erros de segurança.</div>
      </div>
    </div>

  </div>
</div>
<script>
function showOS(os){
  document.querySelectorAll('.os-tab').forEach(t=>t.classList.remove('active'));
  document.querySelectorAll('.os-block').forEach(b=>b.classList.remove('active'));
  event.target.classList.add('active');
  document.getElementById('os-'+os).classList.add('active');
}
</script>
</body>
</html>
HTMLEOF

# Copiar os arquivos da CA para o diretório web (apenas se CA existe)
if [ -f "$CA_CERT" ] && [ -f "$CA_DER" ]; then
    cp --remove-destination "$CA_CERT" "$WPAD_ROOT/ca"
    cp --remove-destination "$CA_CERT" "$WPAD_ROOT/gateway-ca.crt"
    cp --remove-destination "$CA_DER"  "$WPAD_ROOT/ca.der"
    cp --remove-destination "$CA_DER"  "$WPAD_ROOT/gateway-ca.der"
else
    warn "CA não encontrada (SSL Bump desabilitado) — arquivos de CA não copiados para WPAD."
    # Criar arquivos placeholder para evitar 404 no nginx
    echo "SSL Bump não habilitado neste gateway." > "$WPAD_ROOT/ca"
    cp "$WPAD_ROOT/ca" "$WPAD_ROOT/gateway-ca.crt"
    cp "$WPAD_ROOT/ca" "$WPAD_ROOT/ca.der"
    cp "$WPAD_ROOT/ca" "$WPAD_ROOT/gateway-ca.der"
fi
chown -R www-data:www-data "$WPAD_ROOT"
chmod -R 755 "$WPAD_ROOT"
chmod 644 "$WPAD_ROOT"/*

# Script para re-sincronizar a CA no diretório web após eventual regeneração
cat <<'SYNCSCRIPT' > /usr/local/bin/sync-gateway-ca.sh
#!/bin/bash
# Copia a CA atualizada para o diretório WPAD (executar após regenerar a CA)
CA_CERT="/etc/squid/ssl_cert/gateway-ca.crt"
CA_DER="/etc/squid/ssl_cert/gateway-ca.der"
WPAD_ROOT="/var/www/gateway-wpad"
cp --remove-destination "$CA_CERT" "$WPAD_ROOT/ca"
cp --remove-destination "$CA_CERT" "$WPAD_ROOT/gateway-ca.crt"
cp --remove-destination "$CA_DER"  "$WPAD_ROOT/ca.der"
cp --remove-destination "$CA_DER"  "$WPAD_ROOT/gateway-ca.der"
chown www-data:www-data "$WPAD_ROOT"/ca* "$WPAD_ROOT"/gateway-ca.*
chmod 644              "$WPAD_ROOT"/ca* "$WPAD_ROOT"/gateway-ca.*
echo "[OK] CA sincronizada para $WPAD_ROOT"
SYNCSCRIPT
chmod +x /usr/local/bin/sync-gateway-ca.sh

# --- nginx config ---
# Verificar se o IP de monitoramento realmente existe antes de adicionar o listen
MON_LISTEN=""
MON_LISTEN80=""
if [ "${MON_ENABLED:-0}" = "1" ]; then
    if ip addr show | grep -q "192.168.1.1"; then
        MON_LISTEN="    listen 192.168.1.1:8080;"
        MON_LISTEN80="    listen 192.168.1.1:80;"
    else
        warn "IP 192.168.1.1 não encontrado — listen de monitoramento omitido do nginx"
    fi
fi

cat <<NGINXEOF > /etc/nginx/sites-available/gateway-wpad
server {
    listen ${LAN_IP}:8080;
${MON_LISTEN}
    server_name wpad wpad.lan ${LAN_IP};
    root $WPAD_ROOT;
    index index.html;

    disable_symlinks off;

    # MIME types
    types {
        application/x-ns-proxy-autoconfig  pac dat;
        application/x-x509-ca-cert         crt der;
        text/html                           html;
    }


    location = /wpad.dat {
        add_header Content-Type "application/x-ns-proxy-autoconfig";
        add_header Content-Disposition "inline";
    }
    location = /proxy.pac {
        add_header Content-Type "application/x-ns-proxy-autoconfig";
        add_header Content-Disposition "inline";
    }

    # Download CA
    location = /ca {
        default_type application/x-x509-ca-cert;
        add_header Content-Disposition "attachment; filename=gateway-ca.crt";
        try_files /ca =404;
    }
    location = /ca.der {
        default_type application/x-x509-ca-cert;
        add_header Content-Disposition "attachment; filename=gateway-ca.der";
        try_files /ca.der =404;
    }
    location = /gateway-ca.crt {
        default_type application/x-x509-ca-cert;
        add_header Content-Disposition "attachment; filename=gateway-ca.crt";
        try_files /gateway-ca.crt =404;
    }
    location = /gateway-ca.der {
        default_type application/x-x509-ca-cert;
        add_header Content-Disposition "attachment; filename=gateway-ca.der";
        try_files /gateway-ca.der =404;
    }

    location / {
        try_files \$uri \$uri/ /index.html;
    }

    # ── NCSI / Detectores de conectividade ──────────────────────────────────────
    # Windows verifica: GET http://www.msftconnecttest.com/connecttest.txt
    # Resposta esperada exata: "Microsoft Connect Test" (sem aspas, sem newline extra)
    # Sem isso o Windows mostra triangulo/X de "sem internet" mesmo com proxy ok.
    #
    # Para usar: no registro do Windows, aponte NCSI para este gateway:
    #   HKLM\SYSTEM\CurrentControlSet\Services\NlaSvc\Parameters\Internet
    #     ActiveWebProbeHost    = ${LAN_IP}
    #     ActiveWebProbePath    = /connecttest.txt
    #     ActiveWebProbeContent = Microsoft Connect Test
    # Ou simplesmente libere msftconnecttest.com no Squid (ja feito via ACL ncsi_hosts).

    location = /connecttest.txt {
        add_header Content-Type "text/plain";
        return 200 "Microsoft Connect Test";
    }
    # Apple / iOS / macOS captive portal check
    location = /hotspot-detect.html {
        add_header Content-Type "text/html";
        return 200 "<HTML><HEAD><TITLE>Success</TITLE></HEAD><BODY>Success</BODY></HTML>";
    }
    # Android / Chrome OS connectivity check
    location = /generate_204 {
        return 204;
    }
    # Firefox connectivity check
    location = /success.txt {
        add_header Content-Type "text/plain";
        return 200 "success\n";
    }

    access_log /var/log/nginx/gateway-wpad.log;
    error_log  /var/log/nginx/gateway-wpad-err.log;
}

# Virtual host NCSI: responde como msftconnecttest.com localmente
# Corrige o icone de rede (globinho) no Windows/Android mesmo com proxy
# IMPORTANTE: listen sem IP específico + default_server garante que qualquer
# requisição na porta 80 que não case com outro vhost seja respondida aqui.
# O Windows faz NCSI sem proxy (conexão direta), então precisa do default_server.
server {
    listen ${LAN_IP}:80 default_server;
${MON_LISTEN80}
    server_name www.msftconnecttest.com ipv6.msftconnecttest.com
                www.msftncsi.com       ipv6.msftncsi.com
                connectivitycheck.gstatic.com connectivitycheck.android.com
                captive.apple.com detectportal.firefox.com
                _;

    # Windows NCSI — resposta exata exigida pelo Windows
    location = /connecttest.txt {
        add_header Content-Type "text/plain; charset=utf-8";
        return 200 "Microsoft Connect Test";
    }
    # Windows NCSI redirect check
    location = /redirect {
        return 200 "Microsoft Connect Test";
        add_header Content-Type "text/plain";
    }
    # Windows NCSI ncsi.txt (versões mais antigas)
    location = /ncsi.txt {
        add_header Content-Type "text/plain";
        return 200 "Microsoft NCSI";
    }
    # Android / Google
    location = /generate_204 {
        return 204;
    }
    # Apple captive portal
    location = /hotspot-detect.html {
        add_header Content-Type "text/html";
        return 200 "<HTML><HEAD><TITLE>Success</TITLE></HEAD><BODY>Success</BODY></HTML>";
    }
    # Firefox
    location = /success.txt {
        add_header Content-Type "text/plain";
        return 200 "success";
    }
    # Fallback — qualquer outra requisição retorna OK
    location / {
        add_header Content-Type "text/plain";
        return 200 "Microsoft Connect Test";
    }
}
NGINXEOF

# Ativar site nginx
rm -f /etc/nginx/sites-enabled/default 2>/dev/null || true
ln -sf /etc/nginx/sites-available/gateway-wpad /etc/nginx/sites-enabled/gateway-wpad

# Testar e iniciar nginx
nginx -t 2>/dev/null && {
    systemctl enable --force nginx 2>/dev/null || systemctl enable nginx 2>/dev/null || true
    systemctl restart nginx
    ok "Servidor WPAD iniciado (http://${LAN_IP}:8080)."
} || warn "nginx: erro de configuração — verifique /etc/nginx/sites-available/gateway-wpad"

# ==============================================================================
# 12. PAINEL WEB DE ADMINISTRAÇÃO (Flask/Gunicorn)
# ==============================================================================
log "Instalando o Painel Web de Administração..."

PANEL_DIR="/opt/gateway-panel"
PANEL_USER="gateway-panel"

if ! id "$PANEL_USER" &>/dev/null; then
    useradd --system --no-create-home --shell /usr/sbin/nologin "$PANEL_USER"
fi

usermod -aG proxy,shadow "$PANEL_USER" 2>/dev/null || true

# Detectar paths reais dos binários (Debian 13 unificou /usr/sbin → /usr/bin)
SQUID_BIN=$(command -v squid 2>/dev/null || echo "/usr/sbin/squid")
RNDC_BIN=$(command -v rndc 2>/dev/null || echo "/usr/sbin/rndc")
NFT_BIN=$(command -v nft 2>/dev/null || echo "/usr/sbin/nft")
SYSTEMCTL_BIN=$(command -v systemctl 2>/dev/null || echo "/usr/bin/systemctl")

mkdir -p /etc/sudoers.d
cat <<EOF > /etc/sudoers.d/gateway-panel
$PANEL_USER ALL=(root) NOPASSWD: ${SQUID_BIN} -k reconfigure
$PANEL_USER ALL=(root) NOPASSWD: ${SYSTEMCTL_BIN} restart squid
$PANEL_USER ALL=(root) NOPASSWD: ${SYSTEMCTL_BIN} restart squid6
$PANEL_USER ALL=(root) NOPASSWD: /usr/local/bin/update-nat1to1.sh
$PANEL_USER ALL=(root) NOPASSWD: ${RNDC_BIN} reload
$PANEL_USER ALL=(root) NOPASSWD: ${NFT_BIN} -f /etc/nftables.conf
$PANEL_USER ALL=(root) NOPASSWD: ${SYSTEMCTL_BIN} reload nginx
$PANEL_USER ALL=(root) NOPASSWD: /usr/local/bin/sync-gateway-ca.sh
EOF
chmod 440 /etc/sudoers.d/gateway-panel
# Validar sudoers para detectar erros de sintaxe
visudo -c -f /etc/sudoers.d/gateway-panel 2>/dev/null || \
    warn "sudoers pode ter problema de sintaxe — verifique /etc/sudoers.d/gateway-panel"

mkdir -p "$PANEL_DIR/templates"


python3 -m venv "$PANEL_DIR/venv" 2>/dev/null || python3 -m venv --without-pip "$PANEL_DIR/venv" || err "Falha ao criar venv Python"

"$PANEL_DIR/venv/bin/pip" install --quiet --upgrade pip 2>/dev/null || true
# python-pam: pode estar como python3-pam no PyPI; tentar ambos
# Instalar flask e gunicorn no venv
log "Instalando dependências Python do painel..."
"$PANEL_DIR/venv/bin/pip" install --quiet --no-cache-dir flask    || err "Falha ao instalar flask no venv."
"$PANEL_DIR/venv/bin/pip" install --quiet --no-cache-dir gunicorn || err "Falha ao instalar gunicorn no venv."
"$PANEL_DIR/venv/bin/pip" install --quiet six 2>/dev/null || true
# python-pam: necessário para autenticação PAM
"$PANEL_DIR/venv/bin/pip" install --quiet python-pam 2>/dev/null ||     "$PANEL_DIR/venv/bin/pip" install --quiet pam 2>/dev/null ||     apt-get install -y -q python3-pam 2>/dev/null ||     warn "python-pam não instalado — autenticação PAM indisponível (PANEL_PASSWORD ainda funciona)."


PY3_PAM_PATH=$(python3 -c "import site; print(site.getsitepackages()[0])" 2>/dev/null)/pam.py
PY3_PAM_PATH2=$(python3 -c "import site; print(site.getsitepackages()[0])" 2>/dev/null)/PAM.py
VENV_SITE="$PANEL_DIR/venv/lib/python$(python3 -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')/site-packages"
if [ -f "$PY3_PAM_PATH" ] && [ ! -f "$VENV_SITE/pam.py" ]; then
    ln -sf "$PY3_PAM_PATH" "$VENV_SITE/pam.py" 2>/dev/null || true
fi

# ==============================================================================
# 12a. APP.PY
# ==============================================================================
cat <<'PYEOF' > "$PANEL_DIR/app.py"
#!/usr/bin/env python3
"""
Gateway Control Panel — app.py
"""

import os, re, json, uuid, subprocess, logging
from functools import wraps
from collections import defaultdict
from datetime import datetime, timedelta
from flask import (
    Flask, render_template, request, redirect, url_for,
    flash, session, jsonify, send_file,
)

app = Flask(__name__)
app.secret_key = os.environ.get("PANEL_SECRET_KEY", "troque-esta-chave-no-ambiente")
app.config["PERMANENT_SESSION_LIFETIME"] = timedelta(hours=8)

logging.basicConfig(level=logging.INFO, format="%(asctime)s [%(levelname)s] %(message)s")
logger = logging.getLogger(__name__)

PANEL_AUTH_USER = os.environ.get("PANEL_AUTH_USER", "root")
# PANEL_PASSWORD é lido do env mas pode ter aspas literais se o .env
# usar PANEL_PASSWORD="valor" — o systemd EnvironmentFile remove as aspas,
# mas leitura direta do arquivo não remove. Strip para segurança.
_raw_pwd = os.environ.get("PANEL_PASSWORD", "")
PANEL_PASSWORD = _raw_pwd.strip().strip('"').strip("'")

def _get_panel_password() -> str:
    """Lê a senha atual do .env em tempo de execução (suporta alterações sem rebuild)."""
    env_file = "/etc/gateway-panel.env"
    try:
        with open(env_file, "r") as _ef:
            for _line in _ef:
                _line = _line.strip()
                if _line.startswith("PANEL_PASSWORD=") and not _line.startswith("#"):
                    val = _line.split("=", 1)[1].strip().strip('"').strip("'")
                    return val
    except Exception:
        pass
    return PANEL_PASSWORD

# Rate limiting: máx 10 tentativas por IP em 5 minutos
_login_attempts: dict = {}
MAX_LOGIN_ATTEMPTS = 10
LOCKOUT_SECONDS    = 300

def _check_rate_limit(ip: str) -> bool:
    """Retorna True se o IP ainda pode tentar. False se está bloqueado."""
    now = datetime.now()
    entry = _login_attempts.get(ip)
    if entry:
        count, first_ts = entry
        if (now - first_ts).total_seconds() > LOCKOUT_SECONDS:
            del _login_attempts[ip]
        elif count >= MAX_LOGIN_ATTEMPTS:
            return False
    return True

def _register_failed_attempt(ip: str):
    now = datetime.now()
    entry = _login_attempts.get(ip)
    if entry:
        count, first_ts = entry
        if (now - first_ts).total_seconds() > LOCKOUT_SECONDS:
            _login_attempts[ip] = (1, now)
        else:
            _login_attempts[ip] = (count + 1, first_ts)
    else:
        _login_attempts[ip] = (1, now)

def _check_password(password: str) -> bool:
    if not password:
        return False

    # ── Método 1: PANEL_PASSWORD no .env (mais simples e confiável) ──────────
    # Lê em tempo real do arquivo para pegar alterações sem precisar rebuild
    _current_pwd = _get_panel_password()
    if _current_pwd and password == _current_pwd:
        logger.info("Login via PANEL_PASSWORD ok.")
        return True

    # ── Método 2: PAM (autenticação pelo sistema operacional) ────────────────
    # Requer: grupo shadow + python-pam instalado + NoNewPrivileges=no no service
    try:
        import pam
        p = pam.pam()
        result = p.authenticate(PANEL_AUTH_USER, password, service="login")
        if result:
            logger.info("Login PAM ok para '%s'", PANEL_AUTH_USER)
            return True
        else:
            logger.warning("PAM rejeitou senha para '%s': %s", PANEL_AUTH_USER,
                           getattr(p, "reason", "motivo desconhecido"))
    except ImportError:
        logger.warning("python-pam não instalado — autenticação PAM indisponível.")
    except PermissionError as exc:
        logger.warning("PAM: permissão negada (usuário não está no grupo shadow?): %s", exc)
    except Exception as exc:
        logger.warning("PAM: erro inesperado: %s", exc)

    # ── Método 3: /etc/shadow direto — compatível com Python 3.13 ───────────
    # spwd e crypt foram removidos no Python 3.13; usar leitura direta do shadow
    try:
        import hashlib, base64
        with open("/etc/shadow", "r") as _sf:
            for _line in _sf:
                _parts = _line.strip().split(":")
                if len(_parts) >= 2 and _parts[0] == PANEL_AUTH_USER:
                    _hashed = _parts[1]
                    if _hashed in ("*", "!", "", "!!"):
                        break
                    # Detectar algoritmo: $id$salt$hash
                    _seg = _hashed.split("$")
                    if len(_seg) >= 4:
                        _alg_id = _seg[1]
                        _salt = "$" + _seg[1] + "$" + _seg[2] + "$"
                        try:
                            import crypt as _crypt
                            if _crypt.crypt(password, _hashed) == _hashed:
                                logger.info("Login via /etc/shadow ok para '%s'", PANEL_AUTH_USER)
                                return True
                        except ImportError:
                            pass  # Python 3.13+: crypt removido
                    break
    except PermissionError:
        logger.warning("shadow: sem permissão (grupo shadow?)")
    except Exception:
        pass

    # ── Método 4: subprocess su -c (último recurso) ───────────────────────────
    try:
        import subprocess, shutil
        if shutil.which("su"):
            proc = subprocess.run(
                ["su", "-s", "/bin/sh", "-c", "exit 0", PANEL_AUTH_USER],
                input=password + "\n",
                capture_output=True, text=True, timeout=5
            )
            if proc.returncode == 0:
                logger.info("Login via su ok para '%s'", PANEL_AUTH_USER)
                return True
    except Exception:
        pass

    return False

def login_required(f):
    @wraps(f)
    def decorated(*args, **kwargs):
        if not session.get("authenticated"):
            return redirect(url_for("login"))
        return f(*args, **kwargs)
    return decorated

FILES: dict = {
    "ips_totais":             "/etc/squid/ips_totais.txt",
    "ips_parciais":           "/etc/squid/ips_parciais.txt",
    "ips_bloqueados":         "/etc/squid/ips_bloqueados.txt",
    "ips_excecao":            "/etc/squid/ips_excecao_horario.txt",
    "sites_liberados":        "/etc/squid/sites_liberados.txt",
    "sites_bloqueados":       "/etc/squid/sites_bloqueados.txt",
    "streaming_redes":        "/etc/squid/streaming_redes.txt",
    "sites_bancos":           "/etc/squid/sites_bancos.txt",
    "sites_teams":            "/etc/squid/sites_teams.txt",
    "nat_1to1":               "/etc/nftables/nat_1to1.txt",
    "ips_externos_liberados": "/etc/nftables/ips_externos_liberados.txt",
    "ips_rede_wan":           "/etc/nftables/ips_rede_wan.txt",
}

SCHEDULES_FILE          = "/etc/squid/horarios_livres.json"
STREAMING_TEMP_FILE     = "/etc/squid/streaming_temp.json"
ACL_HORARIOS_FILE       = "/etc/squid/acl_horarios.conf"
ACL_STREAMING_TEMP_FILE = "/etc/squid/acl_streaming_temp.conf"

# Detectar paths reais dos binários (Debian 13 unificou /usr/sbin → /usr/bin)
import shutil as _shutil
_squid_bin = os.environ.get("SQUID_BIN") or _shutil.which("squid") or "/usr/sbin/squid"
_rndc_bin  = _shutil.which("rndc")  or "/usr/sbin/rndc"
_nft_bin   = _shutil.which("nft")   or "/usr/sbin/nft"

RELOAD_COMMANDS = {
    "squid":    ["sudo", _squid_bin, "-k", "reconfigure"],
    "nat":      ["sudo", "/usr/local/bin/update-nat1to1.sh"],
    "bind9":    ["sudo", _rndc_bin, "reload"],
    "firewall": ["sudo", _nft_bin, "-f", "/etc/nftables.conf"],
}
RELOAD_MESSAGES = {
    "squid":    "Squid Proxy reconfigurado com sucesso.",
    "nat":      "Regras de NAT 1:1 e Aliases atualizados.",
    "bind9":    "Servidor DNS BIND9 recarregado com sucesso.",
    "firewall": "Regras estruturais do Nftables recarregadas.",
}

CA_CERT_PATH = "/etc/squid/ssl_cert/gateway-ca.crt"
CA_DER_PATH  = "/etc/squid/ssl_cert/gateway-ca.der"
WPAD_ROOT    = "/var/www/gateway-wpad"

@app.route("/api/change-password", methods=["POST"])
@login_required
def api_change_password():
    """Altera a PANEL_PASSWORD no arquivo .env sem precisar editar manualmente."""
    data = request.get_json(silent=True) or {}
    current = data.get("current", "")
    new_pwd = data.get("new_password", "").strip()
    confirm = data.get("confirm", "").strip()

    if not _check_password(current):
        return jsonify({"error": "Senha atual incorreta."}), 403
    if len(new_pwd) < 8:
        return jsonify({"error": "Nova senha deve ter pelo menos 8 caracteres."}), 400
    if new_pwd != confirm:
        return jsonify({"error": "Nova senha e confirmação não coincidem."}), 400

    env_path = "/etc/gateway-panel.env"
    try:
        with open(env_path, "r") as fh:
            lines = fh.readlines()
        new_lines = []
        found = False
        for line in lines:
            if line.startswith("PANEL_PASSWORD="):
                new_lines.append(f'PANEL_PASSWORD="{new_pwd}"\n')
                found = True
            else:
                new_lines.append(line)
        if not found:
            new_lines.append(f'PANEL_PASSWORD="{new_pwd}"\n')
        with open(env_path, "w") as fh:
            fh.writelines(new_lines)
        # Recarregar variável em memória imediatamente
        global PANEL_PASSWORD
        PANEL_PASSWORD = new_pwd
        logger.info("Senha do painel alterada com sucesso.")
        return jsonify({"ok": True, "message": "Senha alterada. Próximo login usará a nova senha."})
    except Exception as exc:
        logger.error("Erro ao alterar senha: %s", exc)
        return jsonify({"error": f"Erro ao salvar: {exc}"}), 500

@app.route("/api/ca_info")
@login_required
def api_ca_info():
    """Retorna informações sobre a CA gerada."""
    import subprocess
    if not os.path.isfile(CA_CERT_PATH):
        return jsonify({"ok": False, "error": f"CA não encontrada em {CA_CERT_PATH}. SSL Bump pode estar desabilitado."})
    try:
        out = subprocess.run(
            ["openssl", "x509", "-in", CA_CERT_PATH, "-noout",
             "-subject", "-issuer", "-startdate", "-enddate", "-fingerprint"],
            capture_output=True, text=True, timeout=5
        )
        return jsonify({"ok": True, "info": out.stdout.strip()})
    except Exception as exc:
        return jsonify({"ok": False, "error": str(exc)})

@app.route("/download/ca")
@login_required
def download_ca():
    from flask import send_file, abort
    if not os.path.isfile(CA_CERT_PATH):
        logger.warning("CA não encontrada em %s", CA_CERT_PATH)
        return (
            "<h2>Certificado CA não encontrado</h2>"
            "<p>O SSL Bump pode estar desabilitado neste gateway, "
            "ou a CA ainda não foi gerada.</p>"
            "<p>Caminho esperado: <code>" + CA_CERT_PATH + "</code></p>"
            "<p><a href='/'>← Voltar ao painel</a></p>",
            404,
        )
    return send_file(CA_CERT_PATH, as_attachment=True, download_name="gateway-ca.crt",
                     mimetype="application/x-x509-ca-cert")

@app.route("/download/ca.der")
@login_required
def download_ca_der():
    from flask import send_file
    if not os.path.isfile(CA_DER_PATH):
        logger.warning("CA DER não encontrada em %s", CA_DER_PATH)
        return (
            "<h2>Certificado CA (.der) não encontrado</h2>"
            "<p>O SSL Bump pode estar desabilitado neste gateway, "
            "ou a CA ainda não foi gerada.</p>"
            "<p>Caminho esperado: <code>" + CA_DER_PATH + "</code></p>"
            "<p><a href='/'>← Voltar ao painel</a></p>",
            404,
        )
    return send_file(CA_DER_PATH, as_attachment=True, download_name="gateway-ca.der",
                     mimetype="application/x-x509-ca-cert")

SQUID_LOG = "/var/log/squid/access.log"

def _read_file(path):
    try:
        with open(path, "r", encoding="utf-8") as fh:
            return fh.read()
    except FileNotFoundError:
        return ""
    except OSError as exc:
        logger.warning("Não foi possível ler %s: %s", path, exc)
        return ""

def _write_file(path, content):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        fh.write(content.replace("\r\n", "\n"))
    os.replace(tmp, path)

def _read_json(path, default=None):
    if default is None:
        default = []
    try:
        with open(path, "r", encoding="utf-8") as fh:
            return json.load(fh)
    except (FileNotFoundError, json.JSONDecodeError):
        return default

def _write_json(path, data):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        json.dump(data, fh, ensure_ascii=False, indent=2)
    os.replace(tmp, path)

def _read_list(path):
    return [
        line.strip()
        for line in _read_file(path).splitlines()
        if line.strip() and not line.strip().startswith("#")
    ]

def _generate_acl_horarios():
    schedules = _read_json(SCHEDULES_FILE, [])
    lines = ["# ── Gerado automaticamente pelo Gateway Control Panel ──\n# NÃO edite manualmente.\n#\n"]
    if not schedules:
        lines.append("acl horario_livre time MTWHF 25:00-25:01\n")
    else:
        for s in schedules:
            lines.append(f"acl horario_livre time {s.get('days','MTWHF')} {s.get('start','00:00')}-{s.get('end','23:59')}  # {s.get('label','')}\n")
    _write_file(ACL_HORARIOS_FILE, "".join(lines))

def _generate_acl_streaming_temp():
    entries = _read_json(STREAMING_TEMP_FILE, [])
    lines = ["# ── Liberações temporárias de Streaming/Redes Sociais ──\n# Gerado automaticamente.\n#\n"]
    for i, e in enumerate(entries):
        idx = i + 1
        ip = e.get("ip", "")
        if not ip:
            continue
        lines += [
            f"# [{e.get('label', ip)}]\n",
            f"acl streaming_temp_ip_{idx} src {ip}\n",
            f"acl streaming_temp_hr_{idx} time {e.get('days','MTWHF')} {e.get('start','00:00')}-{e.get('end','23:59')}\n",
            f"http_access allow streaming_temp_ip_{idx} streaming_redes     streaming_temp_hr_{idx}\n",
            f"http_access allow streaming_temp_ip_{idx} streaming_redes_ssl streaming_temp_hr_{idx}\n\n",
        ]
    if not entries:
        lines.append("# Nenhuma liberação temporária configurada.\n")
    _write_file(ACL_STREAMING_TEMP_FILE, "".join(lines))

def _init_config_files():
    if not os.path.exists(SCHEDULES_FILE):
        _write_json(SCHEDULES_FILE, [
            {"id": "1", "label": "Manhã · Dias úteis",  "days": "MTWHF", "start": "07:00", "end": "08:00"},
            {"id": "2", "label": "Almoço · Dias úteis", "days": "MTWHF", "start": "11:00", "end": "13:00"},
            {"id": "3", "label": "Tarde · Dias úteis",  "days": "MTWHF", "start": "17:00", "end": "18:00"},
            {"id": "4", "label": "Noite · Dias úteis",  "days": "MTWHF", "start": "20:00", "end": "23:00"},
            {"id": "5", "label": "Fim de semana",        "days": "AS",    "start": "00:00", "end": "23:59"},
        ])
    if not os.path.exists(ACL_HORARIOS_FILE):
        _generate_acl_horarios()
    if not os.path.exists(STREAMING_TEMP_FILE):
        _write_json(STREAMING_TEMP_FILE, [])
    if not os.path.exists(ACL_STREAMING_TEMP_FILE):
        _generate_acl_streaming_temp()

_SQUID_RE = re.compile(
    r"^(\d+\.\d+)\s+(\d+)\s+(\S+)\s+(\w+)/(\d+)\s+(\d+)\s+(\w+)\s+(\S+)\s+\S+\s+(\S+)"
)

def _parse_squid_log(max_lines=50000, days=7):
    cutoff = datetime.now() - timedelta(days=days)
    records = []
    try:
        result = subprocess.run(
            ["tail", "-n", str(max_lines), SQUID_LOG],
            capture_output=True, text=True, timeout=15,
        )
        for line in result.stdout.splitlines():
            m = _SQUID_RE.match(line)
            if not m:
                continue
            dt = datetime.fromtimestamp(float(m.group(1)))
            if dt < cutoff:
                continue
            action = m.group(4)
            code   = int(m.group(5))
            denied = action in ("TCP_DENIED", "NONE") or code in (403, 407)
            url    = m.group(8)
            dm     = re.search(r"https?://([^/:]+)", url)
            domain = dm.group(1) if dm else url.split(":")[0]
            records.append({
                "ts":     dt,
                "ts_str": dt.strftime("%Y-%m-%d %H:%M:%S"),
                "hour":   dt.hour,
                "date":   dt.strftime("%Y-%m-%d"),
                "client": m.group(3),
                "action": action,
                "code":   code,
                "bytes":  int(m.group(6)),
                "method": m.group(7),
                "url":    url,
                "domain": domain,
                "denied": denied,
            })
    except Exception as exc:
        logger.warning("Erro ao parsear log: %s", exc)
    return records

def _build_report(days=1):
    records = _parse_squid_log(days=days)
    if not records:
        return {"empty": True, "days": days}

    total       = len(records)
    total_bytes = sum(r["bytes"] for r in records)
    allowed     = [r for r in records if not r["denied"]]
    denied_recs = [r for r in records if r["denied"]]

    # Top IPs
    by_ip = defaultdict(lambda: {"allowed": 0, "denied": 0, "bytes": 0})
    for r in records:
        k = "allowed" if not r["denied"] else "denied"
        by_ip[r["client"]][k] += 1
        by_ip[r["client"]]["bytes"] += r["bytes"]
    top_ips = sorted(by_ip.items(), key=lambda x: x[1]["allowed"] + x[1]["denied"], reverse=True)[:20]

    # Por hora
    by_hour = {h: {"allowed": 0, "denied": 0, "bytes": 0} for h in range(24)}
    for r in records:
        k = "allowed" if not r["denied"] else "denied"
        by_hour[r["hour"]][k] += 1
        by_hour[r["hour"]]["bytes"] += r["bytes"]

    # Top domínios
    by_domain = defaultdict(lambda: {"allowed": 0, "denied": 0, "bytes": 0})
    for r in records:
        k = "allowed" if not r["denied"] else "denied"
        by_domain[r["domain"]][k] += 1
        by_domain[r["domain"]]["bytes"] += r["bytes"]
    top_domains = sorted(by_domain.items(), key=lambda x: x[1]["allowed"] + x[1]["denied"], reverse=True)[:25]

    # Por data
    by_date = defaultdict(lambda: {"allowed": 0, "denied": 0, "bytes": 0})
    for r in records:
        k = "allowed" if not r["denied"] else "denied"
        by_date[r["date"]][k] += 1
        by_date[r["date"]]["bytes"] += r["bytes"]

    # IPs bloqueados — atividade detalhada
    blocked_ips = set(_read_list("/etc/squid/ips_bloqueados.txt"))
    blocked_activity = []
    blocked_by_ip = defaultdict(lambda: {"allowed": 0, "denied": 0, "bytes": 0, "sites": set()})
    for r in records:
        if r["client"] in blocked_ips:
            blocked_activity.append(r)
            k = "allowed" if not r["denied"] else "denied"
            blocked_by_ip[r["client"]][k] += 1
            blocked_by_ip[r["client"]]["bytes"] += r["bytes"]
            blocked_by_ip[r["client"]]["sites"].add(r["domain"])

    # Converte sets em listas para JSON
    blocked_by_ip_list = []
    for ip, data in sorted(blocked_by_ip.items()):
        blocked_by_ip_list.append({
            "ip": ip,
            "allowed": data["allowed"],
            "denied":  data["denied"],
            "bytes":   data["bytes"],
            "sites":   sorted(data["sites"])[:10],
        })

    # Últimas 200 tentativas/acessos de IPs bloqueados (mais recente primeiro)
    blocked_recent = sorted(blocked_activity, key=lambda x: x["ts"], reverse=True)[:200]

    # Últimas 100 negações gerais
    recent_denied = sorted(denied_recs, key=lambda x: x["ts"], reverse=True)[:100]

    return {
        "empty": False, "days": days, "total": total,
        "total_allowed": len(allowed), "total_denied": len(denied_recs),
        "total_bytes": total_bytes, "top_ips": top_ips,
        "by_hour": [(h, by_hour[h]) for h in range(24)],
        "top_domains": top_domains,
        "by_date": sorted(by_date.items()),
        "blocked_by_ip": blocked_by_ip_list,
        "blocked_recent": blocked_recent,
        "recent_denied": recent_denied,
    }

@app.route("/login", methods=["GET", "POST"])
def login():
    if session.get("authenticated"):
        return redirect(url_for("index"))
    if request.method == "POST":
        ip = request.remote_addr or "unknown"
        if not _check_rate_limit(ip):
            logger.warning("Login bloqueado (rate limit) de %s", ip)
            flash("Muitas tentativas incorretas. Aguarde 5 minutos.", "danger")
            return render_template("login.html")
        password = request.form.get("password", "")
        if _check_password(password):
            _login_attempts.pop(ip, None)
            session["authenticated"] = True
            session.permanent = True
            logger.info("Login bem-sucedido de %s", ip)
            return redirect(url_for("index"))
        _register_failed_attempt(ip)
        logger.warning("Login falhou de %s", ip)
        flash("Senha incorreta. Tente novamente.", "danger")
    return render_template("login.html")

@app.route("/logout")
@login_required
def logout():
    session.clear()
    flash("Sessão encerrada com sucesso.", "success")
    return redirect(url_for("login"))

@app.route("/")
@login_required
def index():
    data           = {key: _read_file(path) for key, path in FILES.items()}
    groups         = {key: _read_list(path) for key, path in FILES.items()}
    schedules      = _read_json(SCHEDULES_FILE, [])
    streaming_temp = _read_json(STREAMING_TEMP_FILE, [])
    return render_template("index.html", data=data, groups=groups,
                           schedules=schedules, streaming_temp=streaming_temp)



@app.route("/reload/<service>")
@login_required
def reload_service(service):
    if service not in RELOAD_COMMANDS:
        flash("Serviço desconhecido.", "warning")
        return redirect(url_for("index"))
    try:
        subprocess.run(RELOAD_COMMANDS[service], capture_output=True, text=True, timeout=30, check=True)
        flash(RELOAD_MESSAGES[service], "success")
    except subprocess.TimeoutExpired:
        flash(f"Timeout ao recarregar '{service}'.", "danger")
    except subprocess.CalledProcessError as exc:
        flash(f"Erro ao recarregar '{service}': {exc.stderr.strip() or exc}", "danger")
    return redirect(url_for("index"))

@app.route("/api/schedules", methods=["GET"])
@login_required
def api_schedules_get():
    return jsonify(_read_json(SCHEDULES_FILE, []))

@app.route("/api/schedules", methods=["POST"])
@login_required
def api_schedules_add():
    data  = request.get_json(silent=True) or request.form.to_dict()
    label = str(data.get("label", "")).strip()
    days  = str(data.get("days",  "MTWHF")).strip().upper()
    start = str(data.get("start", "")).strip()
    end   = str(data.get("end",   "")).strip()
    if not label or not start or not end:
        return jsonify({"error": "Campos obrigatórios: label, start, end"}), 400
    if not re.match(r"^\d{2}:\d{2}$", start) or not re.match(r"^\d{2}:\d{2}$", end):
        return jsonify({"error": "Formato de hora inválido (HH:MM)"}), 400
    if start >= end:
        return jsonify({"error": "Hora de início deve ser menor que hora de fim"}), 400
    if not re.match(r"^[MTWHFASmtwhfas]+$", days):
        return jsonify({"error": "Dias inválidos. Use letras: M T W H F A S"}), 400
    schedules = _read_json(SCHEDULES_FILE, [])
    entry = {"id": str(uuid.uuid4())[:8], "label": label, "days": days, "start": start, "end": end}
    schedules.append(entry)
    _write_json(SCHEDULES_FILE, schedules)
    _generate_acl_horarios()
    # Reconfigure automático: novo horário entra em vigor imediatamente
    subprocess.run(RELOAD_COMMANDS["squid"], capture_output=True, timeout=15)
    return jsonify({"ok": True, "entry": entry})

@app.route("/api/schedules/<sid>", methods=["DELETE"])
@login_required
def api_schedules_delete(sid):
    schedules = _read_json(SCHEDULES_FILE, [])
    new_list  = [s for s in schedules if s.get("id") != sid]
    if len(new_list) == len(schedules):
        return jsonify({"error": "ID não encontrado"}), 404
    _write_json(SCHEDULES_FILE, new_list)
    _generate_acl_horarios()
    # Reconfigure automático: remoção entra em vigor imediatamente
    subprocess.run(RELOAD_COMMANDS["squid"], capture_output=True, timeout=15)
    return jsonify({"ok": True})

@app.route("/api/streaming_temp", methods=["GET"])
@login_required
def api_streaming_temp_get():
    return jsonify(_read_json(STREAMING_TEMP_FILE, []))

@app.route("/api/streaming_temp", methods=["POST"])
@login_required
def api_streaming_temp_add():
    data  = request.get_json(silent=True) or request.form.to_dict()
    ip    = str(data.get("ip",    "")).strip()
    label = str(data.get("label", "")).strip()
    days  = str(data.get("days",  "MTWHF")).strip().upper()
    start = str(data.get("start", "")).strip()
    end   = str(data.get("end",   "")).strip()
    if not ip or not start or not end:
        return jsonify({"error": "Campos obrigatórios: ip, start, end"}), 400
    try:
        import ipaddress
        ipaddress.ip_network(ip, strict=False)
    except ValueError:
        return jsonify({"error": "IP ou CIDR inválido"}), 400
    entries = _read_json(STREAMING_TEMP_FILE, [])
    entry = {"id": str(uuid.uuid4())[:8], "label": label or ip, "ip": ip, "days": days, "start": start, "end": end}
    entries.append(entry)
    _write_json(STREAMING_TEMP_FILE, entries)
    _generate_acl_streaming_temp()
    subprocess.run(RELOAD_COMMANDS["squid"], capture_output=True, timeout=15)
    return jsonify({"ok": True, "entry": entry})

@app.route("/api/streaming_temp/<sid>", methods=["DELETE"])
@login_required
def api_streaming_temp_delete(sid):
    entries  = _read_json(STREAMING_TEMP_FILE, [])
    new_list = [e for e in entries if e.get("id") != sid]
    if len(new_list) == len(entries):
        return jsonify({"error": "ID não encontrado"}), 404
    _write_json(STREAMING_TEMP_FILE, new_list)
    _generate_acl_streaming_temp()
    subprocess.run(RELOAD_COMMANDS["squid"], capture_output=True, timeout=15)
    return jsonify({"ok": True})

@app.route("/relatorio")
@login_required
def relatorio():
    try:
        days = max(1, min(int(request.args.get("days", 1)), 30))
    except (ValueError, TypeError):
        days = 1
    return render_template("relatorio.html", report=_build_report(days=days))

@app.route("/api/report")
@login_required
def api_report():
    try:
        days = max(1, min(int(request.args.get("days", 1)), 30))
    except (ValueError, TypeError):
        days = 1
    return jsonify(_build_report(days=days))

# ── Grupos de IPs mutuamente exclusivos ────────────────────────────────────
IP_GROUPS = ["ips_totais", "ips_parciais", "ips_bloqueados", "ips_excecao", "ips_rede_wan"]

def _remove_ip_from_other_groups(ip_to_add: str, current_group: str):
    """Remove um IP de todos os outros grupos para evitar conflito de ACL."""
    NL = chr(10)
    for group in IP_GROUPS:
        if group == current_group:
            continue
        path = FILES.get(group)
        if not path:
            continue
        lines = _read_file(path).splitlines()
        filtered = []
        changed = False
        for line in lines:
            stripped = line.strip()
            if stripped.startswith("#") or not stripped:
                filtered.append(line)
                continue
            if stripped == ip_to_add:
                changed = True
                logger.info("IP %s removido de %s (conflito com %s)", ip_to_add, group, current_group)
            else:
                filtered.append(line)
        if changed:
            _write_file(path, NL.join(filtered) + (NL if filtered else ""))

@app.route("/save/<key>", methods=["POST"])
@login_required
def save_exclusive(key):
    if key not in FILES:
        flash("Identificador de arquivo inválido.", "danger")
        return redirect(url_for("index"))
    content_raw = request.form.get("content", "")
    try:
        if key in IP_GROUPS:
            new_ips = [
                line.strip() for line in content_raw.splitlines()
                if line.strip() and not line.strip().startswith("#")
            ]
            for ip in new_ips:
                _remove_ip_from_other_groups(ip, key)
        _write_file(FILES[key], content_raw)
        flash(f"Lista [{key.replace('_', ' ').upper()}] salva! IPs duplicados removidos automaticamente.", "success")
    except OSError as exc:
        flash(f"Erro ao salvar: {exc}", "danger")
    return redirect(url_for("index"))

with app.app_context():
    try:
        _init_config_files()
    except Exception as exc:
        logger.warning("Não foi possível inicializar arquivos de config: %s", exc)

if __name__ == "__main__":
    app.run(host="127.0.0.1", port=5000, debug=False)
PYEOF

# ==============================================================================
# 12b. TEMPLATE login.html — v18
# ==============================================================================
cat <<'HTML' > "$PANEL_DIR/templates/login.html"
<!DOCTYPE html>
<html lang="pt-br">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>Login · Gateway Control Panel</title>
<link href="https://fonts.googleapis.com/css2?family=Inter:wght@400;500;600&family=JetBrains+Mono:wght@400;500&display=swap" rel="stylesheet">
<style>
*,*::before,*::after{box-sizing:border-box;margin:0;padding:0}
html{-webkit-font-smoothing:antialiased}
body{background:#242c3b;color:#dde6f0;font-family:'Inter',sans-serif;min-height:100vh;display:flex;align-items:center;justify-content:center;padding:1.5rem}
.wrap{width:100%;max-width:380px}
.logo-area{text-align:center;margin-bottom:2rem}
.logo-icon{width:56px;height:56px;margin:0 auto 1rem;background:#347d39;border-radius:14px;display:grid;place-items:center;font-size:1.5rem}
.logo-title{font-size:1.05rem;font-weight:600;color:#cdd9e5}
.logo-sub{font-size:.8rem;color:#545d68;margin-top:.3rem}
.card{background:#22272e;border:1px solid #2d333b;border-radius:12px;overflow:hidden}
.card-head{background:#1c2128;border-bottom:1px solid #2d333b;padding:.75rem 1.25rem;display:flex;align-items:center;gap:.6rem;font-size:.75rem;color:#545d68;font-family:'JetBrains Mono',monospace}
.dots{display:flex;gap:5px}
.dot{width:8px;height:8px;border-radius:50%}
.d1{background:#ff5f57}.d2{background:#febc2e}.d3{background:#28c840}
.card-body{padding:1.5rem 1.25rem;display:flex;flex-direction:column;gap:1rem}
.alert{display:flex;align-items:center;gap:.6rem;padding:.6rem .9rem;border-radius:7px;font-size:.8rem;border:1px solid}
.alert-danger{background:#2d1b1e;border-color:#4a2a2e;color:#e5534b}
.alert-success{background:#1b2d1d;border-color:#2d4a30;color:#57ab5a}
.field{display:flex;flex-direction:column;gap:.4rem}
label{font-size:.72rem;font-weight:600;color:#768390;letter-spacing:.04em;text-transform:uppercase}
.inp-wrap{position:relative}
.ico{position:absolute;left:.8rem;top:50%;transform:translateY(-50%);color:#545d68;font-size:.85rem;pointer-events:none}
.eye{position:absolute;right:.7rem;top:50%;transform:translateY(-50%);background:none;border:none;cursor:pointer;color:#545d68;font-size:.85rem;padding:3px;transition:color .15s}
.eye:hover{color:#57ab5a}
input[type="password"],input[type="text"]{width:100%;background:#1c2128;border:1px solid #2d333b;border-radius:7px;color:#cdd9e5;font-family:'JetBrains Mono',monospace;font-size:.85rem;padding:.65rem .8rem .65rem 2.3rem;outline:none;transition:border-color .18s,box-shadow .18s}
input:focus{border-color:#347d39;box-shadow:0 0 0 3px rgba(52,125,57,.18)}
input::placeholder{color:#545d68}
.btn{width:100%;padding:.75rem;border-radius:8px;background:#347d39;border:1px solid #4a9450;color:#fff;font-family:'Inter',sans-serif;font-size:.88rem;font-weight:600;cursor:pointer;display:flex;align-items:center;justify-content:center;gap:.5rem;transition:all .18s}
.btn:hover{background:#3d8f43;border-color:#57ab5a}
.hint{text-align:center;font-size:.72rem;color:#545d68;line-height:1.55}
code{font-family:'JetBrains Mono',monospace;color:#57ab5a;font-size:.8rem}
</style>
</head>
<body>
<div class="wrap">
  <div class="logo-area">
    <div class="logo-icon">🛡</div>
    <div class="logo-title">Gateway Control Panel</div>
    <div class="logo-sub">Autenticação requerida · Rede Interna</div>
  </div>
  <div class="card">
    <div class="card-head">
      <div class="dots"><div class="dot d1"></div><div class="dot d2"></div><div class="dot d3"></div></div>
      <span>🔒 Acesso Restrito ao Sistema</span>
    </div>
    <div class="card-body">
      {% with messages = get_flashed_messages(with_categories=true) %}
        {% if messages %}{% for c, m in messages %}
          <div class="alert alert-{{ c }}">{{ '✕' if c=='danger' else '✓' }} {{ m }}</div>
        {% endfor %}{% endif %}
      {% endwith %}
      <form method="POST" action="/login" autocomplete="off">
        <div class="field" style="margin-bottom:1rem">
          <label for="password">🔑 Senha do Servidor</label>
          <div class="inp-wrap">
            <span class="ico">🔒</span>
            <input type="password" id="password" name="password"
                   placeholder="Digite a senha do sistema..." autocomplete="current-password" autofocus required>
            <button type="button" class="eye" onclick="togglePw()" id="eye-btn">👁</button>
          </div>
        </div>
        <button type="submit" class="btn">→ Entrar no Painel</button>
      </form>
      <div class="hint">
        Autenticação via <code>root</code> (PAM) ou variável <code>PANEL_PASSWORD</code>
      </div>
    </div>
  </div>
</div>
<script>
function togglePw(){
  const i=document.getElementById('password'),b=document.getElementById('eye-btn');
  const v=i.type==='text';i.type=v?'password':'text';b.textContent=v?'👁':'🙈';
}
</script>
</body>
</html>
HTML

# ==============================================================================
# 12c. TEMPLATE index.html — v18
# ==============================================================================
cat <<'HTML' > "$PANEL_DIR/templates/index.html"
<!DOCTYPE html>
<html lang="pt-br">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>Gateway Control Panel</title>
<link href="https://fonts.googleapis.com/css2?family=Inter:wght@400;500;600&family=JetBrains+Mono:wght@400;500&display=swap" rel="stylesheet">
<style>
:root{
  --bg:#242c3b;--surf:#2c3548;--surf2:#354159;--surf3:#3e4e6a;
  --border:#354159;--border2:#3e4e6a;
  --text:#dde6f0;--text2:#b8c8d8;--text3:#7a90a8;--text4:#566578;
  --green:#4db860;--green-bg:#1a2f1e;--green-bd:#2a4a30;
  --blue:#5ba8f5;--blue-bg:#182540;--blue-bd:#264268;
  --red:#e05548;--red-bg:#2e1a1c;--red-bd:#4a282c;
  --yellow:#d4963a;--yellow-bg:#2a2218;--yellow-bd:#3e3420;
  --cyan:#30bfd0;--cyan-bg:#122830;--cyan-bd:#1c3e4a;
  --purple:#9b7af0;--purple-bg:#201630;--purple-bd:#342248;
  --orange:#e07a32;--orange-bg:#281c10;--orange-bd:#3c2a18;
  --mono:'JetBrains Mono',monospace;--sans:'Inter',sans-serif;
  --r:6px;--rl:10px;--rxl:14px;
}
*,*::before,*::after{box-sizing:border-box;margin:0;padding:0}
html{font-size:14px;-webkit-font-smoothing:antialiased}
body{background:var(--bg);color:var(--text);font-family:var(--sans);min-height:100vh;line-height:1.5;display:flex;flex-direction:column}

/* TOPBAR */
.topbar{background:var(--surf);border-bottom:1px solid var(--border);padding:0 1.25rem;height:48px;display:flex;align-items:center;justify-content:space-between;position:sticky;top:0;z-index:200;flex-shrink:0}
.brand{display:flex;align-items:center;gap:.6rem}
.brand-icon{width:28px;height:28px;background:#3a8a4a;border-radius:7px;display:grid;place-items:center;font-size:14px;font-weight:700;color:#fff;flex-shrink:0}
.brand-name{font-size:.88rem;font-weight:600;color:var(--text);letter-spacing:-.01em}
.brand-ver{font-size:.68rem;color:var(--text4);background:var(--surf2);border:1px solid var(--border2);border-radius:10px;padding:1px 7px;margin-left:.25rem}
.nav-pills{display:flex;gap:2px}
.np{font-size:.75rem;font-weight:500;color:var(--text3);padding:.3rem .7rem;border-radius:var(--r);border:1px solid transparent;cursor:pointer;display:flex;align-items:center;gap:.35rem;text-decoration:none;transition:all .14s}
.np:hover{color:var(--text);background:var(--surf2)}
.np.active{color:var(--green);background:var(--green-bg);border-color:var(--green-bd);font-weight:600}
.topbar-r{display:flex;align-items:center;gap:.5rem}
.online-pill{display:flex;align-items:center;gap:.4rem;font-size:.7rem;color:var(--green);background:var(--green-bg);border:1px solid var(--green-bd);border-radius:20px;padding:2px 9px}
.online-dot{width:5px;height:5px;border-radius:50%;background:var(--green);animation:pulse 2s infinite}
@keyframes pulse{0%,100%{opacity:1}50%{opacity:.35}}
.icon-btn{width:28px;height:28px;background:var(--surf2);border:1px solid var(--border2);border-radius:var(--r);display:grid;place-items:center;font-size:13px;color:var(--text3);cursor:pointer;transition:all .14s;text-decoration:none}
.icon-btn:hover{color:var(--text);border-color:var(--text4)}
.logout-btn{font-size:.72rem;color:var(--text3);background:var(--surf2);border:1px solid var(--border2);border-radius:var(--r);padding:.3rem .7rem;cursor:pointer;display:flex;align-items:center;gap:.35rem;text-decoration:none;transition:all .14s}
.logout-btn:hover{color:var(--red);border-color:var(--red-bd);background:var(--red-bg)}

/* SHELL */
.shell{display:flex;flex:1;overflow:hidden;height:calc(100vh - 48px)}

/* SIDEBAR */
.sidebar{width:200px;background:var(--surf);border-right:1px solid var(--border);padding:6px 5px;flex-shrink:0;overflow-y:auto;display:flex;flex-direction:column}
.sidebar::-webkit-scrollbar{width:3px}
.sidebar::-webkit-scrollbar-thumb{background:var(--surf2)}
.sg{font-size:.62rem;font-weight:700;color:var(--text4);text-transform:uppercase;letter-spacing:.09em;padding:7px 7px 3px;margin-top:3px}
.sg:first-child{margin-top:0}
.si{display:flex;align-items:center;gap:.5rem;padding:4px 8px;border-radius:var(--r);font-size:.76rem;font-weight:500;color:var(--text3);cursor:pointer;border:1px solid transparent;margin-bottom:1px;text-decoration:none;transition:all .12s}
.si:hover{color:var(--text);background:var(--surf2)}
.si.active{color:var(--green);background:var(--green-bg);border-color:var(--green-bd);font-weight:600}
.si-ic{width:14px;text-align:center;flex-shrink:0}
.si-ct{margin-left:auto;font-size:.6rem;font-family:var(--mono);padding:1px 5px;border-radius:8px;background:var(--surf2);border:1px solid var(--border2);color:var(--text4)}
.si-ct.g{background:var(--green-bg);border-color:var(--green-bd);color:var(--green)}
.si-ct.r{background:var(--red-bg);border-color:var(--red-bd);color:var(--red)}
.si-ct.y{background:var(--yellow-bg);border-color:var(--yellow-bd);color:var(--yellow)}

/* MAIN */
.main{flex:1;padding:1rem 1.1rem 3rem;overflow-y:auto;background:var(--bg)}
.main::-webkit-scrollbar{width:4px}
.main::-webkit-scrollbar-thumb{background:var(--surf2);border-radius:2px}

/* ALERTS */
.alerts{display:flex;flex-direction:column;gap:.4rem;margin-bottom:.85rem}
.alert{display:flex;align-items:center;justify-content:space-between;gap:.6rem;padding:.55rem .9rem;border-radius:var(--rl);font-size:.78rem;border:1px solid;animation:sld .2s ease}
@keyframes sld{from{opacity:0;transform:translateY(-5px)}to{opacity:1;transform:translateY(0)}}
.alert-content{display:flex;align-items:center;gap:.45rem;flex:1}
.alert-danger{background:var(--red-bg);border-color:var(--red-bd);color:var(--red)}
.alert-success{background:var(--green-bg);border-color:var(--green-bd);color:var(--green)}
.alert-warning{background:var(--yellow-bg);border-color:var(--yellow-bd);color:var(--yellow)}
.alert-close{background:none;border:none;cursor:pointer;color:inherit;opacity:.5;font-size:.9rem;padding:0 2px}
.alert-close:hover{opacity:1}

/* STATS */
.stats{display:grid;grid-template-columns:repeat(4,1fr);gap:.6rem;margin-bottom:.9rem}
@media(max-width:1100px){.stats{grid-template-columns:repeat(2,1fr)}}
.stat-card{background:var(--surf);border:1px solid var(--border);border-radius:var(--rl);padding:.8rem .95rem;position:relative;overflow:hidden;transition:border-color .14s}
.stat-card:hover{border-color:var(--border2)}
.stat-card::after{content:'';position:absolute;top:0;left:0;right:0;height:2px;border-radius:2px 2px 0 0}
.stat-card.c-green::after{background:var(--green)}
.stat-card.c-blue::after{background:var(--blue)}
.stat-card.c-red::after{background:var(--red)}
.stat-card.c-yellow::after{background:var(--yellow)}
.stat-lbl{font-size:.62rem;font-weight:700;color:var(--text4);text-transform:uppercase;letter-spacing:.07em;margin-bottom:.3rem}
.stat-val{font-size:1.5rem;font-weight:600;font-family:var(--mono);line-height:1}
.stat-card.c-green .stat-val{color:var(--green)}
.stat-card.c-blue .stat-val{color:var(--blue)}
.stat-card.c-red .stat-val{color:var(--red)}
.stat-card.c-yellow .stat-val{color:var(--yellow)}
.stat-sub{font-size:.67rem;color:var(--text4);margin-top:.25rem}

/* TOP 2COL */
.two-col{display:grid;grid-template-columns:1fr 270px;gap:.7rem;margin-bottom:.7rem}
@media(max-width:1024px){.two-col{grid-template-columns:1fr}}

/* CARDS */
.card{background:var(--surf);border:1px solid var(--border);border-radius:var(--rl)}
.card-head{display:flex;align-items:center;justify-content:space-between;padding:.6rem .9rem;border-bottom:1px solid var(--border)}
.card-head-l{display:flex;align-items:center;gap:.45rem;font-size:.77rem;font-weight:600;color:var(--text2)}
.card-head-ic{font-size:.75rem;color:var(--text4)}
.card-body{padding:.8rem .9rem}

/* ACTION BUTTONS - todos mesma altura */
.act-desc{font-size:.72rem;color:var(--text4);margin-bottom:.75rem;line-height:1.55}
.act-grid{display:grid;grid-template-columns:repeat(3,1fr);gap:.45rem}
.ab{display:flex;flex-direction:column;align-items:center;justify-content:center;gap:.35rem;padding:.65rem .4rem;border-radius:var(--r);font-size:.72rem;font-weight:600;cursor:pointer;border:1px solid;text-align:center;line-height:1.25;min-height:58px;text-decoration:none;transition:all .15s}
.ab-icon{font-size:1.1rem;line-height:1}
.ab.gr{background:var(--green-bg);border-color:var(--green-bd);color:var(--green)}
.ab.gr:hover{background:var(--green);color:#1c2128;border-color:var(--green)}
.ab.bl{background:var(--blue-bg);border-color:var(--blue-bd);color:var(--blue)}
.ab.bl:hover{background:var(--blue);color:#1c2128;border-color:var(--blue)}
.ab.cy{background:var(--cyan-bg);border-color:var(--cyan-bd);color:var(--cyan)}
.ab.cy:hover{background:var(--cyan);color:#1c2128;border-color:var(--cyan)}
.ab.yl{background:var(--yellow-bg);border-color:var(--yellow-bd);color:var(--yellow)}
.ab.yl:hover{background:var(--yellow);color:#1c2128;border-color:var(--yellow)}
.ab.pu{background:var(--purple-bg);border-color:var(--purple-bd);color:var(--purple)}
.ab.pu:hover{background:var(--purple);color:#1c2128;border-color:var(--purple)}
.ab.rd{background:var(--red-bg);border-color:var(--red-bd);color:var(--red)}
.ab.rd:hover{background:var(--red);color:#1c2128;border-color:var(--red)}

/* INFO BOXES */
.info-box{background:var(--blue-bg);border:1px solid var(--blue-bd);border-radius:var(--r);padding:.55rem .8rem;font-size:.72rem;color:var(--blue);display:flex;gap:.45rem;align-items:flex-start;line-height:1.5;margin-top:.65rem}
.warn-box{background:var(--yellow-bg);border:1px solid var(--yellow-bd);border-radius:var(--r);padding:.55rem .8rem;font-size:.72rem;color:var(--yellow);display:flex;gap:.45rem;align-items:flex-start;line-height:1.5}
.success-box{background:var(--green-bg);border:1px solid var(--green-bd);border-radius:var(--r);padding:.55rem .8rem;font-size:.72rem;color:var(--green);display:flex;gap:.45rem;align-items:flex-start;line-height:1.5}

/* SCHEDULE */
.schedule-list{display:flex;flex-direction:column;gap:.3rem;margin-bottom:.6rem}
.schedule-item{display:flex;align-items:center;gap:.4rem;padding:.38rem .6rem;background:var(--bg);border:1px solid var(--border);border-radius:var(--r);transition:border-color .13s}
.schedule-item:hover{border-color:var(--border2)}
.schedule-item .label{font-size:.74rem;color:var(--text2);flex:1;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.days-badge{font-family:var(--mono);font-size:.62rem;color:var(--text4);background:var(--surf2);border:1px solid var(--border2);border-radius:4px;padding:1px 5px}
.time-badge-blue{font-family:var(--mono);font-size:.68rem;color:var(--blue);background:var(--blue-bg);border:1px solid var(--blue-bd);border-radius:4px;padding:1px 7px}
.time-badge-orange{font-family:var(--mono);font-size:.68rem;color:var(--orange);background:var(--orange-bg);border:1px solid var(--orange-bd);border-radius:4px;padding:1px 7px}
.btn-del{background:none;border:none;cursor:pointer;color:var(--text4);font-size:.7rem;padding:2px 4px;border-radius:3px;transition:all .13s;flex-shrink:0}
.btn-del:hover{color:var(--red);background:var(--red-bg)}

/* ADD FORM */
.add-form{background:var(--bg);border:1px solid var(--border);border-radius:var(--r);padding:.65rem}
.add-form-title{font-size:.65rem;font-weight:700;color:var(--text4);text-transform:uppercase;letter-spacing:.06em;margin-bottom:.45rem}
.add-form input,.add-form select{width:100%;background:var(--surf);border:1px solid var(--border2);border-radius:5px;color:var(--text);font-family:var(--mono);font-size:.75rem;padding:.38rem .55rem;outline:none;transition:border-color .14s,box-shadow .14s;margin-bottom:.35rem}
.add-form input:focus,.add-form select:focus{border-color:var(--green);box-shadow:0 0 0 2px rgba(87,171,90,.14)}
.add-form input::placeholder{color:var(--text4)}
.form-row{display:grid;grid-template-columns:1fr 1fr;gap:.35rem}
.btn-add{display:flex;align-items:center;justify-content:center;gap:.4rem;width:100%;padding:.45rem;border-radius:5px;font-size:.74rem;font-weight:600;cursor:pointer;transition:all .15s;border:1px solid;margin-top:.2rem}
.btn-add-green{background:var(--green-bg);border-color:var(--green-bd);color:var(--green)}
.btn-add-green:hover{background:var(--green);color:#1c2128;border-color:var(--green)}
.btn-add-orange{background:var(--orange-bg);border-color:var(--orange-bd);color:var(--orange)}
.btn-add-orange:hover{background:var(--orange);color:#1c2128;border-color:var(--orange)}
.spinner{display:none;width:11px;height:11px;border:2px solid rgba(255,255,255,.2);border-top-color:currentColor;border-radius:50%;animation:spin .6s linear infinite}
@keyframes spin{to{transform:rotate(360deg)}}

/* STREAMING TEMP */
.streaming-temp-item{display:flex;align-items:center;gap:.45rem;padding:.45rem .65rem;background:var(--bg);border:1px solid var(--border);border-radius:var(--r);flex-wrap:wrap;transition:border-color .13s}
.streaming-temp-item:hover{border-color:var(--border2)}
.streaming-temp-item .ip{font-family:var(--mono);font-size:.74rem;color:var(--orange);min-width:130px}
.streaming-temp-item .lbl{font-size:.72rem;color:var(--text3);flex:1}
.empty-group{font-family:var(--mono);font-size:.7rem;color:var(--text4);padding:.35rem 0}

/* SECTION HEADER */
.section-header{display:flex;align-items:center;gap:.65rem;margin-bottom:.75rem;margin-top:1.4rem}
.section-header:first-child{margin-top:0}
.section-header h2{font-size:.72rem;font-weight:700;color:var(--text4);text-transform:uppercase;letter-spacing:.07em}

/* GROUPS GRID */
.groups-grid{display:grid;grid-template-columns:repeat(4,1fr);gap:.6rem}
@media(max-width:1300px){.groups-grid{grid-template-columns:repeat(3,1fr)}}
@media(max-width:960px){.groups-grid{grid-template-columns:repeat(2,1fr)}}
.group-card{background:var(--surf);border:1px solid var(--border);border-radius:var(--rl);overflow:hidden;transition:border-color .14s}
.group-card:hover{border-color:var(--border2)}
.group-card-head{display:flex;align-items:center;justify-content:space-between;padding:.45rem .75rem;background:var(--bg);border-bottom:1px solid var(--border);font-size:.65rem;font-weight:700;letter-spacing:.07em;text-transform:uppercase}
.group-card-head .badge{background:var(--surf2);border:1px solid var(--border2);border-radius:10px;padding:1px 7px;font-size:.6rem;color:var(--text4)}
.group-card-body{padding:.5rem .7rem;max-height:130px;overflow-y:auto}
.group-card-body::-webkit-scrollbar{width:2px}
.group-card-body::-webkit-scrollbar-thumb{background:var(--surf3);border-radius:1px}
.ip-pill{display:inline-block;background:var(--surf2);border:1px solid var(--border2);border-radius:4px;padding:2px 6px;font-family:var(--mono);font-size:.67rem;color:var(--text3);margin:2px 2px 0 0}

/* LIST GRID */
.list-grid{display:grid;gap:.6rem;margin-bottom:.6rem}
.grid-4{grid-template-columns:repeat(4,1fr)}
.grid-3{grid-template-columns:repeat(3,1fr)}
.grid-2{grid-template-columns:repeat(2,1fr)}
@media(max-width:1300px){.grid-4{grid-template-columns:repeat(3,1fr)}}
@media(max-width:960px){.grid-4,.grid-3{grid-template-columns:repeat(2,1fr)}}
@media(max-width:600px){.grid-4,.grid-3,.grid-2{grid-template-columns:1fr}}
.list-card{background:var(--surf);border:1px solid var(--border);border-radius:var(--rl);display:flex;flex-direction:column;overflow:hidden;transition:border-color .14s}
.list-card:hover{border-color:var(--border2)}
.list-card .card-head{font-size:.72rem;font-weight:600;color:var(--text2);padding:.55rem .85rem;background:var(--bg);border-left:3px solid transparent;gap:.45rem}
.list-card .card-body{flex:1;display:flex;flex-direction:column;gap:.6rem;padding:.75rem .85rem}
.accent-green .card-head{border-left-color:var(--green)}
.accent-yellow .card-head{border-left-color:var(--yellow)}
.accent-cyan .card-head{border-left-color:var(--cyan)}
.accent-red .card-head{border-left-color:var(--red)}
.accent-blue .card-head{border-left-color:var(--blue)}
.accent-purple .card-head{border-left-color:var(--purple)}
.accent-orange .card-head{border-left-color:var(--orange)}
.accent-muted .card-head{border-left-color:var(--text4)}
.dot{width:7px;height:7px;border-radius:50%;display:inline-block;margin-right:.35rem;flex-shrink:0}
.accent-green .dot{background:var(--green)}
.accent-yellow .dot{background:var(--yellow)}
.accent-cyan .dot{background:var(--cyan)}
.accent-red .dot{background:var(--red)}
.accent-blue .dot{background:var(--blue)}
.accent-purple .dot{background:var(--purple)}
.accent-orange .dot{background:var(--orange)}
.accent-muted .dot{background:var(--text4)}
textarea{width:100%;flex:1;background:var(--bg);border:1px solid var(--border);border-radius:var(--r);color:var(--text);font-family:var(--mono);font-size:.75rem;line-height:1.7;padding:.55rem .7rem;resize:vertical;min-height:100px;transition:border-color .15s;outline:none}
textarea:focus{border-color:var(--green);box-shadow:0 0 0 2px rgba(87,171,90,.12)}
textarea::placeholder{color:var(--text4)}
.btn-save{display:flex;align-items:center;justify-content:center;gap:.45rem;width:100%;padding:.48rem;border-radius:6px;font-size:.74rem;font-weight:600;cursor:pointer;transition:all .15s;background:var(--surf2);border:1px solid var(--border2);color:var(--text3)}
.btn-save:hover{border-color:var(--green);color:var(--green);background:var(--green-bg)}

/* BADGE OPEN/CLOSED */
.badge-open{font-size:.67rem;font-weight:700;font-family:var(--mono);background:var(--green-bg);border:1px solid var(--green-bd);border-radius:4px;padding:2px 8px;color:var(--green)}
.badge-closed{font-size:.67rem;font-weight:700;font-family:var(--mono);background:var(--red-bg);border:1px solid var(--red-bd);border-radius:4px;padding:2px 8px;color:var(--red)}

footer{text-align:center;padding:1.5rem;font-family:var(--mono);font-size:.65rem;color:var(--text4);border-top:1px solid var(--border);margin-top:1.5rem}
</style>
</head>
<body>

<header class="topbar">
  <div class="brand">
    <div class="brand-icon">GW</div>
    <span class="brand-name">Gateway Control Panel</span>
    
  </div>
  <nav class="nav-pills">
    <a href="/" class="np active">⊞ Painel</a>
    <a href="/relatorio" class="np">▦ Relatório</a>
    <a href="/download/ca" class="np">⬡ CA / SSL</a>
  </nav>
  <div class="topbar-r">
    <div class="online-pill"><div class="online-dot"></div>Online</div>
    <a href="/relatorio" class="icon-btn" title="Relatório">📊</a>
    <a href="/logout" class="logout-btn">↩ Sair</a>
  </div>
</header>

<div class="shell">

  <aside class="sidebar">
    <div class="sg">Grupos de IPs</div>
    <a href="#sec-ips" class="si active"><span class="si-ic" style="color:var(--green)">⊕</span> IPs Totais
      <span class="si-ct g">{{ groups.ips_totais|length }}</span></a>
    <a href="#sec-ips" class="si"><span class="si-ic" style="color:var(--yellow)">◑</span> IPs Parciais
      <span class="si-ct y">{{ groups.ips_parciais|length }}</span></a>
    <a href="#sec-ips" class="si"><span class="si-ic" style="color:var(--red)">⊗</span> IPs Bloqueados
      <span class="si-ct r">{{ groups.ips_bloqueados|length }}</span></a>
    <a href="#sec-ips" class="si"><span class="si-ic" style="color:var(--cyan)">◎</span> Exceção Horário
      <span class="si-ct">{{ groups.ips_excecao|length }}</span></a>
    <div class="sg">Sites</div>
    <a href="#sec-sites" class="si"><span class="si-ic" style="color:var(--green)">✓</span> Sites Liberados</a>
    <a href="#sec-sites" class="si"><span class="si-ic" style="color:var(--red)">✕</span> Sites Bloqueados</a>
    <a href="#sec-sites" class="si"><span class="si-ic" style="color:var(--blue)">⊞</span> Bancos</a>
    <a href="#sec-sites" class="si"><span class="si-ic" style="color:var(--blue)">⊟</span> Governo</a>
    <a href="#sec-sites" class="si"><span class="si-ic" style="color:var(--purple)">⊡</span> Teams / Microsoft</a>
    <a href="#sec-sites" class="si"><span class="si-ic" style="color:var(--orange)">▷</span> Streaming</a>
    <div class="sg">Rede / Firewall</div>
    <a href="#sec-nat" class="si"><span class="si-ic" style="color:var(--cyan)">⇄</span> NAT 1:1</a>
    <a href="#sec-nat" class="si"><span class="si-ic" style="color:var(--blue)">⊞</span> IPs Ext. Liberados</a>
    <a href="#sec-wan" class="si"><span class="si-ic" style="color:var(--orange)">⇌</span> Rede WAN → LAN</a>
    <div class="sg">Horários</div>
    <a href="#sec-sched" class="si"><span class="si-ic" style="color:var(--yellow)">◷</span> Horários Livres</a>
    <a href="#sec-stream" class="si"><span class="si-ic" style="color:var(--orange)">▷</span> Streaming Temp.</a>
  </aside>

  <main class="main">

    {% with messages = get_flashed_messages(with_categories=true) %}
      {% if messages %}
        <div class="alerts" id="flash-container">
          {% for category, message in messages %}
            <div class="alert alert-{{ category }}">
              <div class="alert-content">{{ '✓' if category=='success' else '✕' }} {{ message }}</div>
              <button class="alert-close" onclick="this.closest('.alert').remove()">✕</button>
            </div>
          {% endfor %}
        </div>
      {% endif %}
    {% endwith %}

    <!-- STATS -->
    <div class="stats">
      <div class="stat-card c-green">
        <div class="stat-lbl">IPs Totais</div>
        <div class="stat-val">{{ groups.ips_totais|length }}</div>
        <div class="stat-sub">acesso irrestrito</div>
      </div>
      <div class="stat-card c-yellow">
        <div class="stat-lbl">IPs Parciais</div>
        <div class="stat-val">{{ groups.ips_parciais|length }}</div>
        <div class="stat-sub">sujeitos a horário</div>
      </div>
      <div class="stat-card c-red">
        <div class="stat-lbl">IPs Bloqueados</div>
        <div class="stat-val">{{ groups.ips_bloqueados|length }}</div>
        <div class="stat-sub">somente gov/bancos/teams</div>
      </div>
      <div class="stat-card c-blue">
        <div class="stat-lbl">Horários Livres</div>
        <div class="stat-val">{{ schedules|length }}</div>
        <div class="stat-sub">períodos configurados</div>
      </div>
    </div>

    <!-- TOP ROW -->
    <div class="two-col">

      <div class="card">
        <div class="card-head">
          <div class="card-head-l"><span class="card-head-ic">⚡</span> Ações Rápidas</div>
        </div>
        <div class="card-body">
          <p class="act-desc">Aplica imediatamente as alterações salvas. Após editar listas, use <strong>Reconf. Squid</strong>.</p>
          <div class="act-grid">
            <a href="/reload/squid" class="ab gr">
              <span class="ab-icon">↻</span>Reconf. Squid
            </a>
            <a href="/reload/nat" class="ab bl">
              <span class="ab-icon">⇄</span>Atualizar NAT
            </a>
            <a href="/reload/bind9" class="ab cy">
              <span class="ab-icon">◎</span>Reload DNS
            </a>
            <a href="/reload/firewall" class="ab yl">
              <span class="ab-icon">⊞</span>Firewall
            </a>
            <a href="#" onclick="syncCA(event)" class="ab pu">
              <span class="ab-icon">⊡</span>Sincronizar CA
            </a>
            <a href="/reload/nginx" class="ab rd">
              <span class="ab-icon">↺</span>Reload nginx
            </a>
          </div>
          <div class="info-box">
            ℹ <span><strong>CA do Gateway:</strong>
            <a href="/download/ca" style="color:var(--blue);margin-left:.3rem">baixar .CRT</a>
            <a href="/download/ca.der" style="color:var(--blue);margin-left:.5rem">baixar .DER</a></span>
          </div>
        </div>
      </div>

      <div class="card" id="sec-sched">
        <div class="card-head">
          <div class="card-head-l"><span class="card-head-ic">◷</span> Horários Livres</div>
          <span class="badge-open" id="sched-badge">● ABERTO</span>
        </div>
        <div class="card-body" style="padding:.65rem .8rem">
          <div class="schedule-list" id="schedule-list">
            {% for s in schedules %}
            <div class="schedule-item" id="sched-{{ s.id }}">
              <span class="label" title="{{ s.label }}">{{ s.label }}</span>
              <span class="days-badge">{{ s.days }}</span>
              <span class="time-badge-blue">{{ s.start }}–{{ s.end }}</span>
              <button class="btn-del" onclick="deleteSchedule('{{ s.id }}')" title="Remover">✕</button>
            </div>
            {% else %}
            <div class="empty-group" id="sched-empty">— nenhum horário configurado —</div>
            {% endfor %}
          </div>
          <div class="add-form">
            <div class="add-form-title">+ Adicionar Horário</div>
            <input type="text" id="sched-label" placeholder="Descrição (ex: Almoço)" maxlength="40">
            <div class="form-row">
              <input type="time" id="sched-start" value="12:00">
              <input type="time" id="sched-end"   value="13:00">
            </div>
            <select id="sched-days">
              <option value="MTWHF">Seg – Sex (MTWHF)</option>
              <option value="AS">Sáb + Dom (AS)</option>
              <option value="MTWHFAS">Todos os dias</option>
              <option value="MTWH">Seg – Qui</option>
              <option value="MWF">Seg, Qua, Sex</option>
            </select>
            <button class="btn-add btn-add-green" onclick="addSchedule()">
              + Adicionar <span class="spinner" id="sched-spinner"></span>
            </button>
          </div>
        </div>
      </div>

    </div>

    <!-- VISÃO GERAL DOS GRUPOS -->
    <div class="section-header">
      <h2>⊞ Visão Geral dos Grupos</h2>
    </div>
    {% set gm=[
      ("ips_totais","IPs Totais","var(--green)"),
      ("ips_parciais","IPs Parciais","var(--yellow)"),
      ("ips_excecao","Exceção Horário","var(--cyan)"),
      ("ips_bloqueados","IPs Bloqueados","var(--red)"),
      ("sites_liberados","Sites Liberados","var(--green)"),
      ("sites_bloqueados","Sites Bloqueados","var(--red)"),
      ("sites_teams","Teams / Microsoft","var(--blue)"),
      ("sites_bancos","Bancos","var(--cyan)"),
      ("streaming_redes","Streaming","var(--purple)"),
      ("nat_1to1","NAT 1:1","var(--blue)"),
      ("ips_externos_liberados","IPs Externos","var(--text3)"),
      ("ips_rede_wan","Rede WAN → LAN","var(--orange)"),
    ]%}
    <div class="groups-grid">
      {% for key,label,color in gm %}
      <div class="group-card">
        <div class="group-card-head" style="color:{{ color }}">
          <span>{{ label }}</span>
          <span class="badge">{{ groups[key]|length if key in groups else 0 }}</span>
        </div>
        <div class="group-card-body">
          {% if key in groups and groups[key] %}
            {% for item in groups[key] %}<span class="ip-pill">{{ item }}</span>{% endfor %}
          {% else %}<div class="empty-group">— vazio —</div>{% endif %}
        </div>
      </div>
      {% endfor %}
    </div>

    <!-- STREAMING TEMPORÁRIO -->
    <div class="section-header" id="sec-stream">
      <h2>▷ Liberação Temporária · Streaming por IP</h2>
    </div>
    <div class="card">
      <div class="card-head">
        <div class="card-head-l" style="color:var(--orange)">🔓 Acesso temporário a streaming/redes sociais por IP e horário</div>
        <span style="font-size:.68rem;color:var(--text4)" id="stream-count">({{ streaming_temp|length }})</span>
      </div>
      <div class="card-body" style="display:grid;grid-template-columns:1fr 320px;gap:.85rem">
        <div>
          <div class="warn-box" style="margin-bottom:.65rem">
            ⚠ <span>IPs aqui acessam YouTube, Facebook, Netflix etc. <strong>somente no horário configurado</strong>. Após alterações, faça <strong>Reconf. Squid</strong>.</span>
          </div>
          <div id="streaming-temp-list" style="display:flex;flex-direction:column;gap:.3rem">
            {% for e in streaming_temp %}
            <div class="streaming-temp-item" id="stmp-{{ e.id }}">
              <span class="ip">⬡ {{ e.ip }}</span>
              <span class="lbl">{{ e.label }}</span>
              <span class="days-badge">{{ e.days }}</span>
              <span class="time-badge-orange">{{ e.start }}–{{ e.end }}</span>
              <button class="btn-del" onclick="deleteStreamingTemp('{{ e.id }}')">✕</button>
            </div>
            {% else %}
            <div class="empty-group" id="stmp-empty">— nenhuma liberação temporária —</div>
            {% endfor %}
          </div>
        </div>
        <div class="add-form" style="height:fit-content">
          <div class="add-form-title">+ Nova Liberação</div>
          <input type="text" id="stmp-ip"    placeholder="IP ou CIDR (ex: 192.168.0.50)">
          <input type="text" id="stmp-label" placeholder="Identificação (ex: Sala Reunião)">
          <div class="form-row">
            <div><div style="font-size:.6rem;color:var(--text4);margin-bottom:.2rem">Início</div><input type="time" id="stmp-start" value="12:00"></div>
            <div><div style="font-size:.6rem;color:var(--text4);margin-bottom:.2rem">Fim</div><input type="time" id="stmp-end" value="13:00"></div>
          </div>
          <select id="stmp-days">
            <option value="MTWHF">Seg – Sex (MTWHF)</option>
            <option value="AS">Sáb + Dom (AS)</option>
            <option value="MTWHFAS">Todos os dias</option>
            <option value="MTWH">Seg – Qui</option>
            <option value="MWF">Seg, Qua, Sex</option>
          </select>
          <button class="btn-add btn-add-orange" onclick="addStreamingTemp()">
            ▷ Adicionar Liberação <span class="spinner" id="stmp-spinner"></span>
          </button>
        </div>
      </div>
    </div>

    <!-- IPs -->
    <div class="section-header" id="sec-ips">
      <h2>◉ Proxy Squid · Controle de IPs</h2>
    </div>
    <div class="info-box" style="margin-bottom:.65rem;margin-top:0">
      ℹ <span>Ao salvar, IPs duplicados entre grupos são <strong>removidos automaticamente</strong> das outras listas para evitar conflitos de ACL.</span>
    </div>
    <div class="list-grid grid-4">
      <div class="list-card accent-green">
        <div class="card-head"><span class="dot"></span>IPs Totais — Acesso Livre</div>
        <div class="card-body">
          <div class="success-box" style="font-size:.7rem">Acesso irrestrito. Streaming sempre liberado.</div>
          <form action="/save/ips_totais" method="POST" style="display:flex;flex-direction:column;gap:.6rem;flex:1">
            <textarea name="content" rows="6" placeholder="Um IP ou CIDR por linha...">{{ data.ips_totais }}</textarea>
            <button type="submit" class="btn-save">💾 Salvar</button>
          </form>
        </div>
      </div>
      <div class="list-card accent-yellow">
        <div class="card-head"><span class="dot"></span>IPs Parciais — Sujeitos a Horário</div>
        <div class="card-body">
          <div class="warn-box" style="font-size:.7rem">Streaming bloqueado fora do horário livre.</div>
          <form action="/save/ips_parciais" method="POST" style="display:flex;flex-direction:column;gap:.6rem;flex:1">
            <textarea name="content" rows="6" placeholder="Um IP ou CIDR por linha...">{{ data.ips_parciais }}</textarea>
            <button type="submit" class="btn-save">💾 Salvar</button>
          </form>
        </div>
      </div>
      <div class="list-card accent-cyan">
        <div class="card-head"><span class="dot"></span>IPs Exceção de Horário</div>
        <div class="card-body">
          <div class="info-box" style="margin-top:0;font-size:.7rem">Acesso amplo a qualquer hora.</div>
          <form action="/save/ips_excecao" method="POST" style="display:flex;flex-direction:column;gap:.6rem;flex:1">
            <textarea name="content" rows="6" placeholder="Um IP ou CIDR por linha...">{{ data.ips_excecao }}</textarea>
            <button type="submit" class="btn-save">💾 Salvar</button>
          </form>
        </div>
      </div>
      <div class="list-card accent-red">
        <div class="card-head"><span class="dot"></span>IPs Bloqueados — Restrito</div>
        <div class="card-body">
          <div class="warn-box" style="font-size:.7rem">Acesso somente a gov, bancos e Teams.</div>
          <form action="/save/ips_bloqueados" method="POST" style="display:flex;flex-direction:column;gap:.6rem;flex:1">
            <textarea name="content" rows="6" placeholder="Um IP ou CIDR por linha...">{{ data.ips_bloqueados }}</textarea>
            <button type="submit" class="btn-save">💾 Salvar</button>
          </form>
        </div>
      </div>
    </div>

    <!-- SITES -->
    <div class="section-header" id="sec-sites">
      <h2>⊡ Sites · Listas de Acesso</h2>
    </div>
    <div class="list-grid grid-4">
      <div class="list-card accent-green">
        <div class="card-head"><span class="dot"></span>Sites Sempre Liberados</div>
        <div class="card-body">
          <form action="/save/sites_liberados" method="POST" style="display:flex;flex-direction:column;gap:.6rem;flex:1">
            <textarea name="content" rows="7" placeholder=".exemplo.com.br">{{ data.sites_liberados }}</textarea>
            <button type="submit" class="btn-save">💾 Salvar</button>
          </form>
        </div>
      </div>
      <div class="list-card accent-red">
        <div class="card-head"><span class="dot"></span>Sites Sempre Bloqueados</div>
        <div class="card-body">
          <form action="/save/sites_bloqueados" method="POST" style="display:flex;flex-direction:column;gap:.6rem;flex:1">
            <textarea name="content" rows="7" placeholder=".exemplo.com">{{ data.sites_bloqueados }}</textarea>
            <button type="submit" class="btn-save">💾 Salvar</button>
          </form>
        </div>
      </div>
      <div class="list-card accent-purple">
        <div class="card-head"><span class="dot"></span>Streaming / Redes Sociais</div>
        <div class="card-body">
          <div class="warn-box" style="font-size:.7rem">Lista usada para controle de horário e bloqueio de streaming.</div>
          <form action="/save/streaming_redes" method="POST" style="display:flex;flex-direction:column;gap:.6rem;flex:1">
            <textarea name="content" rows="5">{{ data.streaming_redes }}</textarea>
            <button type="submit" class="btn-save">💾 Salvar</button>
          </form>
        </div>
      </div>
      <div class="list-card accent-cyan">
        <div class="card-head"><span class="dot"></span>Bancos (Bloqueados+Todos)</div>
        <div class="card-body">
          <form action="/save/sites_bancos" method="POST" style="display:flex;flex-direction:column;gap:.6rem;flex:1">
            <textarea name="content" rows="7">{{ data.sites_bancos }}</textarea>
            <button type="submit" class="btn-save">💾 Salvar</button>
          </form>
        </div>
      </div>
    </div>
    <div class="list-grid grid-2" style="margin-top:.6rem">
      <div class="list-card accent-blue">
        <div class="card-head"><span class="dot"></span>Teams / Microsoft (Todos)</div>
        <div class="card-body">
          <form action="/save/sites_teams" method="POST" style="display:flex;flex-direction:column;gap:.6rem;flex:1">
            <textarea name="content" rows="6">{{ data.sites_teams }}</textarea>
            <button type="submit" class="btn-save">💾 Salvar Lista Teams</button>
          </form>
        </div>
      </div>
      <div class="list-card accent-muted">
        <div class="card-head"><span class="dot"></span>Governo / OAB (Sempre Liberados)</div>
        <div class="card-body">
          <form action="/save/sites_governo" method="POST" style="display:flex;flex-direction:column;gap:.6rem;flex:1">
            <textarea name="content" rows="6">{{ data.sites_governo }}</textarea>
            <button type="submit" class="btn-save">💾 Salvar Lista Gov</button>
          </form>
        </div>
      </div>
    </div>

    <!-- FIREWALL/NAT -->
    <div class="section-header" id="sec-nat">
      <h2>⇄ Firewall · Roteamento Nftables</h2>
    </div>
    <div class="list-grid grid-2">
      <div class="list-card accent-blue">
        <div class="card-head"><span class="dot"></span>Mapeamento NAT 1 para 1</div>
        <div class="card-body">
          <form action="/save/nat_1to1" method="POST" style="display:flex;flex-direction:column;gap:.6rem;flex:1">
            <textarea name="content" rows="6" placeholder="IP_EXTERNO:IP_INTERNO&#10;Ex: 10.14.29.50:192.168.0.50">{{ data.nat_1to1 }}</textarea>
            <button type="submit" class="btn-save">💾 Salvar Tabela NAT</button>
          </form>
        </div>
      </div>
      <div class="list-card accent-muted">
        <div class="card-head"><span class="dot"></span>IPs Externos com Acesso Direto</div>
        <div class="card-body">
          <form action="/save/ips_externos_liberados" method="POST" style="display:flex;flex-direction:column;gap:.6rem;flex:1">
            <textarea name="content" rows="6" placeholder="Um IP ou CIDR por linha...">{{ data.ips_externos_liberados }}</textarea>
            <button type="submit" class="btn-save">💾 Salvar IPs Externos</button>
          </form>
        </div>
      </div>
    </div>

    <!-- Rede WAN → LAN -->
    <div class="section-header" id="sec-wan">
      <h2>&#x21CC; Rede WAN &middot; IPs com Acesso à LAN</h2>
    </div>
    <div class="card">
      <div class="card-head">
        <div class="card-head-l" style="color:var(--orange)">&#x21CC; IPs da rede 10.14.29.0/24 com acesso bidirecional a 192.168.0.0/24 e 192.168.1.0/24</div>
      </div>
      <div class="card-body" style="display:grid;grid-template-columns:1fr 300px;gap:.85rem">
        <div>
          <div class="info-box" style="margin-bottom:.65rem">
            &#x2139; <span>IPs listados aqui podem comunicar-se diretamente com a LAN principal e a rede de monitoramento. Após salvar, clique em <strong>Atualizar NAT</strong> para aplicar.</span>
          </div>
          <form action="/save/ips_rede_wan" method="POST" style="display:flex;flex-direction:column;gap:.6rem">
            <textarea name="content" rows="8" placeholder="Um IP ou CIDR por linha&#10;Ex:&#10;10.14.29.50&#10;10.14.29.100&#10;10.14.29.0/24">{{ data.ips_rede_wan }}</textarea>
            <button type="submit" class="btn-save">&#x1F4BE; Salvar IPs Rede WAN</button>
          </form>
        </div>
        <div style="display:flex;flex-direction:column;gap:.55rem;padding-top:.2rem">
          <div class="warn-box">
            &#x26A0; <span>Após salvar, use <strong>Atualizar NAT</strong> nas Ações Rápidas para carregar as regras no nftables.</span>
          </div>
          <div style="background:var(--bg);border:1px solid var(--border);border-radius:var(--r);padding:.6rem .75rem;font-size:.71rem;color:var(--text3);line-height:1.65">
            <strong style="color:var(--text2);display:block;margin-bottom:.3rem">&#x1F4CB; Comportamento</strong>
            IPs listados recebem rotas bidirecionais:<br>
            10.14.29.x &#x2194; 192.168.0.0/24<br>
            10.14.29.x &#x2194; 192.168.1.0/24
          </div>
        </div>
      </div>
    </div>

  </main>
</div>

<footer>Gateway Control Panel v25 &middot; Debian 13 &middot; PAM Auth</footer>

<script>
function showSpinner(id){const s=document.getElementById(id);if(s)s.style.display='inline-block'}
function hideSpinner(id){const s=document.getElementById(id);if(s)s.style.display='none'}

function flashMsg(msg,type){
  let c=document.getElementById('flash-container');
  if(!c){c=document.createElement('div');c.id='flash-container';c.className='alerts';document.querySelector('.main').prepend(c)}
  const el=document.createElement('div');
  el.className=`alert alert-${type}`;
  el.innerHTML=`<div class="alert-content">${type==='success'?'✓':'✕'} ${msg}</div><button class="alert-close" onclick="this.closest('.alert').remove()">✕</button>`;
  c.appendChild(el);setTimeout(()=>el.remove(),7000);
}

async function syncCA(e){
  e.preventDefault();
  try{
    const r=await fetch('/reload/nginx');
    flashMsg('CA sincronizada para o diretório WPAD.','success');
  }catch(err){flashMsg('Erro ao sincronizar CA.','danger')}
}

async function addSchedule(){
  const label=document.getElementById('sched-label').value.trim();
  const start=document.getElementById('sched-start').value;
  const end=document.getElementById('sched-end').value;
  const days=document.getElementById('sched-days').value;
  if(!label){flashMsg('Informe uma descrição.','danger');return}
  showSpinner('sched-spinner');
  try{
    const res=await fetch('/api/schedules',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({label,start,end,days})});
    const d=await res.json();
    if(!res.ok){flashMsg(d.error||'Erro.','danger');return}
    const list=document.getElementById('schedule-list');
    document.getElementById('sched-empty')?.remove();
    const item=document.createElement('div');
    item.className='schedule-item';item.id=`sched-${d.entry.id}`;
    item.innerHTML=`<span class="label" title="${d.entry.label}">${d.entry.label}</span><span class="days-badge">${d.entry.days}</span><span class="time-badge-blue">${d.entry.start}–${d.entry.end}</span><button class="btn-del" onclick="deleteSchedule('${d.entry.id}')">✕</button>`;
    list.appendChild(item);
    document.getElementById('sched-label').value='';
    flashMsg(`Horário "${label}" adicionado. Faça o Reconf. Squid.`,'success');
  }catch(e){flashMsg('Erro de comunicação.','danger')}
  finally{hideSpinner('sched-spinner')}
}

async function deleteSchedule(id){
  if(!confirm('Remover este horário?'))return;
  try{
    const res=await fetch(`/api/schedules/${id}`,{method:'DELETE'});
    if(!res.ok){flashMsg('Erro ao remover.','danger');return}
    document.getElementById(`sched-${id}`)?.remove();
    const list=document.getElementById('schedule-list');
    if(!list.querySelectorAll('.schedule-item').length)
      list.innerHTML='<div class="empty-group" id="sched-empty">— nenhum horário configurado —</div>';
    flashMsg('Horário removido. Faça o Reconf. Squid.','success');
  }catch(e){flashMsg('Erro de comunicação.','danger')}
}

async function addStreamingTemp(){
  const ip=document.getElementById('stmp-ip').value.trim();
  const label=document.getElementById('stmp-label').value.trim();
  const start=document.getElementById('stmp-start').value;
  const end=document.getElementById('stmp-end').value;
  const days=document.getElementById('stmp-days').value;
  if(!ip){flashMsg('Informe o IP ou CIDR.','danger');return}
  showSpinner('stmp-spinner');
  try{
    const res=await fetch('/api/streaming_temp',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({ip,label:label||ip,start,end,days})});
    const d=await res.json();
    if(!res.ok){flashMsg(d.error||'Erro.','danger');return}
    const list=document.getElementById('streaming-temp-list');
    document.getElementById('stmp-empty')?.remove();
    const item=document.createElement('div');
    item.className='streaming-temp-item';item.id=`stmp-${d.entry.id}`;
    item.innerHTML=`<span class="ip">⬡ ${d.entry.ip}</span><span class="lbl">${d.entry.label}</span><span class="days-badge">${d.entry.days}</span><span class="time-badge-orange">${d.entry.start}–${d.entry.end}</span><button class="btn-del" onclick="deleteStreamingTemp('${d.entry.id}')">✕</button>`;
    list.appendChild(item);
    document.getElementById('stmp-ip').value='';
    document.getElementById('stmp-label').value='';
    document.getElementById('stream-count').textContent=`(${list.querySelectorAll('.streaming-temp-item').length})`;
    flashMsg(`Liberação para ${ip} adicionada. Faça o Reconf. Squid.`,'success');
  }catch(e){flashMsg('Erro de comunicação.','danger')}
  finally{hideSpinner('stmp-spinner')}
}

async function deleteStreamingTemp(id){
  if(!confirm('Remover esta liberação?'))return;
  try{
    const res=await fetch(`/api/streaming_temp/${id}`,{method:'DELETE'});
    if(!res.ok){flashMsg('Erro ao remover.','danger');return}
    document.getElementById(`stmp-${id}`)?.remove();
    const list=document.getElementById('streaming-temp-list');
    document.getElementById('stream-count').textContent=`(${list.querySelectorAll('.streaming-temp-item').length})`;
    if(!list.querySelectorAll('.streaming-temp-item').length)
      list.innerHTML='<div class="empty-group" id="stmp-empty">— nenhuma liberação temporária —</div>';
    flashMsg('Liberação removida. Faça o Reconf. Squid.','success');
  }catch(e){flashMsg('Erro de comunicação.','danger')}
}

setTimeout(()=>document.querySelectorAll('.alerts .alert').forEach(a=>a.remove()),9000);

document.querySelectorAll('.si').forEach(btn=>{
  btn.addEventListener('click',function(e){
    document.querySelectorAll('.si').forEach(s=>s.classList.remove('active'));
    this.classList.add('active');
  });
});
</script>
</body>
</html>
HTML

# ==============================================================================
# 12d. TEMPLATE relatorio.html — v18 (com salvar/imprimir + seção bloqueados)
# ==============================================================================
cat <<'RHTML' > "$PANEL_DIR/templates/relatorio.html"
<!DOCTYPE html>
<html lang="pt-br">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Relatório de Acessos · Gateway</title>
    <link rel="preconnect" href="https://fonts.googleapis.com">
    <link href="https://fonts.googleapis.com/css2?family=Inter:wght@400;500;600;700&family=JetBrains+Mono:wght@400;500;600&display=swap" rel="stylesheet">
    <link href="https://cdnjs.cloudflare.com/ajax/libs/font-awesome/6.4.2/css/all.min.css" rel="stylesheet">
    <script src="https://cdnjs.cloudflare.com/ajax/libs/Chart.js/4.4.1/chart.umd.min.js"></script>
    <style>
        :root{
            --bg:#080c14; --surface:#0f1520; --surface-2:#141c2a; --surface-3:#1a2438;
            --border:#1e2a3d; --border-soft:#151f30; --border-glow:#253450;
            --text:#dde8f8; --text-muted:#5e7898; --text-dim:#2e4060;
            --green:#22d47e; --green-dim:#061a0f; --green-glow:rgba(34,212,126,.12);
            --yellow:#f5c542; --yellow-dim:#1c1505;
            --blue:#4d9fff;  --blue-dim:#071830;   --blue-glow:rgba(77,159,255,.12);
            --red:#ff5f5f;   --red-dim:#1a0707;
            --cyan:#00d4ff;  --cyan-dim:#001820;
            --orange:#ff8c42;--orange-dim:#1c0e04;
            --accent:#5b7fff;
            --mono:'JetBrains Mono',monospace; --sans:'Inter',sans-serif;
            --radius:8px; --radius-lg:12px;
        }
        *,*::before,*::after{box-sizing:border-box;margin:0;padding:0}
        html{font-size:14px}
        body{
            background:var(--bg); color:var(--text); font-family:var(--sans);
            min-height:100vh;
            background-image: radial-gradient(ellipse at 10% 0%, rgba(77,159,255,.05) 0%, transparent 50%),
                              radial-gradient(ellipse at 90% 100%, rgba(34,212,126,.03) 0%, transparent 50%);
        }
        .topbar{
            background:linear-gradient(90deg,rgba(15,21,32,.95),rgba(20,28,42,.95));
            border-bottom:1px solid var(--border); padding:0 2rem; height:58px;
            display:flex; align-items:center; justify-content:space-between;
            position:sticky; top:0; z-index:100; backdrop-filter:blur(12px);
        }
        .topbar-brand{display:flex;align-items:center;gap:.75rem;font-weight:700;font-size:.92rem;color:var(--text);text-decoration:none}
        .topbar-brand .icon{width:32px;height:32px;background:linear-gradient(135deg,var(--green-dim),rgba(34,212,126,.1));border:1px solid rgba(34,212,126,.4);border-radius:8px;display:grid;place-items:center;color:var(--green);font-size:.9rem;box-shadow:0 0 12px var(--green-glow)}
        .vtag{background:linear-gradient(135deg,var(--surface-2),var(--surface));border:1px solid var(--border-glow);border-radius:4px;padding:1px 8px;font-family:var(--mono);font-size:.68rem;color:var(--accent)}
        .topbar-right{display:flex;align-items:center;gap:.5rem}
        .nav-link{font-size:.78rem;font-weight:500;color:var(--text-muted);text-decoration:none;padding:.35rem .75rem;border-radius:6px;border:1px solid transparent;display:flex;align-items:center;gap:.4rem;transition:all .2s}
        .nav-link:hover{color:var(--blue);border-color:rgba(77,159,255,.3);background:var(--blue-dim)}
        .nav-link.active{color:var(--cyan);border-color:rgba(0,212,255,.3);background:var(--cyan-dim)}
        .btn-logout{font-size:.75rem;font-weight:500;color:var(--text-muted);text-decoration:none;padding:.35rem .8rem;border-radius:6px;border:1px solid var(--border);background:var(--surface-2);display:flex;align-items:center;gap:.4rem;transition:all .2s}
        .btn-logout:hover{color:var(--red);border-color:rgba(255,95,95,.4);background:var(--red-dim)}
        .status-dot{width:7px;height:7px;border-radius:50%;background:var(--green);box-shadow:0 0 8px var(--green);animation:pulse 2s infinite}
        @keyframes pulse{0%,100%{opacity:1}50%{opacity:.3}}

        .main{max-width:1440px;margin:0 auto;padding:1.5rem 2rem 5rem}
        .toolbar{display:flex;align-items:center;justify-content:space-between;gap:1rem;margin-bottom:1.5rem;flex-wrap:wrap}
        .period-group{display:flex;align-items:center;gap:.5rem;flex-wrap:wrap}
        .period-label{font-size:.78rem;font-weight:500;color:var(--text-muted)}
        .period-btn{
            font-family:var(--mono);font-size:.74rem;padding:.38rem .8rem;border-radius:6px;
            border:1px solid var(--border);background:var(--surface-2);color:var(--text-muted);
            cursor:pointer;text-decoration:none;transition:all .2s;
        }
        .period-btn:hover{border-color:var(--blue);color:var(--blue);background:var(--blue-dim)}
        .period-btn.active{border-color:rgba(0,212,255,.5);color:var(--cyan);background:var(--cyan-dim);box-shadow:0 0 10px var(--cyan-dim)}

        /* ── Action buttons do relatório ── */
        .report-actions{display:flex;gap:.5rem;flex-wrap:wrap}
        .btn-report{
            display:inline-flex;align-items:center;gap:.45rem;
            padding:.5rem 1rem;border-radius:var(--radius);font-size:.78rem;font-weight:600;
            cursor:pointer;border:1px solid;text-decoration:none;transition:all .2s;
            white-space:nowrap;
        }
        .btn-report:hover{transform:translateY(-1px)}
        .btn-print{background:linear-gradient(135deg,var(--blue-dim),#0a2040);border-color:rgba(77,159,255,.5);color:var(--blue);box-shadow:0 2px 10px var(--blue-glow)}
        .btn-print:hover{box-shadow:0 6px 18px var(--blue-glow);border-color:var(--blue)}
        .btn-save-html{background:linear-gradient(135deg,var(--green-dim),#0e2d1e);border-color:rgba(34,212,126,.5);color:var(--green);box-shadow:0 2px 10px var(--green-glow)}
        .btn-save-html:hover{box-shadow:0 6px 18px var(--green-glow);border-color:var(--green)}
        .btn-pdf{background:linear-gradient(135deg,var(--orange-dim),#221108);border-color:rgba(255,140,66,.5);color:var(--orange);box-shadow:0 2px 10px rgba(255,140,66,.1)}
        .btn-pdf:hover{box-shadow:0 6px 18px rgba(255,140,66,.25);border-color:var(--orange)}

        /* ── KPIs ── */
        .kpi-row{display:grid;grid-template-columns:repeat(4,1fr);gap:1rem;margin-bottom:1.5rem}
        @media(max-width:900px){.kpi-row{grid-template-columns:repeat(2,1fr)}}
        .kpi{
            background:var(--surface);border:1px solid var(--border);border-radius:var(--radius-lg);
            padding:1rem 1.25rem;display:flex;flex-direction:column;gap:.35rem;
            transition:border-color .2s;
        }
        .kpi:hover{border-color:var(--border-glow)}
        .kpi-label{font-size:.68rem;font-weight:700;letter-spacing:.1em;text-transform:uppercase;color:var(--text-muted)}
        .kpi-value{font-family:var(--mono);font-size:1.65rem;font-weight:600;line-height:1}
        .kpi-sub{font-size:.72rem;color:var(--text-dim)}
        .kpi-green .kpi-value{color:var(--green)}.kpi-red .kpi-value{color:var(--red)}.kpi-blue .kpi-value{color:var(--blue)}.kpi-cyan .kpi-value{color:var(--cyan)}
        .kpi-green{border-color:rgba(34,212,126,.15)}.kpi-red{border-color:rgba(255,95,95,.15)}.kpi-blue{border-color:rgba(77,159,255,.15)}.kpi-cyan{border-color:rgba(0,212,255,.15)}

        /* ── Section headers ── */
        .section-header{display:flex;align-items:center;gap:.6rem;margin:2rem 0 1rem;padding-bottom:.6rem;border-bottom:1px solid var(--border-soft)}
        .section-header h2{font-size:.7rem;font-weight:700;letter-spacing:.12em;text-transform:uppercase;color:var(--text-muted)}

        /* ── Charts ── */
        .charts-row{display:grid;grid-template-columns:1fr 1fr;gap:1rem}
        @media(max-width:960px){.charts-row{grid-template-columns:1fr}}
        .chart-card{background:var(--surface);border:1px solid var(--border);border-radius:var(--radius-lg);overflow:hidden}
        .chart-head{padding:.8rem 1rem;border-bottom:1px solid var(--border);font-size:.74rem;font-weight:600;color:var(--text-muted);display:flex;align-items:center;gap:.5rem}
        .chart-body{padding:1rem;height:270px}

        /* ── Tables ── */
        .data-table{width:100%;border-collapse:collapse;font-family:var(--mono);font-size:.75rem}
        .data-table th{
            text-align:left;padding:.55rem .85rem;border-bottom:1px solid var(--border);
            color:var(--text-muted);font-weight:700;letter-spacing:.07em;text-transform:uppercase;font-size:.67rem;white-space:nowrap;
        }
        .data-table td{padding:.5rem .85rem;border-bottom:1px solid var(--border-soft);color:var(--text);vertical-align:middle}
        .data-table tr:last-child td{border-bottom:none}
        .data-table tbody tr:hover td{background:var(--surface-2)}
        .tbl-wrap{background:var(--surface);border:1px solid var(--border);border-radius:var(--radius-lg);overflow:hidden;overflow-x:auto}
        .pill{display:inline-block;border-radius:4px;padding:2px 8px;font-size:.7rem;font-family:var(--mono)}
        .pill-allowed{background:var(--green-dim);color:var(--green);border:1px solid rgba(34,212,126,.35)}
        .pill-denied{background:var(--red-dim);color:var(--red);border:1px solid rgba(255,95,95,.35)}
        .pill-partial{background:var(--yellow-dim);color:var(--yellow);border:1px solid rgba(245,197,66,.35)}
        .bar-inline{display:inline-block;height:5px;border-radius:3px;vertical-align:middle;margin-left:6px;opacity:.7}

        .empty-state{text-align:center;padding:5rem 2rem;font-family:var(--mono);color:var(--text-dim)}
        .empty-state i{font-size:3.5rem;margin-bottom:1.25rem;display:block;color:var(--border-glow)}

        /* ── Bloqueados section ── */
        .blocked-card{background:linear-gradient(135deg,rgba(26,7,7,.8),var(--surface));border:1px solid rgba(255,95,95,.2);border-radius:var(--radius-lg);overflow:hidden}
        .blocked-head{padding:.8rem 1rem;border-bottom:1px solid rgba(255,95,95,.15);font-size:.74rem;font-weight:600;color:var(--red);display:flex;align-items:center;gap:.5rem;justify-content:space-between}
        .blocked-badge{background:var(--red-dim);border:1px solid rgba(255,95,95,.3);border-radius:4px;padding:1px 8px;font-size:.7rem;color:var(--red)}

        .site-list{display:flex;flex-wrap:wrap;gap:3px}
        .site-tag{background:var(--surface-2);border:1px solid var(--border-soft);border-radius:3px;padding:1px 6px;font-size:.68rem;font-family:var(--mono);color:var(--text-muted)}

        footer{text-align:center;padding:2rem;font-family:var(--mono);font-size:.68rem;color:var(--text-dim);border-top:1px solid var(--border-soft);margin-top:2rem}

        /* ── Print styles ── */
        @media print {
            body{background:#fff !important;color:#000 !important}
            .topbar,.report-actions,.period-group{display:none !important}
            .main{padding:1rem !important}
            .kpi{background:#f5f5f5 !important;border:1px solid #ccc !important}
            .kpi-value{color:#000 !important}
            .chart-card,.tbl-wrap,.blocked-card{background:#fff !important;border:1px solid #ccc !important;page-break-inside:avoid}
            .data-table td,.data-table th{color:#000 !important;border-color:#ccc !important}
            .pill-allowed{background:#d4edda !important;color:#155724 !important;border-color:#c3e6cb !important}
            .pill-denied{background:#f8d7da !important;color:#721c24 !important;border-color:#f5c6cb !important}
            .section-header h2{color:#333 !important}
            .tbl-wrap{box-shadow:none !important}
            footer{color:#666 !important}
        }
    </style>
</head>
<body>
<header class="topbar">
    <a href="/" class="topbar-brand">
        <span class="icon"><i class="fa-solid fa-shield-halved"></i></span>
        Gateway Control Panel
    </a>
    <div class="topbar-right">
        <a href="/" class="nav-link"><i class="fa-solid fa-sliders"></i> Gestão</a>
        <a href="/relatorio" class="nav-link active"><i class="fa-solid fa-chart-bar"></i> Relatório</a>
        <span class="status-dot"></span>
        <a href="/logout" class="btn-logout"><i class="fa-solid fa-right-from-bracket"></i> Sair</a>
    </div>
</header>
<main class="main">
    <div class="toolbar">
        <div class="period-group">
            <span class="period-label"><i class="fa-solid fa-calendar-days" style="margin-right:.35rem"></i>Período:</span>
            {% for d,lbl in [(1,"Hoje"),(3,"3 dias"),(7,"7 dias"),(14,"14 dias"),(30,"30 dias")] %}
            <a href="/relatorio?days={{ d }}" class="period-btn {% if report.days==d %}active{% endif %}">{{ lbl }}</a>
            {% endfor %}
        </div>
        <div class="report-actions">
            <button class="btn-report btn-print" onclick="window.print()">
                <i class="fa-solid fa-print"></i> Imprimir
            </button>
            <button class="btn-report btn-pdf" onclick="window.print()">
                <i class="fa-solid fa-file-pdf"></i> Salvar PDF
            </button>
            <button class="btn-report btn-save-html" onclick="saveReportHTML()">
                <i class="fa-solid fa-file-arrow-down"></i> Salvar HTML
            </button>
        </div>
    </div>

    {% if report.empty %}
    <div class="empty-state">
        <i class="fa-solid fa-database"></i>
        <div style="font-size:.95rem;margin-bottom:.5rem">Nenhum dado encontrado no log do Squid</div>
        <div style="font-size:.8rem">Período: últimos {{ report.days }} dia(s) · Verifique se o Squid está ativo e se /var/log/squid/access.log existe.</div>
    </div>
    {% else %}

    <!-- KPIs -->
    <div class="kpi-row">
        <div class="kpi kpi-blue">
            <div class="kpi-label"><i class="fa-solid fa-list-check" style="margin-right:.3rem"></i>Total de Requisições</div>
            <div class="kpi-value">{{ "{:,}".format(report.total).replace(",",".") }}</div>
            <div class="kpi-sub">últimos {{ report.days }} dia(s)</div>
        </div>
        <div class="kpi kpi-green">
            <div class="kpi-label"><i class="fa-solid fa-circle-check" style="margin-right:.3rem"></i>Permitidas</div>
            <div class="kpi-value">{{ "{:,}".format(report.total_allowed).replace(",",".") }}</div>
            <div class="kpi-sub">{{ "%.1f"|format(report.total_allowed/report.total*100) }}% do total</div>
        </div>
        <div class="kpi kpi-red">
            <div class="kpi-label"><i class="fa-solid fa-ban" style="margin-right:.3rem"></i>Negadas / Bloqueadas</div>
            <div class="kpi-value">{{ "{:,}".format(report.total_denied).replace(",",".") }}</div>
            <div class="kpi-sub">{{ "%.1f"|format(report.total_denied/report.total*100) }}% do total</div>
        </div>
        <div class="kpi kpi-cyan">
            <div class="kpi-label"><i class="fa-solid fa-arrow-up-from-bracket" style="margin-right:.3rem"></i>Banda Transferida</div>
            {% set gb=report.total_bytes/1073741824 %}{% set mb=report.total_bytes/1048576 %}
            <div class="kpi-value">{% if gb>=1 %}{{ "%.2f"|format(gb) }} GB{% else %}{{ "%.1f"|format(mb) }} MB{% endif %}</div>
            <div class="kpi-sub">via proxy Squid</div>
        </div>
    </div>

    <!-- Gráficos -->
    <div class="section-header">
        <h2><i class="fa-solid fa-chart-area" style="margin-right:.4rem"></i>Análise por Hora e por Data</h2>
    </div>
    <div class="charts-row">
        <div class="chart-card">
            <div class="chart-head"><i class="fa-solid fa-clock" style="color:var(--cyan)"></i> Requisições por Hora do Dia</div>
            <div class="chart-body"><canvas id="chartHour"></canvas></div>
        </div>
        <div class="chart-card">
            <div class="chart-head"><i class="fa-solid fa-calendar-days" style="color:var(--blue)"></i> Requisições por Data</div>
            <div class="chart-body"><canvas id="chartDate"></canvas></div>
        </div>
    </div>

    <!-- Top IPs -->
    <div class="section-header">
        <h2><i class="fa-solid fa-network-wired" style="margin-right:.4rem"></i>Top IPs por Atividade</h2>
    </div>
    <div class="tbl-wrap">
        <table class="data-table">
            <thead><tr><th>#</th><th>IP Cliente</th><th>Permitidas</th><th>Negadas</th><th>Total</th><th>Banda (MB)</th><th>Volume</th></tr></thead>
            <tbody>
            {% set max_total=(report.top_ips[0][1].allowed+report.top_ips[0][1].denied) if report.top_ips else 1 %}
            {% for ip,s in report.top_ips %}{% set tot=s.allowed+s.denied %}
            <tr>
                <td style="color:var(--text-dim)">{{ loop.index }}</td>
                <td><code style="color:var(--cyan);font-family:var(--mono)">{{ ip }}</code></td>
                <td><span class="pill pill-allowed">{{ "{:,}".format(s.allowed).replace(",",".") }}</span></td>
                <td>{% if s.denied > 0 %}<span class="pill pill-denied">{{ "{:,}".format(s.denied).replace(",",".") }}</span>{% else %}<span style="color:var(--text-dim)">0</span>{% endif %}</td>
                <td style="font-weight:600">{{ "{:,}".format(tot).replace(",",".") }}</td>
                <td style="color:var(--blue);font-family:var(--mono)">{{ "%.1f"|format(s.bytes/1048576) }}</td>
                <td><span class="bar-inline" style="width:{{ (tot/max_total*130)|int }}px;background:var(--blue)"></span></td>
            </tr>
            {% endfor %}
            </tbody>
        </table>
    </div>

    <!-- Top Domínios -->
    <div class="section-header">
        <h2><i class="fa-solid fa-globe" style="margin-right:.4rem"></i>Top Domínios / Sites Acessados</h2>
    </div>
    <div class="tbl-wrap">
        <table class="data-table">
            <thead><tr><th>#</th><th>Domínio / Site</th><th>Permitidas</th><th>Negadas</th><th>Total</th><th>Banda (MB)</th></tr></thead>
            <tbody>
            {% for domain,s in report.top_domains %}{% set tot=s.allowed+s.denied %}
            <tr>
                <td style="color:var(--text-dim)">{{ loop.index }}</td>
                <td style="max-width:300px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;color:var(--text)">{{ domain }}</td>
                <td><span class="pill pill-allowed">{{ s.allowed }}</span></td>
                <td>{% if s.denied>0 %}<span class="pill pill-denied">{{ s.denied }}</span>{% else %}<span style="color:var(--text-dim)">0</span>{% endif %}</td>
                <td>{{ tot }}</td>
                <td style="color:var(--blue);font-family:var(--mono)">{{ "%.2f"|format(s.bytes/1048576) }}</td>
            </tr>
            {% endfor %}
            </tbody>
        </table>
    </div>

    <!-- Tentativas bloqueadas recentes -->
    {% if report.recent_denied %}
    <div class="section-header">
        <h2><i class="fa-solid fa-shield-xmark" style="margin-right:.4rem;color:var(--red)"></i>Últimas Tentativas Bloqueadas (todos os IPs)</h2>
    </div>
    <div class="tbl-wrap">
        <table class="data-table">
            <thead><tr><th>Data/Hora</th><th>IP Origem</th><th>Site / Domínio</th><th>Método</th><th>Código</th><th>Banda</th></tr></thead>
            <tbody>
            {% for r in report.recent_denied[:50] %}
            <tr>
                <td style="font-family:var(--mono);font-size:.72rem;white-space:nowrap;color:var(--text-muted)">{{ r.ts_str }}</td>
                <td><code style="color:var(--red);font-family:var(--mono);font-size:.75rem">{{ r.client }}</code></td>
                <td style="max-width:280px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;font-family:var(--mono);font-size:.73rem">{{ r.domain }}</td>
                <td style="color:var(--text-muted);font-family:var(--mono);font-size:.72rem">{{ r.method }}</td>
                <td><span class="pill pill-denied">{{ r.code }}</span></td>
                <td style="font-family:var(--mono);font-size:.72rem;color:var(--text-muted)">{{ r.bytes }} B</td>
            </tr>
            {% endfor %}
            </tbody>
        </table>
    </div>
    {% endif %}

    <!-- IPs Bloqueados — atividade específica -->
    {% if report.blocked_by_ip %}
    <div class="section-header">
        <h2><i class="fa-solid fa-ban" style="margin-right:.4rem;color:var(--red)"></i>Atividade dos IPs Bloqueados · Acessos e Tentativas</h2>
    </div>
    <div class="blocked-card" style="margin-bottom:1rem">
        <div class="blocked-head">
            <span><i class="fa-solid fa-eye" style="margin-right:.5rem"></i>Resumo por IP Bloqueado — sites acessados (gov/bancos) e tentativas negadas</span>
            <span class="blocked-badge">{{ report.blocked_by_ip|length }} IP(s)</span>
        </div>
        <div style="overflow-x:auto">
            <table class="data-table">
                <thead>
                    <tr>
                        <th>IP Bloqueado</th>
                        <th>Acessos Permitidos</th>
                        <th>Tentativas Negadas</th>
                        <th>Banda (MB)</th>
                        <th>Sites Acessados (top 10)</th>
                    </tr>
                </thead>
                <tbody>
                {% for item in report.blocked_by_ip %}
                <tr>
                    <td><code style="color:var(--red);font-family:var(--mono)">{{ item.ip }}</code></td>
                    <td>
                        {% if item.allowed > 0 %}<span class="pill pill-partial">{{ item.allowed }} (gov/banco)</span>
                        {% else %}<span style="color:var(--text-dim)">0</span>{% endif %}
                    </td>
                    <td>
                        {% if item.denied > 0 %}<span class="pill pill-denied">{{ item.denied }}</span>
                        {% else %}<span style="color:var(--text-dim)">0</span>{% endif %}
                    </td>
                    <td style="font-family:var(--mono);color:var(--text-muted)">{{ "%.2f"|format(item.bytes/1048576) }}</td>
                    <td>
                        <div class="site-list">
                        {% for site in item.sites %}<span class="site-tag">{{ site }}</span>{% endfor %}
                        </div>
                    </td>
                </tr>
                {% endfor %}
                </tbody>
            </table>
        </div>
    </div>

    <!-- Log detalhado dos bloqueados -->
    {% if report.blocked_recent %}
    <div class="blocked-card">
        <div class="blocked-head">
            <span><i class="fa-solid fa-clock-rotate-left" style="margin-right:.5rem"></i>Log Detalhado — IPs Bloqueados (últimas {{ report.blocked_recent|length }} entradas)</span>
            <span class="blocked-badge">Mais recentes primeiro</span>
        </div>
        <div style="overflow-x:auto">
            <table class="data-table">
                <thead>
                    <tr>
                        <th>Data/Hora</th>
                        <th>IP Bloqueado</th>
                        <th>Site / Domínio</th>
                        <th>Resultado</th>
                        <th>Código</th>
                        <th>Banda</th>
                    </tr>
                </thead>
                <tbody>
                {% for r in report.blocked_recent %}
                <tr>
                    <td style="font-family:var(--mono);font-size:.72rem;white-space:nowrap;color:var(--text-muted)">{{ r.ts_str }}</td>
                    <td><code style="color:var(--red);font-family:var(--mono);font-size:.74rem">{{ r.client }}</code></td>
                    <td style="max-width:260px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;font-family:var(--mono);font-size:.72rem">{{ r.domain }}</td>
                    <td>
                        {% if r.denied %}
                            <span class="pill pill-denied"><i class="fa-solid fa-xmark"></i> Negado</span>
                        {% else %}
                            <span class="pill pill-partial"><i class="fa-solid fa-check"></i> Permitido (gov/banco)</span>
                        {% endif %}
                    </td>
                    <td style="font-family:var(--mono);font-size:.72rem;color:var(--text-muted)">{{ r.code }}</td>
                    <td style="font-family:var(--mono);font-size:.72rem;color:var(--text-muted)">{{ r.bytes }} B</td>
                </tr>
                {% endfor %}
                </tbody>
            </table>
        </div>
    </div>
    {% endif %}
    {% endif %}

    {% endif %}
</main>

<footer id="report-footer">
    Gateway Control Panel · Relatório gerado em tempo real · {{ report.days }} dia(s) · /var/log/squid/access.log
</footer>

<script>
{% if not report.empty %}
const baseOpts={
    responsive:true, maintainAspectRatio:false,
    plugins:{legend:{labels:{color:'#5e7898',font:{family:"'JetBrains Mono'",size:11}}}},
    scales:{
        x:{ticks:{color:'#5e7898',font:{family:"'JetBrains Mono'",size:10}},grid:{color:'#151f30'}},
        y:{ticks:{color:'#5e7898',font:{family:"'JetBrains Mono'",size:10}},grid:{color:'#151f30'}}
    }
};

const hL=[{% for h,_ in report.by_hour %}"{{ '%02d'|format(h) }}h"{% if not loop.last %},{% endif %}{% endfor %}];
const hA=[{% for _,s in report.by_hour %}{{ s.allowed }}{% if not loop.last %},{% endif %}{% endfor %}];
const hD=[{% for _,s in report.by_hour %}{{ s.denied }}{% if not loop.last %},{% endif %}{% endfor %}];

new Chart(document.getElementById('chartHour'),{
    type:'bar',
    data:{labels:hL,datasets:[
        {label:'Permitidas',data:hA,backgroundColor:'rgba(34,212,126,.5)',borderColor:'#22d47e',borderWidth:1,borderRadius:3},
        {label:'Negadas',data:hD,backgroundColor:'rgba(255,95,95,.5)',borderColor:'#ff5f5f',borderWidth:1,borderRadius:3}
    ]},
    options:baseOpts
});

const dL=[{% for d,_ in report.by_date %}"{{ d }}"{% if not loop.last %},{% endif %}{% endfor %}];
const dA=[{% for _,s in report.by_date %}{{ s.allowed }}{% if not loop.last %},{% endif %}{% endfor %}];
const dD=[{% for _,s in report.by_date %}{{ s.denied }}{% if not loop.last %},{% endif %}{% endfor %}];

new Chart(document.getElementById('chartDate'),{
    type:'line',
    data:{labels:dL,datasets:[
        {label:'Permitidas',data:dA,borderColor:'#22d47e',backgroundColor:'rgba(34,212,126,.12)',fill:true,tension:.35,pointRadius:3,pointHoverRadius:6},
        {label:'Negadas',data:dD,borderColor:'#ff5f5f',backgroundColor:'rgba(255,95,95,.08)',fill:true,tension:.35,pointRadius:3,pointHoverRadius:6}
    ]},
    options:baseOpts
});
{% endif %}

function saveReportHTML() {
    const html = '<!DOCTYPE html>\n' + document.documentElement.outerHTML;
    const blob = new Blob([html], {type: 'text/html;charset=utf-8'});
    const url  = URL.createObjectURL(blob);
    const a    = document.createElement('a');
    const ts   = new Date().toISOString().slice(0,16).replace('T','_').replace(':','');
    a.href = url;
    a.download = `relatorio-gateway-${ts}.html`;
    a.click();
    URL.revokeObjectURL(url);
}
</script>
</body>
</html>
RHTML

# ==============================================================================
# 12e. PERMISSÕES DOS ARQUIVOS DO PAINEL
# ==============================================================================
chown -R root:"$PANEL_USER" "$PANEL_DIR"
chmod -R 750 "$PANEL_DIR"

chown -R root:"$PANEL_USER" /etc/squid
chmod 775 /etc/squid
for _f in \
    /etc/squid/ips_totais.txt \
    /etc/squid/ips_parciais.txt \
    /etc/squid/ips_bloqueados.txt \
    /etc/squid/ips_excecao_horario.txt \
    /etc/squid/sites_liberados.txt \
    /etc/squid/sites_bloqueados.txt \
    /etc/squid/streaming_redes.txt \
    /etc/squid/sites_governo.txt \
    /etc/squid/sites_bancos.txt \
    /etc/squid/sites_teams.txt \
    /etc/squid/acl_horarios.conf \
    /etc/squid/acl_streaming_temp.conf \
    /etc/squid/horarios_livres.json \
    /etc/squid/streaming_temp.json; do
    touch "$_f" 2>/dev/null || true
    chown root:"$PANEL_USER" "$_f"
    chmod 664 "$_f"
done

chown -R root:"$PANEL_USER" /etc/nftables
chmod 775 /etc/nftables
for _f in /etc/nftables/nat_1to1.txt /etc/nftables/ips_externos_liberados.txt /etc/nftables/ips_rede_wan.txt; do
    touch "$_f"
    chown root:"$PANEL_USER" "$_f"
    chmod 664 "$_f"
done

chmod o+r /var/log/squid/access.log 2>/dev/null || true
ok "Permissões ajustadas para $PANEL_USER."

# ==============================================================================
# 12f. ARQUIVO DE AMBIENTE
# ==============================================================================
if [ ! -f /etc/gateway-panel.env ]; then
    PANEL_SECRET=$(python3 -c "import secrets; print(secrets.token_hex(32))")
    # Gerar senha aleatória segura para o painel (16 chars legíveis)
    PANEL_AUTO_PWD=$(python3 -c "
import random, string
# Sem caracteres especiais: systemd interpreta ! # & no EnvironmentFile
chars = string.ascii_letters + string.digits
print(''.join(random.SystemRandom().choice(chars) for _ in range(20)))
")
    cat <<ENVEOF > /etc/gateway-panel.env
# Gateway Control Panel — variáveis de ambiente
# Gerado em $(date '+%Y-%m-%d %H:%M:%S')
PANEL_SECRET_KEY=${PANEL_SECRET}
LAN_NET=${LAN_NET}
LAN_IP=${LAN_IP}
LAN_IF=${LAN_IF}
PANEL_AUTH_USER=root
SQUID_SERVICE=${SQUID_SVC:-squid}
SQUID_BIN=${SQUID_BIN:-/usr/sbin/squid}
# Senha de acesso ao painel (gerada automaticamente)
# Para alterar: edite esta linha e reinicie o serviço (systemctl restart gateway-panel)
PANEL_PASSWORD="${PANEL_AUTO_PWD}"
ENVEOF
    chmod 640 /etc/gateway-panel.env
    chown root:"$PANEL_USER" /etc/gateway-panel.env
else
    # Atualizar LAN_NET, LAN_IP, LAN_IF — preservando PANEL_PASSWORD com aspas intactas
    grep -v '^LAN_NET=\|^LAN_IP=\|^LAN_IF=' /etc/gateway-panel.env > /etc/gateway-panel.env.tmp
    echo "LAN_NET=${LAN_NET}" >> /etc/gateway-panel.env.tmp
    echo "LAN_IP=${LAN_IP}"   >> /etc/gateway-panel.env.tmp
    echo "LAN_IF=${LAN_IF}"   >> /etc/gateway-panel.env.tmp
    chmod 640 /etc/gateway-panel.env.tmp
    mv /etc/gateway-panel.env.tmp /etc/gateway-panel.env
    chown root:"$PANEL_USER" /etc/gateway-panel.env
fi
ok "Arquivo de ambiente: /etc/gateway-panel.env"

# ==============================================================================
# 12g. SERVIÇO SYSTEMD DO PAINEL
# ==============================================================================
cat <<EOF > /etc/systemd/system/gateway-panel.service
[Unit]
Description=Gateway Control Panel (Flask/Gunicorn)
After=network.target squid.service nftables.service

[Service]
Type=simple
User=$PANEL_USER
Group=$PANEL_USER
WorkingDirectory=$PANEL_DIR
EnvironmentFile=/etc/gateway-panel.env
ExecStart=$PANEL_DIR/venv/bin/gunicorn \\
    --workers 2 \\
    --bind ${LAN_IP}:5000 \\
    --timeout 60 \\
    --preload \\
    --access-logfile /var/log/gateway-panel/access.log \\
    --error-logfile  /var/log/gateway-panel/error.log \\
    app:app
Restart=on-failure
RestartSec=5
# Segurança: ProtectSystem e NoNewPrivileges foram removidos intencionalmente.
# O PAM (autenticação) precisa acessar /etc/shadow e módulos em /lib/security/.
# NoNewPrivileges=yes bloqueia o PAM de verificar senhas do sistema.
# ProtectSystem=full torna /etc read-only e impede leitura de /etc/pam.d/.
# PrivateTmp isola /tmp mas pode quebrar sockets de autenticação.
# A segurança é mantida pelo usuário gateway-panel sem shell + sudoers restrito.
ReadWritePaths=/etc/squid /etc/nftables /var/log/gateway-panel /var/log/squid /run/squid /var/www/gateway-wpad /etc/gateway-panel.env /etc/nftables/nat_1to1.txt /etc/nftables/ips_externos_liberados.txt /etc/nftables/ips_rede_wan.txt
SupplementaryGroups=shadow

[Install]
WantedBy=multi-user.target
EOF

mkdir -p /var/log/gateway-panel
chown "$PANEL_USER":"$PANEL_USER" /var/log/gateway-panel

# Criar script de diagnóstico/reset de senha do painel
cat <<'DIAGEOF' > /usr/local/bin/gateway-panel-senha.sh
#!/bin/bash
# Utilitário de gerenciamento de senha do painel Gateway
# Uso: gateway-panel-senha.sh [nova_senha]

ENV_FILE="/etc/gateway-panel.env"
SVC="gateway-panel"

if [ ! -f "$ENV_FILE" ]; then
    echo "[ERRO] Arquivo $ENV_FILE não encontrado."
    exit 1
fi

echo ""
echo "=== Gateway Control Panel — Gerenciador de Senha ==="
echo ""

# Exibir senha atual (se houver)
CURRENT=$(grep '^PANEL_PASSWORD=' "$ENV_FILE" 2>/dev/null | cut -d= -f2-)
CURRENT="${CURRENT//"/}"
if [ -n "$CURRENT" ]; then
    echo "  Senha atual: $CURRENT"
else
    echo "  Senha atual: (não definida — usando PAM do sistema)"
fi
echo ""

# Se passou senha como argumento, aplicar direto
if [ -n "${1:-}" ]; then
    NEW_PWD="$1"
else
    read -rsp "  Nova senha (Enter para gerar automaticamente): " NEW_PWD
    echo ""
fi

if [ -z "$NEW_PWD" ]; then
    NEW_PWD=$(python3 -c "import random,string; print(''.join(random.SystemRandom().choice(string.ascii_letters+string.digits) for _ in range(20)))")
    echo "  Senha gerada: $NEW_PWD"
fi

# Atualizar ou criar a linha no .env — SEMPRE com aspas duplas
# Sem aspas: systemd EnvironmentFile pode misinterpretar caracteres
if grep -q '^PANEL_PASSWORD=' "$ENV_FILE"; then
    sed -i "s|^PANEL_PASSWORD=.*|PANEL_PASSWORD=\"${NEW_PWD}\"|" "$ENV_FILE"
else
    echo "PANEL_PASSWORD=\"${NEW_PWD}\"" >> "$ENV_FILE"
fi

echo ""
echo "  [OK] Senha definida: $NEW_PWD"
echo ""

# Reiniciar o serviço para carregar a nova senha
if systemctl is-active --quiet "$SVC" 2>/dev/null; then
    systemctl restart "$SVC"
    echo "  [OK] Serviço $SVC reiniciado."
fi

echo ""
echo "  Acesse: http://$(grep '^LAN_NET=' "$ENV_FILE" | cut -d= -f2 | cut -d/ -f1 | sed 's/\.0$/\.1/'):5000"
echo ""
DIAGEOF
chmod +x /usr/local/bin/gateway-panel-senha.sh
ok "Script de gerenciamento de senha: /usr/local/bin/gateway-panel-senha.sh"

systemctl daemon-reload
systemctl enable --force gateway-panel 2>/dev/null || \
    systemctl enable gateway-panel 2>/dev/null || true
systemctl restart gateway-panel
ok "Painel Web iniciado (http://$LAN_IP:5000)."

# ==============================================================================
# 13. SINCRONISMO INICIAL
# ==============================================================================
log "Executando sincronismo inicial das tabelas dinâmicas..."
/usr/local/bin/update-nat1to1.sh

# ==============================================================================
# RESUMO FINAL
# ==============================================================================
echo ""
echo -e "${CYAN}=============================================================================="
echo " IMPLANTAÇÃO CONCLUÍDA COM SUCESSO (DEBIAN 13)"
echo "=============================================================================="
echo -e "${NC}"
if [ "${WAN_MODE:-static}" = "dhcp" ]; then
    echo -e " ${GREEN}WAN:${NC}      $WAN_IF  (DHCP — IP: ${WAN_IP}/${WAN_PREFIX}  GW: ${WAN_GW})"
else
    echo -e " ${GREEN}WAN:${NC}      $WAN_IF  (${WAN_IP}/${WAN_PREFIX} via ${WAN_GW})"
fi
echo -e " ${GREEN}LAN:${NC}      $LAN_IF  ($LAN_IP / ${LAN_NET})"
echo -e " ${GREEN}DNS:${NC}      BIND9 em $LAN_IP:53"
echo -e " ${GREEN}PROXY:${NC}    Squid em $LAN_IP:3128 (cache: ${CACHE_MEM_MB} MB)"
echo -e " ${GREEN}NTP:${NC}      Chrony servindo ${LAN_NET}"
echo -e " ${GREEN}FIREWALL:${NC} nftables ativo"
echo -e " ${GREEN}REDE WAN:${NC}  ${WAN_IP}/${WAN_PREFIX} via ${WAN_IF} (DNS: 10.14.8.20, 10.1.6.222)"
echo -e " ${GREEN}PAINEL:${NC}   http://$LAN_IP:5000"
echo -e " ${GREEN}WPAD:${NC}     http://$LAN_IP:8080  (pac + download CA)"
echo -e " ${GREEN}CA:${NC}       http://$LAN_IP:8080/ca  (instalar nos clientes)"
echo ""
echo -e "${CYAN}── Política de IPs Bloqueados ─────────────────────────────────────────────${NC}"
echo -e "  PERMITIDO para bloqueados:  gov/sp/oab, bancos, sites_liberados, Teams"
echo -e "  NEGADO para bloqueados:     tudo o mais (redes sociais, streaming, geral)"
echo ""
echo -e "${CYAN}── Acesso ao painel ───────────────────────────────────────────────────────${NC}"
echo -e " URL:        ${CYAN}http://$LAN_IP:5000${NC}"
# Ler a senha gerada para exibir no resumo
_PANEL_PWD=$(grep '^PANEL_PASSWORD=' /etc/gateway-panel.env 2>/dev/null | cut -d= -f2-)
_PANEL_PWD="${_PANEL_PWD//\"/}"
echo -e " ${GREEN}SENHA PAINEL:${NC} ${_PANEL_PWD:-ver /etc/gateway-panel.env}"
echo -e "             ${YELLOW}(salve esta senha! para alterar: edite /etc/gateway-panel.env)${NC}"
echo ""
echo -e "${CYAN}── Notas para máquina física (Debian 13) ──────────────────────────────────${NC}"
echo -e " ${YELLOW}►${NC} Rede configurada via ip direto + /etc/network/interfaces"
echo -e " ${YELLOW}►${NC} NetworkManager desabilitado (não compatível com gateway)"
echo -e " ${YELLOW}►${NC} systemd-resolved mascarado (BIND9 usa porta 53)"
echo -e " ${YELLOW}►${NC} iptables aponta para backend nftables"
echo -e " ${YELLOW}►${NC} Squid SSL: ${SQUID_SSL_STATUS:-verificar}"
echo -e " ${YELLOW}►${NC} Após reboot, verifique: systemctl status squid bind9 nftables"
echo ""