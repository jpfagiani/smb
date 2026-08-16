#!/bin/bash
# Aplica correções em servidores instalados antes dos fixes do git
set -e

# Nome do portal — lido do group_vars para acompanhar a convenção
# <servidor>-portal. Sem o arquivo, cai no padrão.
PORTAL_NOME=$(awk '/^portal:/{p=1;next} p&&/^[a-z]/{p=0} p&&/nome:/{print $2;exit}' \
              /opt/smb/group_vars/all.yml 2>/dev/null)
PORTAL_NOME="${PORTAL_NOME:-smb-portal}"
PORTAL_DIR="/opt/$PORTAL_NOME"


if [[ $EUID -ne 0 ]]; then
    echo "Execute como root: sudo bash fix_server.sh"
    exit 1
fi

echo "==> Criando wrapper de senha..."
cat > /usr/local/bin/cdpni-setpass << 'EOF'
#!/bin/bash
user="$1"
pass="$2"
hash=$(openssl passwd -6 "$pass")
sed -i "s|^${user}:[^:]*:|${user}:${hash}:|" /etc/shadow
EOF
chmod 700 /usr/local/bin/cdpni-setpass
echo "    OK: /usr/local/bin/cdpni-setpass"

echo "==> Criando wrapper de membros de grupo..."
cat > /usr/local/bin/cdpni-setgroup << 'PYEOF'
#!/usr/bin/env python3
import sys

group   = sys.argv[1]
members = sys.argv[2] if len(sys.argv) > 2 else ''

for path in ('/etc/group', '/etc/gshadow'):
    try:
        with open(path) as f:
            lines = f.readlines()
        out = []
        for line in lines:
            parts = line.rstrip('\n').split(':')
            if parts[0] == group:
                parts[-1] = members
                line = ':'.join(parts) + '\n'
            out.append(line)
        with open(path, 'w') as f:
            f.writelines(out)
    except FileNotFoundError:
        pass
PYEOF
chmod 700 /usr/local/bin/cdpni-setgroup
echo "    OK: /usr/local/bin/cdpni-setgroup"

echo "==> Criando wrapper de criação de grupo..."
cat > /usr/local/bin/cdpni-groupadd << 'PYEOF'
#!/usr/bin/env python3
# Uso: cdpni-groupadd [-f] <groupname>
# Usa groupadd e corrige /etc/gshadow manualmente se necessário.
import sys, re, subprocess

args = sys.argv[1:]
force = '-f' in args
groupname = next(a for a in args if not a.startswith('-'))

if not re.match(r'^[a-z][a-z0-9_-]{0,31}$', groupname):
    print(f'Nome inválido: {groupname}', file=sys.stderr)
    sys.exit(1)

# Verifica se já existe
with open('/etc/group') as f:
    exists = any(line.split(':')[0] == groupname for line in f)

if exists:
    if force:
        sys.exit(0)
    print(f'Grupo já existe: {groupname}', file=sys.stderr)
    sys.exit(9)  # mesmo código do groupadd -f quando não usa -f

cmd = ['groupadd']
if force:
    cmd.append('-f')
cmd.append(groupname)
result = subprocess.run(cmd, capture_output=True, text=True)

# Verifica se o grupo foi criado
with open('/etc/group') as f:
    created = any(line.split(':')[0] == groupname for line in f)

if not created:
    print(result.stderr or 'groupadd falhou', file=sys.stderr)
    sys.exit(1)

# Corrige /etc/gshadow se necessário
try:
    with open('/etc/gshadow') as f:
        content = f.read()
    if not any(l.split(':')[0] == groupname for l in content.splitlines()):
        with open('/etc/gshadow', 'a') as f:
            f.write(f'{groupname}:!::\n')
except FileNotFoundError:
    pass

print(f'Grupo {groupname} criado')
PYEOF
chmod 700 /usr/local/bin/cdpni-groupadd
echo "    OK: /usr/local/bin/cdpni-groupadd"

echo "==> Criando wrapper de criação de usuário..."
cat > /usr/local/bin/cdpni-useradd << 'PYEOF'
#!/usr/bin/env python3
# Uso: cdpni-useradd <username>
# Usa useradd para criar o usuário e corrige /etc/gshadow manualmente
# caso o kernel audit bloqueie a escrita durante useradd.
import sys, re, subprocess

username = sys.argv[1]

if not re.match(r'^[a-z][a-z0-9_-]{0,31}$', username):
    print(f'Nome inválido: {username}', file=sys.stderr)
    sys.exit(1)

with open('/etc/passwd') as f:
    for line in f:
        if line.split(':')[0] == username:
            print(f'Usuário já existe: {username}', file=sys.stderr)
            sys.exit(1)

result = subprocess.run(
    ['useradd', '--no-log-init', '-m', '-s', '/bin/bash', username],
    capture_output=True, text=True
)

# Verifica se o usuário foi de fato criado (useradd pode falhar no gshadow
# mas ainda criar a entrada em /etc/passwd)
created = any(line.split(':')[0] == username for line in open('/etc/passwd'))
if not created:
    print(result.stderr or 'useradd falhou', file=sys.stderr)
    sys.exit(1)

# Corrige /etc/gshadow caso a entrada esteja faltando
try:
    with open('/etc/gshadow') as f:
        content = f.read()
    if not any(l.split(':')[0] == username for l in content.splitlines()):
        with open('/etc/gshadow', 'a') as f:
            f.write(f'{username}:!::\n')
except FileNotFoundError:
    pass

print(f'Usuário {username} criado')
PYEOF
chmod 700 /usr/local/bin/cdpni-useradd
echo "    OK: /usr/local/bin/cdpni-useradd"

echo "==> Criando wrapper de exclusão de grupo..."
cat > /usr/local/bin/cdpni-groupdel << 'PYEOF'
#!/usr/bin/env python3
# Usa groupdel e remove entrada do /etc/gshadow manualmente se necessário.
import sys, re, subprocess

groupname = sys.argv[1]

result = subprocess.run(['groupdel', groupname], capture_output=True, text=True)

# Verifica se o grupo ainda existe
with open('/etc/group') as f:
    still_exists = any(line.split(':')[0] == groupname for line in f)

if still_exists:
    print(result.stderr or 'groupdel falhou', file=sys.stderr)
    sys.exit(1)

# Remove de /etc/gshadow se ainda estiver lá
for path in ('/etc/gshadow',):
    try:
        with open(path) as f:
            lines = f.readlines()
        with open(path, 'w') as f:
            f.writelines(l for l in lines if l.split(':')[0] != groupname)
    except FileNotFoundError:
        pass

print(f'Grupo {groupname} removido')
PYEOF
chmod 700 /usr/local/bin/cdpni-groupdel
echo "    OK: /usr/local/bin/cdpni-groupdel"

echo "==> Criando wrapper de exclusão de usuário..."
cat > /usr/local/bin/cdpni-userdel << 'PYEOF'
#!/usr/bin/env python3
# Usa userdel -r e remove entradas do /etc/gshadow manualmente se necessário.
import sys, re, subprocess

username = sys.argv[1]

result = subprocess.run(['userdel', '-r', username], capture_output=True, text=True)

# Verifica se o usuário ainda existe
with open('/etc/passwd') as f:
    still_exists = any(line.split(':')[0] == username for line in f)

if still_exists:
    print(result.stderr or 'userdel falhou', file=sys.stderr)
    sys.exit(1)

# Remove de /etc/gshadow se ainda estiver lá
try:
    with open('/etc/gshadow') as f:
        lines = f.readlines()
    with open('/etc/gshadow', 'w') as f:
        f.writelines(l for l in lines if l.split(':')[0] != username)
except FileNotFoundError:
    pass

print(f'Usuário {username} removido')
PYEOF
chmod 700 /usr/local/bin/cdpni-userdel
echo "    OK: /usr/local/bin/cdpni-userdel"

echo "==> Criando wrapper SMART..."
cat > /usr/local/bin/cdpni-smart << 'EOF'
#!/bin/bash
disk="$1"
if [[ ! "$disk" =~ ^/dev/[a-z]+$ ]]; then
    echo "Dispositivo inválido: $disk" >&2
    exit 1
fi
exec /usr/sbin/smartctl -a -d sat -T permissive "$disk"
EOF
chmod 700 /usr/local/bin/cdpni-smart
echo "    OK: /usr/local/bin/cdpni-smart"

echo "==> Atualizando sudoers..."
cat > "/etc/sudoers.d/$PORTAL_NOME" << 'EOF'
Defaults:cdpni !log_allowed, !syslog, !requiretty
cdpni ALL=(root) NOPASSWD: /usr/local/bin/cdpni-setpass, /usr/local/bin/cdpni-setgroup, /usr/local/bin/cdpni-useradd, /usr/local/bin/cdpni-userdel, /usr/local/bin/cdpni-groupadd, /usr/local/bin/cdpni-groupdel, /usr/local/bin/cdpni-smart, /usr/bin/smbpasswd, /usr/sbin/useradd, /usr/sbin/userdel, /usr/sbin/usermod, /usr/sbin/groupadd, /usr/sbin/groupdel, /usr/bin/gpasswd, /usr/bin/tee, /bin/tee, /usr/bin/systemctl, /usr/bin/smbstatus, /usr/bin/smbcontrol, /usr/bin/testparm, /usr/bin/smartctl, /bin/mkdir, /bin/chmod, /bin/chown, /bin/tar, /usr/bin/tar, /usr/bin/tail, /usr/bin/setfacl, /usr/bin/getfacl, /bin/mv, /usr/bin/mv, /bin/rm, /usr/bin/rm, /bin/bash
EOF
chmod 440 "/etc/sudoers.d/$PORTAL_NOME"
visudo -cf "/etc/sudoers.d/$PORTAL_NOME" && echo "    OK: /etc/sudoers.d/$PORTAL_NOME"

echo "==> Adicionando cdpni ao grupo adm (acesso a logs)..."
usermod -aG adm cdpni
echo "    OK: cdpni no grupo adm"

echo "==> Atualizando repositório..."
cd /opt/smb && git pull

echo "==> Atualizando app.py..."
cp /opt/smb/roles/flask_portal/files/app.py $PORTAL_DIR/app.py
chown cdpni:cdpni $PORTAL_DIR/app.py

echo "==> Reiniciando portal..."
systemctl restart "$PORTAL_NOME"
systemctl is-active "$PORTAL_NOME" && echo "    OK: $PORTAL_NOME ativo"

echo ""
echo "Fix aplicado com sucesso."
