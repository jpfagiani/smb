#!/bin/bash
# =============================================================================
# CDPNI — Restauração PÓS-reinstalação
#
# Contraparte do backup_pre_reinstall.sh. Duas fases:
#
#   FASE "raid" — rodar ANTES do bootstrap.sh / site.yml sempre que o
#   servidor tiver sido reiniciado após o uninstall.sh (que purga o mdadm)
#   ou tiver sido formatado. Remonta o array em /mnt/raid para que a role
#   storage o reconheça como produção — sem isso ela trata como instalação
#   limpa e RECRIA + FORMATA o RAID (perda total dos dados).
#       bash restore_pos_reinstall.sh raid [backup.tar.gz]
#   (o backup é opcional nesta fase — só é usado para o mdadm.conf salvo)
#
#   FASE "dados" — rodar DEPOIS do bootstrap.sh / site.yml. Restaura o que
#   o Ansible não recria: senhas do Samba + SID, senhas Linux, homes,
#   certificado SSL antigo (opcional) e confere se os UIDs recriados batem
#   com os donos dos arquivos no RAID (gera fix_uids.sh se não baterem).
#       bash restore_pos_reinstall.sh dados backup.tar.gz
# =============================================================================

set -uo pipefail

RED='\033[0;31m'; YEL='\033[1;33m'; GRN='\033[0;32m'; NC='\033[0m'
log()  { echo -e "${GRN}[✔]${NC} $*"; }
warn() { echo -e "${YEL}[!]${NC} $*"; }
erro() { echo -e "${RED}[✘]${NC} $*"; }

[[ $EUID -eq 0 ]] || { erro "Execute como root."; exit 1; }

FASE="${1:-}"
BACKUP="${2:-}"
RAID_MOUNT="/mnt/raid"

usage() {
    echo "Uso: bash restore_pos_reinstall.sh raid  [backup.tar.gz]"
    echo "     bash restore_pos_reinstall.sh dados backup.tar.gz"
    exit 1
}
[[ "$FASE" == "raid" || "$FASE" == "dados" ]] || usage

# Extrai o backup (aceita .tar.gz ou o diretório já extraído)
BK_DIR=""
extrair_backup() {
    [[ -n "$BACKUP" ]] || return 0
    if [[ -d "$BACKUP" ]]; then
        BK_DIR="$BACKUP"
    elif [[ -f "$BACKUP" ]]; then
        BK_DIR=$(mktemp -d /root/restore-cdpni.XXXXXX)
        tar -xzf "$BACKUP" -C "$BK_DIR" --strip-components=1 \
            || { erro "Falha ao extrair $BACKUP"; exit 1; }
    else
        erro "Backup não encontrado: $BACKUP"; exit 1
    fi
    log "Backup: ${BK_DIR}"
}

# ═════════════════════════════ FASE RAID ═════════════════════════════════════
fase_raid() {
    extrair_backup

    if findmnt -n "$RAID_MOUNT" >/dev/null 2>&1; then
        log "${RAID_MOUNT} já está montado — nada a fazer. Pode rodar o site.yml."
        return 0
    fi

    if ! command -v mdadm >/dev/null 2>&1; then
        log "Instalando mdadm..."
        DEBIAN_FRONTEND=noninteractive apt-get install -y mdadm || {
            erro "Falha ao instalar mdadm. Verifique a rede/APT e rode de novo."
            exit 1
        }
    fi

    # mdadm.conf salvo ajuda o assemble a usar o nome original (/dev/md0)
    if [[ -n "$BK_DIR" && -f "$BK_DIR/raid/mdadm.conf" && ! -f /etc/mdadm/mdadm.conf ]]; then
        mkdir -p /etc/mdadm
        cp -a "$BK_DIR/raid/mdadm.conf" /etc/mdadm/mdadm.conf
        log "mdadm.conf restaurado do backup."
    fi

    log "Montando arrays existentes (assemble, NUNCA create)..."
    mdadm --assemble --scan 2>/dev/null || true

    DEV=$(blkid -L SAMBA_DATA 2>/dev/null || true)
    if [[ -z "$DEV" ]]; then
        erro "Nenhum filesystem com label SAMBA_DATA encontrado."
        erro "NÃO RODE o site.yml — a role storage vai formatar os discos!"
        warn "Diagnóstico: cat /proc/mdstat; mdadm --examine /dev/sd?; blkid"
        [[ -n "$BK_DIR" ]] && warn "Mapa dos discos originais: ${BK_DIR}/raid/disk_by_id.txt"
        exit 1
    fi

    mkdir -p "$RAID_MOUNT"
    if mount "$DEV" "$RAID_MOUNT"; then
        log "RAID montado: ${DEV} → ${RAID_MOUNT}"
        log "Agora é seguro rodar o bootstrap.sh / site.yml (a role vai"
        log "reconhecer produção e não tocar nos dados)."
    else
        erro "Falha ao montar ${DEV} em ${RAID_MOUNT}. NÃO RODE o site.yml."
        exit 1
    fi
}

# ═════════════════════════════ FASE DADOS ════════════════════════════════════
fase_dados() {
    [[ -n "$BACKUP" ]] || usage
    extrair_backup

    # ── Senhas do Samba + SID ────────────────────────────────────────────────
    if [[ -f "$BK_DIR/samba/passdb.tdb" ]]; then
        log "Restaurando banco de senhas do Samba..."
        systemctl stop smbd nmbd 2>/dev/null || true
        mkdir -p /var/lib/samba/private
        cp -a "$BK_DIR/samba/passdb.tdb"  /var/lib/samba/private/
        [[ -f "$BK_DIR/samba/secrets.tdb" ]] && cp -a "$BK_DIR/samba/secrets.tdb" /var/lib/samba/private/
        systemctl start smbd nmbd 2>/dev/null || true
        if pdbedit -L >/dev/null 2>&1; then
            log "  passdb restaurado ($(pdbedit -L 2>/dev/null | wc -l) usuários)."
        else
            warn "  passdb.tdb copiado mas o pdbedit falhou (versão incompatível?)."
            warn "  Fallback com o export texto: pdbedit -i smbpasswd:${BK_DIR}/samba/usuarios.smbpasswd"
        fi
    elif [[ -s "$BK_DIR/samba/usuarios.smbpasswd" ]]; then
        log "Importando usuários do Samba via export smbpasswd..."
        pdbedit -i smbpasswd:"$BK_DIR/samba/usuarios.smbpasswd" 2>/dev/null \
            && log "  importado." || warn "  falha na importação."
    else
        warn "Backup não contém senhas do Samba — usuários ficarão com a senha do bootstrap."
    fi
    if [[ -s "$BK_DIR/samba/sid.txt" && ! -f "$BK_DIR/samba/secrets.tdb" ]]; then
        net setlocalsid "$(cat "$BK_DIR/samba/sid.txt")" 2>/dev/null \
            && log "SID local restaurado." || true
    fi

    # ── Senhas Linux (hashes do shadow, só para usuários que existem) ────────
    if [[ -f "$BK_DIR/sistema/shadow" ]]; then
        log "Restaurando senhas Linux dos usuários recriados..."
        local n=0
        while IFS=: read -r usuario hash _; do
            [[ "$hash" == "!"* || "$hash" == "*" || -z "$hash" ]] && continue
            id "$usuario" &>/dev/null || continue
            echo "${usuario}:${hash}" | chpasswd -e 2>/dev/null && n=$((n+1))
        done < "$BK_DIR/sistema/shadow"
        log "  ${n} senha(s) restaurada(s)."
    fi

    # ── Homes ────────────────────────────────────────────────────────────────
    if [[ -f "$BK_DIR/sistema/homes.tar.gz" ]]; then
        log "Restaurando homes (sem sobrescrever arquivos mais novos)..."
        tar -xzf "$BK_DIR/sistema/homes.tar.gz" --numeric-owner --keep-newer-files -C / 2>/dev/null || true
    fi

    # ── Conferência de UIDs vs. donos dos arquivos no RAID ───────────────────
    if [[ -f "$BK_DIR/sistema/mapa_uid.txt" ]]; then
        log "Conferindo UIDs antigos × novos..."
        local FIX="/root/fix_uids.sh"
        local tem_diff=0
        {
            echo "#!/bin/bash"
            echo "# Gerado por restore_pos_reinstall.sh — REVISE antes de executar."
            echo "# Remapeia donos em ${RAID_MOUNT} dos UIDs antigos para os novos."
            echo "# Duas fases (offset +100000) para evitar colisão entre mapeamentos."
            echo "set -euo pipefail"
        } > "$FIX"
        # fase 1: uid_antigo → uid_novo+100000
        while IFS=: read -r usuario uid_antigo gid_antigo; do
            id "$usuario" &>/dev/null || { warn "  usuário '${usuario}' não existe no sistema novo"; continue; }
            local uid_novo gid_novo
            uid_novo=$(id -u "$usuario"); gid_novo=$(id -g "$usuario")
            if [[ "$uid_novo" != "$uid_antigo" ]]; then
                warn "  ${usuario}: UID mudou ${uid_antigo} → ${uid_novo}"
                echo "find ${RAID_MOUNT} /home -xdev -uid ${uid_antigo} -exec chown -h \$((${uid_novo}+100000)) {} +  # ${usuario}" >> "$FIX"
                tem_diff=1
            fi
            if [[ "$gid_novo" != "$gid_antigo" ]]; then
                echo "find ${RAID_MOUNT} /home -xdev -gid ${gid_antigo} -exec chgrp -h \$((${gid_novo}+100000)) {} +  # grupo de ${usuario}" >> "$FIX"
                tem_diff=1
            fi
        done < "$BK_DIR/sistema/mapa_uid.txt"
        # fase 2: remove o offset
        echo "# Fase 2 — tira o offset:" >> "$FIX"
        while IFS=: read -r usuario uid_antigo gid_antigo; do
            id "$usuario" &>/dev/null || continue
            local uid_novo gid_novo
            uid_novo=$(id -u "$usuario"); gid_novo=$(id -g "$usuario")
            [[ "$uid_novo" != "$uid_antigo" ]] && \
                echo "find ${RAID_MOUNT} /home -xdev -uid \$((${uid_novo}+100000)) -exec chown -h ${uid_novo} {} +  # ${usuario}" >> "$FIX"
            gid_novo=$(id -g "$usuario")
            [[ "$gid_novo" != "$gid_antigo" ]] && \
                echo "find ${RAID_MOUNT} /home -xdev -gid \$((${gid_novo}+100000)) -exec chgrp -h ${gid_novo} {} +  # grupo de ${usuario}" >> "$FIX"
        done < "$BK_DIR/sistema/mapa_uid.txt"
        if [[ "$tem_diff" -eq 1 ]]; then
            chmod 700 "$FIX"
            erro "UIDs divergentes detectados! Arquivos no RAID podem estar com dono errado."
            warn "Revise e execute: bash ${FIX}"
        else
            rm -f "$FIX"
            log "  todos os UIDs/GIDs batem — donos dos arquivos preservados."
        fi
    fi

    # ── SSL antigo (opcional) ────────────────────────────────────────────────
    if [[ -d "$BK_DIR/ssl/nginx_ssl" ]]; then
        read -rp "Restaurar o certificado SSL antigo do portal? (s/N): " R
        if [[ "${R,,}" == "s" ]]; then
            cp -a "$BK_DIR/ssl/nginx_ssl/." /etc/nginx/ssl/
            systemctl reload nginx 2>/dev/null || true
            log "Certificado antigo restaurado (navegadores não pedirão nova exceção)."
        fi
    fi

    # ── Crontab do root ──────────────────────────────────────────────────────
    if [[ -s "$BK_DIR/cron/root_crontab.txt" ]]; then
        warn "Crontab antigo do root salvo em ${BK_DIR}/cron/root_crontab.txt —"
        warn "o Ansible recria os jobs dele; restaure manualmente só o que for extra."
    fi

    echo ""
    log "Restauração concluída. Teste: login SMB de um usuário antigo com a senha antiga."
}

case "$FASE" in
    raid)  fase_raid  ;;
    dados) fase_dados ;;
esac
