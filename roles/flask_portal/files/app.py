import os, re, shutil, subprocess, mimetypes, hashlib, json, time, signal
from pathlib import Path
from functools import wraps
from datetime import datetime

import pam
from flask import (Flask, render_template_string, request, session,
                   redirect, url_for, send_file, jsonify, flash, abort)
from werkzeug.utils import secure_filename

app = Flask(__name__)
app.config.from_pyfile('config.py')

SECRET_KEY   = app.config['SECRET_KEY']
SAMBA_ROOT   = app.config['SAMBA_ROOT']
ADMIN_USERS  = set(app.config['ADMIN_USERS'])
# Identidade da unidade (definida no bootstrap; fallback = CDPNI)
ORG_NAME     = app.config.get('ORG_NAME', 'CDPNI')
ORG_FULLNAME = app.config.get('ORG_FULLNAME', ORG_NAME)
FQDN         = f"{app.config.get('SERVER_HOSTNAME', 'smb')}.{app.config.get('DOMAIN', 'local')}"
PORTAL_DIR   = os.path.dirname(os.path.abspath(__file__))
BANNER_DIR   = os.path.join(PORTAL_DIR, 'banners')
SMB_CONF     = '/etc/samba/smb.conf'
RECYCLE_ROOT = os.path.join(os.path.dirname(SAMBA_ROOT.rstrip('/')), 'recycle')
BACKUP_DIR      = app.config.get('BACKUP_DIR', '/opt/backups')
BACKUP_INFO_FILE = os.path.join(PORTAL_DIR, '.backup_info.json')
PERMS_FILE   = os.path.join(PORTAL_DIR, 'permissions.json')
os.makedirs(BANNER_DIR, exist_ok=True)

# ── helpers ──────────────────────────────────────────────────────────────────
def safe_path(disk: str, rel: str = '') -> Path:
    base = (Path(SAMBA_ROOT) / secure_filename(disk)).resolve()
    if rel:
        target = (base / rel).resolve()
    else:
        target = base
    if not str(target).startswith(str(base) + os.sep) and target != base:
        abort(403)
    return target

def safe_name(name: str) -> str:
    """Valida nome de arquivo sem manchar espaços/acentos; bloqueia traversal."""
    name = name.strip()
    if not name or '/' in name or '\\' in name or name in ('..', '.'):
        return ''
    return name

def user_disks() -> list[str]:
    user = session.get('user', '')
    if is_admin_user(user):
        try:
            return sorted(d.name for d in Path(SAMBA_ROOT).iterdir() if d.is_dir())
        except Exception:
            return []
    disks = []
    try:
        for d in Path(SAMBA_ROOT).iterdir():
            if d.is_dir() and os.access(str(d), os.R_OK):
                disks.append(d.name)
    except Exception:
        pass
    return sorted(disks)

def login_required(f):
    @wraps(f)
    def wrapper(*a, **kw):
        if not session.get('logged_in'):
            return redirect(url_for('login', next=request.url))
        return f(*a, **kw)
    return wrapper

def is_admin_user(username: str) -> bool:
    return username in ADMIN_USERS or username in get_admin_group_members()

def admin_required(f):
    @wraps(f)
    def wrapper(*a, **kw):
        if not session.get('logged_in'):
            return redirect(url_for('login'))
        if not is_admin_user(session.get('user', '')):
            abort(403)
        return f(*a, **kw)
    return wrapper

def fmt_size(n: int) -> str:
    for u in ('B', 'KB', 'MB', 'GB', 'TB'):
        if n < 1024:
            return f'{n:.1f} {u}'
        n /= 1024
    return f'{n:.1f} PB'

def get_banner() -> str:
    for ext in ('jpg', 'jpeg', 'png', 'gif', 'webp'):
        p = os.path.join(BANNER_DIR, f'banner.{ext}')
        if os.path.exists(p):
            return url_for('banner_img', filename=f'banner.{ext}')
    return ''

def run(cmd: list, input_: str | None = None) -> tuple[int, str, str]:
    proc = subprocess.run(cmd, input=input_, capture_output=True, text=True)
    return proc.returncode, proc.stdout.strip(), proc.stderr.strip()

def set_linux_password(username: str, password: str) -> tuple[int, str]:
    """Define senha Linux via wrapper script privilegiado."""
    rc, _, err = run(['sudo', '/usr/local/bin/cdpni-setpass', username, password])
    return rc, err

def set_group_members(groupname: str, members: list) -> tuple[int, str]:
    """Define membros de um grupo via wrapper (evita gpasswd e auditoria)."""
    rc, _, err = run(['sudo', '/usr/local/bin/cdpni-setgroup', groupname, ','.join(members)])
    return rc, err

def get_group_members(groupname: str) -> list:
    try:
        with open('/etc/group') as f:
            for line in f:
                parts = line.strip().split(':')
                if parts[0] == groupname:
                    return [m for m in parts[-1].split(',') if m]
    except Exception:
        pass
    return []

def add_group_member(username: str, groupname: str) -> tuple[int, str]:
    members = get_group_members(groupname)
    if username not in members:
        members.append(username)
    return set_group_members(groupname, members)

def remove_group_member(username: str, groupname: str) -> tuple[int, str]:
    members = [m for m in get_group_members(groupname) if m != username]
    return set_group_members(groupname, members)

ADMIN_GROUP = 'cdpni-admins'

def get_admin_group_members() -> set:
    try:
        with open('/etc/group') as f:
            for line in f:
                parts = line.strip().split(':')
                if parts[0] == ADMIN_GROUP and len(parts) == 4:
                    return set(m for m in parts[3].split(',') if m)
    except Exception:
        pass
    return set()

def _load_perms_file() -> dict:
    try:
        with open(PERMS_FILE) as f:
            return json.load(f)
    except Exception:
        return {}

def _save_perms_file(data: dict):
    with open(PERMS_FILE, 'w') as f:
        json.dump(data, f, indent=2)

def get_user_share_perms(username: str) -> dict:
    """Retorna dict {share_name: 'rwx'} para o usuário (armazenado em JSON)."""
    return _load_perms_file().get(username, {})

def get_system_users() -> list[dict]:
    users = []
    NOLOGIN = {'/usr/sbin/nologin', '/bin/false', '/sbin/nologin'}
    admins  = get_admin_group_members() | ADMIN_USERS
    try:
        with open('/etc/passwd') as f:
            for line in f:
                parts = line.strip().split(':')
                if len(parts) < 7:
                    continue
                uid = int(parts[2])
                if uid < 1000 or uid > 60000:
                    continue
                shell = parts[6]
                name  = parts[0]
                users.append({
                    'name':    name,
                    'uid':     uid,
                    'home':    parts[5],
                    'shell':   shell,
                    'active':  shell not in NOLOGIN,
                    'is_admin': name in admins,
                })
    except Exception:
        pass
    return sorted(users, key=lambda u: u['name'])

def get_system_groups() -> list[dict]:
    groups = []
    sys_users = {u['name'] for u in get_system_users()}
    try:
        with open('/etc/group') as f:
            for line in f:
                parts = line.strip().split(':')
                if len(parts) < 4:
                    continue
                gid = int(parts[2])
                name = parts[0]
                # inclui grupos de usuários (≥1000) e grupos samba/cdpni de sistema
                is_user_group = gid >= 1000 and gid <= 60000
                is_samba_group = name.startswith('grp_') or name in ('cdpni-admins', 'sambadmin')
                if not is_user_group and not is_samba_group:
                    continue
                members = [m for m in parts[3].split(',') if m]
                groups.append({'name': name, 'gid': gid, 'members': members})
    except Exception:
        pass
    return sorted(groups, key=lambda g: g['name'])

def parse_smb_shares() -> list[dict]:
    shares = []
    current = None
    try:
        with open(SMB_CONF) as f:
            for line in f:
                line = line.strip()
                if line.startswith('[') and line.endswith(']'):
                    name = line[1:-1]
                    if name not in ('global', 'homes', 'printers', 'print$'):
                        current = {'name': name, 'path': '', 'comment': '',
                                   'valid_users': '', 'read_only': 'no',
                                   'browseable': 'yes', 'create_mask': '0664',
                                   'directory_mask': '0775'}
                        shares.append(current)
                    else:
                        current = None
                elif current and '=' in line and not line.startswith('#') and not line.startswith(';'):
                    k, _, v = line.partition('=')
                    k = k.strip().lower().replace(' ', '_')
                    # normaliza writable=yes → read_only=no
                    if k == 'writable':
                        current['read_only'] = 'no' if v.strip().lower() in ('yes', 'true', '1') else 'yes'
                    else:
                        current[k] = v.strip()
    except Exception:
        pass
    return shares

def get_mdstat() -> dict:
    info = {'arrays': [], 'raw': ''}
    try:
        with open('/proc/mdstat') as f:
            raw = f.read()
        info['raw'] = raw
        current_array = None
        for line in raw.splitlines():
            line = line.strip()
            if line.startswith('md'):
                m = re.match(r'^(md\w+)\s*:\s*(\w+)\s+(\w+)\s+(.+)', line)
                if m:
                    current_array = {
                        'name': m.group(1),
                        'status': m.group(2),
                        'level': m.group(3),
                        'devices': m.group(4),
                        'progress': '',
                        'health': 'ok'
                    }
                    info['arrays'].append(current_array)
            elif current_array and 'blocks' in line:
                if 'degraded' in line.lower() or 'failed' in line.lower():
                    current_array['health'] = 'degraded'
                m_prog = re.search(r'(\d+)%', line)
                if m_prog:
                    current_array['progress'] = m_prog.group(1) + '%'
    except Exception:
        pass
    return info

def get_disk_usage() -> list[dict]:
    disks = []
    try:
        rc, out, _ = run(['df', '-h', '--output=source,size,used,avail,pcent,target',
                          '--exclude-type=tmpfs', '--exclude-type=devtmpfs'])
        for line in out.splitlines()[1:]:
            parts = line.split()
            if len(parts) >= 6:
                src = parts[0]
                if src.startswith('/dev') or src.startswith('//'):
                    disks.append({
                        'source': src, 'size': parts[1], 'used': parts[2],
                        'avail': parts[3], 'pct': parts[4].rstrip('%'),
                        'mount': parts[5]
                    })
    except Exception:
        pass
    return disks

def get_raid_saude() -> dict:
    """Saúde do array e SMART dos membros via wrapper privilegiado."""
    try:
        rc, out, _ = run(['sudo', '/usr/local/bin/cdpni-raid', 'saude'])
        if rc == 0 and out:
            return json.loads(out)
    except Exception:
        pass
    return {}

def get_raid_candidatos() -> list:
    """Discos novos elegíveis para entrar no RAID (nunca o do sistema)."""
    try:
        rc, out, _ = run(['sudo', '/usr/local/bin/cdpni-raid', 'candidatos'])
        if rc == 0 and out:
            return json.loads(out)
    except Exception:
        pass
    return []

def get_memory() -> dict:
    info = {'total': 0, 'used': 0, 'avail': 0, 'pct': 0, 'total_h': '—', 'used_h': '—'}
    try:
        with open('/proc/meminfo') as f:
            for line in f:
                k, v = line.split(':', 1)
                k = k.strip()
                v = int(v.strip().split()[0])
                if k == 'MemTotal':
                    info['total'] = v
                elif k == 'MemAvailable':
                    info['avail'] = v
        info['used'] = info['total'] - info['avail']
        info['pct'] = round(info['used'] / info['total'] * 100) if info['total'] else 0
        info['total_h'] = fmt_size(info['total'] * 1024)
        info['used_h'] = fmt_size(info['used'] * 1024)
    except Exception:
        pass
    return info

def get_cpu() -> dict:
    info = {'pct': 0, 'cores': 0}
    try:
        with open('/proc/cpuinfo') as f:
            info['cores'] = f.read().count('processor')
        rc, out, _ = run(['top', '-bn1', '-1'])
        for line in out.splitlines():
            if 'Cpu(s)' in line or line.startswith('%Cpu'):
                m = re.search(r'(\d+[\.,]\d+)\s+id', line)
                if m:
                    info['pct'] = round(100 - float(m.group(1).replace(',', '.')))
                    break
    except Exception:
        pass
    return info

def get_uptime() -> str:
    try:
        with open('/proc/uptime') as f:
            secs = float(f.read().split()[0])
        days = int(secs // 86400)
        hours = int((secs % 86400) // 3600)
        mins = int((secs % 3600) // 60)
        parts = []
        if days:
            parts.append(f'{days}d')
        if hours:
            parts.append(f'{hours}h')
        parts.append(f'{mins}min')
        return ' '.join(parts)
    except Exception:
        return '—'

def get_samba_connections() -> list[dict]:
    conns = []
    try:
        rc, out, _ = run(['sudo', 'smbstatus', '--brief'])
        for line in out.splitlines():
            if re.match(r'^\d+\s+', line):
                parts = line.split()
                if len(parts) >= 4:
                    conns.append({
                        'pid': parts[0], 'user': parts[1],
                        'group': parts[2], 'machine': parts[3],
                        'since': ' '.join(parts[4:]) if len(parts) > 4 else ''
                    })
    except Exception:
        pass
    return conns

def get_samba_logs(lines: int = 100) -> str:
    log_dir = '/var/log/samba'
    result = []
    skip_prefixes = ('log.rpcd_', 'log.samba-', 'log.wb-', 'log.winbindd-')
    priority = ['log.smbd', 'log.nmbd', 'log.winbindd', 'log.']
    try:
        all_names = sorted(os.listdir(log_dir))
        seen = set()
        candidates = []
        for name in priority:
            p = os.path.join(log_dir, name)
            if os.path.isfile(p) and os.path.getsize(p) > 0:
                candidates.append(p)
                seen.add(name)
        for name in all_names:
            if name in seen:
                continue
            if any(name.startswith(s) for s in skip_prefixes):
                continue
            if not name.startswith('log.'):
                continue
            p = os.path.join(log_dir, name)
            if os.path.isfile(p) and os.path.getsize(p) > 0:
                candidates.append(p)
        for p in candidates:
            rc, out, _ = run(['sudo', 'tail', f'-n{lines}', p])
            if out:
                result.append(f'=== {os.path.basename(p)} ===\n{out}')
    except Exception:
        pass
    return '\n\n'.join(result) if result else '(sem logs disponíveis)'

def get_audit_log(lines: int = 400) -> list[dict]:
    """Acessos a ARQUIVOS (full_audit → rsyslog local5 → audit.log).

    Mostra só a AÇÃO do usuário, não o ruído do Windows. Ao listar uma
    pasta, o Explorer abre cada arquivo para gerar ícone/miniatura — o
    log bruto vira dezenas de "openat" no mesmo segundo. Aqui essas
    rajadas de leitura viram UMA linha "Abriu pasta X"; o mesmo vale
    para exclusão recursiva ("Excluiu pasta X" em vez de um unlinkat
    por arquivo). Abertura isolada de um arquivo continua aparecendo,
    e gravação (openat de escrita) vira "Criou/Alterou".
    """
    arquivo = '/var/log/samba/audit.log'
    rc, out, _ = run(['sudo', 'tail', f'-n{lines}', arquivo])
    if rc != 0 or not out:
        return []

    def _ruido(alvo: str) -> bool:
        nome = os.path.basename(alvo).lower()
        return (nome in ('thumbs.db', 'desktop.ini', '.ds_store')
                or nome.startswith('~$')
                or nome.endswith(('.tmp', ':zone.identifier')))

    # ── 1ª fase: parse cronológico das linhas ──────────────────────────
    brutos = []
    for linha in out.splitlines():
        if 'smbd_audit:' not in linha:
            continue
        pre, _, resto = linha.partition('smbd_audit:')
        partes = [p.strip() for p in resto.strip().split('|')]
        if len(partes) < 5:
            continue
        op = partes[3]
        if op not in ('openat', 'renameat', 'unlinkat', 'mkdirat'):
            continue               # ignora connect/disconnect e outros
        pre_campos = pre.split()
        if pre_campos and 'T' in pre_campos[0]:
            ts = pre_campos[0][:19].replace('T', ' ')
            fmt = '%Y-%m-%d %H:%M:%S'
        else:
            ts = ' '.join(pre_campos[:3])
            fmt = '%b %d %H:%M:%S'
        try:
            dt = datetime.strptime(ts, fmt)
            if dt.year == 1900:    # formato syslog não traz o ano
                dt = dt.replace(year=datetime.now().year)
        except ValueError:
            dt = None
        extras = partes[5:]
        modo = ''                  # openat loga r/w antes do caminho
        if op == 'openat' and extras and extras[0] in ('r', 'w'):
            modo = extras[0]
            extras = extras[1:]
        # normaliza "/pasta/.", "/pasta/.." e "pasta/" — o Explorer gera
        # essas variações e elas impediriam o colapso e a deduplicação
        extras = [os.path.normpath(x) if x.startswith('/') else x
                  for x in extras]
        if op == 'renameat' and len(extras) >= 2:
            alvo = ' → '.join(extras)
        else:
            alvo = extras[-1] if extras else ''
        if _ruido(alvo):
            continue
        brutos.append({'ts': ts, 'dt': dt, 'usuario': partes[0],
                       'ip': partes[1], 'share': partes[2], 'op': op,
                       'modo': modo, 'ok': partes[4] == 'ok', 'alvo': alvo})

    # Pastas conhecidas: alvo de mkdirat, pai de outro alvo do lote, ou
    # diretório real no disco (isdir pode falhar por permissão do portal,
    # por isso não é o único critério).
    pais = set()
    for e in brutos:
        d = os.path.dirname(e['alvo'].split(' → ')[-1])
        while len(d) > 1:
            pais.add(d)
            acima = os.path.dirname(d)
            if acima == d:         # "//" é pai de si mesmo (POSIX) — sem isso
                break              # o loop nunca termina e o worker trava
            d = acima
    dirs = {e['alvo'] for e in brutos if e['op'] == 'mkdirat'}
    for e in brutos:
        a = e['alvo']
        if a and a not in dirs and (a in pais or os.path.isdir(a)):
            dirs.add(a)

    # ── 2ª fase: colapsa rajadas consecutivas do mesmo usuário ─────────
    eventos = []
    visto = None

    def _emit(e, rotulo, alvo):
        nonlocal visto
        chave = (e['ts'], e['usuario'], e['ip'], e['share'], rotulo, alvo, e['ok'])
        if chave == visto:         # repetições idênticas no mesmo segundo
            return
        visto = chave
        eventos.append({'hora': e['ts'], 'usuario': e['usuario'],
                        'ip': e['ip'], 'share': e['share'], 'op': rotulo,
                        'ok': e['ok'], 'alvo': alvo})

    grupo = []                     # rajada em andamento (mesmo op/usuário)

    def _flush():
        if not grupo:
            return
        base = 'Abriu' if grupo[0]['op'] == 'openat' else 'Excluiu'
        alvos = {e['alvo'] for e in grupo}
        grupo_dirs = [a for a in alvos if a in dirs]
        if grupo_dirs:
            # navegação/exclusão de pasta: uma linha só, na pasta mais rasa
            _emit(grupo[0], base + ' pasta', min(grupo_dirs, key=len))
        elif len(alvos) >= 3:
            pasta = os.path.commonpath(list(alvos)) if len(alvos) > 1 else grupo[0]['alvo']
            if base == 'Abriu':
                _emit(grupo[0], 'Abriu pasta', pasta)
            else:
                _emit(grupo[0], 'Excluiu', f'{pasta} ({len(alvos)} itens)')
        else:
            for e in grupo:
                _emit(e, base, e['alvo'])
        grupo.clear()

    def _mesma_rajada(a, b):
        if (a['usuario'], a['ip'], a['share'], a['op']) != \
           (b['usuario'], b['ip'], b['share'], b['op']):
            return False
        if a['dt'] and b['dt']:
            return abs((b['dt'] - a['dt']).total_seconds()) <= 2
        return a['ts'] == b['ts']

    for e in brutos:
        agrupavel = e['ok'] and (
            (e['op'] == 'openat' and e['modo'] != 'w') or e['op'] == 'unlinkat')
        if agrupavel:
            if grupo and not _mesma_rajada(grupo[-1], e):
                _flush()
            grupo.append(e)
            continue
        _flush()
        if e['op'] == 'openat':
            rotulo = 'Criou/Alterou' if e['modo'] == 'w' else 'Abriu'
        else:
            rotulo = {'renameat': 'Renomeou', 'unlinkat': 'Excluiu',
                      'mkdirat': 'Criou pasta'}[e['op']]
        _emit(e, rotulo, e['alvo'])
    _flush()
    eventos.reverse()              # mais recente primeiro
    return eventos

def backup_running():
    """Retorna (is_running, info_dict) para o backup em andamento.

    Não usa os.kill(pid, 0): ele responde sucesso até para processo
    ZUMBI (terminado, aguardando o gunicorn colher) — o backup concluía
    e a página ficava em "em andamento" para sempre. Lê o estado real
    em /proc/<pid>/stat e confere o cmdline (proteção contra reuso de
    pid após reboot).
    """
    try:
        with open(BACKUP_INFO_FILE) as f:
            info = json.load(f)
        pid = info.get('pid')
        if pid:
            try:
                with open(f'/proc/{pid}/stat') as fs:
                    estado = fs.read().rsplit(')', 1)[1].split()[0]
                if estado == 'Z':
                    try:
                        os.waitpid(pid, os.WNOHANG)  # colhe o zumbi se for nosso filho
                    except ChildProcessError:
                        pass
                    return False, info
                with open(f'/proc/{pid}/cmdline', 'rb') as fc:
                    cmd = fc.read().decode(errors='ignore')
                if 'backup' not in cmd and 'tar' not in cmd:
                    return False, info
                return True, info
            except (FileNotFoundError, ProcessLookupError, IndexError):
                return False, info
    except (FileNotFoundError, json.JSONDecodeError):
        pass
    return False, {}

def get_backups() -> list[dict]:
    backups = []
    try:
        p = Path(BACKUP_DIR)
        if p.exists():
            for f in sorted(p.glob('*.tar.gz'), key=lambda x: x.stat().st_mtime, reverse=True)[:30]:
                st = f.stat()
                backups.append({
                    'name': f.name,
                    'size': fmt_size(st.st_size),
                    'date': datetime.fromtimestamp(st.st_mtime).strftime('%d/%m/%Y %H:%M'),
                })
    except Exception:
        pass
    return backups

# ── CSS ───────────────────────────────────────────────────────────────────────
CSS = r"""
:root{
  --bg:#f4f6f8;--bg2:#ffffff;--bg3:#f0f2f5;--bg4:#e4e8ee;
  --border:#d0d7de;--text:#1a2a3a;--muted:#7a8a9a;
  --accent:#1c5fad;--danger:#c03030;--success:#2a7a3a;--warn:#8a5a00;
  --font:-apple-system,BlinkMacSystemFont,'Segoe UI',system-ui,sans-serif;
  --mono:'Consolas','Courier New',monospace;
  --sidebar:200px
}
*{box-sizing:border-box;margin:0;padding:0}
body{font-family:var(--font);background:var(--bg);color:var(--text);min-height:100vh;display:flex;flex-direction:column}
a{color:var(--accent);text-decoration:none}a:hover{text-decoration:underline}
.topbar{background:#1c3557;border-bottom:1px solid #152844;padding:.5rem 1.25rem;display:flex;align-items:center;gap:1rem;position:sticky;top:0;z-index:50;flex-shrink:0}
.topbar-logo{font-weight:600;font-size:.95rem;color:#e8f0f8;white-space:nowrap;display:flex;align-items:center;gap:.5rem}
.topbar-logo .logo-icon{width:28px;height:28px;border-radius:7px;background:rgba(255,255,255,.15);display:flex;align-items:center;justify-content:center;font-size:14px;flex-shrink:0}
.topbar-logo .logo-sub{font-size:.7rem;font-weight:400;color:#7a9ec0;display:block;line-height:1}
.topbar-right{margin-left:auto;display:flex;align-items:center;gap:.5rem;font-size:.8rem}
.topbar-user{display:flex;align-items:center;gap:.35rem;background:rgba(255,255,255,.1);border:0.5px solid rgba(255,255,255,.2);border-radius:20px;padding:.25rem .7rem;color:#c0d8f0;font-size:.75rem}
.topbar-user i{font-size:13px}
.layout{display:flex;flex:1;overflow:hidden}
.sidebar{width:var(--sidebar);background:#fff;border-right:0.5px solid var(--border);display:flex;flex-direction:column;flex-shrink:0;overflow-y:auto}
.sidebar-section{padding:.65rem .75rem .2rem;font-size:.62rem;font-weight:600;text-transform:uppercase;letter-spacing:.08em;color:#b0bac8}
.sidebar a{display:flex;align-items:center;gap:.5rem;padding:.4rem .75rem;color:#4a5a6a;font-size:.8rem;border-radius:0;margin:0;border-left:2px solid transparent;transition:background .1s}
.sidebar a:hover{background:#f4f6f8;text-decoration:none;color:#1a2a3a}
.sidebar a.active{background:#e8f0fb;border-left-color:#1c5fad;color:#1c5fad;font-weight:600}
.sidebar-icon{width:16px;text-align:center;font-size:.85rem;flex-shrink:0;opacity:.7}
.sidebar a.active .sidebar-icon{opacity:1}
.sidebar-badge{display:inline-flex;align-items:center;justify-content:center;background:#e8f0fb;color:#1c5fad;font-size:.6rem;font-weight:700;padding:1px 5px;border-radius:10px;min-width:16px;margin-left:auto}
.main{flex:1;overflow-y:auto;padding:1.25rem 1.5rem}
.banner{max-height:160px;width:100%;object-fit:cover;display:block;flex-shrink:0}
.page-title{font-size:1rem;font-weight:600;margin-bottom:1.25rem;display:flex;align-items:center;gap:.5rem;color:var(--text)}
.page-title small{font-size:.75rem;font-weight:400;color:var(--muted)}
.stats-grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(160px,1fr));gap:.75rem;margin-bottom:1.25rem}
.stat-card{background:#fff;border:0.5px solid var(--border);border-radius:8px;padding:.85rem 1rem}
.stat-card .label{font-size:.67rem;text-transform:uppercase;letter-spacing:.06em;color:var(--muted);margin-bottom:.3rem}
.stat-card .value{font-size:1.35rem;font-weight:700;line-height:1}
.stat-card .sub{font-size:.7rem;color:var(--muted);margin-top:.25rem}
.stat-ok{color:var(--success)}.stat-warn{color:#c07820}.stat-err{color:var(--danger)}
.progress{height:5px;background:var(--bg3);border-radius:3px;overflow:hidden;margin-top:.4rem}
.progress-bar{height:100%;border-radius:3px;background:var(--accent);transition:width .3s}
.progress-bar.warn{background:#c07820}.progress-bar.err{background:var(--danger)}
.card{background:#fff;border:0.5px solid var(--border);border-radius:8px;overflow:hidden;margin-bottom:1rem}
.card-header{padding:.55rem 1rem;border-bottom:0.5px solid var(--border);background:var(--bg3);display:flex;align-items:center;gap:.5rem}
.card-header h3{font-size:.85rem;font-weight:600;flex:1;color:var(--text)}
.card-body{padding:1rem}
table{width:100%;border-collapse:collapse;font-size:.82rem}
th{padding:.45rem .9rem;text-align:left;font-size:.67rem;font-weight:600;text-transform:uppercase;letter-spacing:.05em;color:var(--muted);background:var(--bg3);border-bottom:0.5px solid var(--border)}
td{padding:.5rem .9rem;border-bottom:0.5px solid #eef0f2;vertical-align:middle;color:var(--text)}
tr:last-child td{border-bottom:none}tr:hover td{background:#f8f9fa}
.badge{display:inline-block;padding:.15rem .5rem;border-radius:4px;font-size:.67rem;font-weight:600}
.badge-ok{background:#e8f5ec;border:0.5px solid #9ad0aa;color:#1a4a2a}
.badge-warn{background:#fff8e6;border:0.5px solid #f0d080;color:#7a4a00}
.badge-err{background:#fef0f0;border:0.5px solid #f0b0b0;color:#7a1a1a}
.badge-info{background:#e8f0fb;border:0.5px solid #b0c8f0;color:#1a3a7a}
.btn{padding:.32rem .75rem;border-radius:6px;border:0.5px solid #c8d4e0;background:#fff;color:var(--text);cursor:pointer;font-size:.76rem;font-family:var(--font);display:inline-flex;align-items:center;gap:.3rem;text-decoration:none;transition:background .1s}
.btn:hover{background:var(--bg3);text-decoration:none}
.btn-primary{background:#1c3557;border-color:#1c3557;color:#fff}.btn-primary:hover{background:#243f6a}
.btn-danger{border-color:#f0b0b0;color:var(--danger)}.btn-danger:hover{background:#fef0f0}
.btn-warn{border-color:#f0d080;color:var(--warn)}.btn-warn:hover{background:#fffbe6}
.btn-success{border-color:#a0d0a8;color:var(--success)}.btn-success:hover{background:#f0fff2}
.btn-sm{padding:.2rem .5rem;font-size:.72rem}.btn-xs{padding:.12rem .38rem;font-size:.68rem}
.actions{display:flex;gap:.4rem;flex-wrap:wrap;margin-bottom:1rem;align-items:center}
.flash{padding:.5rem .9rem;border-radius:6px;margin-bottom:.75rem;font-size:.8rem}
.flash-success{background:#e8f5ec;border:0.5px solid #9ad0aa;color:#1a4a2a}
.flash-error{background:#fef0f0;border:0.5px solid #f0b0b0;color:#7a1a1a}
.flash-warning{background:#fff8e6;border:0.5px solid #f0d080;color:#7a4a00}
input[type=text],input[type=password],input[type=file],select,textarea{background:var(--bg);border:0.5px solid var(--border);border-radius:6px;padding:.38rem .7rem;font-size:.82rem;color:var(--text);width:100%;font-family:var(--font);outline:none}
input:focus,select:focus,textarea:focus{border-color:var(--accent);background:#fff}
.form-group{margin-bottom:.75rem}.form-group label{display:block;font-size:.75rem;color:var(--muted);margin-bottom:.25rem;font-weight:500}
.form-row{display:grid;grid-template-columns:1fr 1fr;gap:.75rem}
.modal-bg{display:none;position:fixed;inset:0;background:rgba(0,0,0,.35);z-index:100;align-items:center;justify-content:center}
.modal-bg.open{display:flex}
.modal{background:#fff;border:0.5px solid var(--border);border-radius:10px;padding:1.25rem;width:460px;max-width:96vw;max-height:90vh;overflow-y:auto;box-shadow:0 8px 24px rgba(0,0,0,.1)}
.modal h3{font-size:.9rem;font-weight:600;margin-bottom:1rem;padding-bottom:.5rem;border-bottom:0.5px solid var(--border);color:var(--text)}
.modal-footer{display:flex;gap:.5rem;justify-content:flex-end;margin-top:1rem;padding-top:.5rem;border-top:0.5px solid var(--border)}
.modal-title{display:flex;align-items:center;justify-content:space-between;margin-bottom:.75rem}
.modal-title h3{margin:0}
.modal-close{background:none;border:none;font-size:1.2rem;line-height:1;color:var(--muted);cursor:pointer;padding:.1rem .3rem;border-radius:4px}
.modal-close:hover{background:var(--border);color:var(--text)}
.login-wrap{display:flex;align-items:center;justify-content:center;min-height:100vh;background:var(--bg)}
.login-box{background:#fff;border:0.5px solid var(--border);border-radius:12px;width:320px;overflow:hidden;box-shadow:0 4px 20px rgba(0,0,0,.08)}
.login-header{background:#1c3557;border-bottom:none;padding:1.25rem;text-align:center}
.login-header .logo{width:48px;height:48px;background:rgba(255,255,255,.15);border-radius:12px;display:grid;place-items:center;font-size:22px;margin:0 auto .5rem}
.login-header h2{color:#fff;font-size:1rem;font-weight:600}
.login-header p{color:#7a9ec0;font-size:.75rem;margin-top:.2rem}
.login-body{padding:1.25rem;display:flex;flex-direction:column;gap:.7rem}
.error-msg{font-size:.78rem;color:#7a1a1a;padding:.45rem .7rem;background:#fef0f0;border:0.5px solid #f0b0b0;border-radius:6px}
pre.log-box{background:var(--bg3);border:0.5px solid var(--border);border-radius:6px;padding:.75rem 1rem;font-family:var(--mono);font-size:.72rem;overflow:auto;max-height:400px;color:var(--text);white-space:pre-wrap;word-break:break-all}
.disks-grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(160px,1fr));gap:.75rem}
.disk-card{background:#fff;border:0.5px solid var(--border);border-radius:8px;padding:.9rem;cursor:pointer;transition:border-color .15s}
.disk-card:hover{border-color:var(--accent)}
.disk-card .di{font-size:1.8rem;margin-bottom:.35rem}
.disk-card h4{font-size:.85rem;font-weight:600;color:var(--text)}
.disk-card small{color:var(--muted);font-size:.72rem}
.text-muted{color:var(--muted)}.text-right{text-align:right}.nowrap{white-space:nowrap}
.grid2{display:grid;grid-template-columns:1fr 1fr;gap:1rem}
.statusbar{background:#fff;border-top:0.5px solid var(--border);padding:0 1.25rem;height:28px;display:flex;align-items:center;justify-content:space-between;flex-shrink:0}
.statusbar span{font-size:.68rem;color:var(--muted)}
.st-on{display:flex;align-items:center;gap:.3rem;font-size:.68rem;color:var(--success)}
.st-dot{width:5px;height:5px;border-radius:50%;background:currentColor;display:inline-block}
@keyframes spin{to{transform:rotate(360deg)}}
"""

BASE_T = """<!DOCTYPE html><html lang="pt-BR">
<head><meta charset="UTF-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>__ORG_NAME__ — Servidor</title>
<link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/@tabler/icons-webfont@latest/dist/tabler-icons.min.css">
<style>""" + CSS + """</style></head>
<body>
<div class="topbar">
  <div class="topbar-logo">
    <div class="logo-icon"><i class="ti ti-building-prison" aria-hidden="true"></i></div>
    <div>
      __ORG_FULLNAME__
      <span class="logo-sub">Portal de Administração · __FQDN__</span>
    </div>
  </div>
  {% if session.logged_in %}
  <div class="topbar-right">
    <span class="topbar-user"><i class="ti ti-user-circle"></i>{{ session.user }}</span>
    <a href="{{ url_for('change_pass_page') }}" class="btn btn-sm" style="border-color:rgba(255,255,255,.2);color:#a0c4e0;background:transparent"><i class="ti ti-lock"></i>Senha</a>
    <a href="{{ url_for('logout') }}" class="btn btn-sm" style="border-color:rgba(255,255,255,.2);color:#a0c4e0;background:transparent"><i class="ti ti-logout"></i>Sair</a>
  </div>
  {% endif %}
</div>
{% if banner and session.logged_in %}<img src="{{ banner }}" class="banner" alt="">{% endif %}
{% if session.logged_in %}
<div class="layout">
<nav class="sidebar">
  <div class="sidebar-section">Visão Geral</div>
  <a href="{{ url_for('dashboard') }}" class="{{ 'active' if active=='dashboard' else '' }}">
    <i class="ti ti-layout-dashboard sidebar-icon" aria-hidden="true"></i> Dashboard
  </a>
  <div class="sidebar-section">Arquivos</div>
  <a href="{{ url_for('index') }}" class="{{ 'active' if active=='files' else '' }}">
    <i class="ti ti-folders sidebar-icon" aria-hidden="true"></i> Compartilhamentos
  </a>
  {% if is_admin %}
  <a href="{{ url_for('lixeira_page') }}" class="{{ 'active' if active=='lixeira' else '' }}">
    <i class="ti ti-trash sidebar-icon" aria-hidden="true"></i> Lixeira
  </a>
  <div class="sidebar-section">Administração</div>
  <a href="{{ url_for('users_page') }}" class="{{ 'active' if active=='users' else '' }}">
    <i class="ti ti-users sidebar-icon" aria-hidden="true"></i> Usuários
    {% if users_count is defined %}<span class="sidebar-badge">{{ users_count }}</span>{% endif %}
  </a>
  <a href="{{ url_for('groups_page') }}" class="{{ 'active' if active=='groups' else '' }}">
    <i class="ti ti-hierarchy-2 sidebar-icon" aria-hidden="true"></i> Grupos
    {% if groups_count is defined %}<span class="sidebar-badge">{{ groups_count }}</span>{% endif %}
  </a>
  <a href="{{ url_for('shares_page') }}" class="{{ 'active' if active=='shares' else '' }}">
    <i class="ti ti-share sidebar-icon" aria-hidden="true"></i> Compartilhamentos
  </a>
  <div class="sidebar-section">Sistema</div>
  <a href="{{ url_for('raid_page') }}" class="{{ 'active' if active=='raid' else '' }}">
    <i class="ti ti-database sidebar-icon" aria-hidden="true"></i> RAID / Discos
  </a>
  <a href="{{ url_for('backups_page') }}" class="{{ 'active' if active=='backups' else '' }}">
    <i class="ti ti-archive sidebar-icon" aria-hidden="true"></i> Backups
  </a>
  <a href="{{ url_for('logs_page') }}" class="{{ 'active' if active=='logs' else '' }}">
    <i class="ti ti-clipboard-list sidebar-icon" aria-hidden="true"></i> Logs de acesso
  </a>
  {% endif %}
</nav>
<div class="main">
{% with msgs = get_flashed_messages(with_categories=True) %}
  {% for cat, msg in msgs %}<div class="flash flash-{{ cat }}">{{ msg }}</div>{% endfor %}
{% endwith %}
__BODY__
</div>
</div>
<div class="statusbar">
  <span>__ORG_NAME__ — __ORG_FULLNAME__</span>
  <span class="st-on"><span class="st-dot"></span>Samba ativo · RAID 5 saudável</span>
  <span>Portal v2.0 · Python Flask</span>
</div>
{% endif %}
<script>
document.addEventListener('keydown',function(e){
  if(e.key==='Escape'){
    document.querySelectorAll('.modal-bg.open').forEach(function(m){m.classList.remove('open');});
  }
});
</script>
</body></html>
"""

LOGIN_T = """<!DOCTYPE html><html lang="pt-BR">
<head><meta charset="UTF-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>__ORG_NAME__ — Login</title>
<link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/@tabler/icons-webfont@latest/dist/tabler-icons.min.css">
<style>""" + CSS + """</style></head>
<body>
<div class="login-wrap"><div class="login-box">
  <div class="login-header">
    <div class="logo"><i class="ti ti-building-prison" style="color:#fff;font-size:22px"></i></div>
    <h2>__ORG_NAME__</h2><p>Portal do Servidor</p>
  </div>
  <form method="post" class="login-body">
    {% if error %}<div class="error-msg"><i class="ti ti-alert-circle"></i> {{ error }}</div>{% endif %}
    <div class="form-group"><label>Usuário</label><input type="text" name="user" value="{{ req_user }}" autofocus autocomplete="username"></div>
    <div class="form-group"><label>Senha</label><input type="password" name="password" autocomplete="current-password"></div>
    <button type="submit" class="btn btn-primary" style="width:100%;justify-content:center;padding:.5rem">Entrar</button>
  </form>
</div></div>
</body></html>"""

# Substitui a identidade da unidade nos templates (definida no config.py)
for _ph, _val in (('__ORG_NAME__', ORG_NAME),
                  ('__ORG_FULLNAME__', ORG_FULLNAME),
                  ('__FQDN__', FQDN)):
    BASE_T  = BASE_T.replace(_ph, _val)
    LOGIN_T = LOGIN_T.replace(_ph, _val)

# ── auth ───────────────────────────────────────────────────────────────────────
@app.route('/login', methods=['GET', 'POST'])
def login():
    if session.get('logged_in'):
        return redirect(url_for('index'))
    error = ''
    req_user = ''
    if request.method == 'POST':
        user     = request.form.get('user', '').strip()
        password = request.form.get('password', '')
        req_user = user
        p = pam.pam()
        if p.authenticate(user, password, service='cdpni-portal'):
            if user not in ADMIN_USERS and user not in get_admin_group_members():
                error = 'Acesso restrito a administradores'
            else:
                import grp as grp_mod
                groups = []
                try:
                    for g in grp_mod.getgrall():
                        if user in g.gr_mem:
                            groups.append(g.gr_name)
                except Exception:
                    pass
                session.clear()
                session['logged_in'] = True
                session['user']      = user
                session['groups']    = groups
                session.permanent    = True
                nxt = request.args.get('next')
                return redirect(nxt if nxt and nxt.startswith('/') else url_for('index'))
        else:
            error = 'Usuário ou senha inválidos'
    return render_template_string(LOGIN_T, error=error, req_user=req_user,
        session=session, banner=get_banner(), active='', is_admin=False)

@app.route('/logout')
def logout():
    session.clear()
    return redirect(url_for('login'))

# ── arquivos ───────────────────────────────────────────────────────────────────
INDEX_T = BASE_T.replace("__BODY__", """
<div class="page-title">🗂️ Compartilhamentos</div>
{% if notice %}<div class="flash flash-warning">{{ notice|safe }}</div>{% endif %}
<div class="disks-grid">
{% for disk in disks %}
  <a href="{{ url_for('browse', disk=disk, rel='') }}" style="text-decoration:none">
    <div class="disk-card"><div class="di">🗂️</div><h4>{{ disk }}</h4><small>Compartilhamento Samba</small></div>
  </a>
{% else %}
  <p class="text-muted">Nenhum compartilhamento disponível.</p>
{% endfor %}
</div>
""")

@app.route('/')
@login_required
def index():
    disks = user_disks()
    notice_file = os.path.join(PORTAL_DIR, 'notice.html')
    notice = open(notice_file).read() if os.path.exists(notice_file) else ''
    is_admin = is_admin_user(session.get('user', ''))
    return render_template_string(INDEX_T, disks=disks, notice=notice,
        session=session, banner=get_banner(), active='files', is_admin=is_admin)

BROWSE_T = BASE_T.replace("__BODY__", """
<div style="font-size:.78rem;color:var(--muted);margin-bottom:.75rem">
  <a href="{{ url_for('index') }}" style="color:var(--muted)">Início</a> /
  <a href="{{ url_for('browse', disk=disk, rel='') }}" style="color:var(--muted)">{{ disk }}</a>
  {% set parts = rel.split('/') if rel else [] %}
  {% set acc = namespace(path='') %}
  {% for part in parts if part %}
    {% set acc.path = acc.path + '/' + part %}
    / <a href="{{ url_for('browse', disk=disk, rel=acc.path.lstrip('/')) }}" style="color:var(--muted)">{{ part }}</a>
  {% endfor %}
</div>
<div class="actions">
  {% if rel %}<a href="{{ url_for('browse', disk=disk, rel='/'.join(rel.split('/')[:-1])) }}" class="btn">⬆ Voltar</a>{% endif %}
  <button class="btn btn-primary" onclick="document.getElementById('mMkdir').classList.add('open')">📁 Nova Pasta</button>
  <button class="btn btn-primary" onclick="document.getElementById('mUpload').classList.add('open')">⬆ Upload</button>
</div>
<div class="card">
  <div class="card-header"><h3>{{ disk }}{% if rel %}/{{ rel }}{% endif %}</h3>
  <span class="text-muted" style="font-size:.78rem">{{ entries|length }} itens</span></div>
  <table>
    <thead><tr><th>Nome</th><th>Tipo</th><th>Tamanho</th><th class="text-right">Ações</th></tr></thead>
    <tbody>
    {% for e in entries %}
    <tr>
      <td>{% if e.is_dir %}<a href="{{ url_for('browse', disk=disk, rel=(rel+'/' if rel else '')+e.name) }}">📁 {{ e.name }}</a>
      {% else %}📄 {{ e.name }}{% endif %}</td>
      <td class="text-muted">{{ 'Pasta' if e.is_dir else e.ext }}</td>
      <td class="text-muted nowrap" style="font-family:var(--mono);font-size:.76rem">{{ '' if e.is_dir else e.size }}</td>
      <td class="text-right nowrap">
        {% if not e.is_dir %}<a href="{{ url_for('download', disk=disk, rel=(rel+'/' if rel else '')+e.name) }}" class="btn btn-xs">Baixar</a>{% endif %}
      </td>
    </tr>
    {% else %}
    <tr><td colspan="4" style="text-align:center;color:var(--muted);padding:1.5rem">Pasta vazia</td></tr>
    {% endfor %}
    </tbody>
  </table>
</div>
<div class="modal-bg" id="mMkdir"><div class="modal"><div class="modal-title"><h3>Nova Pasta</h3><button type="button" class="modal-close" onclick="closeModal('mMkdir')">&times;</button></div>
  <form method="post" action="{{ url_for('mkdir', disk=disk, rel=rel) }}">
    <div class="form-group"><label>Nome</label><input type="text" name="name" autofocus></div>
    <div class="modal-footer"><button type="button" class="btn" onclick="closeModal('mMkdir')">Cancelar</button>
    <button type="submit" class="btn btn-primary">Criar</button></div>
  </form></div></div>
<div class="modal-bg" id="mUpload"><div class="modal"><div class="modal-title"><h3>Upload de Arquivos</h3><button type="button" class="modal-close" onclick="closeModal('mUpload')">&times;</button></div>
  <form method="post" action="{{ url_for('upload', disk=disk, rel=rel) }}" enctype="multipart/form-data">
    <div class="form-group"><label>Arquivos</label><input type="file" name="files" multiple></div>
    <div class="modal-footer"><button type="button" class="btn" onclick="closeModal('mUpload')">Cancelar</button>
    <button type="submit" class="btn btn-primary">⬆ Enviar</button></div>
  </form></div></div>
<script>
function closeModal(id){document.getElementById(id).classList.remove('open');}
document.querySelectorAll('.modal-bg').forEach(m=>m.addEventListener('click',e=>{if(e.target===m)m.classList.remove('open');}));
</script>
""")

@app.route('/browse/<disk>/', defaults={'rel': ''})
@app.route('/browse/<disk>/<path:rel>')
@login_required
def browse(disk, rel):
    path = safe_path(disk, rel)
    if not path.is_dir():
        abort(404)
    if not os.access(str(path), os.R_OK):
        abort(403)
    entries = []
    try:
        for item in sorted(path.iterdir(), key=lambda x: (not x.is_dir(), x.name.lower())):
            try:
                stat = item.stat()
                entries.append(type('E', (), {
                    'name': item.name, 'is_dir': item.is_dir(),
                    'size': fmt_size(stat.st_size),
                    'ext':  item.suffix.upper().lstrip('.') or 'Arquivo'
                })())
            except PermissionError:
                pass
    except PermissionError:
        abort(403)
    is_admin = is_admin_user(session.get('user', ''))
    return render_template_string(BROWSE_T, disk=disk, rel=rel, entries=entries,
        session=session, banner=get_banner(), active='files', is_admin=is_admin)

@app.route('/download/<disk>/<path:rel>')
@login_required
def download(disk, rel):
    path = safe_path(disk, rel)
    if not path.is_file():
        abort(404)
    if not os.access(str(path), os.R_OK):
        abort(403)
    mime, _ = mimetypes.guess_type(str(path))
    return send_file(str(path), mimetype=mime or 'application/octet-stream',
                     as_attachment=True, download_name=path.name)

@app.route('/upload/<disk>/', defaults={'rel': ''}, methods=['POST'])
@app.route('/upload/<disk>/<path:rel>', methods=['POST'])
@login_required
def upload(disk, rel):
    dest = safe_path(disk, rel)
    if not dest.is_dir():
        abort(404)
    if not os.access(str(dest), os.W_OK):
        flash('Sem permissão de escrita', 'error')
        return redirect(url_for('browse', disk=disk, rel=rel))
    files = request.files.getlist('files')
    saved = 0
    for f in files:
        name = secure_filename(f.filename)
        if name:
            f.save(str(dest / name))
            saved += 1
    flash(f'{saved} arquivo(s) enviado(s)', 'success')
    return redirect(url_for('browse', disk=disk, rel=rel))

@app.route('/mkdir/<disk>/', defaults={'rel': ''}, methods=['POST'])
@app.route('/mkdir/<disk>/<path:rel>', methods=['POST'])
@login_required
def mkdir(disk, rel):
    parent = safe_path(disk, rel)
    name   = secure_filename(request.form.get('name', ''))
    if not name:
        flash('Nome inválido', 'error')
        return redirect(url_for('browse', disk=disk, rel=rel))
    target = parent / name
    if target.exists():
        flash('Já existe', 'error')
    else:
        target.mkdir(parents=False, exist_ok=False)
        os.chmod(str(target), 0o777)
        flash(f'Pasta "{name}" criada', 'success')
    return redirect(url_for('browse', disk=disk, rel=rel))

@app.route('/rename/<disk>/', defaults={'rel': ''}, methods=['POST'])
@app.route('/rename/<disk>/<path:rel>', methods=['POST'])
@login_required
def rename(disk, rel):
    parent   = safe_path(disk, rel)
    old_name = safe_name(request.form.get('old_name', ''))
    new_name = safe_name(request.form.get('new_name', ''))
    if not old_name or not new_name or old_name == new_name:
        flash('Nome inválido', 'error')
        return redirect(url_for('browse', disk=disk, rel=rel))
    src = parent / old_name
    dst = parent / new_name
    if not src.exists():
        flash('Arquivo não encontrado', 'error')
    elif dst.exists():
        flash('Nome já existe', 'error')
    else:
        rc, _, err = run(['sudo', 'mv', str(src), str(dst)])
        if rc == 0:
            flash('Renomeado', 'success')
        else:
            flash(f'Erro ao renomear: {err}', 'error')
    return redirect(url_for('browse', disk=disk, rel=rel))

@app.route('/delete/<disk>/', defaults={'rel': ''}, methods=['POST'])
@app.route('/delete/<disk>/<path:rel>', methods=['POST'])
@login_required
def delete(disk, rel):
    parent = safe_path(disk, rel)
    name   = safe_name(request.form.get('name', ''))
    is_dir = request.form.get('is_dir') == '1'
    if not name:
        flash('Nome inválido', 'error')
        return redirect(url_for('browse', disk=disk, rel=rel))
    target = parent / name
    if not target.exists():
        flash('Não encontrado', 'error')
    elif is_dir:
        rc, _, err = run(['sudo', 'rm', '-rf', str(target)])
        if rc == 0:
            flash(f'Pasta "{name}" removida', 'success')
        else:
            flash(f'Erro ao remover: {err}', 'error')
    else:
        rc, _, err = run(['sudo', 'rm', str(target)])
        if rc == 0:
            flash(f'"{name}" removido', 'success')
        else:
            flash(f'Erro ao remover: {err}', 'error')
    return redirect(url_for('browse', disk=disk, rel=rel))

@app.route('/banner-img/<filename>')
def banner_img(filename):
    name = secure_filename(filename)
    path = os.path.join(BANNER_DIR, name)
    if not os.path.exists(path):
        abort(404)
    mime, _ = mimetypes.guess_type(path)
    return send_file(path, mimetype=mime or 'image/jpeg')

# ── dashboard ──────────────────────────────────────────────────────────────────
DASHBOARD_T = BASE_T.replace("__BODY__", """
<div class="page-title">📊 Dashboard <small>Visão geral do servidor</small></div>
<div class="stats-grid">
  <div class="stat-card">
    <div class="label">CPU</div>
    <div class="value {{ 'stat-err' if cpu.pct > 85 else ('stat-warn' if cpu.pct > 65 else 'stat-ok') }}">{{ cpu.pct }}%</div>
    <div class="sub">{{ cpu.cores }} núcleos</div>
    <div class="progress"><div class="progress-bar {{ 'err' if cpu.pct > 85 else ('warn' if cpu.pct > 65 else '') }}" style="width:{{ cpu.pct }}%"></div></div>
  </div>
  <div class="stat-card">
    <div class="label">Memória RAM</div>
    <div class="value {{ 'stat-err' if mem.pct > 85 else ('stat-warn' if mem.pct > 65 else 'stat-ok') }}">{{ mem.pct }}%</div>
    <div class="sub">{{ mem.used_h }} / {{ mem.total_h }}</div>
    <div class="progress"><div class="progress-bar {{ 'err' if mem.pct > 85 else ('warn' if mem.pct > 65 else '') }}" style="width:{{ mem.pct }}%"></div></div>
  </div>
  <div class="stat-card">
    <div class="label">Uptime</div>
    <div class="value stat-ok" style="font-size:1rem">{{ uptime }}</div>
    <div class="sub">em execução</div>
  </div>
  <div class="stat-card">
    <div class="label">Conexões Samba</div>
    <div class="value" style="color:var(--accent)">{{ conns|length }}</div>
    <div class="sub">sessões ativas</div>
  </div>
</div>
<div class="grid2">
  <div class="card">
    <div class="card-header"><h3>💾 Uso de Disco</h3></div>
    <table>
      <thead><tr><th>Ponto</th><th>Uso</th><th>Livre</th></tr></thead>
      <tbody>
      {% for d in disks %}
      <tr>
        <td>{{ d.mount }}<br><span class="text-muted" style="font-size:.7rem;font-family:var(--mono)">{{ d.source }}</span></td>
        <td>
          <div style="display:flex;align-items:center;gap:.5rem">
            <div class="progress" style="width:80px"><div class="progress-bar {{ 'err' if d.pct|int > 85 else ('warn' if d.pct|int > 65 else '') }}" style="width:{{ d.pct }}%"></div></div>
            <span style="font-size:.76rem">{{ d.pct }}%</span>
          </div>
        </td>
        <td class="text-muted" style="font-size:.76rem">{{ d.avail }}</td>
      </tr>
      {% endfor %}
      </tbody>
    </table>
  </div>
  <div class="card">
    <div class="card-header"><h3>👥 Sessões Samba Ativas</h3></div>
    {% if conns %}
    <table>
      <thead><tr><th>Usuário</th><th>Máquina</th><th>Desde</th></tr></thead>
      <tbody>
      {% for c in conns %}
      <tr><td>{{ c.user }}</td><td class="text-muted">{{ c.machine }}</td>
      <td class="text-muted nowrap" style="font-size:.72rem">{{ c.since }}</td></tr>
      {% endfor %}
      </tbody>
    </table>
    {% else %}
    <div class="card-body text-muted" style="font-size:.82rem">Nenhuma sessão ativa</div>
    {% endif %}
  </div>
</div>
<div class="card">
  <div class="card-header"><h3>⚙️ Serviços</h3></div>
  <table>
    <thead><tr><th>Serviço</th><th>Status</th></tr></thead>
    <tbody>
    {% for svc in services %}
    <tr><td>{{ svc.name }}</td>
    <td><span class="badge {{ 'badge-ok' if svc.active else 'badge-err' }}">{{ 'Ativo' if svc.active else 'Inativo' }}</span></td></tr>
    {% endfor %}
    </tbody>
  </table>
</div>
""")

@app.route('/dashboard')
@admin_required
def dashboard():
    svc_list = ['smbd', 'nmbd', 'winbind', 'cdpni-portal', 'nginx']
    services = []
    for s in svc_list:
        rc, _, _ = run(['systemctl', 'is-active', s])
        services.append({'name': s, 'active': rc == 0})
    return render_template_string(DASHBOARD_T,
        cpu=get_cpu(), mem=get_memory(), uptime=get_uptime(),
        disks=get_disk_usage(), conns=get_samba_connections(),
        services=services,
        session=session, banner=get_banner(), active='dashboard', is_admin=True)

# ── usuários ───────────────────────────────────────────────────────────────────
USERS_T = BASE_T.replace("__BODY__", """
<div class="page-title">👥 Usuários do Sistema</div>
<div class="actions">
  <button class="btn btn-primary" onclick="document.getElementById('mNewUser').classList.add('open')">➕ Novo Usuário</button>
</div>
<div class="card">
  <div class="card-header"><h3>Usuários</h3><span class="text-muted" style="font-size:.76rem">{{ users|length }}</span></div>
  <table>
    <thead><tr><th>Usuário</th><th>UID</th><th>Papel</th><th>Status</th><th class="text-right">Ações</th></tr></thead>
    <tbody>
    {% for u in users %}
    <tr style="opacity:{% if u.active %}1{% else %}.55{% endif %}">
      <td><strong>{{ u.name }}</strong></td>
      <td class="text-muted">{{ u.uid }}</td>
      <td>
        {% if u.is_admin %}
          <span style="color:var(--accent);font-size:.74rem;font-weight:600">★ Admin</span>
        {% else %}
          <span style="color:var(--muted);font-size:.74rem">Comum</span>
        {% endif %}
      </td>
      <td>
        {% if u.active %}
          <span style="color:var(--success);font-size:.75rem;font-weight:600">● Ativo</span>
        {% else %}
          <span style="color:var(--muted);font-size:.75rem;font-weight:600">○ Inativo</span>
        {% endif %}
      </td>
      <td class="text-right nowrap">
        <span style="display:inline-flex;gap:3px;align-items:center">
          <button class="btn btn-xs" style="min-width:48px;text-align:center;justify-content:center" onclick="openResetPass('{{ u.name }}')">Senha</button>
          <button class="btn btn-xs" style="min-width:76px;text-align:center;justify-content:center" onclick="openPerms('{{ u.name }}')">Permissões</button>
          {% if u.name == session.user %}
            <button class="btn btn-xs" style="min-width:90px;text-align:center;justify-content:center" disabled title="Não é possível alterar seu próprio papel">↓ Tornar Comum</button>
            <button class="btn btn-xs" style="min-width:58px;text-align:center;justify-content:center" disabled title="Não é possível inativar seu próprio usuário">Inativar</button>
            <button class="btn btn-xs btn-danger" style="min-width:48px;text-align:center;justify-content:center" disabled title="Não é possível excluir seu próprio usuário">Excluir</button>
          {% else %}
          {% if u.is_admin %}
            <button class="btn btn-xs btn-warn" style="min-width:90px;text-align:center;justify-content:center" onclick="confirmRole('{{ u.name }}','comum')">↓ Tornar Comum</button>
          {% else %}
            <button class="btn btn-xs btn-success" style="min-width:90px;text-align:center;justify-content:center" onclick="confirmRole('{{ u.name }}','admin')">↑ Tornar Admin</button>
          {% endif %}
          {% if u.active %}
            <button class="btn btn-xs btn-warn" style="min-width:58px;text-align:center;justify-content:center" onclick="confirmToggle('{{ u.name }}','deactivate')">Inativar</button>
          {% else %}
            <button class="btn btn-xs btn-success" style="min-width:58px;text-align:center;justify-content:center" onclick="confirmToggle('{{ u.name }}','activate')">Ativar</button>
          {% endif %}
          <button class="btn btn-xs btn-danger" style="min-width:48px;text-align:center;justify-content:center" onclick="confirmDelUser('{{ u.name }}')">Excluir</button>
          {% endif %}
        </span>
      </td>
    </tr>
    {% endfor %}
    </tbody>
  </table>
</div>

<div class="modal-bg" id="mNewUser"><div class="modal"><div class="modal-title"><h3>Novo Usuário</h3><button type="button" class="modal-close" onclick="closeModal('mNewUser')">&times;</button></div>
  <form method="post" action="{{ url_for('user_create') }}">
    <div class="form-group"><label>Usuário (letras minúsculas, números, _ e -)</label>
      <input type="text" name="username" pattern="[a-z][a-z0-9_-]{0,31}" required autofocus></div>
    <div class="form-group"><label>Senha</label><input type="password" name="password" minlength="4" required></div>
    <div class="form-group"><label>Confirmar Senha</label><input type="password" name="confirm" required></div>
    <div class="form-group"><label>Papel</label>
      <select name="role">
        <option value="comum">Usuário Comum</option>
        <option value="admin">Administrador do Painel</option>
      </select></div>
    <div class="form-group"><label>Adicionar ao Samba</label>
      <select name="add_samba"><option value="1">Sim</option><option value="0">Não</option></select></div>
    <div class="modal-footer">
      <button type="button" class="btn" onclick="closeModal('mNewUser')">Cancelar</button>
      <button type="submit" class="btn btn-primary">Criar</button>
    </div>
  </form></div></div>

<div class="modal-bg" id="mResetPass"><div class="modal"><div class="modal-title"><h3>Redefinir Senha</h3><button type="button" class="modal-close" onclick="closeModal('mResetPass')">&times;</button></div>
  <form method="post" action="{{ url_for('user_passwd') }}">
    <input type="hidden" name="username" id="rpUsername">
    <div class="form-group"><label>Usuário</label><input type="text" id="rpUserLabel" readonly style="opacity:.6"></div>
    <div class="form-group"><label>Nova Senha</label><input type="password" name="password" id="rpPass" minlength="4" required></div>
    <div class="form-group"><label>Confirmar</label><input type="password" name="confirm" id="rpConf" required></div>
    <div class="form-group"><label>Atualizar Samba também</label>
      <select name="update_samba"><option value="1">Sim</option><option value="0">Não</option></select></div>
    <div class="modal-footer">
      <button type="button" class="btn" onclick="closeModal('mResetPass')">Cancelar</button>
      <button type="submit" class="btn btn-primary">Redefinir</button>
    </div>
  </form></div></div>

<div class="modal-bg" id="mPerms"><div class="modal" style="min-width:420px"><div class="modal-title"><h3>Permissões por Compartilhamento</h3><button type="button" class="modal-close" onclick="closeModal('mPerms')">&times;</button></div>
  <form method="post" action="{{ url_for('user_permissions') }}" id="fPerms">
    <input type="hidden" name="username" id="permsUsername">
    <p style="font-size:.8rem;color:var(--muted);margin-bottom:.75rem">Usuário: <strong id="permsUserLabel"></strong></p>
    <table style="width:100%">
      <thead>
        <tr><th>Compartilhamento</th><th style="text-align:center">Ler</th><th style="text-align:center">Escrever</th><th style="text-align:center">Executar</th></tr>
        <tr style="border-bottom:1px solid var(--border)">
          <td style="font-size:.75rem;color:var(--muted);padding-bottom:.4rem">Selecionar todos</td>
          <td style="text-align:center;padding-bottom:.4rem"><input type="checkbox" id="chkAllR" title="Selecionar todos Ler" onchange="toggleAll('_r',this.checked)"></td>
          <td style="text-align:center;padding-bottom:.4rem"><input type="checkbox" id="chkAllW" title="Selecionar todos Escrever" onchange="toggleAll('_w',this.checked)"></td>
          <td style="text-align:center;padding-bottom:.4rem"><input type="checkbox" id="chkAllX" title="Selecionar todos Executar" onchange="toggleAll('_x',this.checked)"></td>
        </tr>
      </thead>
      <tbody id="permsBody"></tbody>
    </table>
    <div class="modal-footer" style="margin-top:1rem">
      <button type="button" class="btn" onclick="closeModal('mPerms')">Cancelar</button>
      <button type="submit" class="btn btn-primary">Salvar</button>
    </div>
  </form></div></div>

<form method="post" id="fDelUser" action="{{ url_for('user_delete') }}" style="display:none">
  <input type="hidden" name="username" id="delUsername">
</form>
<form method="post" id="fToggleUser" action="{{ url_for('user_toggle') }}" style="display:none">
  <input type="hidden" name="username" id="toggleUsername">
  <input type="hidden" name="action"   id="toggleAction">
</form>
<form method="post" id="fRoleUser" action="{{ url_for('user_role') }}" style="display:none">
  <input type="hidden" name="username" id="roleUsername">
  <input type="hidden" name="role"     id="roleValue">
</form>

<script>
var SHARES = {{ shares_json|safe }};
var USER_PERMS = {{ user_perms_json|safe }};
function closeModal(id){document.getElementById(id).classList.remove('open');}
document.querySelectorAll('.modal-bg').forEach(m=>m.addEventListener('click',e=>{if(e.target===m)m.classList.remove('open');}));
function openResetPass(u){document.getElementById('rpUsername').value=u;document.getElementById('rpUserLabel').value=u;document.getElementById('mResetPass').classList.add('open');}
function confirmDelUser(u){if(!confirm('Excluir usuário "'+u+'"? Remove do sistema e do Samba.'))return;document.getElementById('delUsername').value=u;document.getElementById('fDelUser').submit();}
function confirmToggle(u,action){
  var msg=action==='activate'?'Ativar usuário "'+u+'"?':'Inativar "'+u+'"? Acesso ao Samba será bloqueado.';
  if(!confirm(msg))return;
  document.getElementById('toggleUsername').value=u;
  document.getElementById('toggleAction').value=action;
  document.getElementById('fToggleUser').submit();
}
function confirmRole(u,role){
  var msg=role==='admin'?'Promover "'+u+'" a Administrador?':'Rebaixar "'+u+'" para Usuário Comum?';
  if(!confirm(msg))return;
  document.getElementById('roleUsername').value=u;
  document.getElementById('roleValue').value=role;
  document.getElementById('fRoleUser').submit();
}
function toggleAll(suffix, checked){
  document.querySelectorAll('#permsBody input[type=checkbox]').forEach(function(cb){
    if(cb.name.endsWith(suffix)) cb.checked=checked;
  });
}
function openPerms(u){
  document.getElementById('permsUsername').value=u;
  document.getElementById('permsUserLabel').textContent=u;
  ['chkAllR','chkAllW','chkAllX'].forEach(function(id){document.getElementById(id).checked=false;});
  var perms=USER_PERMS[u]||{};
  var tbody=document.getElementById('permsBody');
  tbody.innerHTML='';
  SHARES.forEach(function(s){
    var p=perms[s]||'';
    tbody.innerHTML+='<tr>'
      +'<td><strong>'+s+'</strong></td>'
      +'<td style="text-align:center"><input type="checkbox" name="perm_'+s+'_r"'+(p.includes('r')?' checked':'')+' value="1"></td>'
      +'<td style="text-align:center"><input type="checkbox" name="perm_'+s+'_w"'+(p.includes('w')?' checked':'')+' value="1"></td>'
      +'<td style="text-align:center"><input type="checkbox" name="perm_'+s+'_x"'+(p.includes('x')?' checked':'')+' value="1"></td>'
      +'</tr>';
  });
  document.getElementById('mPerms').classList.add('open');
}
</script>
""")

@app.route('/admin/users')
@admin_required
def users_page():
    users  = get_system_users()
    shares = parse_smb_shares()
    share_names = [s['name'] for s in shares if s.get('path') and s['name'] not in ('global','homes','printers')]
    user_perms  = {u['name']: get_user_share_perms(u['name']) for u in users}
    return render_template_string(USERS_T, users=users,
        shares_json=json.dumps(share_names),
        user_perms_json=json.dumps(user_perms),
        session=session, banner=get_banner(), active='users', is_admin=True)

@app.route('/admin/users/create', methods=['POST'])
@admin_required
def user_create():
    username  = request.form.get('username', '').strip()
    password  = request.form.get('password', '')
    confirm   = request.form.get('confirm', '')
    add_samba = request.form.get('add_samba', '1') == '1'
    is_admin  = request.form.get('role', 'comum') == 'admin'
    if not re.match(r'^[a-z][a-z0-9_-]{0,31}$', username):
        flash('Nome de usuário inválido', 'error')
        return redirect(url_for('users_page'))
    if password != confirm:
        flash('Senhas não coincidem', 'error')
        return redirect(url_for('users_page'))
    if len(password) < 4:
        flash('Mínimo 4 caracteres', 'error')
        return redirect(url_for('users_page'))
    rc, _, err = run(['sudo', '/usr/local/bin/cdpni-useradd', username])
    if rc != 0:
        flash(f'Erro ao criar usuário: {err}', 'error')
        return redirect(url_for('users_page'))
    set_linux_password(username, password)
    if add_samba:
        run(['sudo', 'smbpasswd', '-a', '-s', username], input_=f'{password}\n{password}\n')
    if is_admin:
        run(['sudo', '/usr/local/bin/cdpni-groupadd', '-f', ADMIN_GROUP])
        add_group_member(username, ADMIN_GROUP)
    flash(f'Usuário "{username}" criado como {"administrador" if is_admin else "comum"}', 'success')
    return redirect(url_for('users_page'))

@app.route('/admin/users/role', methods=['POST'])
@admin_required
def user_role():
    username = request.form.get('username', '').strip()
    role     = request.form.get('role', 'comum')
    if not re.match(r'^[a-z][a-z0-9_-]{0,31}$', username):
        flash('Usuário inválido', 'error')
        return redirect(url_for('users_page'))
    run(['sudo', '/usr/local/bin/cdpni-groupadd', '-f', ADMIN_GROUP])
    if role == 'admin':
        add_group_member(username, ADMIN_GROUP)
        flash(f'"{username}" promovido a administrador', 'success')
    else:
        remove_group_member(username, ADMIN_GROUP)
        flash(f'"{username}" alterado para usuário comum', 'success')
    return redirect(url_for('users_page'))

@app.route('/admin/users/permissions', methods=['POST'])
@admin_required
def user_permissions():
    username = request.form.get('username', '').strip()
    if not re.match(r'^[a-z][a-z0-9_-]{0,31}$', username):
        flash('Usuário inválido', 'error')
        return redirect(url_for('users_page'))
    shares = parse_smb_shares()
    all_perms = _load_perms_file()
    user_p = {}
    for s in shares:
        path = s.get('path', '')
        r = 'r' if request.form.get(f'perm_{s["name"]}_r') else ''
        w = 'w' if request.form.get(f'perm_{s["name"]}_w') else ''
        x = 'x' if request.form.get(f'perm_{s["name"]}_x') else ''
        perm_str = r + w + x
        user_p[s['name']] = perm_str
        # Sincroniza grupo Linux com o acesso Samba (valid users = @grupo)
        grp = s.get('force_group', '').lstrip('+').strip()
        if grp and re.match(r'^[a-z][a-z0-9_-]*$', grp):
            if perm_str:
                add_group_member(username, grp)
            else:
                remove_group_member(username, grp)
        if path and os.path.isdir(path):
            if perm_str:
                run(['sudo', 'setfacl', '-m', f'u:{username}:{perm_str}', path])
            else:
                run(['sudo', 'setfacl', '-x', f'u:{username}', path])
    all_perms[username] = user_p
    _save_perms_file(all_perms)
    flash(f'Permissões de "{username}" atualizadas', 'success')
    return redirect(url_for('users_page'))

@app.route('/admin/users/passwd', methods=['POST'])
@admin_required
def user_passwd():
    username     = request.form.get('username', '').strip()
    password     = request.form.get('password', '')
    confirm      = request.form.get('confirm', '')
    update_samba = request.form.get('update_samba', '1') == '1'
    if not re.match(r'^[a-z][a-z0-9_-]{0,31}$', username):
        flash('Usuário inválido', 'error')
        return redirect(url_for('users_page'))
    if password != confirm:
        flash('Senhas não coincidem', 'error')
        return redirect(url_for('users_page'))
    if len(password) < 4:
        flash('Mínimo 4 caracteres', 'error')
        return redirect(url_for('users_page'))
    rc, err = set_linux_password(username, password)
    if rc != 0:
        flash(f'Erro ao alterar senha: {err}', 'error')
        return redirect(url_for('users_page'))
    if update_samba:
        run(['sudo', 'smbpasswd', '-s', username], input_=f'{password}\n{password}\n')
    flash(f'Senha de "{username}" alterada', 'success')
    return redirect(url_for('users_page'))

@app.route('/admin/users/delete', methods=['POST'])
@admin_required
def user_delete():
    username = request.form.get('username', '').strip()
    if not re.match(r'^[a-z][a-z0-9_-]{0,31}$', username):
        flash('Usuário inválido', 'error')
        return redirect(url_for('users_page'))
    if username == session.get('user'):
        flash('Não é possível excluir o próprio usuário logado', 'error')
        return redirect(url_for('users_page'))
    run(['sudo', 'smbpasswd', '-x', username])
    rc, _, err = run(['sudo', '/usr/local/bin/cdpni-userdel', username])
    if rc != 0 and 'does not exist' not in err:
        flash(f'Erro ao remover: {err}', 'error')
    else:
        flash(f'Usuário "{username}" removido', 'success')
    return redirect(url_for('users_page'))

@app.route('/admin/users/toggle', methods=['POST'])
@admin_required
def user_toggle():
    username = request.form.get('username', '').strip()
    action   = request.form.get('action', '')   # 'activate' | 'deactivate'
    if not re.match(r'^[a-z][a-z0-9_-]{0,31}$', username):
        flash('Usuário inválido', 'error')
        return redirect(url_for('users_page'))
    if username == session.get('user'):
        flash('Não é possível alterar o próprio usuário logado', 'error')
        return redirect(url_for('users_page'))
    if action == 'activate':
        rc, _, err = run(['sudo', 'usermod', '-s', '/bin/bash', username])
        msg = f'Usuário "{username}" ativado' if rc == 0 else f'Erro: {err}'
    else:
        rc, _, err = run(['sudo', 'usermod', '-s', '/usr/sbin/nologin', username])
        run(['sudo', 'smbpasswd', '-d', username])
        msg = f'Usuário "{username}" inativado' if rc == 0 else f'Erro: {err}'
    flash(msg, 'success' if rc == 0 else 'error')
    return redirect(url_for('users_page'))

# ── grupos ─────────────────────────────────────────────────────────────────────
GROUPS_T = BASE_T.replace("__BODY__", """
<div class="page-title">🏷️ Grupos do Sistema</div>
<div class="actions">
  <button class="btn btn-primary" onclick="document.getElementById('mNewGroup').classList.add('open')">➕ Novo Grupo</button>
</div>
<div class="card">
  <div class="card-header"><h3>Grupos</h3></div>
  <table>
    <thead><tr><th>Grupo</th><th>GID</th><th>Membros</th><th class="text-right">Ações</th></tr></thead>
    <tbody>
    {% for g in groups %}
    <tr>
      <td><strong>{{ g.name }}</strong></td>
      <td class="text-muted">{{ g.gid }}</td>
      <td class="text-muted" style="font-size:.76rem">{{ g.members|join(', ') if g.members else '—' }}</td>
      <td class="text-right nowrap">
        <button class="btn btn-xs" onclick="openEditGroup('{{ g.name }}','{{ g.members|join(',') }}')">Editar</button>
        <button class="btn btn-xs btn-danger" onclick="confirmDelGroup('{{ g.name }}')">Excluir</button>
      </td>
    </tr>
    {% endfor %}
    </tbody>
  </table>
</div>
<div class="modal-bg" id="mNewGroup"><div class="modal"><div class="modal-title"><h3>Novo Grupo</h3><button type="button" class="modal-close" onclick="closeModal('mNewGroup')">&times;</button></div>
  <form method="post" action="{{ url_for('group_create') }}">
    <div class="form-group"><label>Nome do grupo</label>
      <input type="text" name="groupname" pattern="[a-z][a-z0-9_-]{0,31}" required autofocus></div>
    <div class="modal-footer"><button type="button" class="btn" onclick="closeModal('mNewGroup')">Cancelar</button>
    <button type="submit" class="btn btn-primary">Criar</button></div>
  </form></div></div>
<div class="modal-bg" id="mEditGroup"><div class="modal" style="max-width:480px"><div class="modal-title"><h3>Editar Membros — <span id="editGroupLabel"></span></h3><button type="button" class="modal-close" onclick="closeModal('mEditGroup')">&times;</button></div>
  <form method="post" action="{{ url_for('group_members') }}" onsubmit="buildMembersList()">
    <input type="hidden" name="groupname" id="editGroupName">
    <input type="hidden" name="members"   id="editGroupMembers">
    <div class="form-group" style="margin-bottom:.5rem">
      <label style="display:flex;align-items:center;gap:.4rem;font-size:.78rem;color:var(--muted);cursor:pointer">
        <input type="checkbox" id="cbSelectAll" onchange="toggleAllMembers(this.checked)"> Selecionar todos
      </label>
    </div>
    <div id="memberCheckboxes" style="display:grid;grid-template-columns:1fr 1fr;gap:.25rem .75rem;max-height:320px;overflow-y:auto;padding:.25rem 0">
      {% for u in all_users %}
      <label style="display:flex;align-items:center;gap:.4rem;font-size:.84rem;cursor:pointer;white-space:nowrap">
        <input type="checkbox" class="member-cb" value="{{ u.name }}"> {{ u.name }}
      </label>
      {% endfor %}
    </div>
    <div class="modal-footer"><button type="button" class="btn" onclick="closeModal('mEditGroup')">Cancelar</button>
    <button type="submit" class="btn btn-primary">Salvar</button></div>
  </form></div></div>
<form method="post" id="fDelGroup" action="{{ url_for('group_delete') }}" style="display:none">
  <input type="hidden" name="groupname" id="delGroupName">
</form>
<script>
function closeModal(id){document.getElementById(id).classList.remove('open');}
document.querySelectorAll('.modal-bg').forEach(m=>m.addEventListener('click',e=>{if(e.target===m)m.classList.remove('open');}));
function openEditGroup(name,members){
  var current=members?members.split(',').map(function(s){return s.trim();}):[];
  document.getElementById('editGroupName').value=name;
  document.getElementById('editGroupLabel').textContent=name;
  document.querySelectorAll('.member-cb').forEach(function(cb){
    cb.checked=current.indexOf(cb.value)!==-1;
  });
  syncSelectAll();
  document.getElementById('mEditGroup').classList.add('open');
}
function toggleAllMembers(checked){
  document.querySelectorAll('.member-cb').forEach(function(cb){cb.checked=checked;});
}
function syncSelectAll(){
  var cbs=document.querySelectorAll('.member-cb');
  var all=Array.from(cbs).every(function(cb){return cb.checked;});
  document.getElementById('cbSelectAll').checked=all;
}
document.addEventListener('change',function(e){if(e.target&&e.target.classList.contains('member-cb'))syncSelectAll();});
function buildMembersList(){
  var checked=Array.from(document.querySelectorAll('.member-cb:checked')).map(function(cb){return cb.value;});
  document.getElementById('editGroupMembers').value=checked.join(',');
}
function confirmDelGroup(g){if(!confirm('Excluir grupo "'+g+'"?'))return;document.getElementById('delGroupName').value=g;document.getElementById('fDelGroup').submit();}
</script>
""")

@app.route('/admin/groups')
@admin_required
def groups_page():
    return render_template_string(GROUPS_T, groups=get_system_groups(),
        all_users=get_system_users(),
        session=session, banner=get_banner(), active='groups', is_admin=True)

@app.route('/admin/groups/create', methods=['POST'])
@admin_required
def group_create():
    groupname = request.form.get('groupname', '').strip()
    if not re.match(r'^[a-z][a-z0-9_-]{0,31}$', groupname):
        flash('Nome de grupo inválido', 'error')
        return redirect(url_for('groups_page'))
    rc, _, err = run(['sudo', '/usr/local/bin/cdpni-groupadd', groupname])
    if rc != 0:
        flash(f'Erro ao criar grupo: {err}', 'error')
    else:
        flash(f'Grupo "{groupname}" criado', 'success')
    return redirect(url_for('groups_page'))

@app.route('/admin/groups/members', methods=['POST'])
@admin_required
def group_members():
    groupname = request.form.get('groupname', '').strip()
    members   = request.form.get('members', '').strip()
    if not re.match(r'^[a-z][a-z0-9_-]{0,31}$', groupname):
        flash('Grupo inválido', 'error')
        return redirect(url_for('groups_page'))
    member_list = [m.strip() for m in members.split(',') if m.strip()]
    rc, err = set_group_members(groupname, member_list)
    if rc != 0:
        flash(f'Erro ao atualizar membros: {err}', 'error')
    else:
        flash(f'Membros do grupo "{groupname}" atualizados', 'success')
    return redirect(url_for('groups_page'))

@app.route('/admin/groups/delete', methods=['POST'])
@admin_required
def group_delete():
    groupname = request.form.get('groupname', '').strip()
    if not re.match(r'^[a-z][a-z0-9_-]{0,31}$', groupname):
        flash('Grupo inválido', 'error')
        return redirect(url_for('groups_page'))
    rc, _, err = run(['sudo', '/usr/local/bin/cdpni-groupdel', groupname])
    if rc != 0:
        flash(f'Erro ao remover: {err}', 'error')
    else:
        flash(f'Grupo "{groupname}" removido', 'success')
    return redirect(url_for('groups_page'))

# ── shares samba ───────────────────────────────────────────────────────────────
SHARES_T = BASE_T.replace("__BODY__", """
<div class="page-title">📁 Shares Samba <small>{{ smb_conf }}</small></div>
<div class="actions">
  <button class="btn btn-primary" onclick="document.getElementById('mNewShare').classList.add('open')">➕ Novo Share</button>
  <a href="{{ url_for('shares_testparm') }}" class="btn">🔍 testparm</a>
  <form method="post" action="{{ url_for('shares_reload') }}" style="display:inline">
    <button class="btn">🔄 Reload Samba</button>
  </form>
</div>
<div class="card">
  <div class="card-header"><h3>Compartilhamentos</h3><span class="text-muted" style="font-size:.76rem">{{ shares|length }}</span></div>
  <table>
    <thead><tr><th>Nome</th><th>Caminho</th><th>Usuários/Grupos</th><th>Leitura</th><th class="text-right">Ações</th></tr></thead>
    <tbody>
    {% for s in shares %}
    <tr>
      <td><strong>{{ s.name }}</strong></td>
      <td class="text-muted nowrap" style="font-family:var(--mono);font-size:.74rem">{{ s.path }}</td>
      <td class="text-muted" style="font-size:.74rem">{% if s.get('guest_ok') == 'yes' %}<span class="badge badge-warn">Público (sem senha)</span>{% else %}{{ s.valid_users or '—' }}{% endif %}</td>
      <td><span class="badge {{ 'badge-warn' if s.read_only == 'yes' else 'badge-ok' }}">{{ 'Sim' if s.read_only == 'yes' else 'Não' }}</span></td>
      <td class="text-right nowrap">
        <button class="btn btn-xs"
          data-name="{{ s.name|e }}"
          data-path="{{ s.path|e }}"
          data-comment="{{ s.comment|e }}"
          data-users="{{ s.valid_users|e }}"
          data-ro="{{ s.read_only|e }}"
          data-browse="{{ s.browseable|e }}"
          data-guest="{{ s.get('guest_ok', 'no')|e }}"
          onclick="openEditShare(this)">Editar</button>
        <button class="btn btn-xs btn-danger"
          data-name="{{ s.name|e }}"
          onclick="confirmDelShare(this)">Excluir</button>
      </td>
    </tr>
    {% endfor %}
    </tbody>
  </table>
</div>
<div class="modal-bg" id="mNewShare"><div class="modal"><div class="modal-title"><h3>Novo Share</h3><button type="button" class="modal-close" onclick="closeModal('mNewShare')">&times;</button></div>
  <form method="post" action="{{ url_for('share_create') }}">
    <div class="form-group"><label>Nome do share</label><input type="text" name="name" id="nsName" required autofocus oninput="nsAutoPath(this)"></div>
    <div class="form-group">
      <label>Caminho (path)</label>
      <input type="text" name="path" id="nsPath" placeholder="/mnt/raid/shares/nome" required oninput="window._nsPathEdited=true">
      <small class="text-muted">Preenchido automaticamente — edite se necessário</small>
    </div>
    <div class="form-group"><label>Comentário</label><input type="text" name="comment"></div>
    <div class="form-group"><label>Tipo de acesso</label>
      <select name="acesso" id="nsAcesso" onchange="toggleShareUsers('nsAcesso','nsUsersGrp')">
        <option value="restrito">Restrito — só usuários/grupos autorizados</option>
        <option value="publico">Público — toda a rede, sem senha</option>
      </select></div>
    <div class="form-group" id="nsUsersGrp"><label>Usuários/grupos válidos (ex: user1 @grupo1 — vazio = grupo do share + admin)</label><input type="text" name="valid_users"></div>
    <div class="form-row">
      <div class="form-group"><label>Somente leitura</label>
        <select name="read_only"><option value="no">Não</option><option value="yes">Sim</option></select></div>
      <div class="form-group"><label>Visível no browse</label>
        <select name="browseable"><option value="yes">Sim</option><option value="no">Não</option></select></div>
    </div>
    <div class="form-group"><label>Criar diretório se não existir</label>
      <select name="create_dir"><option value="1">Sim</option><option value="0">Não</option></select></div>
    <div class="modal-footer"><button type="button" class="btn" onclick="closeModal('mNewShare')">Cancelar</button>
    <button type="submit" class="btn btn-primary">Criar</button></div>
  </form></div></div>
<div class="modal-bg" id="mEditShare"><div class="modal"><div class="modal-title"><h3>Editar Share</h3><button type="button" class="modal-close" onclick="closeModal('mEditShare')">&times;</button></div>
  <form method="post" action="{{ url_for('share_edit') }}">
    <input type="hidden" name="original_name" id="esOrigName">
    <div class="form-group"><label>Nome</label><input type="text" name="name" id="esName" required></div>
    <div class="form-group"><label>Caminho</label><input type="text" name="path" id="esPath" required></div>
    <div class="form-group"><label>Comentário</label><input type="text" name="comment" id="esComment"></div>
    <div class="form-group"><label>Tipo de acesso</label>
      <select name="acesso" id="esAcesso" onchange="toggleShareUsers('esAcesso','esUsersGrp')">
        <option value="restrito">Restrito — só usuários/grupos autorizados</option>
        <option value="publico">Público — toda a rede, sem senha</option>
      </select></div>
    <div class="form-group" id="esUsersGrp"><label>Usuários/grupos válidos (vazio = grupo do share + admin)</label><input type="text" name="valid_users" id="esUsers"></div>
    <div class="form-row">
      <div class="form-group"><label>Somente leitura</label>
        <select name="read_only" id="esRO"><option value="no">Não</option><option value="yes">Sim</option></select></div>
      <div class="form-group"><label>Visível</label>
        <select name="browseable" id="esBrowse"><option value="yes">Sim</option><option value="no">Não</option></select></div>
    </div>
    <div class="modal-footer"><button type="button" class="btn" onclick="closeModal('mEditShare')">Cancelar</button>
    <button type="submit" class="btn btn-primary">Salvar</button></div>
  </form></div></div>
<form method="post" id="fDelShare" action="{{ url_for('share_delete') }}" style="display:none">
  <input type="hidden" name="name" id="delShareName">
</form>
<script>
window._nsPathEdited = false;
function nsAutoPath(inp) {
  if (window._nsPathEdited) return;
  var p = document.getElementById("nsPath");
  if (p) p.value = inp.value.trim() ? "/mnt/raid/shares/" + inp.value.trim() : "";
}
function closeModal(id) {
  var el = document.getElementById(id);
  if (el) el.classList.remove("open");
}
document.querySelectorAll(".modal-bg").forEach(function(m) {
  m.addEventListener("click", function(e) { if (e.target === m) m.classList.remove("open"); });
});
function toggleShareUsers(selId, grpId) {
  var sel = document.getElementById(selId), g = document.getElementById(grpId);
  if (sel && g) g.style.display = sel.value === "publico" ? "none" : "";
}
function openEditShare(btn) {
  var d = btn.dataset;
  function s(id, v) { var el = document.getElementById(id); if (el) el.value = v || ""; }
  s("esOrigName", d.name); s("esName", d.name); s("esPath", d.path);
  s("esComment", d.comment); s("esUsers", d.users);
  var ro = document.getElementById("esRO");
  if (ro) ro.value = d.ro === "yes" ? "yes" : "no";
  var br = document.getElementById("esBrowse");
  if (br) br.value = d.browse === "no" ? "no" : "yes";
  var ac = document.getElementById("esAcesso");
  if (ac) { ac.value = d.guest === "yes" ? "publico" : "restrito"; }
  toggleShareUsers("esAcesso", "esUsersGrp");
  var m = document.getElementById("mEditShare");
  if (m) m.classList.add("open");
}
function confirmDelShare(btn) {
  var name = btn.dataset.name;
  if (!confirm("Remover share: " + name + "?\\nA pasta no disco nao sera apagada.")) return;
  var inp = document.getElementById("delShareName");
  if (inp) inp.value = name;
  var f = document.getElementById("fDelShare");
  if (f) f.submit();
}
</script>
""")

# mapeamento share → grupo correto (casos onde nome != grupo)
SHARE_GROUP_MAP = {
    'Chefia_Turno_I':    'grp_chefia1',
    'Chefia_Turno_II':   'grp_chefia2',
    'Chefia_Turno_III':  'grp_chefia3',
    'Chefia_Turno_IV':   'grp_chefia4',
    'Conexao_Familiar':  'grp_conexao',
    'Infraestrutura':    'grp_infra',
    'Nucleo_de_Pessoal': 'grp_npessoal',
    'Portaria_Turno_I':  'grp_portaria1',
    'Portaria_Turno_II': 'grp_portaria2',
    'Portaria_Turno_III':'grp_portaria3',
    'Portaria_Turno_IV': 'grp_portaria4',
    'Rol_de_Visitas':    'grp_rol',
    'Diretoria_Geral':   'grp_dg',
}

def _share_group(name: str, existente: str = '') -> str:
    """Grupo dono do share: mapeamento fixo > valor existente > deriva do nome."""
    return SHARE_GROUP_MAP.get(name) or existente.lstrip('+').strip() \
        or ('grp_' + name.lower())

def _default_valid_users(name: str, force_group: str = '') -> str:
    """Acesso padrão de um share sem 'valid users' informado: só o grupo
    dele + admins. Sem essa linha o Samba aceitaria QUALQUER usuário
    autenticado. Garante que o grupo exista (senão o force group
    derrubaria a conexão de todo mundo)."""
    grp = _share_group(name, force_group)
    run(['sudo', '/usr/local/bin/cdpni-groupadd', '-f', grp])
    return f'@{grp} ' + ' '.join(sorted(ADMIN_USERS))

def _rebuild_smb_conf(shares: list[dict]) -> str:
    try:
        raw = open(SMB_CONF).read()
    except Exception:
        raw = '[global]\n   workgroup = WORKGROUP\n   server string = Samba Server\n'
    lines_out = []
    in_managed = False
    for line in raw.splitlines():
        stripped = line.strip()
        if stripped.startswith('[') and stripped.endswith(']'):
            name = stripped[1:-1]
            if name in ('global', 'homes', 'printers', 'print$'):
                in_managed = False
                lines_out.append(line)
            else:
                in_managed = True
        elif not in_managed:
            lines_out.append(line)
    result = '\n'.join(lines_out).rstrip() + '\n'
    # campos escritos explicitamente — os demais são preservados como estão
    EXPLICIT = {'name', 'comment', 'path', 'browseable', 'read_only', 'writable',
                'valid_users', 'create_mask', 'directory_mask', 'force_group',
                'force_create_mode', 'force_directory_mode', 'guest_ok'}
    for s in shares:
        result += f'\n[{s["name"]}]\n'
        if s.get('comment'):
            result += f'   comment = {s["comment"]}\n'
        result += f'   path = {s["path"]}\n'
        result += f'   browseable = {s.get("browseable","yes")}\n'
        result += f'   read only = {s.get("read_only","no")}\n'
        fg = _share_group(s['name'], s.get('force_group', ''))
        guest = s.get('guest_ok', 'no')
        result += f'   guest ok = {guest}\n'
        if s.get('valid_users'):
            result += f'   valid users = {s["valid_users"]}\n'
        elif guest != 'yes':
            # rede de segurança: share sem 'valid users' aceitaria qualquer
            # usuário autenticado — fecha no grupo dele + admins
            result += f'   valid users = @{fg} {" ".join(sorted(ADMIN_USERS))}\n'
        result += f'   force group = {fg}\n'
        result += f'   create mask = {s.get("create_mask","0664")}\n'
        result += f'   directory mask = {s.get("directory_mask","0775")}\n'
        result += f'   force create mode = {s.get("force_create_mode","0664")}\n'
        result += f'   force directory mode = {s.get("force_directory_mode","0777")}\n'
        # preserva outros campos extras do smb.conf original
        for k, v in s.items():
            if k in EXPLICIT:
                continue
            smb_key = k.replace('_', ' ')
            result += f'   {smb_key} = {v}\n'
    return result

def _write_smb_conf(content: str) -> tuple[bool, str]:
    rc, _, err = run(['sudo', 'tee', SMB_CONF], input_=content)
    return (rc == 0), err

@app.route('/admin/shares')
@admin_required
def shares_page():
    return render_template_string(SHARES_T, shares=parse_smb_shares(),
        smb_conf=SMB_CONF,
        session=session, banner=get_banner(), active='shares', is_admin=True)

@app.route('/admin/shares/create', methods=['POST'])
@admin_required
def share_create():
    name        = re.sub(r'[^\w\-]', '', request.form.get('name', '').strip())
    path        = request.form.get('path', '').strip()
    comment     = request.form.get('comment', '').strip()
    acesso      = request.form.get('acesso', 'restrito')
    valid_users = request.form.get('valid_users', '').strip()
    read_only   = request.form.get('read_only', 'no')
    browseable  = request.form.get('browseable', 'yes')
    create_dir  = request.form.get('create_dir', '1') == '1'
    if not name or not path:
        flash('Nome e caminho são obrigatórios', 'error')
        return redirect(url_for('shares_page'))
    # o force group exige que o grupo exista, mesmo em share público
    run(['sudo', '/usr/local/bin/cdpni-groupadd', '-f', _share_group(name)])
    if acesso == 'publico':
        valid_users = ''           # público (guest): sem lista de usuários
    elif not valid_users:
        # sem 'valid users' o share ficaria aberto a qualquer usuário
        # autenticado — o padrão é fechado: grupo do share + admins
        valid_users = _default_valid_users(name)
    if create_dir and not os.path.exists(path):
        run(['sudo', 'mkdir', '-p', path])
        # mesmo padrão dos shares do playbook: 0777 + grupo do share
        # (quem barra estranhos é o valid users, na camada SMB)
        run(['sudo', 'chmod', '0777', path])
        run(['sudo', 'chown', f'root:{_share_group(name)}', path])
    shares = parse_smb_shares()
    if any(s['name'] == name for s in shares):
        flash(f'Share "{name}" já existe', 'error')
        return redirect(url_for('shares_page'))
    novo = {'name': name, 'path': path, 'comment': comment,
            'valid_users': valid_users, 'read_only': read_only,
            'browseable': browseable, 'create_mask': '0664',
            'directory_mask': '0775', 'guest_ok': 'no'}
    if acesso == 'publico':
        novo['guest_ok'] = 'yes'
        novo['public'] = 'yes'
    shares.append(novo)
    ok, err = _write_smb_conf(_rebuild_smb_conf(shares))
    if not ok:
        flash(f'Erro ao salvar smb.conf: {err}', 'error')
    else:
        run(['sudo', 'smbcontrol', 'smbd', 'reload-config'])
        flash(f'Share "{name}" criado', 'success')
    return redirect(url_for('shares_page'))

@app.route('/admin/shares/edit', methods=['POST'])
@admin_required
def share_edit():
    orig_name   = re.sub(r'[^\w\-]', '', request.form.get('original_name', '').strip())
    name        = re.sub(r'[^\w\-]', '', request.form.get('name', '').strip())
    path        = request.form.get('path', '').strip()
    comment     = request.form.get('comment', '').strip()
    acesso      = request.form.get('acesso', 'restrito')
    valid_users = request.form.get('valid_users', '').strip()
    read_only   = request.form.get('read_only', 'no')
    browseable  = request.form.get('browseable', 'yes')
    if not name or not path:
        flash('Nome e caminho são obrigatórios', 'error')
        return redirect(url_for('shares_page'))
    shares = parse_smb_shares()
    updated = []
    found = False
    for s in shares:
        if s['name'] == orig_name:
            found = True
            if acesso == 'publico':
                s['guest_ok'] = 'yes'
                s['public'] = 'yes'
                valid_users = ''   # público (guest): sem lista de usuários
            else:
                s['guest_ok'] = 'no'
                s.pop('public', None)
                # campo vazio não pode abrir o share para todo mundo —
                # aplica o padrão fechado (grupo do share + admins)
                if not valid_users:
                    valid_users = _default_valid_users(name, s.get('force_group', ''))
            s.update({'name': name, 'path': path, 'comment': comment,
                      'valid_users': valid_users, 'read_only': read_only, 'browseable': browseable})
        updated.append(s)
    if not found:
        flash(f'Share "{orig_name}" não encontrado', 'error')
        return redirect(url_for('shares_page'))
    ok, err = _write_smb_conf(_rebuild_smb_conf(updated))
    if not ok:
        flash(f'Erro ao salvar smb.conf: {err}', 'error')
    else:
        run(['sudo', 'smbcontrol', 'smbd', 'reload-config'])
        flash(f'Share "{name}" atualizado', 'success')
    return redirect(url_for('shares_page'))

@app.route('/admin/shares/delete', methods=['POST'])
@admin_required
def share_delete():
    name = re.sub(r'[^\w\-]', '', request.form.get('name', '').strip())
    shares = [s for s in parse_smb_shares() if s['name'] != name]
    ok, err = _write_smb_conf(_rebuild_smb_conf(shares))
    if not ok:
        flash(f'Erro ao salvar smb.conf: {err}', 'error')
    else:
        run(['sudo', 'smbcontrol', 'smbd', 'reload-config'])
        flash(f'Share "{name}" removido', 'success')
    return redirect(url_for('shares_page'))

@app.route('/admin/shares/reload', methods=['POST'])
@admin_required
def shares_reload():
    rc, _, err = run(['sudo', 'systemctl', 'reload', 'smbd'])
    if rc != 0:
        flash(f'Erro ao recarregar smbd: {err}', 'error')
    else:
        flash('smbd recarregado', 'success')
    return redirect(url_for('shares_page'))

@app.route('/admin/shares/testparm')
@admin_required
def shares_testparm():
    rc, out, err = run(['sudo', 'testparm', '-s'])
    output = out + ('\n' + err if err else '')
    return render_template_string(BASE_T.replace("__BODY__", """
<div class="page-title">🔍 testparm <a href="{{ url_for('shares_page') }}" class="btn btn-sm" style="margin-left:.75rem">← Voltar</a></div>
<pre class="log-box">{{ output }}</pre>
"""), output=output,
        session=session, banner=get_banner(), active='shares', is_admin=True)

# ── raid / discos ──────────────────────────────────────────────────────────────
RAID_T = BASE_T.replace("__BODY__", """
<div class="page-title">💾 RAID / Discos</div>

{% if saude and saude.array %}
<div class="card">
  <div class="card-header"><h3>❤️ Saúde do RAID — {{ saude.array.device }}</h3></div>
  <div class="card-body">
    <div style="display:flex;align-items:center;gap:.6rem;flex-wrap:wrap;margin-bottom:.6rem">
      {% if saude.array.acao %}
        <span class="badge badge-warn">{{ 'Expandindo' if saude.array.acao == 'reshape' else 'Reconstruindo' }} {{ saude.array.progresso }}%</span>
      {% elif saude.array.saudavel %}
        <span class="badge badge-ok">Saudável</span>
      {% else %}
        <span class="badge badge-err">DEGRADADO</span>
      {% endif %}
      <span class="badge badge-info">{{ saude.array.level }}</span>
      <span class="text-muted" style="font-size:.78rem">{{ saude.array.ativos }}/{{ saude.array.total }} discos ativos</span>
      {% if saude.array.spares != '0' %}<span class="badge badge-info">{{ saude.array.spares }} spare</span>{% endif %}
      {% if saude.array.falhos != '0' %}<span class="badge badge-err">{{ saude.array.falhos }} com falha</span>{% endif %}
      {% if saude.array.tamanho %}<span class="text-muted" style="font-size:.78rem">· {{ saude.array.tamanho }}</span>{% endif %}
    </div>
    {% if saude.array.acao %}
    <div style="display:flex;align-items:center;gap:.5rem;margin-bottom:.6rem">
      <div class="progress" style="flex:1"><div class="progress-bar warn" style="width:{{ saude.array.progresso or 0 }}%"></div></div>
      <span class="text-muted" style="font-size:.76rem">{{ saude.array.termino }}</span>
    </div>
    {% endif %}
    {% if saude.growfs_pendente and not saude.array.acao %}
    <p class="text-muted" style="font-size:.78rem">⏳ Expansão do filesystem pendente — será concluída na próxima verificação automática (a cada hora).</p>
    {% elif saude.growfs_pendente %}
    <p class="text-muted" style="font-size:.78rem">⏳ Ao fim do reshape, o filesystem será expandido automaticamente.</p>
    {% endif %}
    <table>
      <thead><tr><th>Disco</th><th>Papel no array</th><th>SMART</th><th>Temp</th><th>Horas ligado</th><th>Setores realocados</th><th>Pendentes</th></tr></thead>
      <tbody>
      {% for d in saude.discos %}
      <tr>
        <td style="font-family:var(--mono);font-size:.78rem">{{ d.dev }}</td>
        <td style="font-size:.78rem">{{ d.papel }}</td>
        <td>
          {% if d.smart == 'ok' %}<span class="badge badge-ok">OK</span>
          {% elif d.smart == 'atencao' %}<span class="badge badge-warn">Atenção</span>
          {% elif d.smart == 'falha' %}<span class="badge badge-err">FALHA</span>
          {% else %}<span class="badge badge-info">—</span>{% endif %}
        </td>
        <td style="font-size:.78rem">{{ d.temp ~ '°C' if d.temp is not none else '—' }}</td>
        <td style="font-size:.78rem">{{ d.horas if d.horas is not none else '—' }}</td>
        <td style="font-size:.78rem">{{ d.realocados if d.realocados is not none else '—' }}</td>
        <td style="font-size:.78rem">{{ d.pendentes if d.pendentes is not none else '—' }}</td>
      </tr>
      {% endfor %}
      </tbody>
    </table>
  </div>
</div>
{% elif saude and saude.modo == 'disco_unico' %}
<div class="card">
  <div class="card-header"><h3>❤️ Disco de dados — modo disco único</h3></div>
  <div class="card-body">
    <p style="font-size:.8rem;margin-bottom:.6rem">
      <span class="badge badge-warn">Sem RAID</span>
      <span class="text-muted" style="font-size:.78rem">
        Uma falha deste disco perde os dados — mantenha os backups em dia.
        Para ganhar tolerância a falhas, instale mais discos e reinstale o
        armazenamento com RAID.
      </span>
    </p>
    <table>
      <thead><tr><th>Disco</th><th>Papel</th><th>SMART</th><th>Temp</th><th>Horas ligado</th><th>Setores realocados</th><th>Pendentes</th></tr></thead>
      <tbody>
      {% for d in saude.discos %}
      <tr>
        <td style="font-family:var(--mono);font-size:.78rem">{{ d.dev }}</td>
        <td style="font-size:.78rem">{{ d.papel }}</td>
        <td>
          {% if d.smart == 'ok' %}<span class="badge badge-ok">OK</span>
          {% elif d.smart == 'atencao' %}<span class="badge badge-warn">Atenção</span>
          {% elif d.smart == 'falha' %}<span class="badge badge-err">FALHA</span>
          {% else %}<span class="badge badge-info">—</span>{% endif %}
        </td>
        <td style="font-size:.78rem">{{ d.temp ~ '°C' if d.temp is not none else '—' }}</td>
        <td style="font-size:.78rem">{{ d.horas if d.horas is not none else '—' }}</td>
        <td style="font-size:.78rem">{{ d.realocados if d.realocados is not none else '—' }}</td>
        <td style="font-size:.78rem">{{ d.pendentes if d.pendentes is not none else '—' }}</td>
      </tr>
      {% endfor %}
      </tbody>
    </table>
  </div>
</div>
{% endif %}

{% if candidatos %}
<div class="card">
  <div class="card-header"><h3>🆕 Discos novos detectados</h3></div>
  <div class="card-body">
    <p class="text-muted" style="font-size:.78rem;margin-bottom:.6rem">
      Discos fora do RAID e sem uso pelo sistema. <strong>Todo o conteúdo do disco
      escolhido será apagado</strong> ao adicioná-lo.
    </p>
    <table>
      <thead><tr><th>Disco</th><th>Tamanho</th><th>Modelo</th><th>Conteúdo</th><th class="text-right">Ações</th></tr></thead>
      <tbody>
      {% for c in candidatos %}
      <tr>
        <td style="font-family:var(--mono);font-size:.78rem">{{ c.dev }}</td>
        <td>{{ c.tamanho }}</td>
        <td style="font-size:.78rem">{{ c.modelo }}</td>
        <td>{% if c.tem_dados %}<span class="badge badge-warn">Tem dados</span>{% else %}<span class="badge badge-ok">Vazio</span>{% endif %}</td>
        <td class="text-right" style="white-space:nowrap">
          <form method="post" action="{{ url_for('raid_adicionar') }}" style="display:inline"
                onsubmit="return confirm('Adicionar {{ c.dev }} como HOT SPARE?\\n\\nO disco fica de reserva e assume automaticamente se um disco do RAID falhar.\\nTODOS os dados de {{ c.dev }} serão apagados.')">
            <input type="hidden" name="disk" value="{{ c.dev }}">
            <input type="hidden" name="modo" value="spare">
            <button type="submit" class="btn btn-xs">🛟 Hot spare</button>
          </form>
          <form method="post" action="{{ url_for('raid_adicionar') }}" style="display:inline"
                onsubmit="return confirm('EXPANDIR o RAID com {{ c.dev }}?\\n\\nO array será redistribuído (reshape) — leva HORAS e não deve ser interrompido por queda de energia.\\nO espaço extra aparece automaticamente ao final.\\nTODOS os dados de {{ c.dev }} serão apagados.')">
            <input type="hidden" name="disk" value="{{ c.dev }}">
            <input type="hidden" name="modo" value="expandir">
            <button type="submit" class="btn btn-xs">📈 Expandir capacidade</button>
          </form>
        </td>
      </tr>
      {% endfor %}
      </tbody>
    </table>
  </div>
</div>
{% endif %}

<div class="card">
  <div class="card-header"><h3>Arrays RAID — /proc/mdstat</h3></div>
  <div class="card-body">
  {% if raid.arrays %}
    {% for a in raid.arrays %}
    <div style="margin-bottom:.75rem;padding:.75rem;background:var(--bg3);border-radius:6px;border:1px solid var(--border)">
      <div style="display:flex;align-items:center;gap:.75rem;margin-bottom:.25rem">
        <strong style="font-family:var(--mono)">{{ a.name }}</strong>
        <span class="badge {{ 'badge-ok' if a.health == 'ok' else 'badge-err' }}">{{ 'Saudável' if a.health == 'ok' else 'DEGRADADO' }}</span>
        <span class="badge badge-info">{{ a.level }}</span>
        <span class="text-muted" style="font-size:.76rem">{{ a.status }}</span>
        {% if a.progress %}<span class="text-muted" style="font-size:.76rem">{{ a.progress }}</span>{% endif %}
      </div>
      <div class="text-muted" style="font-size:.76rem;font-family:var(--mono)">{{ a.devices }}</div>
    </div>
    {% endfor %}
  {% else %}
    <p class="text-muted" style="font-size:.82rem">Nenhum array RAID detectado</p>
  {% endif %}
  </div>
</div>
<div class="card">
  <div class="card-header"><h3>💽 Discos e Partições</h3></div>
  <table>
    <thead><tr><th>Dispositivo</th><th>Tamanho</th><th>Usado</th><th>Livre</th><th>%</th><th>Ponto</th><th class="text-right">SMART</th></tr></thead>
    <tbody>
    {% for d in disks %}
    <tr>
      <td style="font-family:var(--mono);font-size:.76rem">{{ d.source }}</td>
      <td>{{ d.size }}</td><td>{{ d.used }}</td><td>{{ d.avail }}</td>
      <td>
        <div style="display:flex;align-items:center;gap:.4rem">
          <div class="progress" style="width:55px"><div class="progress-bar {{ 'err' if d.pct|int > 85 else ('warn' if d.pct|int > 65 else '') }}" style="width:{{ d.pct }}%"></div></div>
          {{ d.pct }}%
        </div>
      </td>
      <td class="text-muted">{{ d.mount }}</td>
      <td class="text-right">
        <form method="post" action="{{ url_for('raid_smart') }}" style="display:inline">
          <input type="hidden" name="disk" value="{{ d.source }}">
          <button type="submit" class="btn btn-xs">🔬</button>
        </form>
      </td>
    </tr>
    {% endfor %}
    </tbody>
  </table>
</div>
{% if smart_output %}
<div class="card">
  <div class="card-header"><h3>🔬 SMART — {{ smart_disk }}</h3></div>
  <pre class="log-box">{{ smart_output }}</pre>
</div>
{% endif %}
<div class="card">
  <div class="card-header"><h3>/proc/mdstat (bruto)</h3></div>
  <pre class="log-box" style="max-height:150px">{{ raid.raw }}</pre>
</div>
""")

@app.route('/admin/raid')
@admin_required
def raid_page():
    return render_template_string(RAID_T,
        raid=get_mdstat(), disks=get_disk_usage(), smart_output='', smart_disk='',
        saude=get_raid_saude(), candidatos=get_raid_candidatos(),
        session=session, banner=get_banner(), active='raid', is_admin=True)

@app.route('/admin/raid/adicionar', methods=['POST'])
@admin_required
def raid_adicionar():
    disk = request.form.get('disk', '').strip()
    modo = request.form.get('modo', '')
    if not re.match(r'^/dev/(sd[a-z]+|vd[a-z]+|nvme\d+n\d+)$', disk) or modo not in ('spare', 'expandir'):
        flash('Requisição inválida', 'error')
        return redirect(url_for('raid_page'))
    cmd = 'add-spare' if modo == 'spare' else 'expandir'
    rc, out, err = run(['sudo', '/usr/local/bin/cdpni-raid', cmd, disk])
    flash(out or err or 'Sem resposta do comando', 'success' if rc == 0 else 'error')
    return redirect(url_for('raid_page'))

@app.route('/admin/raid/smart', methods=['POST'])
@admin_required
def raid_smart():
    disk = request.form.get('disk', '').strip()
    smart_output = ''
    smart_disk = disk
    if not disk or not re.match(r'^/dev/[\w]+$', disk):
        smart_output = 'Dispositivo inválido'
    elif re.match(r'^/dev/md\d*$', disk):
        # Dispositivo RAID virtual — executa SMART em cada disco membro
        members = []
        try:
            with open('/proc/mdstat') as f:
                for line in f:
                    if line.startswith('md') and 'active' in line:
                        members = re.findall(r'(sd[a-z]+)\[\d+\]', line)
        except Exception:
            pass
        if not members:
            smart_output = 'Não foi possível identificar os discos membros do RAID.'
        else:
            parts = []
            for m in members:
                dev = f'/dev/{m}'
                rc, out, err = run(['sudo', '/usr/local/bin/cdpni-smart', dev])
                output = out or err or 'Sem saída'
                if 'No Information Found' in output or 'Operation not permitted' in output:
                    output = f'SMART não disponível para {dev}.\nA controladora ou camada de virtualização não expõe dados SMART diretamente.'
                parts.append(f'=== {dev} ===\n{output}')
            smart_output = '\n\n'.join(parts)
    else:
        base_disk = re.sub(r'\d+$', '', disk)
        rc, out, err = run(['sudo', '/usr/local/bin/cdpni-smart', base_disk])
        output = out or err or 'Sem saída'
        if 'No Information Found' in output or 'Operation not permitted' in output:
            smart_output = f'SMART não disponível para {base_disk}.\nA controladora ou camada de virtualização não expõe dados SMART diretamente.'
        else:
            smart_output = output
    return render_template_string(RAID_T,
        raid=get_mdstat(), disks=get_disk_usage(),
        smart_output=smart_output, smart_disk=smart_disk,
        saude=get_raid_saude(), candidatos=get_raid_candidatos(),
        session=session, banner=get_banner(), active='raid', is_admin=True)

# ── backups ────────────────────────────────────────────────────────────────────
BACKUPS_T = BASE_T.replace("__BODY__", r"""
<div class="page-title">🗄️ Backups</div>
{% if backup_running %}
<div class="card" style="margin-bottom:1rem;border:2px solid var(--accent)">
  <div class="card-header" style="background:var(--accent);color:#fff;display:flex;align-items:center;gap:.5rem">
    <span style="animation:spin 1s linear infinite;display:inline-block">⏳</span>
    <h3 style="color:#fff">Backup em Andamento</h3>
  </div>
  <div class="card-body">
    <div style="margin-bottom:.75rem">
      <span id="bkSize" style="font-family:var(--mono);font-size:1.1rem;font-weight:600">--</span>
      <span class="text-muted" style="font-size:.82rem"> gravados &nbsp;·&nbsp; <span id="bkElapsed">0s</span> decorridos</span>
    </div>
    <div style="background:var(--border);border-radius:4px;height:10px;overflow:hidden;margin-bottom:1rem">
      <div id="bkBar" style="height:100%;background:var(--accent);width:5%;transition:width .8s ease;border-radius:4px"></div>
    </div>
    <form method="post" action="{{ url_for('backup_cancel') }}" onsubmit="return confirm('Cancelar o backup em andamento? O arquivo parcial sera removido.')">
      <button type="submit" class="btn" style="background:#c0392b;color:#fff;font-size:.82rem">✖ Cancelar Backup</button>
    </form>
  </div>
</div>
{% endif %}
{% if backup_log and not backup_running %}
<div class="card" style="margin-bottom:1rem">
  <div class="card-header"><h3>📜 Última execução de backup em rede (log)</h3></div>
  <pre class="log-box" style="max-height:170px">{{ backup_log }}</pre>
</div>
{% endif %}
<div class="card" style="margin-bottom:1rem">
  <div class="card-header"><h3>Novo Backup</h3></div>
  <div class="card-body">
    <form method="post" action="{{ url_for('backup_run') }}" onsubmit="this.querySelector('[type=submit]').disabled=true;this.querySelector('[type=submit]').textContent='Aguarde...'">
      <div class="form-group">
        <label>Tipo de destino</label>
        <div style="display:flex;gap:1.5rem;margin-top:.25rem">
          <label style="font-weight:400;font-size:.83rem"><input type="radio" name="dest_type" value="local" checked onchange="toggleDest(this.value)"> Local (no servidor)</label>
          <label style="font-weight:400;font-size:.83rem"><input type="radio" name="dest_type" value="smb" onchange="toggleDest(this.value)"> Rede Windows (SMB)</label>
        </div>
      </div>
      <div id="dest-local" class="form-group">
        <label>Caminho local</label>
        <input type="text" name="backup_dest" value="{{ backup_dir }}" style="width:100%;font-family:var(--mono);font-size:.82rem" placeholder="/mnt/raid/backups">
        <small class="text-muted">Caminho absoluto no servidor</small>
      </div>
      <div id="dest-smb" style="display:none">
        <div style="display:grid;grid-template-columns:1fr 1fr;gap:.5rem">
          <div class="form-group">
            <label>IP / nome do computador</label>
            <input type="text" id="smbHost" name="smb_host" placeholder="Cadastro-129" style="width:100%;font-family:var(--mono);font-size:.82rem">
          </div>
          <div class="form-group">
            <label>Nome do compartilhamento</label>
            <input type="text" id="smbShare" name="smb_share" placeholder="d" style="width:100%;font-family:var(--mono);font-size:.82rem">
          </div>
          <div class="form-group">
            <label>Usuário Windows</label>
            <input type="text" id="smbUser" name="smb_user" placeholder="seu_usuario" style="width:100%;font-family:var(--mono);font-size:.82rem">
          </div>
          <div class="form-group">
            <label>Senha Windows</label>
            <input type="password" id="smbPass" name="smb_pass" placeholder="••••••" style="width:100%;font-family:var(--mono);font-size:.82rem">
          </div>
        </div>
        <div class="form-group" style="margin-top:.25rem">
          <label>Pasta de destino no compartilhamento</label>
          <div style="display:flex;gap:.5rem;align-items:center">
            <input type="text" id="smbSub" name="smb_sub" placeholder="Backups\Servidor (opcional)"
                   style="flex:1;font-family:var(--mono);font-size:.82rem">
            <button type="button" class="btn" onclick="smbBrowse('')" style="white-space:nowrap">
              📂 Navegar
            </button>
          </div>
          <small class="text-muted" id="smbPreview"></small>
        </div>
      </div>
      <div class="form-group" style="margin-top:.5rem">
        <label>Incluir no backup</label>
        <div style="display:flex;flex-wrap:wrap;gap:.5rem .75rem;margin-top:.25rem">
          <label style="font-weight:400;font-size:.83rem"><input type="checkbox" name="inc_shares" value="1" checked> Compartilhamentos (<code>{{ samba_root }}</code>)</label>
          <label style="font-weight:400;font-size:.83rem"><input type="checkbox" name="inc_samba"  value="1" checked> Configuração Samba (<code>/etc/samba</code>)</label>
          <label style="font-weight:400;font-size:.83rem"><input type="checkbox" name="inc_users"  value="1" checked> Usuários/Grupos (<code>/etc/passwd, shadow, group</code>)</label>
          <label style="font-weight:400;font-size:.83rem"><input type="checkbox" name="inc_portal" value="1" checked> Portal (<code>/opt/cdpni-portal</code>)</label>
        </div>
      </div>
      <button type="submit" class="btn btn-primary">▶ Executar Backup</button>
    </form>
  </div>
</div>
<script>
function toggleDest(v) {
  document.getElementById("dest-local").style.display = v === "local" ? "" : "none";
  document.getElementById("dest-smb").style.display   = v === "smb"   ? "" : "none";
  updateSmbPreview();
}
function updateSmbPreview() {
  var host  = (document.getElementById("smbHost")  || {value:""}).value;
  var share = (document.getElementById("smbShare") || {value:""}).value;
  var sub   = (document.getElementById("smbSub")   || {value:""}).value;
  var p = document.getElementById("smbPreview");
  if (!p) return;
  p.textContent = (host && share)
    ? "Destino: //" + host + "/" + share + (sub ? "/" + sub.replace(/\\/g, "/") : "") + "/"
    : "";
}
["smbHost","smbShare","smbSub"].forEach(function(id) {
  var el = document.getElementById(id);
  if (el) el.addEventListener("input", updateSmbPreview);
});
(function() {
  var sel = document.querySelector("input[name='dest_type']:checked");
  if (sel) toggleDest(sel.value);
})();
function smbBrowse(path) {
  var host  = document.getElementById("smbHost").value.trim();
  var share = document.getElementById("smbShare").value.trim();
  var user  = document.getElementById("smbUser").value.trim();
  var pass  = document.getElementById("smbPass").value;
  if (!host || !share) { alert("Preencha o IP e o nome do compartilhamento primeiro."); return; }
  document.getElementById("mSmbBrowser").classList.add("open");
  smbLoadDir(host, share, user, pass, path);
}
function smbLoadDir(host, share, user, pass, path) {
  var body = document.getElementById("smbDirBody");
  body.innerHTML = "";
  var loading = document.createElement("tr");
  loading.innerHTML = "<td colspan='2' class='text-muted'>Carregando...</td>";
  body.appendChild(loading);
  document.getElementById("smbCurrentPath").value = path || "";
  fetch("{{ url_for('backup_browse') }}", {
    method: "POST",
    headers: {"Content-Type": "application/json"},
    body: JSON.stringify({host:host, share:share, user:user, pass:pass, path:path||""})
  })
  .then(function(r) { return r.json(); })
  .then(function(d) {
    var bread = document.getElementById("smbBreadcrumb");
    if (bread) {
      bread.innerHTML = "";
      var root = document.createElement("span");
      root.style.cursor = "pointer";
      root.className = "text-muted";
      root.textContent = "\\\\" + host + "\\" + share;
      root.onclick = function() { smbLoadDir(host, share, user, pass, ""); };
      bread.appendChild(root);
      var parts = path ? path.split("\\").filter(Boolean) : [];
      var acc = "";
      parts.forEach(function(part) {
        acc = acc ? acc + "\\" + part : part;
        var sep = document.createTextNode(" \\ ");
        bread.appendChild(sep);
        var sp = document.createElement("span");
        sp.style.cursor = "pointer";
        sp.textContent = part;
        (function(p) { sp.onclick = function() { smbLoadDir(host, share, user, pass, p); }; })(acc);
        bread.appendChild(sp);
      });
    }
    body.innerHTML = "";
    if (d.error) {
      var tr = document.createElement("tr");
      tr.innerHTML = "<td colspan='2' style='color:#c0392b'>" + d.error + "</td>";
      body.appendChild(tr); return;
    }
    if (path) {
      var up = document.createElement("tr");
      var td = document.createElement("td");
      td.textContent = "📁 ..";
      td.style.cursor = "pointer";
      var par = path.split("\\").slice(0,-1).join("\\");
      (function(p) { td.onclick = function() { smbLoadDir(host, share, user, pass, p); }; })(par);
      up.appendChild(td);
      up.appendChild(document.createElement("td"));
      body.appendChild(up);
    }
    (d.dirs || []).forEach(function(dir) {
      var full = path ? path + "\\" + dir : dir;
      var tr = document.createElement("tr");
      var td1 = document.createElement("td");
      td1.textContent = "📁 " + dir;
      td1.style.cursor = "pointer";
      (function(f) { td1.onclick = function() { smbLoadDir(host, share, user, pass, f); }; })(full);
      var td2 = document.createElement("td");
      var btn = document.createElement("button");
      btn.type = "button";
      btn.className = "btn btn-xs btn-primary";
      btn.textContent = "Selecionar";
      (function(f) { btn.onclick = function() { smbSelect(f); }; })(full);
      td2.appendChild(btn);
      tr.appendChild(td1); tr.appendChild(td2);
      body.appendChild(tr);
    });
    if (!body.hasChildNodes()) {
      var empty = document.createElement("tr");
      empty.innerHTML = "<td colspan='2' class='text-muted'>Pasta vazia</td>";
      body.appendChild(empty);
    }
  })
  .catch(function(e) {
    body.innerHTML = "";
    var tr = document.createElement("tr");
    tr.innerHTML = "<td colspan='2' style='color:#c0392b'>Erro: " + e + "</td>";
    body.appendChild(tr);
  });
}
function smbSelect(path) {
  document.getElementById("smbSub").value = path;
  document.getElementById("mSmbBrowser").classList.remove("open");
  updateSmbPreview();
}
function smbSelectCurrent() {
  smbSelect(document.getElementById("smbCurrentPath").value || "");
}
</script>
<div class="modal-bg" id="mSmbBrowser">
  <div class="modal" style="min-width:520px;max-width:680px">
    <div class="modal-title">
      <h3>📂 Navegar no Compartilhamento Windows</h3>
      <button type="button" class="modal-close" onclick="closeModal('mSmbBrowser')">&times;</button>
    </div>
    <div style="padding:.75rem 1rem .5rem;font-family:var(--mono);font-size:.8rem;background:var(--bg3);border-bottom:1px solid var(--border)">
      <span id="smbBreadcrumb" class="text-muted">—</span>
    </div>
    <input type="hidden" id="smbCurrentPath" value="">
    <div style="max-height:340px;overflow-y:auto">
      <table style="width:100%">
        <tbody id="smbDirBody">
          <tr><td class="text-muted">Clique em Navegar para carregar.</td></tr>
        </tbody>
      </table>
    </div>
    <div class="modal-footer">
      <button type="button" class="btn" onclick="closeModal('mSmbBrowser')">Fechar</button>
      <button type="button" class="btn btn-primary" onclick="smbSelectCurrent()">
        Usar esta pasta
      </button>
    </div>
  </div>
</div>
<div class="card">
  <div class="card-header"><h3>Histórico de Backups</h3><span class="text-muted" style="font-size:.76rem">{{ backups|length }} arquivos</span></div>
  {% if backups %}
  <table>
    <thead><tr><th>Arquivo</th><th>Data</th><th>Tamanho</th><th class="text-right">Ação</th></tr></thead>
    <tbody>
    {% for b in backups %}
    <tr>
      <td style="font-family:var(--mono);font-size:.74rem">{{ b.name }}</td>
      <td class="text-muted">{{ b.date }}</td>
      <td class="text-muted">{{ b.size }}</td>
      <td class="text-right">
        <a href="{{ url_for('backup_download', filename=b.name) }}" class="btn btn-xs">⬇</a>
        <button class="btn btn-xs btn-danger" onclick="confirmDelBackup('{{ b.name }}')">🗑</button>
      </td>
    </tr>
    {% endfor %}
    </tbody>
  </table>
  {% else %}
  <div class="card-body text-muted" style="font-size:.82rem">Nenhum backup em {{ backup_dir }}</div>
  {% endif %}
</div>
<form method="post" id="fDelBackup" action="{{ url_for('backup_delete') }}" style="display:none">
  <input type="hidden" name="filename" id="delBackupName">
</form>
<script>
function confirmDelBackup(n) {
  if (!confirm("Excluir " + n + "?")) return;
  document.getElementById("delBackupName").value = n;
  document.getElementById("fDelBackup").submit();
}
(function() {
  var running = {{ "true" if backup_running else "false" }};
  if (!running) return;
  var timer = null;
  function fmtTime(s) {
    if (s < 60) return s + "s";
    return Math.floor(s / 60) + "m " + (s % 60) + "s";
  }
  function poll() {
    fetch("{{ url_for('backup_status') }}")
      .then(function(r) { return r.json(); })
      .then(function(d) {
        if (d.running) {
          var sz = document.getElementById("bkSize");
          var el = document.getElementById("bkElapsed");
          var bar = document.getElementById("bkBar");
          if (sz) sz.textContent = d.size_fmt;
          if (el) el.textContent = fmtTime(d.elapsed);
          if (bar) bar.style.width = Math.min(90, 5 + (d.elapsed / 180) * 85) + "%";
        } else {
          clearInterval(timer);
          window.location.reload();
        }
      })
      .catch(function() {});
  }
  poll();
  timer = setInterval(poll, 2000);
})();
</script>
""")

@app.route('/admin/backups')
@admin_required
def backups_page():
    running, bk_info = backup_running()
    backup_log = ''
    if os.path.exists('/var/log/cdpni_backup.log'):
        _, saida, _ = run(['sudo', 'tail', '-n40', '/var/log/cdpni_backup.log'])
        # mostra apenas a ÚLTIMA execução (blocos separados por "=== data ===")
        blocos = re.split(r'(?=^=== )', saida, flags=re.M)
        backup_log = blocos[-1].strip() if blocos else saida
    return render_template_string(BACKUPS_T,
        backups=get_backups(), backup_dir=BACKUP_DIR, samba_root=SAMBA_ROOT,
        backup_running=running, bk_info=bk_info, backup_log=backup_log,
        session=session, banner=get_banner(), active='backups', is_admin=True)

def smb_erro_amigavel(saida: str) -> str:
    """Traduz os NT_STATUS do smbclient para mensagens acionáveis."""
    mapa = {
        'NT_STATUS_BAD_NETWORK_NAME':  'O compartilhamento não existe nessa máquina. '
                                       'No Windows: botão direito na pasta → Propriedades → '
                                       'Compartilhamento → Compartilhamento Avançado.',
        'NT_STATUS_LOGON_FAILURE':     'Usuário ou senha do Windows incorretos.',
        'NT_STATUS_ACCESS_DENIED':     'Acesso negado: o usuário informado não tem permissão '
                                       'no compartilhamento.',
        'NT_STATUS_HOST_UNREACHABLE':  'Máquina inacessível na rede.',
        'NT_STATUS_IO_TIMEOUT':        'A máquina não respondeu (firewall do Windows?).',
        'NT_STATUS_CONNECTION_REFUSED':'Conexão recusada — compartilhamento de arquivos '
                                       'desativado ou firewall bloqueando a porta 445.',
        'NT_STATUS_UNSUCCESSFUL':      'Falha ao conectar — confira IP/nome da máquina.',
        'NT_STATUS_NOT_FOUND':         'Máquina não encontrada — confira o IP/nome.',
    }
    for chave, msg in mapa.items():
        if chave in saida:
            return msg
    return saida.strip() or 'Falha ao conectar.'

@app.route('/admin/backups/browse', methods=['POST'])
@admin_required
def backup_browse():
    import re as _re
    data  = request.get_json(force=True) or {}
    host  = data.get('host', '').strip()
    share = data.get('share', '').strip()
    user  = data.get('user', '').strip()
    pwd   = data.get('pass', '')
    path  = data.get('path', '').strip().strip('\\').strip('/')
    if not host or not share:
        return jsonify({'error': 'Informe host e compartilhamento'}), 400
    smb_path = (path.replace('/', '\\') + '\\*') if path else '*'
    rc, out, err = run(['smbclient', f'//{host}/{share}',
                        '-U', f'{user}%{pwd}', '-c', f'ls {smb_path}'])
    if rc != 0:
        return jsonify({'error': smb_erro_amigavel(err or out)})
    dirs = []
    for line in out.splitlines():
        m = _re.match(r'^  (.+?)\s{2,}([A-Z]+)\s+\d', line)
        if m:
            name, attrs = m.group(1).rstrip(), m.group(2)
            if 'D' in attrs and name not in ('.', '..'):
                dirs.append(name)
    return jsonify({'dirs': sorted(dirs), 'path': path})

@app.route('/admin/backups/status')
@admin_required
def backup_status():
    running, info = backup_running()
    size = 0
    f = info.get('file', '')
    if f and os.path.exists(f):
        size = os.path.getsize(f)
    elapsed = int(time.time() - info['started']) if info.get('started') else 0
    is_smb = info.get('type') == 'smb'
    return jsonify({'running': running, 'size': size,
                    'size_fmt': 'Enviando via rede...' if is_smb else fmt_size(size),
                    'elapsed': elapsed, 'is_smb': is_smb,
                    'filename': info.get('filename', '')})

@app.route('/admin/backups/cancel', methods=['POST'])
@admin_required
def backup_cancel():
    try:
        _, info = backup_running()
        pgid = info.get('pgid')
        if pgid and pgid != os.getpgrp():
            run(['sudo', 'kill', '-TERM', f'-{pgid}'])
        else:
            pid = info.get('pid')
            if pid:
                run(['sudo', 'kill', '-TERM', str(pid)])
        out_file = info.get('file', '')
        if out_file and os.path.exists(out_file):
            try:
                os.remove(out_file)
            except Exception:
                pass
        if os.path.exists(BACKUP_INFO_FILE):
            os.remove(BACKUP_INFO_FILE)
        flash('Backup cancelado.', 'warning')
    except Exception as e:
        flash(f'Erro ao cancelar: {e}', 'error')
    return redirect(url_for('backups_page'))

@app.route('/admin/backups/run', methods=['GET', 'POST'])
@admin_required
def backup_run():
    try:
        tar = '/usr/bin/tar' if os.path.exists('/usr/bin/tar') else '/bin/tar'
        timestamp = datetime.now().strftime('%Y%m%d_%H%M%S')
        filename  = f'backup_{timestamp}.tar.gz'

        targets = []
        if request.form.get('inc_shares'): targets.append(SAMBA_ROOT)
        if request.form.get('inc_samba'):  targets.append('/etc/samba')
        if request.form.get('inc_users'):  targets += ['/etc/passwd', '/etc/shadow', '/etc/group']
        if request.form.get('inc_portal'): targets.append('/opt/cdpni-portal')
        if not targets:
            flash('Selecione ao menos um item para incluir no backup.', 'error')
            return redirect(url_for('backups_page'))

        dest_type = request.form.get('dest_type', 'local')

        if dest_type == 'smb':
            smb_host  = request.form.get('smb_host', '').strip()
            smb_share = request.form.get('smb_share', '').strip()
            smb_user  = request.form.get('smb_user', '').strip()
            smb_pass  = request.form.get('smb_pass', '').strip()
            if not smb_host or not smb_share:
                flash('Informe o IP e o nome do compartilhamento Windows.', 'error')
                return redirect(url_for('backups_page'))
            # Pré-teste: valida host/share/credenciais ANTES de iniciar —
            # sem isso o backup "iniciava" e morria em silêncio no mount
            rc_t, out_t, err_t = run(['smbclient', f'//{smb_host}/{smb_share}',
                                      '-U', f'{smb_user}%{smb_pass}', '-c', 'ls'])
            if rc_t != 0:
                flash(f'Não foi possível acessar \\\\{smb_host}\\{smb_share}: '
                      f'{smb_erro_amigavel(err_t or out_t)}', 'error')
                return redirect(url_for('backups_page'))
            # Monta o compartilhamento CIFS e grava direto na rede (sem espaço local)
            import shlex
            smb_sub  = request.form.get('smb_sub', '').strip().strip('\\').strip('/')
            mnt      = f'/run/smb_backup_{timestamp}'
            sub_path = smb_sub.replace('\\', '/') if smb_sub else ''
            dest_dir = os.path.join(mnt, sub_path) if sub_path else mnt
            out_file = os.path.join(dest_dir, filename)
            # caminhos relativos + tar -C /: evita o aviso "Removendo '/'
            # inicial dos nomes dos membros" que assustava no log
            tar_srcs = ' '.join(shlex.quote(t.lstrip('/')) for t in targets)
            # Sem vers= fixo: o kernel negocia a maior versão SMB que o
            # destino suportar (vers=3.0 fixo falhava em Windows antigos)
            smb_opts = shlex.quote(
                f'username={smb_user},password={smb_pass},uid=0,gid=0'
            )
            log = '/var/log/cdpni_backup.log'
            script = (
                f'exec >>{shlex.quote(log)} 2>&1; '
                f'echo "=== $(date "+%d/%m/%Y %H:%M:%S") backup SMB para //{smb_host}/{smb_share} ==="; '
                f'mkdir -p {shlex.quote(mnt)} && '
                f'timeout 90 mount -t cifs //{smb_host}/{smb_share} {shlex.quote(mnt)} -o {smb_opts} && '
                f'mkdir -p {shlex.quote(dest_dir)} && '
                f'{tar} -czf {shlex.quote(out_file)} -C / {tar_srcs} && '
                f'echo "OK: backup concluído ({filename})" '
                f'|| echo "ERRO: backup falhou — veja as mensagens acima"; '
                f'umount {shlex.quote(mnt)} 2>/dev/null; '
                f'rmdir {shlex.quote(mnt)} 2>/dev/null; true'
            )
            proc = subprocess.Popen(
                ['sudo', 'bash', '-c', script],
                stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                start_new_session=True
            )
            pgid = os.getpgid(proc.pid)
            with open(BACKUP_INFO_FILE, 'w') as fp:
                json.dump({'pid': proc.pid, 'pgid': pgid, 'file': out_file,
                           'filename': filename, 'started': time.time(),
                           'type': 'smb'}, fp)
            flash(f'Backup SMB iniciado → \\\\{smb_host}\\{smb_share}\\{filename}', 'success')
        else:
            dest = request.form.get('backup_dest', BACKUP_DIR).strip() or BACKUP_DIR
            run(['sudo', 'mkdir', '-p', dest])
            out_file = os.path.join(dest, filename)
            proc = subprocess.Popen(
                ['sudo', tar, '-czf', out_file, '-C', '/'] + [t.lstrip('/') for t in targets],
                start_new_session=True
            )
            pgid = os.getpgid(proc.pid)
            with open(BACKUP_INFO_FILE, 'w') as fp:
                json.dump({'pid': proc.pid, 'pgid': pgid, 'file': out_file,
                           'filename': filename, 'started': time.time()}, fp)
            flash(f'Backup iniciado → {out_file}', 'success')

    except Exception as e:
        flash(f'Erro ao iniciar backup: {e}', 'error')
    return redirect(url_for('backups_page'))

@app.route('/admin/backups/download/<filename>')
@admin_required
def backup_download(filename):
    name = secure_filename(filename)
    path = os.path.join(BACKUP_DIR, name)
    if not os.path.exists(path):
        abort(404)
    return send_file(path, as_attachment=True, download_name=name)

@app.route('/admin/backups/delete', methods=['POST'])
@admin_required
def backup_delete():
    filename = secure_filename(request.form.get('filename', ''))
    path = os.path.join(BACKUP_DIR, filename)
    if os.path.exists(path) and os.path.abspath(path).startswith(os.path.abspath(BACKUP_DIR)):
        os.unlink(path)
        flash(f'"{filename}" removido', 'success')
    else:
        flash('Arquivo não encontrado', 'error')
    return redirect(url_for('backups_page'))

# ── lixeira ────────────────────────────────────────────────────────────────────
def lixeira_safe(rel: str) -> Path:
    base = Path(RECYCLE_ROOT).resolve()
    alvo = (base / rel).resolve()
    if not str(alvo).startswith(str(base) + os.sep):
        abort(403)
    return alvo

def _lx_iterdir(p: Path) -> list:
    """Lista o conteúdo de uma pasta sem NUNCA propagar erro de permissão.

    As lixeiras pessoais são 0700 de cada dono; se a ACL do portal tiver
    sido mascarada (ex.: o role samba recria a pasta com chmod), a leitura
    falharia — a página inteira daria 500. Aqui a pasta ilegível é apenas
    pulada.
    """
    try:
        return list(p.iterdir())
    except OSError:
        return []

def _lx_is_dir(p: Path) -> bool:
    try:
        return p.is_dir()
    except OSError:
        return False

def _lx_info_dir(p: Path) -> tuple:
    """(bytes, n_arquivos, ctime mais recente) de uma pasta da lixeira."""
    total, n, mt = 0, 0, 0.0
    for raiz, _d, arqs in os.walk(p):   # os.walk ignora erros por padrão
        for a in arqs:
            try:
                st = os.stat(os.path.join(raiz, a))
            except OSError:
                continue
            total += st.st_size
            n += 1
            mt = max(mt, st.st_ctime)
    if mt == 0.0:
        try:
            mt = p.stat().st_ctime
        except OSError:
            pass
    return total, n, mt

def _lx_item(ent: Path, usuario: str, share: str, rel: str, restauravel: bool) -> dict:
    if _lx_is_dir(ent):
        total, n, mt = _lx_info_dir(ent)
        tipo, nome = 'pasta', ent.name + '/'
    else:
        try:
            st = ent.stat()
        except OSError:
            st = None
        total = st.st_size if st else 0
        n, mt = 1, (st.st_ctime if st else 0.0)
        tipo, nome = 'arquivo', ent.name
    return {
        'tipo': tipo, 'rel': rel, 'usuario': usuario, 'share': share,
        'nome': nome, 'n': n, 'tam': fmt_size(total), 'mtime': mt,
        'quando': datetime.fromtimestamp(mt).strftime('%d/%m/%Y %H:%M') if mt else '—',
        'restauravel': restauravel,
    }

def lixeira_listar(rel: str = '') -> list[dict]:
    """Lista UM nível da lixeira, navegável como o Explorer.

    rel=''  → unidades excluídas (recycle/<usuario>/<share>/*)
    rel='usuario/share/sub/...' → conteúdo daquela pasta
    Espelha a visão do share \\servidor\\Recycle no Windows.
    """
    base = Path(RECYCLE_ROOT)
    try:
        shares_validos = {d.name for d in Path(SAMBA_ROOT).iterdir() if d.is_dir()}
    except Exception:
        shares_validos = set()
    itens = []
    if not rel:
        if not base.is_dir():
            return itens
        for udir in sorted(_lx_iterdir(base)):
            if not _lx_is_dir(udir):
                continue
            for ent in sorted(_lx_iterdir(udir), key=lambda e: e.name.lower()):
                if _lx_is_dir(ent) and ent.name in shares_validos:
                    for sub in sorted(_lx_iterdir(ent), key=lambda e: (not _lx_is_dir(e), e.name.lower())):
                        itens.append(_lx_item(sub, udir.name, ent.name,
                                              f'{udir.name}/{ent.name}/{sub.name}', True))
                else:
                    # layout antigo (sem share) — só baixar/excluir
                    itens.append(_lx_item(ent, udir.name, '—',
                                          f'{udir.name}/{ent.name}', False))
        itens.sort(key=lambda i: i['mtime'], reverse=True)
    else:
        alvo = lixeira_safe(rel)
        comps = rel.split('/')
        usuario = comps[0]
        share = comps[1] if len(comps) > 1 and comps[1] in shares_validos else '—'
        for ent in sorted(_lx_iterdir(alvo), key=lambda e: (not _lx_is_dir(e), e.name.lower())):
            itens.append(_lx_item(ent, usuario, share,
                                  f'{rel}/{ent.name}', share != '—'))
    return itens

LIXEIRA_T = BASE_T.replace("__BODY__", """
<div class="page-title">🗑️ Lixeira</div>
<div class="card">
  <div class="card-header" style="display:flex;align-items:center;justify-content:space-between">
    <h3>
      <a href="{{ url_for('lixeira_page') }}" style="text-decoration:none">Lixeira</a>
      {%- for nome, p in crumbs %} <span class="text-muted">/</span>
      {%- if loop.last %} {{ nome }}
      {%- else %} <a href="{{ url_for('lixeira_page') }}?p={{ p | urlencode }}" style="text-decoration:none">{{ nome }}</a>
      {%- endif %}{% endfor %}
    </h3>
    <form method="post" action="{{ url_for('lixeira_esvaziar') }}"
          onsubmit="return confirm('Excluir DEFINITIVAMENTE todos os itens com mais de 30 dias?')">
      <button type="submit" class="btn btn-xs">🧹 Esvaziar itens &gt; 30 dias</button>
    </form>
  </div>
  {% if itens %}
  <table>
    <thead><tr><th>Excluído em</th><th>Por</th><th>Share</th><th>Nome</th><th>Tamanho</th><th class="text-right">Ações</th></tr></thead>
    <tbody>
    {% for i in itens %}
    <tr>
      <td style="font-family:var(--mono);font-size:.74rem;white-space:nowrap">{{ i.quando }}</td>
      <td style="font-size:.78rem">{{ i.usuario }}</td>
      <td style="font-size:.78rem">{{ i.share }}</td>
      <td style="font-family:var(--mono);font-size:.74rem;max-width:340px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap" title="{{ i.nome }}">
        {% if i.tipo == 'pasta' %}
        <a href="{{ url_for('lixeira_page') }}?p={{ i.rel | urlencode }}" style="text-decoration:none" title="Abrir pasta">
          📁 {{ i.nome }}
        </a> <span class="text-muted">({{ i.n }} arquivo{{ 's' if i.n != 1 }})</span>
        {% else %}📄 {{ i.nome }}{% endif %}
      </td>
      <td style="font-size:.76rem;white-space:nowrap">{{ i.tam }}</td>
      <td class="text-right" style="white-space:nowrap">
        {% if i.restauravel %}
        <form method="post" action="{{ url_for('lixeira_restaurar') }}" style="display:inline"
              onsubmit="return confirm('Restaurar {{ 'esta pasta e todo o conteúdo' if i.tipo == 'pasta' else 'este arquivo' }} para o share {{ i.share }}?')">
          <input type="hidden" name="rel" value="{{ i.rel }}">
          <input type="hidden" name="voltar" value="{{ rel }}">
          <button type="submit" class="btn btn-xs" title="Restaurar ao local de origem">↩️ Restaurar</button>
        </form>
        {% endif %}
        {% if i.tipo == 'arquivo' %}
        <a href="{{ url_for('lixeira_baixar') }}?p={{ i.rel | urlencode }}" class="btn btn-xs" title="Baixar">⬇️</a>
        {% endif %}
        <form method="post" action="{{ url_for('lixeira_excluir') }}" style="display:inline"
              onsubmit="return confirm('Excluir DEFINITIVAMENTE {{ 'esta pasta e todo o conteúdo' if i.tipo == 'pasta' else 'este arquivo' }}?')">
          <input type="hidden" name="rel" value="{{ i.rel }}">
          <input type="hidden" name="voltar" value="{{ rel }}">
          <button type="submit" class="btn btn-xs" title="Excluir definitivamente">✖</button>
        </form>
      </td>
    </tr>
    {% endfor %}
    </tbody>
  </table>
  <div style="padding:.5rem .9rem;border-top:1px solid var(--border)">
    <p class="text-muted" style="font-size:.74rem;margin:0">
      Clique nas pastas para navegar, como no Explorer. Também acessível pelo
      Windows: \\\\{{ server_ip }}\\Recycle (somente administradores). Itens
      sem share identificado (—) são de exclusões antigas — use Baixar e
      salve manualmente no destino.
    </p>
  </div>
  {% else %}
  <div class="card-body">
    <p class="text-muted" style="font-size:.82rem">
      {{ 'Pasta vazia.' if rel else 'Lixeira vazia. Arquivos excluídos dos shares aparecem aqui e podem ser restaurados ao local de origem.' }}
    </p>
  </div>
  {% endif %}
</div>
""")

@app.route('/admin/lixeira')
@admin_required
def lixeira_page():
    rel = request.args.get('p', '').strip('/')
    if rel:
        alvo = lixeira_safe(rel)
        if not alvo.is_dir():
            abort(404)
    crumbs, acc = [], ''
    for parte in (rel.split('/') if rel else []):
        acc = f'{acc}/{parte}'.strip('/')
        crumbs.append((parte, acc))
    return render_template_string(LIXEIRA_T, itens=lixeira_listar(rel),
        rel=rel, crumbs=crumbs,
        server_ip=app.config.get('SERVER_IP', ''),
        session=session, banner=get_banner(), active='lixeira', is_admin=True)

@app.route('/admin/lixeira/restaurar', methods=['POST'])
@admin_required
def lixeira_restaurar():
    rel = request.form.get('rel', '')
    voltar = request.form.get('voltar', '').strip('/')
    origem = lixeira_safe(rel)
    comps = rel.replace('\\', '/').split('/')
    if not origem.exists() or len(comps) < 3:
        flash('Item inválido ou sem share de origem identificado.', 'error')
        return redirect(url_for('lixeira_page', p=voltar) if voltar else url_for('lixeira_page'))
    destino = Path(SAMBA_ROOT) / comps[1] / Path(*comps[2:])
    if origem.is_dir() and destino.is_dir():
        # A pasta já existe no share (ex.: restauração parcial anterior):
        # MESCLA o conteúdo em vez de criar cópia com sufixo
        import shlex
        rc, _, err = run(['sudo', 'bash', '-c',
            f'cp -a {shlex.quote(str(origem))}/. {shlex.quote(str(destino))}/ '
            f'&& rm -rf {shlex.quote(str(origem))}'])
        if rc == 0:
            flash(f'Conteúdo mesclado na pasta existente {destino}', 'success')
        else:
            flash(f'Falha ao restaurar: {err}', 'error')
        return redirect(url_for('lixeira_page', p=voltar) if voltar else url_for('lixeira_page'))
    if destino.exists():
        sufixo = datetime.now().strftime(' (restaurado %d-%m-%Y %H%M%S)')
        destino = destino.with_name(destino.stem + sufixo + destino.suffix)
    rc1, _, e1 = run(['sudo', 'mkdir', '-p', str(destino.parent)])
    rc2, _, e2 = run(['sudo', 'mv', str(origem), str(destino)])
    if rc1 == 0 and rc2 == 0:
        flash(f'Restaurado para {destino}', 'success')
    else:
        flash(f'Falha ao restaurar: {e1 or e2}', 'error')
    return redirect(url_for('lixeira_page', p=voltar) if voltar else url_for('lixeira_page'))

@app.route('/admin/lixeira/baixar')
@admin_required
def lixeira_baixar():
    alvo = lixeira_safe(request.args.get('p', ''))
    if not alvo.is_file():
        abort(404)
    return send_file(str(alvo), as_attachment=True, download_name=alvo.name)

@app.route('/admin/lixeira/excluir', methods=['POST'])
@admin_required
def lixeira_excluir():
    alvo = lixeira_safe(request.form.get('rel', ''))
    voltar = request.form.get('voltar', '').strip('/')
    if not alvo.exists():
        abort(404)
    rc, _, err = run(['sudo', 'rm', '-rf', str(alvo)])
    flash('Excluído definitivamente.' if rc == 0 else f'Falha: {err}',
          'success' if rc == 0 else 'error')
    return redirect(url_for('lixeira_page', p=voltar) if voltar else url_for('lixeira_page'))

@app.route('/admin/lixeira/esvaziar', methods=['POST'])
@admin_required
def lixeira_esvaziar():
    rc, _, err = run(['sudo', 'bash', '-c',
        f'find {RECYCLE_ROOT} -type f -mtime +30 -delete; '
        f'find {RECYCLE_ROOT} -mindepth 2 -type d -empty -delete'])
    flash('Itens com mais de 30 dias removidos.' if rc == 0 else f'Falha: {err}',
          'success' if rc == 0 else 'error')
    return redirect(url_for('lixeira_page'))

# ── logs ───────────────────────────────────────────────────────────────────────
LOGS_T = BASE_T.replace("__BODY__", """
<div class="page-title">📋 Logs de Acesso Samba</div>
<div class="actions">
  <a href="?lines=50" class="btn {{ 'btn-primary' if lines==50 else '' }}">50 linhas</a>
  <a href="?lines=200" class="btn {{ 'btn-primary' if lines==200 else '' }}">200 linhas</a>
  <a href="?lines=500" class="btn {{ 'btn-primary' if lines==500 else '' }}">500 linhas</a>
</div>
<div class="card">
  <div class="card-header"><h3>👣 Acessos a arquivos</h3></div>
  {% if eventos %}
  <table>
    <thead><tr><th>Data/Hora</th><th>Usuário</th><th>IP</th><th>Share</th><th>Ação</th><th>Arquivo / Alvo</th></tr></thead>
    <tbody>
    {% for e in eventos %}
    <tr>
      <td style="font-family:var(--mono);font-size:.74rem;white-space:nowrap">{{ e.hora }}</td>
      <td style="font-size:.78rem">{{ e.usuario }}</td>
      <td style="font-family:var(--mono);font-size:.74rem">{{ e.ip }}</td>
      <td style="font-size:.78rem">{{ e.share }}</td>
      <td><span class="badge {{ 'badge-ok' if e.ok else 'badge-warn' }}">{{ e.op }}{{ '' if e.ok else ' (falhou)' }}</span></td>
      <td style="font-family:var(--mono);font-size:.74rem;max-width:340px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap" title="{{ e.alvo }}">{{ e.alvo }}</td>
    </tr>
    {% endfor %}
    </tbody>
  </table>
  <div style="padding:.5rem .9rem;border-top:1px solid var(--border)">
    <p class="text-muted" style="font-size:.74rem;margin:0">
      "Falhou" = a tentativa de abertura retornou erro, o que nem sempre é
      permissão negada: o Windows faz sondagens normais que falham (streams
      :Zone.Identifier, arquivos de lock ~$, Thumbs.db). Falha seguida de
      sucesso no mesmo segundo para o mesmo arquivo é acesso normal.
    </p>
  </div>
  {% else %}
  <div class="card-body">
    <p class="text-muted" style="font-size:.82rem">
      Nenhum evento de acesso registrado ainda. A auditoria grava em
      /var/log/samba/audit.log a partir das próximas conexões — se o
      arquivo não existir, reaplique o playbook (tags samba,common).
    </p>
  </div>
  {% endif %}
</div>
<div class="card">
  <div class="card-header"><h3>Logs do serviço (smbd/nmbd)</h3></div>
  <pre class="log-box">{{ logs }}</pre>
</div>
""")

@app.route('/admin/logs')
@admin_required
def logs_page():
    lines = min(int(request.args.get('lines', 100)), 1000)
    return render_template_string(LOGS_T, logs=get_samba_logs(lines), lines=lines,
        eventos=get_audit_log(lines),
        session=session, banner=get_banner(), active='logs', is_admin=True)

# ── change-pass própria senha ──────────────────────────────────────────────────
CHPASS_T = BASE_T.replace("__BODY__", """
<div class="page-title">🔑 Alterar Minha Senha</div>
<div style="max-width:380px">
  <div class="card"><div class="card-header"><h3>Nova Senha</h3></div><div class="card-body">
    <form method="post" action="{{ url_for('change_pass') }}">
      <div class="form-group"><label>Senha Atual</label><input type="password" name="current_pass" required autocomplete="current-password"></div>
      <div class="form-group"><label>Nova Senha</label><input type="password" name="new_pass" required minlength="4" autocomplete="new-password"></div>
      <div class="form-group"><label>Confirmar Nova Senha</label><input type="password" name="confirm_pass" required autocomplete="new-password"></div>
      <button type="submit" class="btn btn-primary" style="width:100%;justify-content:center">Salvar</button>
    </form>
  </div></div>
</div>
""")

@app.route('/change-pass', methods=['GET'])
@login_required
def change_pass_page():
    is_admin = is_admin_user(session.get('user', ''))
    return render_template_string(CHPASS_T,
        session=session, banner=get_banner(), active='', is_admin=is_admin)

@app.route('/change-pass', methods=['POST'])
@login_required
def change_pass():
    user         = session['user']
    current_pass = request.form.get('current_pass', '')
    new_pass     = request.form.get('new_pass', '')
    confirm      = request.form.get('confirm_pass', '')
    p = pam.pam()
    if not p.authenticate(user, current_pass, service='cdpni-portal'):
        flash('Senha atual incorreta', 'error')
        return redirect(url_for('change_pass_page'))
    if len(new_pass) < 4:
        flash('Mínimo 4 caracteres', 'error')
        return redirect(url_for('change_pass_page'))
    if new_pass != confirm:
        flash('Senhas não coincidem', 'error')
        return redirect(url_for('change_pass_page'))
    rc, err = set_linux_password(user, new_pass)
    if rc != 0:
        flash(f'Erro ao alterar senha: {err}', 'error')
    else:
        run(['sudo', 'smbpasswd', '-s', user], input_=f'{new_pass}\n{new_pass}\n')
        flash('Senha alterada com sucesso', 'success')
    return redirect(url_for('change_pass_page'))

# ── admin: configurações do portal ────────────────────────────────────────────
ADMIN_T = BASE_T.replace("__BODY__", """
<div class="page-title">⚙️ Configurações do Portal</div>
<div class="grid2">
  <div class="card"><div class="card-header"><h3>Aviso / Notícia</h3></div><div class="card-body">
    <form method="post" action="{{ url_for('admin_notice') }}">
      <div class="form-group"><label>Texto (HTML simples)</label>
        <textarea name="notice" rows="4">{{ notice }}</textarea></div>
      <button class="btn btn-primary btn-sm">Salvar</button>
    </form>
  </div></div>
  <div class="card"><div class="card-header"><h3>Banner do Portal</h3></div><div class="card-body">
    {% if banner %}<img src="{{ banner }}" style="max-height:80px;border-radius:4px;margin-bottom:.75rem;display:block">{% endif %}
    <form method="post" action="{{ url_for('admin_banner_upload') }}" enctype="multipart/form-data">
      <div class="form-group"><label>Imagem (JPG/PNG/GIF/WebP)</label>
        <input type="file" name="banner" accept="image/*"></div>
      <button class="btn btn-primary btn-sm">Enviar</button>
      {% if banner %}<a href="{{ url_for('admin_banner_delete') }}" class="btn btn-danger btn-sm" style="margin-left:.4rem">Remover</a>{% endif %}
    </form>
  </div></div>
</div>
""")

@app.route('/admin')
@admin_required
def admin():
    notice_file = os.path.join(PORTAL_DIR, 'notice.html')
    notice = open(notice_file).read() if os.path.exists(notice_file) else ''
    return render_template_string(ADMIN_T, notice=notice,
        session=session, banner=get_banner(), active='admin', is_admin=True)

@app.route('/admin/notice', methods=['POST'])
@admin_required
def admin_notice():
    notice = request.form.get('notice', '')
    notice = re.sub(r'<(?!/?(?:b|i|strong|em|br|p|ul|li|span|a)[\s>])[^>]+>', '', notice)
    with open(os.path.join(PORTAL_DIR, 'notice.html'), 'w') as f:
        f.write(notice)
    flash('Aviso atualizado', 'success')
    return redirect(url_for('admin'))

@app.route('/admin/banner/upload', methods=['POST'])
@admin_required
def admin_banner_upload():
    f = request.files.get('banner')
    if not f or not f.filename:
        flash('Nenhum arquivo', 'error')
        return redirect(url_for('admin'))
    ext = Path(secure_filename(f.filename)).suffix.lower()
    if ext not in ('.jpg', '.jpeg', '.png', '.gif', '.webp'):
        flash('Formato inválido', 'error')
        return redirect(url_for('admin'))
    for old in Path(BANNER_DIR).glob('banner.*'):
        old.unlink()
    f.save(os.path.join(BANNER_DIR, f'banner{ext}'))
    flash('Banner atualizado', 'success')
    return redirect(url_for('admin'))

@app.route('/admin/banner/delete')
@admin_required
def admin_banner_delete():
    for old in Path(BANNER_DIR).glob('banner.*'):
        old.unlink()
    flash('Banner removido', 'success')
    return redirect(url_for('admin'))

# ── API JSON ───────────────────────────────────────────────────────────────────
@app.route('/api/status')
@admin_required
def api_status():
    return jsonify({
        'cpu': get_cpu(), 'mem': get_memory(),
        'uptime': get_uptime(), 'connections': len(get_samba_connections()),
        'disks': get_disk_usage(),
    })

if __name__ == '__main__':
    app.run(host='127.0.0.1', port=5000, debug=False)
