#!/bin/bash
# ─────────────────────────────────────────────────────────────────────────
#  Permite acessos simultâneos aos compartilhamentos (mesmo usuário em vários
#  computadores) num servidor JÁ instalado — sem reinstalar nada.
#
#  Uso:  sudo bash scripts/permitir_acessos_simultaneos.sh [max_connections]
#        (padrão 0 = sem limite; qualquer valor informado deve ser >= 20)
#
#  O que faz (idempotente):
#    • backup de /etc/samba/smb.conf  (smb.conf.bak.simult.<data>)
#    • grava em [global]: max connections / max smbd processes
#    • valida com testparm; se falhar, restaura o backup e não mexe em nada
#    • recarrega o smbd SEM derrubar as conexões em andamento
#  O painel web preserva o [global] ao salvar compartilhamentos, e uma nova
#  execução do Ansible grava os mesmos valores — nada se perde.
# ─────────────────────────────────────────────────────────────────────────
set -euo pipefail

CONF="${SMB_CONF:-/etc/samba/smb.conf}"
MAXC="${1:-0}"

[ "$(id -u)" -eq 0 ] || { echo "Execute como root:  sudo bash $0"; exit 1; }
[[ "$MAXC" =~ ^[0-9]+$ ]] || { echo "Valor inválido: '$MAXC' (use um número; 0 = sem limite)"; exit 1; }
if [ "$MAXC" -ne 0 ] && [ "$MAXC" -lt 20 ]; then
    echo "Valor $MAXC é menor que 20 — use 0 (sem limite) ou um número >= 20."; exit 1
fi
[ -f "$CONF" ] || { echo "Não encontrei $CONF"; exit 1; }
grep -q '^\[global\]' "$CONF" || { echo "$CONF não tem seção [global]"; exit 1; }

BAK="${CONF}.bak.simult.$(date +%Y%m%d%H%M%S)"
cp -a "$CONF" "$BAK"
echo "→ Backup: $BAK"

TMP="$(mktemp)"
# remove entradas antigas (qualquer espaçamento) e insere logo após [global]
awk -v maxc="$MAXC" '
    /^[[:space:]]*max connections[[:space:]]*=/    { next }
    /^[[:space:]]*max smbd processes[[:space:]]*=/ { next }
    { print }
    /^\[global\]/ && !feito {
        print "    # Acessos simultaneos: mesmo usuario em varios PCs (0 = sem limite)"
        print "    max connections      = " maxc
        print "    max smbd processes   = 0"
        feito = 1
    }
' "$CONF" > "$TMP"

if command -v testparm >/dev/null 2>&1 && ! testparm -s "$TMP" >/dev/null 2>&1; then
    echo "✖ testparm rejeitou a nova configuração — nada foi alterado."
    rm -f "$TMP"; exit 1
fi

cat "$TMP" > "$CONF"      # preserva dono/permissões do arquivo original
rm -f "$TMP"
echo "✔ Gravado em [global]:  max connections = $MAXC   max smbd processes = 0"

if command -v smbcontrol >/dev/null 2>&1; then
    smbcontrol smbd reload-config 2>/dev/null && echo "✔ Configuração recarregada (conexões ativas mantidas)."
fi
if command -v testparm >/dev/null 2>&1; then
    echo; echo "Valores em vigor:"
    testparm -s --parameter-name="max connections" 2>/dev/null | sed 's/^/   max connections = /'
fi
echo; echo "Se o erro continuar, rode:  sudo bash scripts/diagnostico_acessos.sh"
