#!/bin/bash
# Adiciona force group em cada share do smb.conf para permitir escrita entre usuários
set -e

# Nome do portal — lido do group_vars para acompanhar a convenção
# <servidor>-portal. Sem o arquivo, cai no padrão.
PORTAL_NOME=$(awk '/^portal:/{p=1;next} p&&/^[a-z]/{p=0} p&&/nome:/{print $2;exit}' \
              /opt/smb/group_vars/all.yml 2>/dev/null)
PORTAL_NOME="${PORTAL_NOME:-smb-portal}"
PORTAL_DIR="/opt/$PORTAL_NOME"


if [[ $EUID -ne 0 ]]; then
    echo "Execute como root: sudo bash fix_samba_group.sh"
    exit 1
fi

SMB_CONF=/etc/samba/smb.conf
BACKUP=/etc/samba/smb.conf.bak.$(date +%s)

echo "==> Backup: $BACKUP"
cp "$SMB_CONF" "$BACKUP"

echo "==> Adicionando force group nos shares..."

python3 << 'PYEOF'
import re

conf_path = '/etc/samba/smb.conf'
with open(conf_path) as f:
    content = f.read()

# Para cada seção [NomeShare] que tenha force directory mode mas não tenha force group,
# injeta force group = grp_nomedoshare (nome do share em minúsculo)
def inject_force_group(m):
    section_header = m.group(1)   # ex: [Sindicancia]
    share_name = m.group(2)       # ex: Sindicancia
    grp_name   = 'grp_' + share_name.lower()
    body       = m.group(3)       # tudo até o próximo [

    # Não altera seções especiais (global, Recycle, homes, printers)
    if share_name.lower() in ('global', 'recycle', 'homes', 'printers'):
        return m.group(0)

    # Já tem force group? não altera
    if re.search(r'^\s*force group\s*=', body, re.MULTILINE):
        return m.group(0)

    # Insere após force directory mode
    new_body = re.sub(
        r'(force directory mode\s*=\s*\S+)',
        r'\1\n    force group          = ' + grp_name,
        body,
        count=1
    )
    return section_header + new_body

# Divide em blocos por seção
result = re.sub(
    r'(\[([^\]]+)\]\n)(.*?)(?=\[|\Z)',
    inject_force_group,
    content,
    flags=re.DOTALL
)

with open(conf_path, 'w') as f:
    f.write(result)

print('    smb.conf atualizado')
PYEOF

echo "==> Validando smb.conf..."
testparm -s "$SMB_CONF" > /dev/null && echo "    OK: testparm passou"

echo "==> Corrigindo grupo e permissão em arquivos existentes nos shares..."
python3 << 'PYEOF'
import re, os, subprocess, grp as grpmod

conf_path = '/etc/samba/smb.conf'
with open(conf_path) as f:
    content = f.read()

SKIP = {'global', 'recycle', 'homes', 'printers'}

def group_exists(name):
    try:
        grpmod.getgrnam(name)
        return True
    except KeyError:
        return False

for m in re.finditer(r'\[([^\]]+)\]\s*\n(.*?)(?=\[|\Z)', content, re.DOTALL):
    share_name = m.group(1).strip()
    body       = m.group(2)
    if share_name.lower() in SKIP:
        continue

    # Tenta pegar o grupo de 'force group' já existente
    fg = re.search(r'^\s*force group\s*=\s*(\S+)', body, re.MULTILINE)
    if fg:
        grp = fg.group(1).lstrip('+')
    else:
        # Tenta extrair @grupo da linha valid users
        vu = re.search(r'^\s*valid users\s*=.*?@(\S+)', body, re.MULTILINE)
        grp = vu.group(1) if vu else 'grp_' + share_name.lower()

    # Verifica se o grupo existe antes de usar
    if not group_exists(grp):
        print(f'    AVISO: grupo "{grp}" não existe — pulando {share_name}')
        continue

    pm = re.search(r'^\s*path\s*=\s*(.+)', body, re.MULTILINE)
    if not pm:
        continue
    path = pm.group(1).strip()
    if not os.path.isdir(path):
        print(f'    AVISO: {path} não existe — pulando {share_name}')
        continue

    print(f'    {share_name}: chown -R :{grp}  chmod -R g+rw  {path}')
    subprocess.run(['chown', '-R', f':{grp}', path])
    subprocess.run(['find', path, '-type', 'f', '-exec', 'chmod', 'g+rw', '{}', '+'])
    subprocess.run(['find', path, '-type', 'd', '-exec', 'chmod', 'g+rwx', '{}', '+'])

print('    Permissões recursivas aplicadas.')
PYEOF

echo "==> Reiniciando smbd..."
systemctl restart smbd
systemctl is-active smbd && echo "    OK: smbd ativo"

echo ""
echo "==> Atualizando portal e portal permissoes..."
cd /opt/smb && git pull
cp /opt/smb/roles/flask_portal/files/app.py $PORTAL_DIR/app.py
chown cdpni:cdpni $PORTAL_DIR/app.py
[ -f $PORTAL_DIR/permissions.json ] || echo '{}' > $PORTAL_DIR/permissions.json
chown cdpni:cdpni $PORTAL_DIR/permissions.json
systemctl restart "$PORTAL_NOME"
systemctl is-active "$PORTAL_NOME" && echo "    OK: $PORTAL_NOME ativo"

echo ""
echo "Fix aplicado com sucesso."
echo "Verifique com: grep 'force group' /etc/samba/smb.conf"
