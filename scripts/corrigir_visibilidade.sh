#!/bin/bash
# ─────────────────────────────────────────────────────────────────────────
#  Corrige "arquivos salvos somem da pasta e voltam depois de um backup"
#  num servidor JÁ instalado — sem reinstalar e sem tocar nos dados.
#
#  Uso:  sudo bash scripts/corrigir_visibilidade.sh
#
#  O que faz (idempotente):
#    1. sobe os limites de inotify (change notify do Samba estourava)
#    2. dead time = 0 no smb.conf (não derruba mais sessões ociosas)
#    3. smbd só inicia com /mnt/raid realmente montado (ConditionPathIsMountPoint)
#    4. conserta /usr/local/bin/raid_check.sh (faltava um "fi": o monitoramento
#       do RAID nunca rodava e nenhum alerta era enviado)
#  smb.conf é validado com testparm; se falhar, o backup é restaurado.
# ─────────────────────────────────────────────────────────────────────────
set -euo pipefail

CONF="${SMB_CONF:-/etc/samba/smb.conf}"
MNT="${RAID_MOUNT:-/mnt/raid}"

[ "$(id -u)" -eq 0 ] || { echo "Execute como root:  sudo bash $0"; exit 1; }
[ -f "$CONF" ] || { echo "Não encontrei $CONF"; exit 1; }

echo "── 1. inotify"
cat > /etc/sysctl.d/90-samba-inotify.conf <<'EOF'
# change notify do Samba: um inotify por conexão (smbd roda como root)
fs.inotify.max_user_instances = 8192
fs.inotify.max_user_watches   = 524288
fs.inotify.max_queued_events  = 65536
EOF
sysctl --system >/dev/null
sysctl fs.inotify.max_user_instances fs.inotify.max_user_watches | sed 's/^/   /'

echo "── 2. dead time"
BAK="${CONF}.bak.visib.$(date +%Y%m%d%H%M%S)"
cp -a "$CONF" "$BAK"
echo "   backup: $BAK"
if grep -qE '^[[:space:]]*dead time[[:space:]]*=' "$CONF"; then
    sed -i -E 's/^([[:space:]]*dead time[[:space:]]*=).*/\1 0/' "$CONF"
else
    sed -i '0,/^\[global\]/s//[global]\n    dead time            = 0/' "$CONF"
fi
if testparm -s "$CONF" >/dev/null 2>&1; then
    smbcontrol smbd reload-config 2>/dev/null || true
    echo "   dead time = $(testparm -s --parameter-name='dead time' 2>/dev/null)  (testparm OK)"
else
    cp -a "$BAK" "$CONF"
    echo "   ✖ testparm rejeitou a alteração — smb.conf restaurado."
    exit 1
fi

echo "── 3. smbd só sobe com o RAID montado"
mkdir -p /etc/systemd/system/smbd.service.d
cat > /etc/systemd/system/smbd.service.d/raid-dependency.conf <<EOF
[Unit]
RequiresMountsFor=${MNT}
# Nunca sobe o smbd se ${MNT} não for um ponto de montagem real
ConditionPathIsMountPoint=${MNT}
After=local-fs.target
EOF
systemctl daemon-reload
echo "   ok"

echo "── 4. raid_check.sh"
F=/usr/local/bin/raid_check.sh
if [ -f "$F" ]; then
    if bash -n "$F" 2>/dev/null; then
        echo "   já está correto"
    else
        cp -a "$F" "${F}.bak.visib"
        # fecha o 'elif' antes do 'if [[ -n "$MSG" ]]'
        sed -i '0,/^\([[:space:]]*\)if \[\[ -n "\$MSG" \]\]; then/s//\1fi\n\1if [[ -n "$MSG" ]]; then/' "$F"
        bash -n "$F" && echo "   corrigido" || { cp -a "${F}.bak.visib" "$F"; echo "   ✖ não consegui corrigir; restaurado. Rode o playbook (tag storage)."; }
    fi
else
    echo "   $F não existe (modo disco único?) — nada a fazer"
fi

echo
echo "Pronto. Verificação de montagem agora:"
findmnt -n "$MNT" || echo "   ⚠ $MNT NÃO está montado!"
echo "Peça aos usuários para apertar F5 (ou reabrir a pasta) uma vez."
