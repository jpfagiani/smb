#!/bin/bash
# ============================================================================
# Renomeia o portal já instalado — cdpni-portal → portal-samba (ou outro nome)
# ============================================================================
# O Ansible não remove o nome antigo: rodar o playbook depois de trocar
# portal.nome criaria a unidade, o site e a jail novos AO LADO dos velhos, com
# dois gunicorn disputando a porta 5000. Este script faz a migração no disco.
#
#   sudo bash scripts/renomear_portal.sh                  # cdpni-portal → portal-samba
#   sudo bash scripts/renomear_portal.sh <antigo> <novo>
#
# Ordem importa: para o serviço, move tudo, só então sobe. Se algo falhar
# antes de subir, o estado antigo ainda está inteiro em disco.
# ============================================================================

set -euo pipefail

# O nome antigo e' descoberto, nao chutado: a maquina pode ter parado em
# qualquer etapa da renomeacao (cdpni-portal -> smb-portal -> portal-samba).
detectar_nome_atual() {
    local n
    for n in smb-portal cdpni-portal; do
        [ -d "/opt/${n}" ] && { echo "$n"; return 0; }
    done
    for n in smb-portal cdpni-portal; do
        [ -e "/etc/systemd/system/${n}.service" ] && { echo "$n"; return 0; }
    done
    return 1
}

ANTIGO="${1:-$(detectar_nome_atual || echo cdpni-portal)}"
NOVO="${2:-portal-samba}"

LOG_ANTIGO="${ANTIGO//-/_}"
LOG_NOVO="${NOVO//-/_}"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BOLD='\033[1m'; NC='\033[0m'
ok()    { echo -e "${GREEN}[OK]${NC} $1"; }
info()  { echo -e "${YELLOW}[..]${NC} $1"; }
aviso() { echo -e "${YELLOW}[!]${NC} $1"; }
erro()  { echo -e "${RED}[ERRO]${NC} $1" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || erro "Execute como root."
[ "$ANTIGO" != "$NOVO" ] || erro "Os nomes são iguais — nada a fazer."

echo -e "\n${BOLD}Renomeando o portal: ${ANTIGO} → ${NOVO}${NC}\n"

if [ ! -d "/opt/${ANTIGO}" ] && [ -d "/opt/${NOVO}" ]; then
    ok "Já está em /opt/${NOVO} — migração aparentemente feita."
    exit 0
fi
[ -d "/opt/${ANTIGO}" ] || erro "/opt/${ANTIGO} não existe. Nada a migrar."

echo "  Serão renomeados:"
echo "    /opt/${ANTIGO}                      → /opt/${NOVO}"
echo "    systemd  ${ANTIGO}.service          → ${NOVO}.service"
echo "    nginx    sites-*/${ANTIGO}          → ${NOVO}"
echo "    PAM      /etc/pam.d/${ANTIGO}       → ${NOVO}"
echo "    sudoers  /etc/sudoers.d/${ANTIGO}   → ${NOVO}"
echo "    fail2ban jail e filter ${ANTIGO}    → ${NOVO}"
echo "    logs     /var/log/${LOG_ANTIGO}_*   → ${LOG_NOVO}_*"
echo ""
read -rp "  Confirma? [s/N]: " R
[[ "${R:-N}" =~ ^[Ss]$ ]] || { echo "Cancelado."; exit 0; }

# ---------------------------------------------------------------------------
# 1. Parar o que está em execução
# ---------------------------------------------------------------------------
info "Parando ${ANTIGO}..."
systemctl disable --now "${ANTIGO}.service" 2>/dev/null || true
if pgrep -f "gunicorn.*/opt/${ANTIGO}" >/dev/null 2>&1; then
    pkill -f "gunicorn.*/opt/${ANTIGO}" 2>/dev/null || true
    sleep 2
    pkill -9 -f "gunicorn.*/opt/${ANTIGO}" 2>/dev/null || true
fi
ok "Serviço parado."

# ---------------------------------------------------------------------------
# 2. Aplicação
# ---------------------------------------------------------------------------
mv "/opt/${ANTIGO}" "/opt/${NOVO}"
ok "/opt/${ANTIGO} → /opt/${NOVO}"

# ---------------------------------------------------------------------------
# 3. Arquivos de configuração — nome no caminho e nas referências internas
# ---------------------------------------------------------------------------
for par in \
    "/etc/systemd/system/${ANTIGO}.service:/etc/systemd/system/${NOVO}.service" \
    "/etc/pam.d/${ANTIGO}:/etc/pam.d/${NOVO}" \
    "/etc/sudoers.d/${ANTIGO}:/etc/sudoers.d/${NOVO}" \
    "/etc/nginx/sites-available/${ANTIGO}:/etc/nginx/sites-available/${NOVO}" \
    "/etc/fail2ban/jail.d/${ANTIGO}.conf:/etc/fail2ban/jail.d/${NOVO}.conf" \
    "/etc/fail2ban/filter.d/${ANTIGO}.conf:/etc/fail2ban/filter.d/${NOVO}.conf"
do
    de="${par%%:*}"; para="${par#*:}"
    if [ -e "$de" ]; then
        mv "$de" "$para"
        # O conteúdo também cita o nome antigo (WorkingDirectory, logpath,
        # ExecStart, [jail]) — trocar só o nome do arquivo deixaria o serviço
        # apontando para um diretório que não existe mais.
        sed -i "s|/opt/${ANTIGO}|/opt/${NOVO}|g; s|${LOG_ANTIGO}_|${LOG_NOVO}_|g; s|\b${ANTIGO}\b|${NOVO}|g" "$para"
        ok "$(basename "$de") → $(basename "$para")"
    fi
done

# Link do nginx: recriado, não movido (aponta para o caminho antigo)
rm -f "/etc/nginx/sites-enabled/${ANTIGO}"
if [ -f "/etc/nginx/sites-available/${NOVO}" ]; then
    ln -sf "/etc/nginx/sites-available/${NOVO}" "/etc/nginx/sites-enabled/${NOVO}"
    ok "Site do nginx religado como ${NOVO}."
fi

# ---------------------------------------------------------------------------
# 4. Logs
# ---------------------------------------------------------------------------
# 'A && B' com A falso devolve 1 e, sob set -e, mataria o script aqui —
# um log que ainda não existe não é erro.
for tipo in access error; do
    if [ -f "/var/log/${LOG_ANTIGO}_${tipo}.log" ]; then
        mv "/var/log/${LOG_ANTIGO}_${tipo}.log" "/var/log/${LOG_NOVO}_${tipo}.log"
    fi
done
ok "Logs renomeados."

# ---------------------------------------------------------------------------
# 5. config.py — o app.py lê PORTAL_NAME e PAM_SERVICE daqui
# ---------------------------------------------------------------------------
CONF="/opt/${NOVO}/config.py"
if [ -f "$CONF" ]; then
    sed -i "s|'${ANTIGO}'|'${NOVO}'|g; s|/opt/${ANTIGO}|/opt/${NOVO}|g" "$CONF"
    grep -q 'PORTAL_NAME' "$CONF" || {
        printf "PORTAL_NAME = '%s'\nPAM_SERVICE = '%s'\n" "$NOVO" "$NOVO" >> "$CONF"
    }
    ok "config.py ajustado (PORTAL_NAME e PAM_SERVICE)."
fi

# ---------------------------------------------------------------------------
# 6. Subir e conferir
# ---------------------------------------------------------------------------
systemctl daemon-reload

if ! nginx -t >/dev/null 2>&1; then
    aviso "nginx -t reprovou — corrija antes de recarregar:"
    nginx -t || true
else
    systemctl reload nginx 2>/dev/null || true
fi

systemctl enable --now "${NOVO}.service" 2>/dev/null || true
sleep 2

if systemctl is-active --quiet "${NOVO}.service"; then
    ok "${NOVO} está ativo."
else
    aviso "${NOVO} não subiu. Diagnóstico:"
    journalctl -u "${NOVO}" -n 20 --no-pager 2>/dev/null | sed 's/^/      /' || true
    echo ""
    echo "  Nada foi perdido: a aplicação está em /opt/${NOVO}."
    echo "  Para voltar ao nome anterior:"
    echo "    bash $0 ${NOVO} ${ANTIGO}"
    exit 1
fi

systemctl restart fail2ban 2>/dev/null || true

# ---------------------------------------------------------------------------
# 7. Serviço auxiliar de IP — segue a mesma convenção <servidor>-*
# ---------------------------------------------------------------------------
if [ -e /etc/systemd/system/cdpni-update-ip.service ]    && [ ! -e /etc/systemd/system/smb-update-ip.service ]; then
    systemctl disable --now cdpni-update-ip.service 2>/dev/null || true
    mv /etc/systemd/system/cdpni-update-ip.service /etc/systemd/system/smb-update-ip.service
    if [ -e /usr/local/bin/cdpni-update-ip.sh ]; then
        mv /usr/local/bin/cdpni-update-ip.sh /usr/local/bin/smb-update-ip.sh
    fi
    sed -i "s|cdpni-update-ip|smb-update-ip|g"         /etc/systemd/system/smb-update-ip.service /usr/local/bin/smb-update-ip.sh 2>/dev/null || true
    systemctl daemon-reload
    systemctl enable smb-update-ip.service 2>/dev/null || true
    ok "cdpni-update-ip → smb-update-ip"
fi

echo ""
ok "Migração concluída."
echo ""
echo -e "  Atualize também o ${BOLD}group_vars/all.yml${NC}:"
echo    "    portal:"
echo    "      nome: ${NOVO}"
echo    "      dir:  /opt/${NOVO}"
echo ""
echo    "  Depois confira o login no portal — é o PAM que muda de nome e,"
echo    "  se ele e o config.py divergirem, ninguém entra."
echo ""
