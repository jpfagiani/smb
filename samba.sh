#!/bin/bash
# =============================================================================
# SERVIDOR SAMBA — DEBIAN 13 (CDPNI)
# Script único de instalação completa
# Versão: 6.3 — Removidas opções deprecated Samba 4.22 (syslog, encrypt passwords, socket options)
#
# Inclui:
#   - RAID 5 (5 discos, ~8TB úteis)
#   - Samba 4 com 33 pastas compartilhadas
#   - Permissões 777 recursivas em todas as pastas
#   - Controle de acesso exclusivamente via Samba (valid users)
#   - Usuários e grupos iniciais
#   - Painel web (Nginx + PHP + HTTPS)
#   - Firewall, Fail2ban, S.M.A.R.T, monitoramento RAID
# =============================================================================

set -euo pipefail
IFS=$'\n\t'

# ---------------------------------------------------------------------------
# CORES E LOG
# ---------------------------------------------------------------------------
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'; BOLD='\033[1m'

LOG_FILE="/var/log/samba_setup.log"
mkdir -p "$(dirname "$LOG_FILE")"
exec > >(tee -a "$LOG_FILE") 2>&1

log()    { echo -e "${GREEN}[$(date '+%Y-%m-%d %H:%M:%S')] ✔ $*${NC}"; }
warn()   { echo -e "${YELLOW}[$(date '+%Y-%m-%d %H:%M:%S')] ⚠ $*${NC}"; }
error()  { echo -e "${RED}[$(date '+%Y-%m-%d %H:%M:%S')] ✘ ERRO: $*${NC}"; exit 1; }
info()   { echo -e "${CYAN}[$(date '+%Y-%m-%d %H:%M:%S')] ℹ $*${NC}"; }
header() { echo -e "\n${BOLD}${BLUE}═══════════════════════════════════════════${NC}";
           echo -e "${BOLD}${BLUE}  $*${NC}";
           echo -e "${BOLD}${BLUE}═══════════════════════════════════════════${NC}\n"; }

[[ $EUID -ne 0 ]] && error "Execute este script como root!"

# ---------------------------------------------------------------------------
# CONFIGURAÇÕES GLOBAIS
# ---------------------------------------------------------------------------
SAMBA_IP="192.168.0.11"
SAMBA_MASK="24"
GATEWAY="192.168.0.1"
DNS_SERVER="192.168.0.1"
SAMBA_WORKGROUP="WORKGROUP"
SAMBA_SERVERNAME="CDPNI"
SAMBA_REALM="cdpni.local"
RAID_MOUNT="/mnt/raid"
RAID_DEVICE="/dev/md0"
SAMBA_ROOT="${RAID_MOUNT}/shares"
RECYCLE_DIR="${RAID_MOUNT}/recycle"
LOG_SAMBA="/var/log/samba"
DEFAULT_PASS="1234"

# ---------------------------------------------------------------------------
# LISTA COMPLETA DE COMPARTILHAMENTOS
# Formato: "NomePasta:grp_grupo:visivel(yes|no)"
# Permissões: 777 em todas — controle de acesso via valid users no smb.conf
# ---------------------------------------------------------------------------
declare -a ALL_SHARES=(
    "Administrativo:grp_administrativo:yes"
    "Aevp:grp_aevp:yes"
    "Almoxarifado:grp_almoxarifado:yes"
    "Cadastro:grp_cadastro:yes"
    "Canil:grp_canil:yes"
    "Chefia_Turno_I:grp_chefia_turno:yes"
    "Chefia_Turno_II:grp_chefia_turno:yes"
    "Chefia_Turno_III:grp_chefia_turno:yes"
    "Chefia_Turno_IV:grp_chefia_turno:yes"
    "Cipa:grp_cipa:yes"
    "Conexao_Familiar:grp_conexao_familiar:yes"
    "CPD:grp_cpd:no"
    "csd:grp_csd:yes"
    "Diretoria_Geral:grp_diretoria:yes"
    "Educacao:grp_educacao:yes"
    "Financas:grp_financas:yes"
    "Inclusao:grp_inclusao:yes"
    "Infraestrutura:grp_infraestrutura:yes"
    "Nucleo_de_Pessoal:grp_nucleo_pessoal:yes"
    "Papel_de_Parede:grp_papel_parede:yes"
    "Planilhas:grp_planilhas:yes"
    "Papel_de_Parede:grp_papel_parede:yes"
    "Planilhas:grp_planilhas:yes"
    "Portaria_Turno_I:grp_portaria:yes"
    "Portaria_Turno_II:grp_portaria:yes"
    "Portaria_Turno_III:grp_portaria:yes"
    "Portaria_Turno_IV:grp_portaria:yes"
    "Publico:grp_publico:yes"
    "Rol_de_Visitas:grp_rol_visitas:yes"
    "Saude:grp_saude:yes"
    "Scanner:grp_scanner:yes"
    "Simic:grp_simic:yes"
    "Sindicancia:grp_sindicancia:yes"
    "Supervisao:grp_supervisao:yes"
)

# Usuários iniciais: "login:nome_completo:grupo_primario:grupos_extras"
# Formato: PRIMARY é o 1º grupo (pasta principal do usuário)
# Grupos extras = demais grupos de acesso
declare -a INITIAL_USERS=(
    # ── Administradores (acesso total) ────────────────────────────
    "sambadmin:Administrador Samba:grp_administrativo:grp_administrativo,grp_aevp,grp_almoxarifado,grp_cadastro,grp_canil,grp_chefia_turno,grp_cipa,grp_conexao_familiar,grp_cpd,grp_csd,grp_diretoria,grp_educacao,grp_financas,grp_inclusao,grp_infraestrutura,grp_nucleo_pessoal,grp_papel_parede,grp_planilhas,grp_portaria,grp_rol_visitas,grp_saude,grp_scanner,grp_simic,grp_sindicancia,grp_supervisao"
    "cpd:CPD - Acesso Total:grp_cpd:grp_administrativo,grp_aevp,grp_almoxarifado,grp_cadastro,grp_canil,grp_chefia_turno,grp_cipa,grp_conexao_familiar,grp_cpd,grp_csd,grp_diretoria,grp_educacao,grp_financas,grp_inclusao,grp_infraestrutura,grp_nucleo_pessoal,grp_papel_parede,grp_planilhas,grp_portaria,grp_rol_visitas,grp_saude,grp_scanner,grp_simic,grp_sindicancia,grp_supervisao"
    "jpfagiani:JP Fagiani - Acesso Root:grp_administrativo:grp_administrativo,grp_aevp,grp_almoxarifado,grp_cadastro,grp_canil,grp_chefia_turno,grp_cipa,grp_conexao_familiar,grp_cpd,grp_csd,grp_diretoria,grp_educacao,grp_financas,grp_inclusao,grp_infraestrutura,grp_nucleo_pessoal,grp_papel_parede,grp_planilhas,grp_portaria,grp_rol_visitas,grp_saude,grp_scanner,grp_simic,grp_sindicancia,grp_supervisao"
    "rcborges:RC Borges - Acesso Total:grp_administrativo:grp_administrativo,grp_aevp,grp_almoxarifado,grp_cadastro,grp_canil,grp_chefia_turno,grp_cipa,grp_conexao_familiar,grp_cpd,grp_csd,grp_diretoria,grp_educacao,grp_financas,grp_inclusao,grp_infraestrutura,grp_nucleo_pessoal,grp_papel_parede,grp_planilhas,grp_portaria,grp_rol_visitas,grp_saude,grp_scanner,grp_simic,grp_sindicancia,grp_supervisao"
    # ── Usuários por setor ─────────────────────────────────────────
    "adm:Administrativo:grp_administrativo:"
    "aevp:AEVP:grp_aevp:"
    "almoxarifado:Almoxarifado:grp_almoxarifado:"
    "cadastro:Cadastro:grp_cadastro:"
    "canil:Canil:grp_canil:"
    "chefia1:Chefia Turno I:grp_chefia_turno:"
    "chefia2:Chefia Turno II:grp_chefia_turno:"
    "chefia3:Chefia Turno III:grp_chefia_turno:"
    "chefia4:Chefia Turno IV:grp_chefia_turno:"
    "cipa:CIPA:grp_cipa:"
    "conexao:Conexao Familiar:grp_conexao_familiar:"
    "csd:CSD:grp_csd:grp_chefia_turno,grp_csd,grp_rol_visitas,grp_sindicancia"
    "dg:Diretoria Geral:grp_diretoria:"
    "educacao:Educacao:grp_educacao:"
    "financas:Financas:grp_financas:"
    "inclusao:Inclusao:grp_inclusao:"
    "infra:Infraestrutura:grp_infraestrutura:"
    "npessoal:Nucleo de Pessoal:grp_nucleo_pessoal:"
    "portaria:Portaria (todos os turnos):grp_portaria:"
    "rol:Rol de Visitas:grp_rol_visitas:"
    "saude:Saude:grp_saude:"
    "simic:Simic:grp_simic:"
    "sindicancia:Sindicancia:grp_sindicancia:grp_chefia_turno,grp_csd,grp_rol_visitas,grp_sindicancia"
    "supervisao:Supervisao:grp_supervisao:grp_administrativo,grp_aevp,grp_almoxarifado,grp_cadastro,grp_canil,grp_chefia_turno,grp_cipa,grp_conexao_familiar,grp_cpd,grp_csd,grp_diretoria,grp_educacao,grp_financas,grp_inclusao,grp_infraestrutura,grp_nucleo_pessoal,grp_papel_parede,grp_planilhas,grp_portaria,grp_rol_visitas,grp_saude,grp_scanner,grp_simic,grp_sindicancia,grp_supervisao"
)

# ===========================================================================
# 1. DETECÇÃO DOS HDs
# ===========================================================================
header "1. DETECÇÃO AUTOMÁTICA DOS HDs"

info "Detectando discos no sistema..."
mapfile -t ALL_DISKS < <(lsblk -dno NAME,TYPE | awk '$2=="disk"{print "/dev/"$1}' | sort)
[[ ${#ALL_DISKS[@]} -eq 0 ]] && error "Nenhum disco detectado"

printf "%-15s %-10s %-22s %s\n" "DISPOSITIVO" "TAMANHO" "MODELO" "STATUS"
echo "─────────────────────────────────────────────────────────────────"
for disk in "${ALL_DISKS[@]}"; do
    SIZE=$(lsblk -dno SIZE "$disk" 2>/dev/null || echo "?")
    MODEL=$(cat /sys/block/"$(basename "$disk")"/device/model 2>/dev/null | xargs || echo "N/D")
    MPTS=$(lsblk -no MOUNTPOINT "$disk" 2>/dev/null | grep -v '^$' | head -1 || true)
    ST="Disponível"; [[ -n "$MPTS" ]] && ST="Em uso (${MPTS})"
    printf "%-15s %-10s %-22s %s\n" "$disk" "$SIZE" "${MODEL:0:20}" "$ST"
done
echo ""

_SRC=$(findmnt -n -o SOURCE / 2>/dev/null || echo "")
if [[ -n "$_SRC" ]]; then
    _PKNAME=$(lsblk -no PKNAME "$_SRC" 2>/dev/null | head -1 || true)
    SYS_DISK="/dev/${_PKNAME:-$(basename "$_SRC" | sed 's/[0-9]*$//')}"
else
    SYS_DISK="/dev/sda"
    warn "Disco do sistema não detectado — assumindo ${SYS_DISK}"
fi
info "Disco do sistema: ${SYS_DISK}"

RAID_DISKS=()
for disk in "${ALL_DISKS[@]}"; do
    [[ "$disk" != "$SYS_DISK" ]] && RAID_DISKS+=("$disk")
done

echo ""
echo -e "${GREEN}Discos disponíveis para RAID 5:${NC}"
for i in "${!RAID_DISKS[@]}"; do
    SZ=$(lsblk -dno SIZE "${RAID_DISKS[$i]}" 2>/dev/null || echo "?")
    echo -e "  ${CYAN}[$i]${NC} ${RAID_DISKS[$i]} ($SZ)"
done
echo ""

[[ ${#RAID_DISKS[@]} -lt 5 ]] && \
    error "Necessários 5 discos para RAID 5. Encontrados: ${#RAID_DISKS[@]}"
[[ ${#RAID_DISKS[@]} -gt 5 ]] && {
    warn "Mais de 5 discos livres. Usando os 5 primeiros."
    RAID_DISKS=("${RAID_DISKS[@]:0:5}")
}

echo -e "${CYAN}RAID 5: 5 × 2TB = ~8TB úteis | Tolerância: 1 disco${NC}"
echo ""
echo -e "${RED}${BOLD}⚠  TODOS OS DADOS NOS DISCOS SERÃO APAGADOS!${NC}"
echo -n "Confirma? [s/N]: "
read -r CONFIRM
[[ "${CONFIRM,,}" != "s" ]] && error "Cancelado."

# ===========================================================================
# 2. PACOTES
# ===========================================================================
header "2. ATUALIZAÇÃO E PACOTES"

export DEBIAN_FRONTEND=noninteractive
echo "postfix postfix/main_mailer_type select Local only" | debconf-set-selections
echo "postfix postfix/mailname string cdpni"              | debconf-set-selections

apt-get update -y
apt-get upgrade -y

# ---------------------------------------------------------------------------
# PHP não está nos repositórios padrão do Debian 13 Trixie (em desenvolvimento)
# Repositório oficial Sury (packages.sury.org) é necessário para qualquer versão
# ---------------------------------------------------------------------------
info "Verificando disponibilidade do PHP..."
if ! apt-cache show php8.3-fpm &>/dev/null 2>&1; then
    info "Adicionando repositório PHP (packages.sury.org)..."
    apt-get install -y curl gnupg2 ca-certificates lsb-release apt-transport-https
    curl -sSLo /tmp/sury.gpg https://packages.sury.org/php/apt.gpg
    gpg --dearmor < /tmp/sury.gpg > /usr/share/keyrings/sury-php.gpg
    rm -f /tmp/sury.gpg
    echo "deb [signed-by=/usr/share/keyrings/sury-php.gpg] https://packages.sury.org/php/ bookworm main" \
        > /etc/apt/sources.list.d/sury-php.list
    apt-get update -y
    log "Repositório PHP (Sury) adicionado"
else
    log "PHP 8.3 já disponível"
fi

apt-get install -y \
    mdadm smartmontools hdparm \
    samba samba-common-bin smbclient \
    nginx php8.3-fpm php8.3-cli php8.3-common \
    acl attr xfsprogs e2fsprogs \
    net-tools iproute2 htop iotop rsync \
    curl wget vim tmux \
    mailutils postfix \
    fail2ban ufw cron lsof \
    bash-completion bc jq findutils openssl

unset DEBIAN_FRONTEND

command -v smbd &>/dev/null || error "smbd não instalado. Verifique repositórios."
command -v php  &>/dev/null || error "PHP não instalado. Verifique conexão com packages.sury.org"
log "Pacotes instalados | Samba: $(smbd --version) | PHP: $(php -r 'echo PHP_VERSION;')"

# ===========================================================================
# 3. REDE
# ===========================================================================
header "3. CONFIGURAÇÃO DE REDE"

IFACE=$(ip route show default 2>/dev/null | awk '/default/{print $5}' | head -1)
[[ -z "$IFACE" ]] && IFACE="eth0"
info "Interface: ${IFACE}"

cat > /etc/network/interfaces << EOF
# Gerado por 01_setup_raid_samba.sh — $(date '+%Y-%m-%d %H:%M:%S')
source /etc/network/interfaces.d/*

auto lo
iface lo inet loopback

auto ${IFACE}
iface ${IFACE} inet static
    address ${SAMBA_IP}/${SAMBA_MASK}
    gateway ${GATEWAY}
    dns-nameservers ${DNS_SERVER} 8.8.8.8
    dns-search cdpni.local
EOF

hostnamectl set-hostname "cdpni"
{
    echo "127.0.0.1   localhost"
    echo "127.0.1.1   cdpni.cdpni.local cdpni"
    echo "${SAMBA_IP}   cdpni.cdpni.local cdpni"
} > /etc/hosts

log "Rede: ${SAMBA_IP}/${SAMBA_MASK} | GW: ${GATEWAY} | IF: ${IFACE}"

# ===========================================================================
# 4. RAID 5
# ===========================================================================
header "4. RAID 5 — 5 discos | ~8TB úteis"

for disk in "${RAID_DISKS[@]}"; do
    info "Zerando: ${disk}"
    mdadm --zero-superblock --force "$disk" 2>/dev/null || true
    wipefs -af "$disk" 2>/dev/null || true
    dd if=/dev/zero of="$disk" bs=1M count=10 oflag=direct 2>/dev/null || true
done

mdadm --create "${RAID_DEVICE}" \
    --level=5 \
    --raid-devices=5 \
    --chunk=512 \
    --layout=left-symmetric \
    --metadata=1.2 \
    --name=data \
    --run \
    "${RAID_DISKS[@]}"

sleep 5
cat /proc/mdstat

echo 200000 > /proc/sys/dev/raid/speed_limit_min 2>/dev/null || true
echo 400000 > /proc/sys/dev/raid/speed_limit_max 2>/dev/null || true
{
    echo "# RAID 5"
    echo "dev.raid.speed_limit_min = 50000"
    echo "dev.raid.speed_limit_max = 200000"
} >> /etc/sysctl.conf

mkdir -p /etc/mdadm
: > /etc/mdadm/mdadm.conf
mdadm --detail --scan > /etc/mdadm/mdadm.conf
echo "MAILADDR root" >> /etc/mdadm/mdadm.conf
update-initramfs -u -k all 2>/dev/null || update-initramfs -u

log "RAID 5 criado: ${RAID_DEVICE}"

# ===========================================================================
# 5. FORMATAÇÃO XFS E MONTAGEM
# ===========================================================================
header "5. FORMATAÇÃO XFS E MONTAGEM"

info "Aguardando array..."
for i in {1..30}; do [[ -b "${RAID_DEVICE}" ]] && break; sleep 2; done
[[ -b "${RAID_DEVICE}" ]] || error "${RAID_DEVICE} não disponível"

mkfs.xfs -f -L "SAMBA_DATA" -d su=512k,sw=4 "${RAID_DEVICE}"

mkdir -p "${RAID_MOUNT}"
RAID_UUID=$(blkid -s UUID -o value "${RAID_DEVICE}")
[[ -z "$RAID_UUID" ]] && error "UUID não encontrado após mkfs"

grep -v "${RAID_DEVICE}\|SAMBA_DATA" /etc/fstab > /tmp/fstab.tmp && mv /tmp/fstab.tmp /etc/fstab
echo "# RAID 5 Samba" >> /etc/fstab
echo "UUID=${RAID_UUID}  ${RAID_MOUNT}  xfs  defaults,noatime,nodiratime,allocsize=64m,largeio  0  2" >> /etc/fstab

mount "${RAID_MOUNT}"
log "Montado: ${RAID_MOUNT} | UUID: ${RAID_UUID}"

# ===========================================================================
# 6. GRUPOS
# ===========================================================================
header "6. CRIAÇÃO DE GRUPOS"

# Coletar todos os grupos únicos da lista de shares
declare -A _GRUPOS_VISTOS
for entry in "${ALL_SHARES[@]}"; do
    grp=$(echo "$entry" | cut -d: -f2)
    _GRUPOS_VISTOS[$grp]=1
done
# Grupos base adicionais
for grp in grp_diretoria grp_administrativo grp_cpd grp_sindicancia grp_chefia_turno; do
    _GRUPOS_VISTOS[$grp]=1
done

for grp in "${!_GRUPOS_VISTOS[@]}"; do
    if getent group "$grp" &>/dev/null; then
        warn "Grupo já existe: ${grp}"
    else
        groupadd --system "$grp"
        log "Grupo criado: ${grp}"
    fi
done

# ===========================================================================
# 7. ESTRUTURA DE DIRETÓRIOS — 777 RECURSIVO
# ===========================================================================
header "7. ESTRUTURA DE DIRETÓRIOS (chmod 777)"

mkdir -p "${SAMBA_ROOT}"
mkdir -p "${RECYCLE_DIR}"
mkdir -p "${LOG_SAMBA}"

for entry in "${ALL_SHARES[@]}"; do
    NAME=$(echo "$entry" | cut -d: -f1)
    DIR="${SAMBA_ROOT}/${NAME}"
    mkdir -p "${DIR}"
    # 777 recursivo — controle de acesso feito exclusivamente pelo Samba
    chmod -R 777 "${DIR}"
    chown -R root:root "${DIR}"
    log "Pasta: ${DIR} (777)"
done

# Lixeira
chmod 1777 "${RECYCLE_DIR}"
chown root:root "${RECYCLE_DIR}"

log "Todas as pastas criadas com permissão 777"

# ===========================================================================
# 8. USUÁRIOS
# ===========================================================================
header "8. CRIAÇÃO DOS USUÁRIOS"

create_samba_user() {
    local LOGIN="$1"
    local FULLNAME="$2"
    local PRIMARY="$3"
    local EXTRAS="$4"

    if ! id "$LOGIN" &>/dev/null; then
        if [[ -n "$EXTRAS" ]]; then
            useradd -m -c "$FULLNAME" -s /usr/sbin/nologin \
                    -g "$PRIMARY" -G "$EXTRAS" "$LOGIN"
        else
            useradd -m -c "$FULLNAME" -s /usr/sbin/nologin \
                    -g "$PRIMARY" "$LOGIN"
        fi
        echo "${LOGIN}:${DEFAULT_PASS}" | chpasswd
        log "Usuário criado: ${LOGIN}"
    else
        usermod -g "$PRIMARY" ${EXTRAS:+-G "$EXTRAS"} "$LOGIN" 2>/dev/null || true
        warn "Usuário já existe; grupos atualizados: ${LOGIN}"
    fi

    printf '%s\n%s\n' "${DEFAULT_PASS}" "${DEFAULT_PASS}" | smbpasswd -s -a "$LOGIN"
    smbpasswd -e "$LOGIN"

    # Lixeira pessoal
    mkdir -p "${RECYCLE_DIR}/${LOGIN}"
    chmod 700 "${RECYCLE_DIR}/${LOGIN}"
    chown "${LOGIN}:${PRIMARY}" "${RECYCLE_DIR}/${LOGIN}"

    log "Samba: ${LOGIN} | ${FULLNAME}"
}

for entry in "${INITIAL_USERS[@]}"; do
    IFS=':' read -r LOGIN FULLNAME PRIMARY EXTRAS <<< "$entry"
    create_samba_user "$LOGIN" "$FULLNAME" "$PRIMARY" "$EXTRAS"
done

log "Todos os usuários criados"

# ===========================================================================
# 9. SMB.CONF
# ===========================================================================
header "9. CONFIGURAÇÃO DO SAMBA (smb.conf)"

[[ -f /etc/samba/smb.conf ]] && \
    cp /etc/samba/smb.conf "/etc/samba/smb.conf.bak.$(date +%Y%m%d_%H%M%S)"

# Gerar smb.conf — seção global
cat > /etc/samba/smb.conf << SMBEOF
# ============================================================
# smb.conf — CDPNI File Server — gerado $(date)
# Controle de acesso: via valid users por share
# Permissões de disco: 777 (sem restrição no filesystem)
# ============================================================

[global]
    workgroup            = ${SAMBA_WORKGROUP}
    server string        = CDPNI File Server
    netbios name         = CDPNI
    server role          = standalone server

    # Autenticação
    security             = user
    passdb backend       = tdbsam
    map to guest         = never

    # Rede
    interfaces           = lo ${IFACE}
    bind interfaces only = yes
    hosts allow          = 127.0.0.1 192.168.0.0/24
    hosts deny           = ALL

    # Protocolo SMB2/SMB3
    min protocol         = SMB2
    max protocol         = SMB3
    smb encrypt          = off

    # Performance
    use sendfile         = yes
    aio read size        = 16384
    aio write size       = 16384
    read raw             = yes
    write raw            = yes
    max xmit             = 65535
    dead time            = 15
    getwd cache          = yes

    # Logs
    log file             = ${LOG_SAMBA}/log.%m
    max log size         = 51200
    log level            = 1 auth:2

    # Permissões — 777 no filesystem, controle via valid users
    create mask          = 0664
    directory mask       = 0777
    force create mode    = 0664
    force directory mode = 0777

    # Impressoras desabilitadas
    load printers        = no
    printing             = bsd
    printcap name        = /dev/null
    disable spoolss      = yes

    # Charset
    unix charset         = UTF-8
    dos charset          = CP850

    # Lixeira + auditoria
    vfs objects                  = recycle full_audit
    recycle:repository           = ${RECYCLE_DIR}/%U
    recycle:keeptree             = yes
    recycle:versions             = yes
    recycle:touch                = yes
    recycle:touch_mtime          = yes
    recycle:exclude              = *.tmp *.temp ~\$* .DS_Store Thumbs.db desktop.ini
    recycle:exclude_dir          = .recycle tmp temp
    recycle:maxsize              = 1073741824
    full_audit:prefix            = %u|%I|%S
    full_audit:success           = open read write rename unlink mkdir rmdir
    full_audit:failure           = connect
    full_audit:facility          = local5
    full_audit:priority          = notice

# ============================================================
# LIXEIRA (somente sambadmin)
# ============================================================

[Recycle]
    comment      = Lixeira
    path         = ${RECYCLE_DIR}
    valid users  = sambadmin
    writable     = no
    browseable   = no

SMBEOF

# Gerar uma entrada por share
# Shares especiais com valid users extras:
#   Chefia_Turno_*: csd e sindicancia também têm acesso
#   CPD: oculto mas acessível por usuários do grp_cpd
for entry in "${ALL_SHARES[@]}"; do
    NAME=$(echo "$entry" | cut -d: -f1)
    GRP=$(echo "$entry"  | cut -d: -f2)
    VIS=$(echo "$entry"  | cut -d: -f3)
    DIR="${SAMBA_ROOT}/${NAME}"

    # Valid users extras por share
    EXTRA_VALID=""
    case "$NAME" in
        Chefia_Turno_I|Chefia_Turno_II|Chefia_Turno_III|Chefia_Turno_IV)
            EXTRA_VALID=" @grp_csd @grp_sindicancia" ;;
    esac

    cat >> /etc/samba/smb.conf << SHAREEOF
[${NAME}]
    comment      = ${NAME}
    path         = ${DIR}
    valid users  = @${GRP}${EXTRA_VALID} sambadmin
    writable     = yes
    browseable   = ${VIS}
    create mask  = 0664
    directory mask = 0777
    force create mode = 0664
    force directory mode = 0777

SHAREEOF
done

testparm -s /etc/samba/smb.conf || error "smb.conf inválido!"

systemctl enable smbd nmbd
systemctl restart smbd nmbd
systemctl is-active smbd &>/dev/null || error "smbd não iniciou"
log "Samba iniciado: $(smbd --version)"


# ===========================================================================
# 10. FIREWALL
# ===========================================================================
header "10. FIREWALL (UFW)"

ufw --force reset
ufw default deny incoming
ufw default allow outgoing
ufw allow 22/tcp    comment "SSH"
ufw allow 137/udp   comment "Samba NetBIOS Name"
ufw allow 138/udp   comment "Samba NetBIOS Datagram"
ufw allow 139/tcp   comment "Samba NetBIOS Session"
ufw allow 445/tcp   comment "Samba SMB"
ufw allow 80/tcp    comment "HTTP"
ufw allow 443/tcp   comment "HTTPS"
ufw allow from 192.168.0.0/24 to any
ufw --force enable
log "Firewall ativo"

# ===========================================================================
# 10b. INTEGRAÇÃO COM GATEWAY (192.168.0.1)
# ===========================================================================
header "10b. INTEGRAÇÃO COM GATEWAY"

info "Verificando conectividade com o gateway..."

# Testar conectividade
if ping -c2 -W2 "${GATEWAY}" &>/dev/null; then
    log "Gateway ${GATEWAY} acessível"
else
    warn "Gateway ${GATEWAY} não responde — verifique a rede"
fi

# Criar script auxiliar para aplicar no gateway
# Execute este script NO GATEWAY (192.168.0.1) para liberar o Samba
cat > /tmp/gateway_samba_rules.sh << 'GWEOF'
#!/bin/bash
# ============================================================
# REGRAS DE INTEGRAÇÃO SAMBA → GATEWAY
# Execute NO SERVIDOR GATEWAY (192.168.0.1)
# ============================================================

SAMBA_IP="192.168.0.11"
LAN_NET="192.168.0.0/24"

echo "[*] Aplicando regras nftables para Samba..."

# 1. Garantir que tráfego SMB não passe pelo proxy Squid
#    (Samba usa portas 137-139 UDP/TCP e 445 TCP)
nft add rule inet filter forward \
    ip daddr ${SAMBA_IP} tcp dport { 139, 445 } accept 2>/dev/null || true
nft add rule inet filter forward \
    ip saddr ${SAMBA_IP} tcp sport { 139, 445 } ct state established,related accept 2>/dev/null || true
nft add rule inet filter forward \
    ip daddr ${SAMBA_IP} udp dport { 137, 138 } accept 2>/dev/null || true

# 2. Permitir acesso ao painel web (HTTP/HTTPS)
nft add rule inet filter forward \
    ip daddr ${SAMBA_IP} tcp dport { 80, 443 } accept 2>/dev/null || true
nft add rule inet filter forward \
    ip saddr ${SAMBA_IP} tcp sport { 80, 443 } ct state established,related accept 2>/dev/null || true

# 3. Garantir que cdpni.local está no squid.conf com splice (sem interceptação SSL)
if ! grep -q "samba_server_ip" /etc/squid/squid.conf 2>/dev/null; then
    echo "[!] ACLs do Samba não encontradas no squid.conf — adicionando..."
    cat >> /etc/squid/squid.conf << 'SQUIDEOF'

# Samba/CDPNI — bypass SSL bump e acesso direto
acl no_bump_samba_ip  dst 192.168.0.11
acl no_bump_samba_dns ssl::server_name_regex -i cdpni\.local$ cdpni$
ssl_bump splice no_bump_samba_ip
ssl_bump splice no_bump_samba_dns
acl samba_server_ip  dst 192.168.0.11
acl samba_server_dns dstdomain cdpni.local cdpni
http_access allow samba_server_ip
http_access allow samba_server_dns
SQUIDEOF
    squid -k parse && squid -k reconfigure
    echo "[OK] squid.conf atualizado"
else
    echo "[OK] squid.conf já tem as ACLs do Samba"
fi

# 4. Salvar regras nftables
nft list ruleset > /etc/nftables.conf
echo "[OK] Regras salvas em /etc/nftables.conf"
echo "[OK] Integração Samba → Gateway concluída"
GWEOF

chmod +x /tmp/gateway_samba_rules.sh

log "Script de integração gerado: /tmp/gateway_samba_rules.sh"
info "Para aplicar no gateway, execute:"
info "  scp /tmp/gateway_samba_rules.sh root@${GATEWAY}:/tmp/"
info "  ssh root@${GATEWAY} 'bash /tmp/gateway_samba_rules.sh'"


# ===========================================================================
# 11. FAIL2BAN
# ===========================================================================
header "11. FAIL2BAN"

mkdir -p /etc/fail2ban/jail.d
cat > /etc/fail2ban/jail.d/samba.conf << 'EOF'
[samba]
enabled  = true
port     = 445
protocol = tcp
filter   = samba
logpath  = /var/log/samba/log.*
maxretry = 5
bantime  = 3600
findtime = 600
EOF

systemctl enable fail2ban
systemctl restart fail2ban
log "Fail2ban configurado"

# ===========================================================================
# 12. S.M.A.R.T.
# ===========================================================================
header "12. MONITORAMENTO S.M.A.R.T"

cat > /etc/smartd.conf << 'EOF'
DEVICESCAN -a -o on -S on -n standby,q \
  -s (S/../.././02|L/../../6/03) \
  -m root \
  -M exec /usr/share/smartmontools/smartd-runner
EOF
# Debian 13: smartd.service pode ser symlink — tratar sem abortar o script
systemctl enable smartd 2>/dev/null ||     systemctl enable --force smartd 2>/dev/null ||     warn "smartd enable falhou — monitoramento S.M.A.R.T. manual necessário"
systemctl restart smartd 2>/dev/null ||     systemctl start smartd 2>/dev/null ||     warn "smartd não iniciou — verifique: systemctl status smartd"
systemctl is-active smartd &>/dev/null && log "smartd ativo" || warn "smartd inativo — não crítico"

# ===========================================================================
# 13. MONITORAMENTO RAID
# ===========================================================================
header "13. MONITORAMENTO RAID 5"

cat > /usr/local/bin/raid_check.sh << 'RAIDEOF'
#!/bin/bash
RAID_DEV="/dev/md0"
STATE=$(mdadm --detail "$RAID_DEV" 2>/dev/null | awk '/State :/{print $3}')
FAILED=$(mdadm --detail "$RAID_DEV" 2>/dev/null | awk '/Failed Devices/{print $4}')
DEGRADED=$(mdadm --detail "$RAID_DEV" 2>/dev/null | grep -c "degraded" 2>/dev/null || echo 0)
ALERT=0; MSG=""
[[ "${FAILED:-0}" -gt 0 ]]   && { MSG+="DISCO FALHO (${FAILED})! "; ALERT=1; }
[[ "${DEGRADED:-0}" -gt 0 ]] && { MSG+="ARRAY DEGRADADO! "; ALERT=1; }
[[ "$STATE" != "clean" && "$STATE" != "active" ]] && { MSG+="Estado: ${STATE}. "; ALERT=1; }
if [[ $ALERT -eq 1 ]]; then
    echo "RAID ALERTA em $(hostname) $(date): ${MSG}" | mail -s "RAID ALERT" root 2>/dev/null || true
    echo "$(date): ${MSG}" >> /var/log/raid_alert.log
fi
echo "=== $(date) ===" >> /var/log/raid_check.log
mdadm --detail "$RAID_DEV" >> /var/log/raid_check.log 2>&1
RAIDEOF
chmod +x /usr/local/bin/raid_check.sh

cat > /etc/cron.d/raid_monitor << 'EOF'
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin
0 * * * * root /usr/local/bin/raid_check.sh
EOF
log "Monitoramento RAID configurado (1×/hora)"

# ===========================================================================
# 14. PAINEL WEB (Nginx + PHP + HTTPS)
# ===========================================================================
header "14. PAINEL WEB"

PANEL_DIR="/var/www/samba-panel"
PANEL_SSL_DIR="/etc/nginx/ssl"
PANEL_DOMAIN="cdpni.local"
mkdir -p "${PANEL_DIR}/public/api" "${PANEL_SSL_DIR}"

# Certificado SSL
if [[ ! -f "${PANEL_SSL_DIR}/cdpni.crt" ]]; then
    openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
        -keyout "${PANEL_SSL_DIR}/cdpni.key" \
        -out    "${PANEL_SSL_DIR}/cdpni.crt" \
        -subj   "/C=BR/ST=SP/O=CDPNI/CN=${PANEL_DOMAIN}" \
        -addext "subjectAltName=DNS:${PANEL_DOMAIN},IP:${SAMBA_IP}" \
        2>/dev/null
    chmod 600 "${PANEL_SSL_DIR}/cdpni.key"
    log "Certificado SSL gerado"
fi

# Nginx
cat > /etc/nginx/sites-available/samba-panel << NGINXEOF
server {
    listen 80;
    server_name ${PANEL_DOMAIN} ${SAMBA_IP};
    return 301 https://\$host\$request_uri;
}
server {
    listen 443 ssl;
    server_name ${PANEL_DOMAIN} ${SAMBA_IP};
    ssl_certificate     ${PANEL_SSL_DIR}/cdpni.crt;
    ssl_certificate_key ${PANEL_SSL_DIR}/cdpni.key;
    ssl_protocols       TLSv1.2 TLSv1.3;
    ssl_ciphers         HIGH:!aNULL:!MD5;
    root  ${PANEL_DIR}/public;
    index index.php;
    add_header X-Frame-Options SAMEORIGIN;
    add_header X-Content-Type-Options nosniff;
    location / { try_files \$uri \$uri/ /index.php\$is_args\$args; }
    location ~ \.php$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:/run/php/php8.3-fpm.sock;
        fastcgi_param SCRIPT_FILENAME \$realpath_root\$fastcgi_script_name;
    }
    location ~ /\.          { deny all; }
    location ~* \.(sh|conf|log|key)$ { deny all; }
}
NGINXEOF

ln -sf /etc/nginx/sites-available/samba-panel /etc/nginx/sites-enabled/
rm -f /etc/nginx/sites-enabled/default

# sudoers — criar diretório se não existir (Debian 13 pode não ter)
mkdir -p /etc/sudoers.d
cat > /etc/sudoers.d/samba-panel << 'SUDOEOF'
www-data ALL=(ALL) NOPASSWD: /usr/bin/smbpasswd, /usr/sbin/useradd, /usr/sbin/usermod, /usr/sbin/userdel, /usr/bin/gpasswd, /usr/sbin/groupadd, /usr/sbin/groupdel, /bin/mkdir, /bin/chown, /bin/chmod, /usr/bin/pdbedit, /usr/sbin/testparm, /bin/systemctl restart smbd, /bin/systemctl reload smbd, /bin/systemctl status smbd
SUDOEOF
chmod 440 /etc/sudoers.d/samba-panel
# Garantir que o sudoers principal inclui o diretório
grep -q "includedir /etc/sudoers.d" /etc/sudoers 2>/dev/null ||     echo "#includedir /etc/sudoers.d" >> /etc/sudoers

# config.php
PANEL_PASS_HASH=$(php -r "echo password_hash('admin', PASSWORD_BCRYPT);")
cat > "${PANEL_DIR}/config.php" << PHPEOF
<?php
define('PANEL_TITLE',  'CDPNI — Painel de Arquivos');
define('SAMBA_ROOT',   '${SAMBA_ROOT}');
define('RECYCLE_DIR',  '${RECYCLE_DIR}');
define('SMB_CONF',     '/etc/samba/smb.conf');
define('LOG_FILE',     '/var/log/samba_panel.log');
define('PANEL_USER',   'admin');
define('PANEL_PASS',   '${PANEL_PASS_HASH}');
ini_set('session.cookie_httponly', 1);
ini_set('session.cookie_secure',   1);
ini_set('session.gc_maxlifetime',  3600);
session_name('SAMBA_PANEL');
PHPEOF

# API
cat > "${PANEL_DIR}/public/api/index.php" << 'PHPEOF'
<?php
require_once dirname(__DIR__, 2) . '/config.php';
session_start();
header('Content-Type: application/json; charset=utf-8');

function json_out($d,$c=200){http_response_code($c);echo json_encode($d,JSON_UNESCAPED_UNICODE);exit;}
function run($cmd){$o=[];$r=0;exec($cmd.' 2>&1',$o,$r);return['output'=>implode("\n",$o),'code'=>$r];}
function log_action($m){file_put_contents(LOG_FILE,date('[Y-m-d H:i:s]').' ['.($_SESSION['user']??'?').'] '.$m."\n",FILE_APPEND);}
function require_auth(){if(empty($_SESSION['auth']))json_out(['error'=>'Não autenticado'],401);}

$action=$_GET['action']??$_POST['action']??'';

if($action==='login'){
    if(($_POST['user']??'')===PANEL_USER&&password_verify($_POST['pass']??'',PANEL_PASS)){
        $_SESSION['auth']=true;$_SESSION['user']=$_POST['user'];log_action('Login');json_out(['ok'=>true]);
    }
    json_out(['error'=>'Usuário ou senha inválidos'],401);
}
if($action==='logout'){session_destroy();json_out(['ok'=>true]);}
require_auth();

if($action==='list_users'){
    $out=run('sudo pdbedit -L -v 2>/dev/null');$users=[];$cur=[];
    foreach(explode("\n",$out['output'])as$line){
        if(preg_match('/^Unix username:\s+(.+)/',$line,$m)){if($cur)$users[]=$cur;$cur=['user'=>trim($m[1]),'fullname'=>'','status'=>'Ativo','groups'=>[]];}
        elseif(preg_match('/^Full Name:\s+(.*)/',$line,$m)&&$cur)$cur['fullname']=trim($m[1]);
        elseif(preg_match('/^Account Flags:\s+\[(.+)\]/',$line,$m)&&$cur)$cur['status']=str_contains($m[1],'D')?'Desabilitado':'Ativo';
    }
    if($cur)$users[]=$cur;
    foreach($users as&$u){$g=run('id -nG '.escapeshellarg($u['user']).' 2>/dev/null');$u['groups']=array_values(array_filter(explode(' ',trim($g['output']))));}
    json_out($users);
}
if($action==='create_user'){
    $user=preg_replace('/[^a-z0-9_]/','',strtolower(trim($_POST['user']??'')));
    $full=trim($_POST['fullname']??$user);$pass=$_POST['pass']??'1234';$groups=trim($_POST['groups']??'');
    if(!$user)json_out(['error'=>'Nome inválido'],400);
    $primary=explode(',',$groups)[0]??'grp_administrativo';
    $extra=implode(',',array_slice(explode(',',$groups),1));
    $cmd="sudo useradd -m -c ".escapeshellarg($full)." -s /usr/sbin/nologin -g ".escapeshellarg($primary);
    if($extra)$cmd.=" -G ".escapeshellarg($extra);
    run($cmd." ".escapeshellarg($user));
    run("echo ".escapeshellarg("{$user}:{$pass}")." | sudo chpasswd");
    run("printf '%s\n%s\n' ".escapeshellarg($pass)." ".escapeshellarg($pass)." | sudo smbpasswd -s -a ".escapeshellarg($user));
    run("sudo smbpasswd -e ".escapeshellarg($user));
    $rec=RECYCLE_DIR."/{$user}";
    run("sudo mkdir -p ".escapeshellarg($rec));
    run("sudo chmod 700 ".escapeshellarg($rec));
    run("sudo chown {$user}:{$primary} ".escapeshellarg($rec));
    log_action("Usuário criado: {$user}");
    json_out(['ok'=>true,'message'=>"Usuário {$user} criado"]);
}
if($action==='delete_user'){
    $user=preg_replace('/[^a-z0-9_]/','',trim($_POST['user']??''));
    if(!$user)json_out(['error'=>'Inválido'],400);
    run("sudo smbpasswd -x ".escapeshellarg($user)." 2>/dev/null");
    run("sudo usermod -s /usr/sbin/nologin ".escapeshellarg($user));
    run("sudo passwd -l ".escapeshellarg($user));
    log_action("Desativado: {$user}");json_out(['ok'=>true]);
}
if($action==='reset_pass'){
    $user=preg_replace('/[^a-z0-9_]/','',trim($_POST['user']??''));$pass=$_POST['pass']??'1234';
    if(!$user)json_out(['error'=>'Inválido'],400);
    run("echo ".escapeshellarg("{$user}:{$pass}")." | sudo chpasswd");
    run("printf '%s\n%s\n' ".escapeshellarg($pass)." ".escapeshellarg($pass)." | sudo smbpasswd -s ".escapeshellarg($user));
    log_action("Senha: {$user}");json_out(['ok'=>true]);
}
if($action==='toggle_user'){
    $user=preg_replace('/[^a-z0-9_]/','',trim($_POST['user']??''));$enable=($_POST['enable']??'0')==='1';
    if(!$user)json_out(['error'=>'Inválido'],400);
    if($enable){run("sudo smbpasswd -e ".escapeshellarg($user));}else{run("sudo smbpasswd -d ".escapeshellarg($user));}
    log_action(($enable?'Habilitado':'Desabilitado').": {$user}");json_out(['ok'=>true]);
}
if($action==='list_groups'){
    $out=run("getent group | grep '^grp_'");$groups=[];
    foreach(explode("\n",$out['output'])as$line){
        if(!$line)continue;$p=explode(':',$line);
        $groups[]=['name'=>$p[0],'gid'=>$p[2],'members'=>$p[3]?array_values(array_filter(explode(',',$p[3]))):[]];
    }
    json_out($groups);
}
if($action==='create_group'){
    $name='grp_'.preg_replace('/[^a-z0-9_]/','',strtolower(trim($_POST['name']??'')));
    if($name==='grp_')json_out(['error'=>'Nome inválido'],400);
    $r=run("sudo groupadd ".escapeshellarg($name)." 2>&1");
    if($r['code']!==0&&str_contains($r['output'],'already exists'))json_out(['error'=>'Já existe'],409);
    log_action("Grupo: {$name}");json_out(['ok'=>true,'message'=>"Grupo {$name} criado"]);
}
if($action==='add_to_group'){
    $user=preg_replace('/[^a-z0-9_]/','',trim($_POST['user']??''));
    $group=preg_replace('/[^a-z0-9_]/','',trim($_POST['group']??''));
    if(!$user||!$group)json_out(['error'=>'Dados inválidos'],400);
    run("sudo usermod -aG ".escapeshellarg($group)." ".escapeshellarg($user));
    log_action("{$user} → {$group}");json_out(['ok'=>true]);
}
if($action==='remove_from_group'){
    $user=preg_replace('/[^a-z0-9_]/','',trim($_POST['user']??''));
    $group=preg_replace('/[^a-z0-9_]/','',trim($_POST['group']??''));
    run("sudo gpasswd -d ".escapeshellarg($user)." ".escapeshellarg($group)." 2>&1");
    log_action("{$user} ← {$group}");json_out(['ok'=>true]);
}
if($action==='list_shares'){
    $shares=[];$conf=file_get_contents(SMB_CONF);
    preg_match_all('/^\[([^\]]+)\]/m',$conf,$names);
    foreach($names[1]as$name){
        if(in_array(strtolower($name),['global','printers','print$','recycle']))continue;
        preg_match('/\['.preg_quote($name,'/').'\].*?(?=\n\[|\z)/s',$conf,$block);
        $b=$block[0]??'';
        $path=preg_match('/path\s*=\s*(.+)/i',$b,$m)?trim($m[1]):'';
        $comment=preg_match('/comment\s*=\s*(.+)/i',$b,$m)?trim($m[1]):'';
        $writable=preg_match('/writable\s*=\s*yes/i',$b);
        $browse=!preg_match('/browseable\s*=\s*no/i',$b);
        $size='';
        if($path&&is_dir($path)){$df=shell_exec("df -h ".escapeshellarg($path)." 2>/dev/null | tail -1");$p=preg_split('/\s+/',trim($df??''));$size=($p[2]??'').'/'.($p[1]??'');}
        $shares[]=compact('name','path','comment','writable','browse','size');
    }
    json_out($shares);
}
if($action==='create_share'){
    $name=preg_replace('/[^a-zA-Z0-9_\-]/','',trim($_POST['name']??''));
    $group=preg_replace('/[^a-z0-9_]/','',trim($_POST['group']??''));
    $comment=trim($_POST['comment']??$name);
    $writable=($_POST['writable']??'1')==='1'?'yes':'no';
    $browse=($_POST['browse']??'1')==='1'?'yes':'no';
    if(!$name||!$group)json_out(['error'=>'Nome e grupo obrigatórios'],400);
    $path=SAMBA_ROOT."/{$name}";
    run("sudo mkdir -p ".escapeshellarg($path));
    run("sudo chmod -R 777 ".escapeshellarg($path));
    run("sudo chown -R root:root ".escapeshellarg($path));
    $entry="\n[{$name}]\n    comment      = {$comment}\n    path         = {$path}\n    valid users  = @{$group} sambadmin\n    writable     = {$writable}\n    browseable   = {$browse}\n    create mask  = 0664\n    directory mask = 0777\n    force create mode = 0664\n    force directory mode = 0777\n";
    file_put_contents(SMB_CONF,$entry,FILE_APPEND);
    $t=run("sudo testparm -s ".escapeshellarg(SMB_CONF)." 2>&1");
    if(str_contains($t['output'],'FATAL'))json_out(['error'=>'Erro smb.conf: '.$t['output']],500);
    run("sudo systemctl reload smbd 2>/dev/null || sudo systemctl restart smbd");
    log_action("Share: {$name}");json_out(['ok'=>true,'message'=>"Share {$name} criado"]);
}
if($action==='status'){
    $smbd=run("systemctl is-active smbd 2>/dev/null");
    $nmbd=run("systemctl is-active nmbd 2>/dev/null");
    $raid=run("cat /proc/mdstat 2>/dev/null | head -5");
    $disk=run("df -h ".escapeshellarg(SAMBA_ROOT)." 2>/dev/null | tail -1");
    $conns=run("sudo smbstatus -S 2>/dev/null | grep -v '^\$\|^-\|^Share' | wc -l");
    $uptime=run("uptime -p 2>/dev/null");
    $p=preg_split('/\s+/',trim($disk['output']??''));
    json_out(['smbd'=>trim($smbd['output']),'nmbd'=>trim($nmbd['output']),'disk_used'=>$p[2]??'-','disk_total'=>$p[1]??'-','disk_pct'=>$p[4]??'-','connections'=>max(0,(int)trim($conns['output'])-1),'uptime'=>trim($uptime['output']),'raid'=>trim($raid['output'])]);
}
json_out(['error'=>'Ação desconhecida'],404);
PHPEOF

# Front-end
cat > "${PANEL_DIR}/public/index.php" << 'HTMLEOF'
<?php
require_once dirname(__DIR__) . '/config.php';
session_start();
$logged = !empty($_SESSION['auth']);
?>
<!DOCTYPE html>
<html lang="pt-BR">
<head>
<meta charset="UTF-8"><meta name="viewport" content="width=device-width,initial-scale=1.0">
<title>CDPNI — Painel de Arquivos</title>
<link href="https://fonts.googleapis.com/css2?family=DM+Sans:wght@300;400;500;600&family=DM+Mono:wght@400;500&display=swap" rel="stylesheet">
<style>
:root{--bg:#0d1117;--bg2:#161b22;--bg3:#21262d;--border:#30363d;--text:#e6edf3;--muted:#8b949e;--accent:#2ea043;--accent2:#1f6feb;--danger:#da3633;--font:'DM Sans',sans-serif;--mono:'DM Mono',monospace}
*{box-sizing:border-box;margin:0;padding:0}body{font-family:var(--font);background:var(--bg);color:var(--text);min-height:100vh}
.login-wrap{display:flex;align-items:center;justify-content:center;min-height:100vh;background:radial-gradient(ellipse at 50% 0%,#0d2436,var(--bg) 70%)}
.login-box{background:var(--bg2);border:1px solid var(--border);border-radius:12px;padding:2.5rem 2rem;width:340px;box-shadow:0 16px 48px rgba(0,0,0,.4)}
.login-logo{text-align:center;margin-bottom:2rem}.logo-icon{width:52px;height:52px;background:linear-gradient(135deg,var(--accent2),var(--accent));border-radius:12px;display:inline-flex;align-items:center;justify-content:center;font-size:1.5rem;margin-bottom:.75rem}
.login-logo h1{font-size:1.4rem;font-weight:600}.login-logo p{font-size:.8rem;color:var(--muted)}
.layout{display:flex;height:100vh;overflow:hidden}
.sidebar{width:220px;min-width:220px;background:var(--bg2);border-right:1px solid var(--border);display:flex;flex-direction:column;padding:1.25rem 0;overflow-y:auto}
.sidebar-logo{padding:.5rem 1.25rem 1.5rem;border-bottom:1px solid var(--border);margin-bottom:.75rem}
.sidebar-logo h2{font-size:.95rem;font-weight:600}.sidebar-logo small{color:var(--muted);font-size:.75rem}
.nav-section{padding:.25rem 1rem .125rem}.nav-section span{font-size:.68rem;font-weight:600;letter-spacing:.08em;text-transform:uppercase;color:var(--muted)}
.nav-item{display:flex;align-items:center;gap:.625rem;padding:.5rem 1.25rem;color:var(--muted);cursor:pointer;font-size:.875rem;transition:background .15s,color .15s;user-select:none}
.nav-item:hover{background:var(--bg3);color:var(--text)}.nav-item.active{background:rgba(31,111,235,.15);color:var(--accent2);border-right:2px solid var(--accent2)}
.sidebar-footer{margin-top:auto;padding:1rem 1.25rem;border-top:1px solid var(--border)}
.logout-btn{width:100%;padding:.5rem;background:transparent;border:1px solid var(--border);border-radius:8px;color:var(--muted);cursor:pointer;font-size:.8rem;font-family:var(--font);transition:all .15s}
.logout-btn:hover{border-color:var(--danger);color:var(--danger)}
.main{flex:1;display:flex;flex-direction:column;overflow:hidden}
.topbar{height:52px;border-bottom:1px solid var(--border);display:flex;align-items:center;padding:0 1.5rem;background:var(--bg2);gap:1rem}
.topbar h3{font-size:.95rem;font-weight:600;flex:1}
.content{flex:1;overflow-y:auto;padding:1.5rem}
.status-grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(160px,1fr));gap:.75rem;margin-bottom:1.5rem}
.stat-card{background:var(--bg2);border:1px solid var(--border);border-radius:8px;padding:1rem 1.125rem}
.stat-card .label{font-size:.7rem;color:var(--muted);text-transform:uppercase;letter-spacing:.06em}
.stat-card .value{font-size:1.4rem;font-weight:600;margin-top:.25rem;font-family:var(--mono)}
.stat-card .sub{font-size:.75rem;color:var(--muted)}
.dot{display:inline-block;width:8px;height:8px;border-radius:50%;margin-right:4px}
.dot-green{background:var(--accent);box-shadow:0 0 6px var(--accent)}.dot-red{background:var(--danger)}
.card{background:var(--bg2);border:1px solid var(--border);border-radius:8px;overflow:hidden;margin-bottom:1rem}
.card-header{padding:.875rem 1.25rem;border-bottom:1px solid var(--border);display:flex;align-items:center;gap:.75rem}
.card-header h4{font-size:.9rem;font-weight:600;flex:1}
table{width:100%;border-collapse:collapse;font-size:.85rem}
th{padding:.625rem 1.25rem;text-align:left;font-size:.72rem;font-weight:600;text-transform:uppercase;letter-spacing:.06em;color:var(--muted);background:var(--bg3);border-bottom:1px solid var(--border)}
td{padding:.75rem 1.25rem;border-bottom:1px solid var(--border);vertical-align:middle}
tr:last-child td{border-bottom:none}tr:hover td{background:rgba(255,255,255,.02)}
.tag{display:inline-block;padding:.15rem .55rem;border-radius:4px;font-size:.72rem;font-family:var(--mono);background:var(--bg3);border:1px solid var(--border);color:var(--muted);margin:.1rem}
.tag-blue{background:rgba(31,111,235,.15);border-color:rgba(31,111,235,.3);color:#79b8ff}
.tag-green{background:rgba(46,160,67,.15);border-color:rgba(46,160,67,.3);color:#7ee787}
.tag-red{background:rgba(218,54,51,.15);border-color:rgba(218,54,51,.3);color:#ffa198}
.btn{padding:.45rem .9rem;border-radius:6px;border:1px solid var(--border);background:var(--bg3);color:var(--text);cursor:pointer;font-size:.8rem;font-family:var(--font);font-weight:500;transition:all .15s;display:inline-flex;align-items:center;gap:.4rem}
.btn:hover{border-color:var(--accent2);color:var(--accent2)}.btn-primary{background:var(--accent2);border-color:var(--accent2);color:#fff}
.btn-primary:hover{background:#388bfd;color:#fff}.btn-danger{border-color:var(--danger);color:var(--danger)}
.btn-danger:hover{background:rgba(218,54,51,.15)}.btn-sm{padding:.3rem .65rem;font-size:.75rem}
.form-group{margin-bottom:1rem}.form-group label{display:block;font-size:.8rem;color:var(--muted);margin-bottom:.35rem;font-weight:500}
input[type=text],input[type=password],select{width:100%;padding:.55rem .75rem;background:var(--bg);border:1px solid var(--border);border-radius:6px;color:var(--text);font-size:.875rem;font-family:var(--font);outline:none;transition:border-color .15s}
input:focus,select:focus{border-color:var(--accent2)}select option{background:var(--bg2)}
.form-row{display:grid;grid-template-columns:1fr 1fr;gap:1rem}
.modal-overlay{display:none;position:fixed;inset:0;background:rgba(0,0,0,.6);backdrop-filter:blur(4px);z-index:100;align-items:center;justify-content:center}
.modal-overlay.open{display:flex}
.modal{background:var(--bg2);border:1px solid var(--border);border-radius:12px;width:480px;max-width:95vw;padding:1.5rem;box-shadow:0 24px 64px rgba(0,0,0,.5);animation:mIn .2s ease}
@keyframes mIn{from{opacity:0;transform:translateY(-12px) scale(.97)}to{opacity:1;transform:none}}
.modal h3{font-size:1rem;font-weight:600;margin-bottom:1.25rem;padding-bottom:.75rem;border-bottom:1px solid var(--border)}
.modal-footer{display:flex;gap:.625rem;justify-content:flex-end;margin-top:1.25rem;padding-top:.75rem;border-top:1px solid var(--border)}
.toast-wrap{position:fixed;bottom:1.5rem;right:1.5rem;z-index:999;display:flex;flex-direction:column;gap:.5rem}
.toast{padding:.75rem 1.25rem;border-radius:8px;border:1px solid;font-size:.85rem;font-weight:500;max-width:320px;animation:tIn .25s ease}
@keyframes tIn{from{opacity:0;transform:translateX(20px)}to{opacity:1;transform:none}}
.toast.success{background:rgba(46,160,67,.2);border-color:var(--accent);color:#7ee787}
.toast.error{background:rgba(218,54,51,.2);border-color:var(--danger);color:#ffa198}
.empty{text-align:center;padding:3rem 1rem;color:var(--muted)}.empty .icon{font-size:2.5rem;display:block;margin-bottom:.75rem;opacity:.4}
.spin{display:inline-block;width:14px;height:14px;border:2px solid var(--border);border-top-color:var(--accent2);border-radius:50%;animation:spin .6s linear infinite}
@keyframes spin{to{transform:rotate(360deg)}}
::-webkit-scrollbar{width:6px}::-webkit-scrollbar-thumb{background:var(--border);border-radius:3px}
</style>
</head>
<body>
<?php if(!$logged): ?>
<div class="login-wrap"><div class="login-box">
  <div class="login-logo"><div class="logo-icon">📁</div><h1>CDPNI</h1><p>Painel de Gerenciamento de Arquivos</p></div>
  <form id="lF">
    <div class="form-group"><label>Usuário</label><input type="text" id="lU" value="admin" required></div>
    <div class="form-group"><label>Senha</label><input type="password" id="lP" placeholder="••••••••" required></div>
    <button type="submit" class="btn btn-primary" style="width:100%;justify-content:center;padding:.6rem">Entrar</button>
    <div id="lE" style="color:var(--danger);font-size:.8rem;margin-top:.5rem;text-align:center;display:none"></div>
  </form>
</div></div>
<?php else: ?>
<div class="layout">
  <aside class="sidebar">
    <div class="sidebar-logo"><h2>📁 CDPNI</h2><small>Painel de Arquivos</small></div>
    <div class="nav-section"><span>Principal</span></div>
    <div class="nav-item active" onclick="goto('dashboard')"><span>🏠</span> Dashboard</div>
    <div class="nav-section"><span>Usuários</span></div>
    <div class="nav-item" onclick="goto('users')"><span>👤</span> Usuários</div>
    <div class="nav-item" onclick="goto('groups')"><span>👥</span> Grupos</div>
    <div class="nav-section"><span>Arquivos</span></div>
    <div class="nav-item" onclick="goto('shares')"><span>🗂️</span> Compartilhamentos</div>
    <div class="sidebar-footer"><button class="logout-btn" onclick="logout()">⏻ Sair</button></div>
  </aside>
  <div class="main">
    <div class="topbar"><h3 id="pT">Dashboard</h3><button id="tA" class="btn btn-primary btn-sm" style="display:none"></button></div>
    <div class="content" id="ct"><div style="display:flex;align-items:center;gap:.5rem;color:var(--muted)"><span class="spin"></span> Carregando...</div></div>
  </div>
</div>
<div class="modal-overlay" id="modal"><div class="modal"><h3 id="mT"></h3><div id="mB"></div><div class="modal-footer" id="mF"></div></div></div>
<div class="toast-wrap" id="toasts"></div>
<?php endif; ?>
<script>
const $=id=>document.getElementById(id);
const esc=s=>String(s).replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;');
function toast(msg,type='success'){const t=document.createElement('div');t.className='toast '+type;t.textContent=msg;$('toasts').appendChild(t);setTimeout(()=>t.remove(),3500);}
async function api(action,data={},method='GET'){const isGet=method==='GET';const opts={method,credentials:'same-origin'};if(!isGet){const fd=new FormData();fd.append('action',action);Object.entries(data).forEach(([k,v])=>fd.append(k,v));opts.body=fd;}const res=await fetch(isGet?`api/?action=${action}`:'api/',opts);const json=await res.json();if(json.error)throw new Error(json.error);return json;}
function modal(title,body,btns=[]){$('mT').textContent=title;$('mB').innerHTML=body;$('mF').innerHTML='';btns.forEach(b=>{const el=document.createElement('button');el.className='btn '+(b.cls||'');el.textContent=b.label;el.onclick=b.fn;$('mF').appendChild(el);});$('modal').classList.add('open');}
function closeModal(){$('modal').classList.remove('open');}
$('modal')?.addEventListener('click',e=>{if(e.target===$('modal'))closeModal();});
document.getElementById('lF')?.addEventListener('submit',async e=>{e.preventDefault();const btn=e.target.querySelector('button');btn.disabled=true;btn.textContent='Entrando...';try{await api('login',{user:$('lU').value,pass:$('lP').value},'POST');location.reload();}catch(err){$('lE').textContent=err.message;$('lE').style.display='block';btn.disabled=false;btn.textContent='Entrar';}});
async function logout(){await api('logout',{},'POST');location.reload();}
const pages={dashboard:{title:'Dashboard',action:null},users:{title:'Usuários',action:{label:'+ Novo Usuário',fn:'openCreateUser'}},groups:{title:'Grupos',action:{label:'+ Novo Grupo',fn:'openCreateGroup'}},shares:{title:'Compartilhamentos',action:{label:'+ Novo Share',fn:'openCreateShare'}}};
function goto(page){document.querySelectorAll('.nav-item').forEach(n=>n.classList.remove('active'));document.querySelectorAll('.nav-item').forEach(n=>{if(n.getAttribute('onclick')?.includes(`'${page}'`))n.classList.add('active');});const p=pages[page];$('pT').textContent=p.title;const btn=$('tA');if(p.action){btn.style.display='';btn.textContent=p.action.label;btn.onclick=()=>window[p.action.fn]();}else btn.style.display='none';$('ct').innerHTML='<div style="display:flex;align-items:center;gap:.5rem;color:var(--muted)"><span class="spin"></span> Carregando...</div>';renders[page]?.();}
const renders={
async dashboard(){try{const s=await api('status');const ok=v=>v==='active';$('ct').innerHTML=`<div class="status-grid"><div class="stat-card"><div class="label">Samba</div><div class="value" style="font-size:1rem;margin-top:.4rem"><span class="dot ${ok(s.smbd)?'dot-green':'dot-red'}"></span>${ok(s.smbd)?'Ativo':'Inativo'}</div></div><div class="stat-card"><div class="label">NetBIOS</div><div class="value" style="font-size:1rem;margin-top:.4rem"><span class="dot ${ok(s.nmbd)?'dot-green':'dot-red'}"></span>${ok(s.nmbd)?'Ativo':'Inativo'}</div></div><div class="stat-card"><div class="label">Disco</div><div class="value">${esc(s.disk_used||'-')}</div><div class="sub">de ${esc(s.disk_total||'-')} (${esc(s.disk_pct||'-')})</div></div><div class="stat-card"><div class="label">Conexões</div><div class="value">${esc(s.connections)}</div></div><div class="stat-card" style="grid-column:span 2"><div class="label">Uptime</div><div class="value" style="font-size:.95rem;margin-top:.35rem">${esc(s.uptime||'-')}</div></div></div><div class="card"><div class="card-header"><h4>Status RAID 5</h4></div><pre style="padding:1rem 1.25rem;font-family:var(--mono);font-size:.78rem;color:var(--muted);white-space:pre-wrap">${esc(s.raid||'N/D')}</pre></div>`;}catch(e){$('ct').innerHTML=`<div class="empty"><span class="icon">⚠️</span>${esc(e.message)}</div>`;}},
async users(){try{const u=await api('list_users');if(!u.length){$('ct').innerHTML='<div class="empty"><span class="icon">👤</span>Nenhum usuário</div>';return;}$('ct').innerHTML=`<div class="card"><div class="card-header"><h4>Usuários Samba (${u.length})</h4></div><table><thead><tr><th>Usuário</th><th>Nome</th><th>Status</th><th>Grupos</th><th></th></tr></thead><tbody>${u.map(x=>`<tr><td><span style="font-family:var(--mono);font-weight:500">${esc(x.user)}</span></td><td style="color:var(--muted)">${esc(x.fullname||'-')}</td><td>${x.status==='Ativo'?'<span class="tag tag-green">Ativo</span>':'<span class="tag tag-red">Desabilitado</span>'}</td><td>${x.groups.map(g=>`<span class="tag tag-blue">${esc(g)}</span>`).join('')||'-'}</td><td style="text-align:right;white-space:nowrap"><button class="btn btn-sm" onclick="openResetPass('${esc(x.user)}')">🔑</button> <button class="btn btn-sm" onclick="toggleUser('${esc(x.user)}','${x.status}')">${x.status==='Ativo'?'⏸':'▶'}</button> <button class="btn btn-sm btn-danger" onclick="deleteUser('${esc(x.user)}')">🗑</button></td></tr>`).join('')}</tbody></table></div>`;}catch(e){$('ct').innerHTML=`<div class="empty"><span class="icon">⚠️</span>${esc(e.message)}</div>`;}},
async groups(){try{const g=await api('list_groups');if(!g.length){$('ct').innerHTML='<div class="empty"><span class="icon">👥</span>Nenhum grupo</div>';return;}$('ct').innerHTML=`<div class="card"><div class="card-header"><h4>Grupos (${g.length})</h4></div><table><thead><tr><th>Grupo</th><th>GID</th><th>Membros</th><th></th></tr></thead><tbody>${g.map(x=>`<tr><td><span style="font-family:var(--mono);font-weight:500">${esc(x.name)}</span></td><td style="color:var(--muted);font-family:var(--mono)">${esc(x.gid)}</td><td>${x.members.map(m=>`<span class="tag">${esc(m)}</span>`).join('')||'<span style="color:var(--muted);font-size:.8rem">sem membros</span>'}</td><td style="text-align:right"><button class="btn btn-sm" onclick="openAddMember('${esc(x.name)}')">+ Membro</button></td></tr>`).join('')}</tbody></table></div>`;}catch(e){$('ct').innerHTML=`<div class="empty"><span class="icon">⚠️</span>${esc(e.message)}</div>`;}},
async shares(){try{const s=await api('list_shares');if(!s.length){$('ct').innerHTML='<div class="empty"><span class="icon">🗂️</span>Nenhum share</div>';return;}$('ct').innerHTML=`<div class="card"><div class="card-header"><h4>Compartilhamentos (${s.length})</h4></div><table><thead><tr><th>Nome</th><th>Caminho</th><th>Disco</th><th>Flags</th></tr></thead><tbody>${s.map(x=>`<tr><td><span style="font-family:var(--mono);font-weight:500">${esc(x.name)}</span></td><td style="color:var(--muted);font-size:.8rem;font-family:var(--mono)">${esc(x.path)}</td><td style="font-family:var(--mono);font-size:.8rem">${esc(x.size||'-')}</td><td>${x.writable?'<span class="tag tag-green">gravável</span>':'<span class="tag">leitura</span>'} ${x.browse?'<span class="tag">visível</span>':'<span class="tag tag-red">oculto</span>'}</td></tr>`).join('')}</tbody></table></div>`;}catch(e){$('ct').innerHTML=`<div class="empty"><span class="icon">⚠️</span>${esc(e.message)}</div>`;}}};
async function loadGrps(){try{const g=await api('list_groups');return g.map(x=>`<option value="${esc(x.name)}">${esc(x.name)}</option>`).join('');}catch{return '';}}
async function openCreateUser(){const opts=await loadGrps();modal('Novo Usuário',`<div class="form-row"><div class="form-group"><label>Login *</label><input type="text" id="nU" placeholder="ex: joao"></div><div class="form-group"><label>Nome Completo</label><input type="text" id="nF"></div></div><div class="form-row"><div class="form-group"><label>Senha</label><input type="password" id="nP" placeholder="1234"></div><div class="form-group"><label>Grupo Principal *</label><select id="nG">${opts}</select></div></div>`,[{label:'Cancelar',fn:closeModal},{label:'Criar',cls:'btn-primary',fn:async()=>{const user=$('nU').value.trim();if(!user)return toast('Informe o login','error');try{await api('create_user',{user,fullname:$('nF').value,pass:$('nP').value||'C1234!',groups:$('nG').value},'POST');toast(`Usuário ${user} criado`);closeModal();renders.users();}catch(e){toast(e.message,'error');}}}]);}
function openResetPass(user){modal(`Resetar Senha — ${user}`,`<div class="form-group"><label>Nova Senha</label><input type="password" id="rP" placeholder="1234"></div>`,[{label:'Cancelar',fn:closeModal},{label:'Salvar',cls:'btn-primary',fn:async()=>{try{await api('reset_pass',{user,pass:$('rP').value||'C1234!'},'POST');toast('Senha atualizada');closeModal();}catch(e){toast(e.message,'error');}}}]);}
async function toggleUser(user,status){try{await api('toggle_user',{user,enable:status!=='Ativo'?'1':'0'},'POST');toast(`${user} ${status!=='Ativo'?'habilitado':'desabilitado'}`);renders.users();}catch(e){toast(e.message,'error');}}
function deleteUser(user){modal(`Revogar Acesso — ${user}`,`<p style="color:var(--muted)">Acesso de <strong style="color:var(--text)">${esc(user)}</strong> será revogado.</p>`,[{label:'Cancelar',fn:closeModal},{label:'Revogar',cls:'btn-danger',fn:async()=>{try{await api('delete_user',{user},'POST');toast('Acesso revogado');closeModal();renders.users();}catch(e){toast(e.message,'error');}}}]);}
function openCreateGroup(){modal('Novo Grupo',`<div class="form-group"><label>Nome (prefixado com grp_) *</label><input type="text" id="gN" placeholder="ex: financeiro"></div>`,[{label:'Cancelar',fn:closeModal},{label:'Criar',cls:'btn-primary',fn:async()=>{const name=$('gN').value.trim();if(!name)return toast('Informe o nome','error');try{await api('create_group',{name},'POST');toast(`Grupo grp_${name} criado`);closeModal();renders.groups();}catch(e){toast(e.message,'error');}}}]);}
async function openAddMember(group){modal(`Adicionar Membro — ${group}`,`<div class="form-group"><label>Usuário *</label><input type="text" id="mU" placeholder="ex: joao"></div>`,[{label:'Cancelar',fn:closeModal},{label:'Adicionar',cls:'btn-primary',fn:async()=>{const user=$('mU').value.trim();if(!user)return toast('Informe o usuário','error');try{await api('add_to_group',{user,group},'POST');toast(`${user} adicionado`);closeModal();renders.groups();}catch(e){toast(e.message,'error');}}}]);}
async function openCreateShare(){const opts=await loadGrps();modal('Novo Compartilhamento',`<div class="form-row"><div class="form-group"><label>Nome *</label><input type="text" id="sN"></div><div class="form-group"><label>Grupo *</label><select id="sG">${opts}</select></div></div><div class="form-group"><label>Descrição</label><input type="text" id="sC"></div><div class="form-row"><div class="form-group"><label>Gravável</label><select id="sW"><option value="1">Sim</option><option value="0">Não</option></select></div><div class="form-group"><label>Visível</label><select id="sB"><option value="1">Sim</option><option value="0">Não</option></select></div></div>`,[{label:'Cancelar',fn:closeModal},{label:'Criar',cls:'btn-primary',fn:async()=>{const name=$('sN').value.trim(),group=$('sG').value;if(!name||!group)return toast('Nome e grupo obrigatórios','error');try{await api('create_share',{name,group,comment:$('sC').value,writable:$('sW').value,browse:$('sB').value},'POST');toast(`Share ${name} criado`);closeModal();renders.shares();}catch(e){toast(e.message,'error');}}}]);}
<?php if($logged): ?>goto('dashboard');<?php endif; ?>
</script></body></html>
HTMLEOF

chown -R www-data:www-data "${PANEL_DIR}"
chmod -R 750 "${PANEL_DIR}"
chmod 640 "${PANEL_DIR}/config.php"

systemctl enable php8.3-fpm
systemctl restart php8.3-fpm
nginx -t || error "Nginx config inválida"
systemctl enable nginx
systemctl restart nginx

log "Painel web: https://${SAMBA_IP} | admin / admin"

# ===========================================================================
# 15. RESUMO FINAL
# ===========================================================================
header "INSTALAÇÃO CONCLUÍDA"

echo -e "${GREEN}${BOLD}"
cat << 'BANNER'
  ██████╗██████╗ ██████╗ ███╗   ██╗██╗
 ██╔════╝██╔══██╗██╔══██╗████╗  ██║██║
 ██║     ██║  ██║██████╔╝██╔██╗ ██║██║
 ██║     ██║  ██║██╔═══╝ ██║╚██╗██║██║
 ╚██████╗██████╔╝██║     ██║ ╚████║██║
  ╚═════╝╚═════╝ ╚═╝     ╚═╝  ╚═══╝╚═╝
BANNER
echo -e "${NC}"

TOTAL_SHARES=${#ALL_SHARES[@]}
OCULTAS=$(printf '%s\n' "${ALL_SHARES[@]}" | grep -c ':no$' || true)

echo -e "${CYAN}┌──────────────────────────────────────────────────────────┐"
echo -e "│                  RESUMO DA INSTALAÇÃO                   │"
echo -e "├──────────────────────────────────────────────────────────┤"
echo -e "│  Servidor     : cdpni  (192.168.0.11/24)                 │"
echo -e "│  Gateway/DNS  : 192.168.0.1                              │"
echo -e "│  RAID 5       : /dev/md0 — 5 × 2TB — ~8TB úteis         │"
echo -e "│  Permissões   : 777 recursivo (controle via Samba)       │"
echo -e "│  Pastas       : ${TOTAL_SHARES} compartilhamentos (${OCULTAS} oculta: CPD)       │"
echo -e "├──────────────────────────────────────────────────────────┤"
echo -e "│  USUÁRIO      SENHA  ACESSO                              │"
echo -e "│  sambadmin    1234   todos os compartilhamentos          │"
echo -e "│  cpd          1234   todos os compartilhamentos          │"
echo -e "│  jpfagiani    1234   todos (acesso root)                 │"
echo -e "│  rcborges     1234   todos os compartilhamentos          │"
echo -e "│  supervisao   1234   todos os compartilhamentos          │"
echo -e "│  adm/aevp/... 1234   pasta do respectivo setor           │"
echo -e "│  sindicancia  1234   Sindicancia + Chefias               │"
echo -e "│  csd          1234   CSD + Chefias + Rol + Sindicancia   │"
echo -e "├──────────────────────────────────────────────────────────┤"
echo -e "│  Painel Web   : https://192.168.0.11  (admin / admin)    │"
echo -e "│  Samba        : \\\\\\\\cdpni.local  ou  \\\\\\\\192.168.0.11        │"
echo -e "│  CPD oculto   : acesse direto \\\\\\\\192.168.0.11\\\\CPD         │"
echo -e "├──────────────────────────────────────────────────────────┤"
echo -e "│  ⚠  RAID 5 sincronizando em background                  │"
echo -e "│     watch cat /proc/mdstat                               │"
echo -e "└──────────────────────────────────────────────────────────┘${NC}"
echo ""
echo -e "${YELLOW}Próximos passos:"
echo -e "  1. Acessar painel     : https://192.168.0.11"
echo -e "  2. Trocar senha admin : https://192.168.0.11 → config.php"
echo -e "  3. Gerenciar via CLI  : sudo ./02_manage_users.sh"
echo -e "  4. Configurar backup  : sudo ./03_backup_setup.sh setup"
echo -e "  5. Reiniciar          : sudo reboot${NC}"
echo ""