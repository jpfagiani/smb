#!/bin/bash
# =============================================================================
# CDPNI — Servidor Samba — Script de Desinstalação Completa
# Executar DIRETAMENTE no servidor como root via SSH:
#   ssh root@IP "bash -s" < uninstall.sh
# ou copiar para o servidor e executar:
#   bash uninstall.sh [--com-raid]
# =============================================================================

set -euo pipefail

RED='\033[0;31m'
YEL='\033[1;33m'
GRN='\033[0;32m'
NC='\033[0m'

log()  { echo -e "${GRN}[✔]${NC} $*"; }
warn() { echo -e "${YEL}[!]${NC} $*"; }
erro() { echo -e "${RED}[✘]${NC} $*"; }

# ── verificações ──────────────────────────────────────────────────────────────
if [[ $EUID -ne 0 ]]; then
    erro "Execute como root: sudo bash uninstall.sh"
    exit 1
fi

DESTRUIR_RAID=0
if [[ "${1:-}" == "--com-raid" ]]; then
    DESTRUIR_RAID=1
fi

# ── confirmação ───────────────────────────────────────────────────────────────
echo ""
echo -e "${RED}╔══════════════════════════════════════════════════════╗${NC}"
echo -e "${RED}║      DESINSTALAÇÃO COMPLETA DO SERVIDOR CDPNI        ║${NC}"
echo -e "${RED}╚══════════════════════════════════════════════════════╝${NC}"
echo ""
warn "Isso vai remover: Samba, Nginx, PHP, portal Flask, usuários, grupos,"
warn "configurações, logs e arquivos de sudoers criados pelo Ansible."
echo ""
if [[ $DESTRUIR_RAID -eq 1 ]]; then
    echo -e "${RED}⚠  --com-raid informado: O ARRAY RAID SERÁ DESTRUÍDO e os DADOS APAGADOS!${NC}"
else
    warn "O RAID e os arquivos de shares NÃO serão tocados (use --com-raid para apagar)."
fi
echo ""
read -rp "Confirma a desinstalação? (digite SIM para continuar): " CONF
if [[ "$CONF" != "SIM" ]]; then
    echo "Cancelado."
    exit 0
fi

echo ""
log "Iniciando desinstalação..."

# ── 1. Parar e desabilitar serviços ──────────────────────────────────────────
log "Parando serviços..."
for svc in smbd nmbd winbind cdpni-portal nginx php8.4-fpm \
           fail2ban nftables smartd chrony; do
    systemctl stop    "$svc" 2>/dev/null || true
    systemctl disable "$svc" 2>/dev/null || true
done

# ── 2. Remover pacotes ────────────────────────────────────────────────────────
log "Removendo pacotes..."
DEBIAN_FRONTEND=noninteractive apt-get purge -y \
    samba samba-common samba-common-bin smbclient winbind \
    nginx nginx-common nginx-full nginx-light \
    php8.4-fpm php8.4-cli php8.4-common \
    python3-pip python3-venv python3-pam \
    nftables fail2ban \
    smartmontools \
    mdadm \
    postfix chrony \
    acl attr \
    2>/dev/null || true

apt-get autoremove -y 2>/dev/null || true
apt-get autoclean   2>/dev/null || true

# ── 3. Remover arquivos e configurações ───────────────────────────────────────
log "Removendo configurações e diretórios..."

# Samba
rm -rf /etc/samba /var/lib/samba /var/log/samba /run/samba

# Nginx
rm -rf /etc/nginx /var/log/nginx

# PHP
rm -rf /etc/php /var/log/php*

# Portal Flask
rm -rf /opt/cdpni-portal

# Painel PHP antigo
rm -rf /var/www/samba-panel

# SSL
rm -rf /etc/nginx/ssl /etc/ssl/cdpni

# Systemd
rm -f /etc/systemd/system/cdpni-portal.service

# Sudoers
rm -f /etc/sudoers.d/cdpni-portal
rm -f /etc/sudoers.d/samba-panel
rm -f /etc/sudoers.d/cdpni-panel

# Fail2ban
rm -rf /etc/fail2ban /var/log/fail2ban*

# Logs CDPNI
rm -f /var/log/cdpni*.log
rm -f /var/log/samba_panel.log
rm -f /var/log/raid_*.log

# Logrotate
rm -f /etc/logrotate.d/cdpni

# Backup
rm -rf /backup/samba /opt/backups

# Smart
rm -f /etc/smartd.conf

# Webroot residual
rm -rf /var/www/html/cdpni-ca.crt

# ── 4. Remover usuários operacionais ─────────────────────────────────────────
log "Removendo usuários operacionais..."
for u in jpfagiani rcborges cpd supervisao sambadmin cdpni cdpni-portal; do
    if id "$u" &>/dev/null; then
        userdel -r "$u" 2>/dev/null || userdel "$u" 2>/dev/null || true
        log "  usuário removido: $u"
    fi
done

# ── 5. Remover usuários por share ─────────────────────────────────────────────
log "Removendo usuários dos compartilhamentos..."
SHARE_USERS=(
    administrativo aevp almoxarifado cadastro canil
    chefia1 chefia2 chefia3 chefia4
    cipa conexao csd educacao financas inclusao
    infra npessoal planilhas
    portaria1 portaria2 portaria3 portaria4
    rol saude simic sindicancia dg
    publico scanner papel_de_parede
)
for u in "${SHARE_USERS[@]}"; do
    if id "$u" &>/dev/null; then
        userdel -r "$u" 2>/dev/null || userdel "$u" 2>/dev/null || true
        log "  usuário removido: $u"
    fi
done

# ── 6. Remover grupos ─────────────────────────────────────────────────────────
log "Removendo grupos..."
GRUPOS=(
    grp_administrativo grp_aevp grp_almoxarifado grp_cadastro grp_canil
    grp_chefia1 grp_chefia2 grp_chefia3 grp_chefia4
    grp_cipa grp_conexao grp_cpd grp_csd grp_dg
    grp_educacao grp_financas grp_inclusao grp_infra
    grp_npessoal grp_papel_de_parede grp_planilhas
    grp_portaria1 grp_portaria2 grp_portaria3 grp_portaria4
    grp_publico grp_rol grp_saude grp_scanner
    grp_simic grp_sindicancia grp_supervisao
    sambashare
)
for g in "${GRUPOS[@]}"; do
    if getent group "$g" &>/dev/null; then
        groupdel "$g" 2>/dev/null || true
        log "  grupo removido: $g"
    fi
done

# ── 7. Remover cron jobs ──────────────────────────────────────────────────────
log "Removendo cron jobs..."
crontab -r 2>/dev/null || true
rm -f /etc/cron.d/cdpni*

# ── 8. Destruir RAID (opcional) ───────────────────────────────────────────────
if [[ $DESTRUIR_RAID -eq 1 ]]; then
    warn "Destruindo array RAID..."
    MOUNT_RAID=$(grep '/mnt/raid' /etc/fstab | awk '{print $1}' | head -1 || true)

    umount /mnt/raid 2>/dev/null || true

    # Detecta arrays ativos
    ARRAYS=$(awk '/^md/{print "/dev/"$1}' /proc/mdstat 2>/dev/null || true)
    for arr in $ARRAYS; do
        mdadm --stop "$arr" 2>/dev/null || true
        log "  array parado: $arr"
    done

    # Remove metadados dos discos membros
    MEMBROS=$(mdadm --detail "$arr" 2>/dev/null | awk '/\/dev\/sd/{print $NF}' || true)
    for disco in $MEMBROS; do
        mdadm --zero-superblock "$disco" 2>/dev/null || true
        wipefs -a "$disco" 2>/dev/null || true
        log "  superblock limpo: $disco"
    done

    # Remove do fstab
    sed -i '/\/mnt\/raid/d' /etc/fstab 2>/dev/null || true
    rm -f /etc/mdadm/mdadm.conf

    log "RAID destruído. Discos prontos para nova partição."
else
    warn "RAID preservado. Desmontando apenas para garantir reinstalação limpa..."
    umount /mnt/raid 2>/dev/null || true
    warn "Monte manual após reinstalar: mount /dev/md0 /mnt/raid"
    echo ""
    erro "NÃO REINICIE o servidor antes de reinstalar: o mdadm foi removido e o"
    erro "array não montará no boot. Se reiniciar, rode antes do site.yml:"
    erro "  bash scripts/restore_pos_reinstall.sh raid <backup.tar.gz>"
fi

# ── 9. Recarregar systemd ────────────────────────────────────────────────────
log "Recarregando systemd..."
systemctl daemon-reload
systemctl reset-failed 2>/dev/null || true

# ── 10. Restaurar iptables para aceitar tudo (caso nftables esteja bloqueando)
log "Limpando regras de firewall..."
nft flush ruleset 2>/dev/null || true
iptables -P INPUT   ACCEPT 2>/dev/null || true
iptables -P FORWARD ACCEPT 2>/dev/null || true
iptables -P OUTPUT  ACCEPT 2>/dev/null || true
iptables -F 2>/dev/null || true

# ── Resumo ────────────────────────────────────────────────────────────────────
echo ""
echo -e "${GRN}╔══════════════════════════════════════════════════════╗${NC}"
echo -e "${GRN}║           DESINSTALAÇÃO CONCLUÍDA                    ║${NC}"
echo -e "${GRN}╚══════════════════════════════════════════════════════╝${NC}"
echo ""
if [[ $DESTRUIR_RAID -eq 1 ]]; then
    warn "RAID destruído — discos limpos para nova instalação."
else
    log "RAID preservado em /mnt/raid."
fi
echo ""
log "Pronto para nova instalação:"
echo "   ansible-playbook -i inventory/hosts.ini site.yml"
echo ""
