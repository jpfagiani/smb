#!/bin/bash
# ─────────────────────────────────────────────────────────────────────────
#  Diagnóstico: "usuário já está acessando esta pasta em outro local".
#  SOMENTE LEITURA — não altera nada. Mostra quem está conectado, o que o
#  Samba/PAM/firewall permitem e os últimos erros relevantes.
#
#  Uso:  sudo bash scripts/diagnostico_acessos.sh [usuario]
#        (com o nome do usuário, filtra as conexões e erros dele)
# ─────────────────────────────────────────────────────────────────────────
U="${1:-}"
t() { printf '\n\033[1;36m── %s ──\033[0m\n' "$*"; }
[ "$(id -u)" -eq 0 ] || { echo "Execute como root: sudo bash $0"; exit 1; }

t "1. Limites configurados no Samba (0 = sem limite)"
if command -v testparm >/dev/null 2>&1; then
    for p in "max connections" "max smbd processes" "oplocks" "smb2 leases" "dead time"; do
        printf '   %-20s = %s\n' "$p" "$(testparm -s --parameter-name="$p" 2>/dev/null)"
    done
else echo "   testparm não encontrado"; fi

t "2. Limite de logins por usuário no PAM (maxlogins) — deve estar VAZIO"
grep -rhn "maxlogins" /etc/security/limits.conf /etc/security/limits.d/ 2>/dev/null || echo "   nenhum maxlogins definido ✔"

t "3. Sessões SMB abertas agora${U:+ (usuário $U)}"
if [ -n "$U" ]; then smbstatus -b 2>/dev/null | awk -v u="$U" 'NR<=4 || $2==u'; else smbstatus -b 2>/dev/null; fi
echo; echo "   Total de sessões: $(smbstatus -b 2>/dev/null | grep -cE '^[0-9]+ ')"

t "4. Compartilhamentos conectados (quantas máquinas por pasta)"
smbstatus -S 2>/dev/null | sed -n '1,60p'

t "5. Arquivos travados/abertos${U:+ por $U}"
if [ -n "$U" ]; then smbstatus -L 2>/dev/null | grep -i -- "$U" | head -30; else smbstatus -L 2>/dev/null | head -30; fi

t "6. Últimos erros relevantes nos logs do Samba"
ERROS=$(grep -h -E "NT_STATUS_(SHARING_VIOLATION|TOO_MANY_SESSIONS|INSUFF_SERVER_RESOURCES|ACCOUNT_LOCKED_OUT|LOGON_FAILURE|CONNECTION_DISCONNECTED|USER_SESSION_DELETED|NETWORK_SESSION_EXPIRED)|max connections|too many" /var/log/samba/log.* 2>/dev/null)
if [ -n "$U" ]; then ERROS=$(printf '%s\n' "$ERROS" | grep -i -- "$U"); fi
printf '%s\n' "$ERROS" | tail -25

t "7. Banimentos do fail2ban / bloqueios de firewall"
fail2ban-client status 2>/dev/null | sed 's/^/   /' || echo "   fail2ban não instalado"
journalctl -k --since "-1 day" 2>/dev/null | grep -c "nft-cdpni-drop" | sed 's/^/   pacotes descartados pelo firewall nas últimas 24h: /'

cat <<'TXT'

Como interpretar:
 • "max connections" diferente de 0 e menor que o nº de PCs → é o teto; rode scripts/permitir_acessos_simultaneos.sh
 • maxlogins no PAM → limita sessões por usuário; remova a linha do limits.conf
 • NT_STATUS_SHARING_VIOLATION → ARQUIVO aberto com exclusividade por outro PC (Excel/Word/Access); não é limite de usuário
 • Erro 1219 no Windows ("várias conexões ... mais de um nome de usuário") → o PC já está conectado ao servidor com OUTRO usuário
   (ou como convidado). No PC: cmd → net use * /delete /y  e reconecte sempre com o mesmo usuário e o mesmo nome do servidor.
TXT
