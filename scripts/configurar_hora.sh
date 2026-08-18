#!/bin/bash
# =============================================================================
#  Configura a hora do servidor (chrony) — script avulso
# =============================================================================
#  Uso:  sudo bash scripts/configurar_hora.sh [servidor_ntp]
#
#  Não faz parte do bootstrap. O servidor de arquivos não precisa ser dono do
#  relógio: numa unidade com o gateway GWOS, quem serve a hora para a rede é
#  ele, e dois donos do /etc/chrony/chrony.conf só geram conflito. Este script
#  existe para os casos em que o Samba está sozinho, ou em que a fonte de hora
#  precisa mudar depois da instalação.
#
#  Relógio errado não é detalhe: o apt passa a recusar as assinaturas dos
#  repositórios ("Not live until ...") e a autenticação do Samba começa a
#  falhar por diferença de horário.
# =============================================================================

set -euo pipefail

VERDE='\033[0;32m'; AMARELO='\033[1;33m'; VERMELHO='\033[0;31m'
AZUL='\033[0;36m';  NEGRITO='\033[1m';    SEM='\033[0m'

ok()      { echo -e "${VERDE}  ✔ $*${SEM}"; }
aviso()   { echo -e "${AMARELO}  ⚠ $*${SEM}"; }
erro()    { echo -e "${VERMELHO}  ✖ $*${SEM}" >&2; exit 1; }
info()    { echo -e "${AZUL}  → $*${SEM}"; }
titulo()  { echo -e "\n${NEGRITO}${AZUL}$*${SEM}\n"; }

[ "$(id -u)" -eq 0 ] || erro "Execute como root: sudo bash $0"

CONF="/etc/chrony/chrony.conf"
POOL_RESERVA="pool.ntp.br"

titulo "── Hora do servidor ──"

# ---------------------------------------------------------------------------
# 1. O GWOS já é o dono?
# ---------------------------------------------------------------------------
# O módulo hora-chrony do GWOS escreve /etc/chrony/conf.d/gwos.conf, com as
# regras 'allow' que autorizam a rede a pedir a hora, e acrescenta o 'confdir'
# ao chrony.conf. Reescrever o arquivo aqui apagaria essa linha: o gwos.conf
# continuaria no disco, mudo, e o servidor pararia de atender os clientes —
# sem erro em log nenhum.
if [ -e /etc/gwos/modulos.d/hora-chrony ]; then
    aviso "O GWOS gerencia o chrony nesta máquina."
    echo  "     Ele serve a hora para a rede inteira; mexer aqui quebraria isso."
    echo  ""
    echo  "     Para trocar a fonte de hora:"
    echo  "       sudo gwos-definir NTP_SERVIDORES <ip>"
    echo  "       sudo gwos-integrar"
    echo  ""
    exit 0
fi

# ---------------------------------------------------------------------------
# 2. Qual a fonte de hora
# ---------------------------------------------------------------------------
valida_ip() {
    local o='(25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9]?[0-9])'
    echo "$1" | grep -qE "^(${o}\.){3}${o}$"
}

SERVIDOR="${1:-}"

if [ -z "$SERVIDOR" ]; then
    # Sugestão: o que o GWOS usa, se ele existir nesta máquina sem o módulo de
    # hora; senão o gateway da rede, que costuma repassar a hora institucional.
    SUGESTAO=""
    if [ -f /etc/gwos/gwos.conf ]; then
        SUGESTAO=$(awk -F= '/^NTP_SERVIDORES=/{gsub(/"/,"",$2); print $2}' \
                   /etc/gwos/gwos.conf 2>/dev/null | awk '{print $1}')
    fi
    [ -n "$SUGESTAO" ] || SUGESTAO=$(ip route 2>/dev/null | awk '/^default/{print $3; exit}')

    echo "  Servidor de hora da rede (deixe vazio para usar só ${POOL_RESERVA})."
    echo -e "  ${NEGRITO}Servidor NTP [${SUGESTAO:-nenhum}]:${SEM}"
    read -rp "  > " SERVIDOR
    SERVIDOR="${SERVIDOR:-$SUGESTAO}"
fi

if [ -n "$SERVIDOR" ] && ! valida_ip "$SERVIDOR"; then
    # Aceita nome também — mas avisa, porque nome depende de DNS funcionando,
    # e o DNS pode depender do relógio estar certo.
    if echo "$SERVIDOR" | grep -qE '^[a-zA-Z0-9]([a-zA-Z0-9.-]*[a-zA-Z0-9])?$'; then
        aviso "'${SERVIDOR}' é um nome, não um IP — depende do DNS estar funcionando."
    else
        erro "Servidor inválido: '${SERVIDOR}'"
    fi
fi

# ---------------------------------------------------------------------------
# 3. Instala o chrony se preciso
# ---------------------------------------------------------------------------
if ! command -v chronyd >/dev/null 2>&1; then
    info "Instalando o chrony..."
    export DEBIAN_FRONTEND=noninteractive
    apt-get install -y -qq chrony >/dev/null 2>&1 \
        || erro "Falha ao instalar o chrony. Verifique a rede e tente de novo."
    ok "chrony instalado."
fi

# O Debian pode ter o systemd-timesyncd ativo; dois clientes NTP disputando o
# relógio se atrapalham, e o timesyncd não aceita as opções que usamos aqui.
if systemctl is-active --quiet systemd-timesyncd 2>/dev/null; then
    systemctl disable --now systemd-timesyncd >/dev/null 2>&1 || true
    ok "systemd-timesyncd desativado (o chrony assume)."
fi

# ---------------------------------------------------------------------------
# 4. Gera, valida e só então aplica
# ---------------------------------------------------------------------------
TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT

{
    echo "# Gerado por scripts/configurar_hora.sh em $(date '+%Y-%m-%d %H:%M:%S')."
    echo "# Para trocar a fonte, rode o script de novo — não edite à mão."
    echo ""
    if [ -n "$SERVIDOR" ]; then
        echo "# Fonte principal — servidor de hora da rede."
        echo "server ${SERVIDOR} iburst prefer minpoll 4 maxpoll 6"
        echo ""
    fi
    echo "# Reserva: se a fonte principal cair, o relógio não deriva."
    echo "pool ${POOL_RESERVA} iburst"
    echo ""
    echo "driftfile /var/lib/chrony/drift"
    echo "# Corrige diferenças grandes por salto, a qualquer momento — um servidor"
    echo "# recém-instalado pode estar horas errado, e ajustar devagar demoraria dias."
    echo "makestep 1.0 -1"
    echo "rtcsync"
    echo ""
    echo "# Lê /etc/chrony/conf.d — é por onde o GWOS acrescenta as regras dele"
    echo "# se um dia o gateway for instalado nesta mesma máquina."
    echo "confdir /etc/chrony/conf.d"
} > "$TMP"

mkdir -p /etc/chrony/conf.d

# chronyd -p analisa o arquivo e sai, sem tocar no relógio nem no serviço.
if chronyd -p -f "$TMP" >/dev/null 2>&1; then
    ok "Configuração validada."
else
    # Nem toda versão do chronyd tem o -p. Só trata como erro se o binário
    # existe e reclamou de fato do arquivo.
    if chronyd -p -f "$TMP" 2>&1 | grep -qi 'error\|invalid\|cannot'; then
        chronyd -p -f "$TMP" 2>&1 | sed 's/^/     /' >&2
        erro "Configuração inválida — ${CONF} não foi alterado."
    fi
    aviso "Esta versão do chronyd não valida arquivo; seguindo com verificação pós-restart."
fi

BACKUP=""
if [ -f "$CONF" ]; then
    BACKUP="${CONF}.bak-$(date +%Y%m%d%H%M%S)"
    cp -a "$CONF" "$BACKUP"
    info "Backup do anterior: ${BACKUP}"
fi

install -m 644 "$TMP" "$CONF"

systemctl enable chrony >/dev/null 2>&1 || true
if ! systemctl restart chrony >/dev/null 2>&1 || ! systemctl is-active --quiet chrony; then
    if [ -n "$BACKUP" ]; then
        cp -a "$BACKUP" "$CONF"
        systemctl restart chrony >/dev/null 2>&1 || true
        erro "O chrony não subiu — configuração anterior restaurada de ${BACKUP}."
    fi
    erro "O chrony não subiu. Veja: journalctl -u chrony -n 30 --no-pager"
fi

ok "chrony ativo com a fonte: ${SERVIDOR:-só ${POOL_RESERVA}}"

# ---------------------------------------------------------------------------
# 5. Mostra o resultado
# ---------------------------------------------------------------------------
# A primeira sincronização leva alguns segundos; o burst apressa as amostras.
chronyc burst 4/4 >/dev/null 2>&1 || true
sleep 3
chronyc makestep >/dev/null 2>&1 || true

titulo "── Estado ──"
chronyc tracking 2>/dev/null | sed 's/^/  /' || aviso "chronyc tracking indisponível."
echo ""
chronyc sources 2>/dev/null | sed 's/^/  /' || true

echo ""
echo -e "  ${NEGRITO}Conferir depois:${SEM}  chronyc sources    (o '^*' marca a fonte em uso)"
echo -e "  ${NEGRITO}Forçar acerto:${SEM}    sudo chronyc makestep"
echo ""
