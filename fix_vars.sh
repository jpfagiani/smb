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
  dir:  /opt/cdpni-portal
  user: cdpni
  port: 5000"

add_if_missing "ssl" "ssl:
  dir:      /etc/nginx/ssl
  cert:     /etc/nginx/ssl/cdpni.crt
  key:      /etc/nginx/ssl/cdpni.key
  days:     3650
  country:  BR
  state:    SP
  org:      CDPNI"

add_if_missing "panel" "panel:
  dir:  /var/www/samba-panel
  user: admin
  pass: admin"

echo ""
echo "Pronto. Execute:"
# php_panel fica FORA da lista: o role nao esta no site.yml (o portal Flask
# o substituiu) e aplica-lo criaria conflito com o portal na porta 8443.
echo "  ansible-playbook -i inventory/hosts.ini site.yml --tags samba,security,portal"
