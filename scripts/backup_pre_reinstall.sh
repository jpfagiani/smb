#!/bin/bash
# =============================================================================
# CDPNI — Backup PRÉ-reinstalação
#
# Salva tudo que o uninstall.sh e/ou uma formatação destroem e que o
# Ansible NÃO recria sozinho:
#   - senhas do Samba (passdb.tdb / secrets.tdb / export smbpasswd + SID)
#   - usuários Linux com UIDs/GIDs e senhas (passwd/group/shadow/gshadow)
#   - diretórios home (userdel -r do uninstall apaga os homes!)
#   - config real do Ansible (group_vars/all.yml — fica fora do git)
#   - certificados SSL do portal (evita novo aviso nos navegadores)
#   - chaves de host do SSH (evita aviso de "host key changed" ao formatar)
#   - metadados do RAID (mdadm.conf, detail/examine, fstab, mapa de discos)
#   - ACLs e donos dos diretórios de shares no RAID
#   - crontab do root (uninstall roda crontab -r)
#
# Uso (como root, ANTES do uninstall.sh):
#   bash backup_pre_reinstall.sh [dir_destino]      # padrão: /root
#
# O resultado é um .tar.gz com chmod 600 (contém hashes de senha!).
# COPIE-O PARA FORA DO SERVIDOR — se formatar, /root vai junto:
#   scp root@IP:/root/cdpni-pre-reinstall-*.tar.gz .
#
# Restauração: scripts/restore_pos_reinstall.sh (veja o cabeçalho dele).
# =============================================================================

set -uo pipefail

RED='\033[0;31m'; YEL='\033[1;33m'; GRN='\033[0;32m'; NC='\033[0m'
log()  { echo -e "${GRN}[✔]${NC} $*"; }
warn() { echo -e "${YEL}[!]${NC} $*"; }
erro() { echo -e "${RED}[✘]${NC} $*"; }

[[ $EUID -eq 0 ]] || { erro "Execute como root."; exit 1; }

DEST_BASE="${1:-/root}"
TS=$(date +%Y%m%d-%H%M%S)
NOME="cdpni-pre-reinstall-${TS}"
DIR="${DEST_BASE}/${NOME}"
RAID_MOUNT="/mnt/raid"
# Homes maiores que isso (em MB) não entram no tar — ajuste se precisar:
LIMITE_HOME_MB="${LIMITE_HOME_MB:-4096}"

mkdir -p "$DIR"/{samba,sistema,raid,config,ssl,ssh,cron,acl}
log "Coletando em ${DIR}"

# ── 1. Samba: senhas, SID e configuração ─────────────────────────────────────
log "Samba (senhas, SID, smb.conf)..."
if [[ -d /var/lib/samba/private ]]; then
    cp -a /var/lib/samba/private/passdb.tdb  "$DIR/samba/" 2>/dev/null || warn "  passdb.tdb não encontrado"
    cp -a /var/lib/samba/private/secrets.tdb "$DIR/samba/" 2>/dev/null || warn "  secrets.tdb não encontrado"
fi
# Export em formato smbpasswd — restaurável com pdbedit -i mesmo se os tdb
# ficarem incompatíveis com a versão nova do Samba
pdbedit -L -w > "$DIR/samba/usuarios.smbpasswd" 2>/dev/null || warn "  pdbedit falhou (samba parado?)"
pdbedit -L -v > "$DIR/samba/usuarios_detalhe.txt" 2>/dev/null || true
net getlocalsid 2>/dev/null | awk '{print $NF}' > "$DIR/samba/sid.txt" || true
[[ -d /etc/samba ]] && cp -a /etc/samba "$DIR/samba/etc_samba"

# ── 2. Usuários e grupos Linux (UIDs, GIDs, senhas) ──────────────────────────
log "Usuários/grupos Linux..."
cp -a /etc/passwd /etc/group /etc/shadow /etc/gshadow "$DIR/sistema/"
# Mapa só dos usuários "de verdade" (UID >= 1000, exceto nobody) — usado na
# restauração para conferir se os UIDs recriados batem com os donos dos
# arquivos que ficaram no RAID
awk -F: '$3 >= 1000 && $1 != "nobody" {print $1":"$3":"$4}' /etc/passwd > "$DIR/sistema/mapa_uid.txt"
awk -F: '$3 >= 1000 && $1 != "nogroup" {print $1":"$3}' /etc/group > "$DIR/sistema/mapa_gid.txt"

# ── 3. Homes (userdel -r do uninstall apaga tudo em /home) ───────────────────
TAM_HOME_MB=$(du -sm /home 2>/dev/null | awk '{print $1}')
TAM_HOME_MB=${TAM_HOME_MB:-0}
if [[ "$TAM_HOME_MB" -le "$LIMITE_HOME_MB" ]]; then
    log "Homes (/home, ${TAM_HOME_MB} MB)..."
    tar -czf "$DIR/sistema/homes.tar.gz" --numeric-owner -C / home 2>/dev/null \
        || warn "  falha ao empacotar /home"
else
    warn "Homes: /home tem ${TAM_HOME_MB} MB (> ${LIMITE_HOME_MB} MB) — NÃO incluído."
    warn "  Copie manualmente ou rode com LIMITE_HOME_MB=maior. Tamanhos:"
    du -sm /home/* 2>/dev/null | sort -rn | head -20 | tee "$DIR/sistema/homes_tamanhos.txt"
fi

# ── 4. RAID: metadados e mapa de discos ──────────────────────────────────────
log "RAID (metadados, fstab, mapa de discos)..."
cat /proc/mdstat > "$DIR/raid/mdstat.txt" 2>/dev/null || true
mdadm --detail --scan > "$DIR/raid/mdadm_scan.txt" 2>/dev/null || true
[[ -f /etc/mdadm/mdadm.conf ]] && cp -a /etc/mdadm/mdadm.conf "$DIR/raid/"
for md in /dev/md*; do
    [[ -b "$md" ]] || continue
    mdadm --detail "$md" > "$DIR/raid/detail_$(basename "$md").txt" 2>/dev/null || true
    for membro in $(mdadm --detail "$md" 2>/dev/null | awk '/\/dev\//{print $NF}' | grep '^/dev/'); do
        mdadm --examine "$membro" > "$DIR/raid/examine_$(basename "$membro").txt" 2>/dev/null || true
    done
done
lsblk -o NAME,SIZE,TYPE,MODEL,SERIAL,LABEL,UUID,MOUNTPOINT > "$DIR/raid/lsblk.txt" 2>/dev/null || true
blkid > "$DIR/raid/blkid.txt" 2>/dev/null || true
ls -l /dev/disk/by-id/ > "$DIR/raid/disk_by_id.txt" 2>/dev/null || true
cp -a /etc/fstab "$DIR/raid/fstab"

# ── 5. Config real do Ansible (fora do git) ──────────────────────────────────
log "Config do Ansible (all.yml)..."
[[ -f /opt/smb/group_vars/all.yml ]] && cp -a /opt/smb/group_vars/all.yml "$DIR/config/"
[[ -f /root/all.yml.bak ]] && cp -a /root/all.yml.bak "$DIR/config/"
[[ -f "$DIR/config/all.yml" ]] || warn "  all.yml não encontrado em /opt/smb/group_vars/"

# ── 6. SSL do portal e chaves de host SSH ────────────────────────────────────
log "Certificados SSL e chaves SSH..."
[[ -d /etc/nginx/ssl ]] && cp -a /etc/nginx/ssl "$DIR/ssl/nginx_ssl"
cp -a /etc/ssh/ssh_host_* "$DIR/ssh/" 2>/dev/null || true
[[ -d /root/.ssh ]] && cp -a /root/.ssh "$DIR/ssh/root_dot_ssh"

# ── 7. Crontabs ───────────────────────────────────────────────────────────────
log "Crontabs..."
crontab -l > "$DIR/cron/root_crontab.txt" 2>/dev/null || echo "" > "$DIR/cron/root_crontab.txt"
cp -a /etc/cron.d/cdpni* "$DIR/cron/" 2>/dev/null || true

# ── 8. ACLs e donos dos shares no RAID ───────────────────────────────────────
if findmnt -n "$RAID_MOUNT" >/dev/null 2>&1; then
    log "ACLs e donos em ${RAID_MOUNT} (até 3 níveis)..."
    find "$RAID_MOUNT" -maxdepth 3 -print0 2>/dev/null \
        | xargs -0 getfacl -p --absolute-names > "$DIR/acl/getfacl_raid.txt" 2>/dev/null || true
    ls -lnR --time-style=+%Y-%m-%d "$RAID_MOUNT" 2>/dev/null | head -5000 > "$DIR/acl/ls_ln_raid.txt" || true
else
    warn "${RAID_MOUNT} não está montado — ACLs dos shares não coletadas."
fi

# ── 9. Manifesto ──────────────────────────────────────────────────────────────
{
    echo "Backup pré-reinstalação CDPNI"
    echo "Data:     $(date)"
    echo "Hostname: $(hostname -f 2>/dev/null || hostname)"
    echo "Kernel:   $(uname -r)"
    echo "Samba:    $(smbd --version 2>/dev/null || echo 'não instalado')"
    echo "RAID:     $(mdadm --detail --scan 2>/dev/null || echo 'nenhum array detectado')"
} > "$DIR/MANIFESTO.txt"

# ── 10. Empacotar ─────────────────────────────────────────────────────────────
TARBALL="${DEST_BASE}/${NOME}.tar.gz"
tar -czf "$TARBALL" -C "$DEST_BASE" "$NOME"
chmod 600 "$TARBALL"
rm -rf "$DIR"

echo ""
log "Backup criado: ${TARBALL} ($(du -h "$TARBALL" | awk '{print $1}'))"
echo ""
erro "IMPORTANTE — leia antes de desinstalar:"
warn "1. COPIE o backup PARA FORA do servidor agora:"
echo "     scp root@$(hostname -I 2>/dev/null | awk '{print $1}'):${TARBALL} ."
warn "2. O arquivo contém hashes de senha (shadow + passdb) — guarde com cuidado."
warn "3. NÃO REINICIE o servidor entre o uninstall.sh e o novo site.yml sem antes"
warn "   rodar 'restore_pos_reinstall.sh raid <backup>': o uninstall remove o mdadm"
warn "   e, sem o array montado, a role storage TRATA COMO INSTALAÇÃO LIMPA e"
warn "   RECRIA + FORMATA o RAID (perda total dos dados)."
warn "4. Após o bootstrap/site.yml, restaure senhas e homes com:"
echo "     bash restore_pos_reinstall.sh dados ${TARBALL}"
echo ""
