#!/bin/bash
# Completa o group_vars/all.yml gerado pelo bootstrap com as secoes faltantes.
# Execute apos git pull quando o bootstrap ja foi rodado anteriormente.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VARS="${SCRIPT_DIR}/group_vars/all.yml"

if [ ! -f "$VARS" ]; then
    if [ -f "${VARS}.example" ]; then
        cp "${VARS}.example" "$VARS"
        echo "group_vars/all.yml criado a partir do exemplo — AJUSTE os valores (IP, senhas)!"
    else
        echo "ERRO: $VARS nao encontrado. Execute bootstrap.sh primeiro."
        exit 1
    fi
fi

add_if_missing() {
    local key="$1"
    local block="$2"
    if ! grep -q "^${key}:" "$VARS"; then
        echo "" >> "$VARS"
        echo "$block" >> "$VARS"
        echo "  adicionado: ${key}"
    else
        echo "  ja existe:  ${key}"
    fi
}

echo "Verificando variaveis em group_vars/all.yml..."

# Identidade da unidade (exibida no portal e no certificado SSL)
add_if_missing "org" "org:
  name:     \"CDPNI\"
  fullname: \"Centro de Detencao Provisoria de Nova Independencia\""

# Redes permitidas no firewall (nftables usa auto-merge; sobreposicoes OK).
# Sem esta secao o template nftables.conf.j2 falha por variavel indefinida.
add_if_missing "network_ranges" "network_ranges:
  - \"10.0.0.0/8\"        # RFC 1918 - cobre a rede padrao 10.14.29.0/24
  - \"172.16.0.0/12\"     # RFC 1918
  - \"192.168.0.0/16\"    # RFC 1918
  - \"172.14.29.0/24\"    # faixa CDPNI legada (fora do RFC 1918)
  - \"192.14.29.0/24\"    # faixa CDPNI legada (fora do RFC 1918)"

add_if_missing "samba" "samba:
  workgroup:    \"WORKGROUP\"
  default_pass: \"Cdpni@2025\"
  log_dir:      /var/log/samba"

add_if_missing "portal" "portal:
  nome: portal-samba
  dir:  /opt/portal-samba
  user: cdpni
  port: 5000"

# Seção portal de versão antiga (sem nome:/dir:) — o role flask_portal exige
# portal.nome. Com argumento ("portal-samba") força nome e dir; sem argumento
# só preenche o que falta, usando o nome JÁ instalado no disco para o
# playbook não criar um segundo portal ao lado do existente.
portal_get() {
    awk -v k="$1" '/^portal:/{p=1;next} p&&/^[^ #\t]/{p=0} p&&$1==k":"{print $2;exit}' "$VARS"
}
NOME_ATUAL="$(portal_get nome)"
DIR_ATUAL="$(portal_get dir)"
NOME_ALVO="${1:-}"
if [ -z "$NOME_ALVO" ] && [ -z "$NOME_ATUAL" ]; then
    NOME_ALVO="portal-samba"
    for n in portal-samba smb-portal cdpni-portal; do
        [ -d "/opt/$n" ] && { NOME_ALVO="$n"; break; }
    done
fi
if [ -n "$NOME_ALVO" ] && { [ -n "$1" ] || [ -z "$NOME_ATUAL" ] || [ -z "$DIR_ATUAL" ]; }; then
    awk -v n="$NOME_ALVO" '
        /^portal:/ { print; print "  nome: " n; print "  dir:  /opt/" n; inp=1; next }
        inp && /^[^ #\t]/ { inp=0 }
        inp && $1 ~ /^(nome|dir):$/ { next }
        { print }' "$VARS" > "${VARS}.tmp"
    if cmp -s "$VARS" "${VARS}.tmp"; then
        rm -f "${VARS}.tmp"
    else
        cp -a "$VARS" "${VARS}.bak.$(date +%Y%m%d_%H%M%S)"
        cat "${VARS}.tmp" > "$VARS" && rm -f "${VARS}.tmp"
        echo "  ajustado:   portal.nome=${NOME_ALVO}  portal.dir=/opt/${NOME_ALVO}"
    fi
fi

add_if_missing "ssl" "ssl:
  dir:      /etc/nginx/ssl
  cert:     /etc/nginx/ssl/cdpni.crt
  key:      /etc/nginx/ssl/cdpni.key
  days:     3650
  country:  BR
  state:    SP
  org:      CDPNI"

echo ""
echo "Pronto. Execute:"
echo "  ansible-playbook -i inventory/hosts.ini site.yml --tags portal   (ou: sudo bash atualizar.sh)"
