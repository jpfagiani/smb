#!/bin/bash
# ============================================================================
# atualizar.sh — atualiza o servidor com a versão atual deste repositório
# ============================================================================
#   sudo bash atualizar.sh
#
# Faz, nesta ordem (pode rodar quantas vezes quiser):
#   1. completa o group_vars/all.yml (fix_vars.sh) — guarda cópia .bak
#   2. migra o portal antigo (cdpni-portal / smb-portal) para portal-samba
#   3. valida e aplica o playbook só do portal (app, nginx, serviço)
#   4. confere que o portal responde
# O RAID, os compartilhamentos, o Samba e o firewall NÃO são tocados.
# ============================================================================
set -euo pipefail

RAIZ="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$RAIZ"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BOLD='\033[1m'; NC='\033[0m'
ok()   { echo -e "${GREEN}[OK]${NC} $1"; }
info() { echo -e "${YELLOW}[..]${NC} $1"; }
erro() { echo -e "${RED}[ERRO]${NC} $1" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || erro "Execute como root:  sudo bash atualizar.sh"
command -v ansible-playbook >/dev/null || erro "ansible-playbook não encontrado — rode o bootstrap.sh primeiro."
[ -f group_vars/all.yml ] || erro "group_vars/all.yml não existe — este servidor ainda não foi instalado (use bootstrap.sh)."

NOVO="portal-samba"

echo -e "\n${BOLD}Atualizando o servidor${NC}\n"

# 1. variáveis que versões antigas não tinham
info "Conferindo group_vars/all.yml..."
bash fix_vars.sh

# 2. nome antigo do portal → portal-samba (só se ainda não migrou)
ANTIGO=""
for n in smb-portal cdpni-portal; do
    [ -d "/opt/${n}" ] && [ ! -d "/opt/${NOVO}" ] && { ANTIGO="$n"; break; }
done
if [ -n "$ANTIGO" ]; then
    info "Migrando o portal: ${ANTIGO} → ${NOVO} (fica fora do ar por ~1 min)..."
    bash scripts/renomear_portal.sh -y "$ANTIGO" "$NOVO"
else
    bash fix_vars.sh "$NOVO" >/dev/null   # garante nome/dir no all.yml
    ok "Portal já usa o nome ${NOVO}."
fi

# 3. playbook do portal
info "Validando o playbook..."
ansible-playbook -i inventory/hosts.ini site.yml --tags portal --syntax-check >/dev/null \
    || erro "O playbook não passou na validação de sintaxe."
info "Aplicando o portal..."
ansible-playbook -i inventory/hosts.ini site.yml --tags portal --diff

# 4. conferência final
info "Conferindo..."
systemctl is-active --quiet "$NOVO" || erro "O serviço ${NOVO} não está ativo — veja: journalctl -u ${NOVO} -n 50"
systemctl is-active --quiet nginx   || erro "O nginx não está ativo — veja: nginx -t"
sleep 2
CODE=$(curl -sk -o /dev/null -w '%{http_code}' https://127.0.0.1:8443/ || true)
case "$CODE" in
    200|301|302|303) ok "Portal respondendo (HTTP ${CODE})." ;;
    *) erro "O portal não respondeu em https://127.0.0.1:8443/ (HTTP ${CODE:-000}) — veja: journalctl -u ${NOVO} -n 50" ;;
esac

echo ""
ok "Atualização concluída. Abra o portal e use Ctrl+F5."
echo "  Serviço: ${NOVO}   |   Pasta: /opt/${NOVO}"
echo ""
