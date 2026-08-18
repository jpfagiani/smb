#!/bin/bash
# =============================================================================
#  Detecta outros sistemas coexistindo nesta máquina e as portas que eles
#  precisam ver liberadas no firewall (política padrão: DROP).
# =============================================================================
#  Não execute diretamente — é sourced por bootstrap.sh e por
#  atualizar_firewall.sh, para as duas ferramentas nunca divergirem sobre
#  o que cada sistema conhecido precisa.
#
#  Preenche, ao ser chamada:
#    EXTRA_TCP[]   — portas TCP a liberar
#    EXTRA_UDP[]   — portas UDP a liberar
#    DETECTADOS[]  — uma linha por achado, para o chamador exibir como quiser
#
#  Reseta as três a cada chamada — seguro chamar mais de uma vez no mesmo
#  processo.
# =============================================================================

detectar_outros_sistemas() {
    EXTRA_TCP=()
    EXTRA_UDP=()
    DETECTADOS=()

    if [[ -d /etc/gwos/modulos.d ]]; then
        local _mods
        _mods=$(ls /etc/gwos/modulos.d/ 2>/dev/null | paste -sd ', ' -)
        DETECTADOS+=("GWOS detectado nesta máquina: ${_mods}")

        if [[ -e /etc/gwos/modulos.d/dns-bind9 ]]; then
            EXTRA_TCP+=(53); EXTRA_UDP+=(53)
            DETECTADOS+=("  → liberando 53 (DNS)")
        fi
        if [[ -e /etc/gwos/modulos.d/hora-chrony ]]; then
            EXTRA_UDP+=(123)
            DETECTADOS+=("  → liberando 123 (NTP)")
        fi
        if [[ -e /etc/gwos/modulos.d/painel-web ]]; then
            # Convenção do projeto: 80 sistemas, 8080 gateway, 8443 samba.
            # 80/443/8443 já estão em WEB_PORTS; só a do gateway precisa entrar.
            local _pp
            _pp=$(awk -F= '/^PAINEL_PORTA=/{print $2}' /etc/gwos/gwos.conf 2>/dev/null | tr -d ' ')
            _pp="${_pp:-8080}"
            if [[ "$_pp" != "80" && "$_pp" != "443" && "$_pp" != "8443" ]]; then
                EXTRA_TCP+=("$_pp")
                DETECTADOS+=("  → liberando ${_pp} (painel do GWOS)")
            fi
        fi
        if [[ -e /etc/gwos/modulos.d/proxy-squid ]]; then
            EXTRA_TCP+=(3127 3128 3129)
            DETECTADOS+=("  → liberando 3127-3129 (proxy Squid)")
        fi
    fi

    # SGF — Sistema de Gestão de Frota (repositório separado: jpfagiani/sgf).
    # Não é um dos três portais do projeto GWOS, mas é comum coexistir nesta
    # máquina. Independe do GWOS estar instalado.
    if [[ -d /opt/sgf ]] || systemctl is-active --quiet sgf 2>/dev/null; then
        EXTRA_TCP+=(8091)
        DETECTADOS+=("SGF detectado nesta máquina.")
        DETECTADOS+=("  → liberando 8091 (portal SGF)")
    fi
}
