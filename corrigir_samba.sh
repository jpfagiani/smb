#!/bin/bash
# =============================================================================
# CORREÇÕES SAMBA — CDPNI
# Remove opções deprecated do Samba 4.22 no Debian 13
# Execute como root no servidor Samba (192.168.0.11)
# =============================================================================

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; NC='\033[0m'; BOLD='\033[1m'

log()    { echo -e "${GREEN}[✔] $*${NC}"; }
warn()   { echo -e "${YELLOW}[⚠] $*${NC}"; }
error()  { echo -e "${RED}[✘] $*${NC}"; exit 1; }
header() { echo -e "\n${BOLD}${CYAN}══════════════════════════════════════════${NC}";
           echo -e "${BOLD}${CYAN}  $*${NC}";
           echo -e "${BOLD}${CYAN}══════════════════════════════════════════${NC}\n"; }

[[ $EUID -ne 0 ]] && error "Execute como root!"

SMB_CONF="/etc/samba/smb.conf"

# ---------------------------------------------------------------------------
header "1. BACKUP DO smb.conf"
# ---------------------------------------------------------------------------
cp "$SMB_CONF" "${SMB_CONF}.bak.$(date +%Y%m%d_%H%M%S)"
log "Backup criado: ${SMB_CONF}.bak.*"

# ---------------------------------------------------------------------------
header "2. REMOVER OPÇÕES DEPRECATED E PROBLEMÁTICAS"
# ---------------------------------------------------------------------------

# syslog — deprecated no Samba 4.22
if grep -q "^\s*syslog" "$SMB_CONF"; then
    sed -i '/^\s*syslog\s*=/d' "$SMB_CONF"
    log "Removido: syslog"
else
    warn "syslog: não encontrado — pulando"
fi

# encrypt passwords — deprecated no Samba 4.22
if grep -q "^\s*encrypt passwords" "$SMB_CONF"; then
    sed -i '/^\s*encrypt passwords\s*=/d' "$SMB_CONF"
    log "Removido: encrypt passwords"
else
    warn "encrypt passwords: não encontrado — pulando"
fi

# null passwords — deprecated no Samba 4.22
if grep -q "^\s*null passwords" "$SMB_CONF"; then
    sed -i '/^\s*null passwords\s*=/d' "$SMB_CONF"
    log "Removido: null passwords"
else
    warn "null passwords: não encontrado — pulando"
fi

# socket options — causa warning e desabilita auto-tuning do kernel
if grep -q "^\s*socket options" "$SMB_CONF"; then
    sed -i '/^\s*socket options\s*=/d' "$SMB_CONF"
    log "Removido: socket options"
else
    warn "socket options: não encontrado — pulando"
fi

# ---------------------------------------------------------------------------
header "3. VALIDAR smb.conf"
# ---------------------------------------------------------------------------
ERRORS=$(testparm -s "$SMB_CONF" 2>&1 | grep -iE "^ERROR|^FATAL" || true)
if [[ -n "$ERRORS" ]]; then
    error "smb.conf com erros:\n${ERRORS}"
fi

WARNINGS=$(testparm -s "$SMB_CONF" 2>&1 | grep -i "WARNING" | grep -v "Weak crypto" || true)
if [[ -n "$WARNINGS" ]]; then
    warn "Avisos restantes (verificar):\n${WARNINGS}"
else
    log "smb.conf validado sem erros"
fi

# ---------------------------------------------------------------------------
header "4. REINICIAR SAMBA"
# ---------------------------------------------------------------------------
systemctl restart smbd nmbd
sleep 2

systemctl is-active smbd &>/dev/null && log "smbd: ativo" || error "smbd não iniciou"
systemctl is-active nmbd &>/dev/null && log "nmbd: ativo" || warn "nmbd não iniciou"

# ---------------------------------------------------------------------------
header "5. TESTE DE CONECTIVIDADE"
# ---------------------------------------------------------------------------
log "Testando smbclient local..."
if smbclient -L 192.168.0.11 -N 2>&1 | grep -q "Sharename\|shares"; then
    log "Samba respondendo — lista de shares disponível"
    smbclient -L 192.168.0.11 -N 2>/dev/null | grep -v "^$\|WARNING\|lpcfg"
else
    warn "smbclient -N falhou — testando com sambadmin..."
    smbclient -L 192.168.0.11 -U sambadmin%1234 2>&1 | grep -v "WARNING\|lpcfg\|deprecated" || true
fi

# ---------------------------------------------------------------------------
header "CORREÇÕES CONCLUÍDAS"
# ---------------------------------------------------------------------------
echo -e "${CYAN}┌──────────────────────────────────────────────┐"
echo -e "│  Opções removidas do smb.conf:               │"
echo -e "│    syslog         (deprecated Samba 4.22)    │"
echo -e "│    encrypt passwords (deprecated Samba 4.22) │"
echo -e "│    null passwords (deprecated Samba 4.22)    │"
echo -e "│    socket options (interfere no kernel)      │"
echo -e "│                                              │"
echo -e "│  Acesso ao Samba:                            │"
echo -e "│    \\\\\\\\192.168.0.11  ou  \\\\\\\\cdpni.local          │"
echo -e "│    Usuário: sambadmin  Senha: 1234           │"
echo -e "└──────────────────────────────────────────────┘${NC}"
