# Manual do Servidor de Arquivos Samba — CDPNI

## Visão Geral

Servidor de arquivos Windows (SMB/CIFS) instalado via Ansible em Debian 12/13.  
Inclui: RAID de dados, Samba 4, portal web de administração (Flask + Nginx + TLS).

- **IP padrão:** 192.168.2.11 (configurável no inventory)
- **Portal web:** `https://192.168.2.11:8443`
- **Compartilhamentos Windows:** `\\192.168.2.11\NomeDoShare`
- **Compartilhamentos Linux:** `smb://192.168.2.11/NomeDoShare`

---

## 1. Instalação do Zero

### Pré-requisitos na máquina destino

- Debian 12 ou 13 (instalação mínima, sem desktop)
- Pelo menos 2 discos adicionais além do disco do SO (para o RAID)
- Acesso SSH com senha root ou chave pública
- IP estático configurado

### Pré-requisitos na máquina de controle (onde você roda o Ansible)

```
apt install ansible python3-pip
```

### Passo 1 — Clonar o repositório

```bash
git clone <url_do_repo> smb
cd smb
```

### Passo 2 — Configurar o inventory

Edite `inventory/hosts.ini`:

```ini
[samba_server]
192.168.2.11 ansible_user=root ansible_ssh_pass=SUA_SENHA
```

Se usar chave SSH:
```ini
[samba_server]
192.168.2.11 ansible_user=root ansible_ssh_private_key_file=~/.ssh/id_rsa
```

### Passo 3 — Configurar as variáveis

O `bootstrap.sh` gera o `group_vars/all.yml` automaticamente com as respostas
interativas — este passo manual só é necessário se você **não** usar o bootstrap.

O arquivo real fica **fora do git** (contém IP e senhas do ambiente; um
`git pull` nunca o sobrescreve). Crie a partir do exemplo versionado:

```bash
cp group_vars/all.yml.example group_vars/all.yml
```

Edite `group_vars/all.yml` com os valores do ambiente:

```yaml
server:
  ip:          "192.168.2.11"
  domain:      "cdpni.local"
  admin_user:  "admin"

raid:
  devices:     ["/dev/sdb", "/dev/sdc"]   # discos para o RAID (NÃO o disco do SO)
  level:       1                           # RAID-1 (espelho); use 5 para 3+ discos
  mount:       "/mnt/raid"

samba:
  workgroup:   "CDPNI"
  shares:
    - name:      "compartilhado"
      comment:   "Pasta compartilhada geral"
      group:     "sambashare"
    - name:      "restrito"
      comment:   "Somente administração"
      group:     "admins"

portal:
  user:        "cdpni-portal"
  dir:         "/opt/cdpni-portal"
  port:        8443

backup:
  dir:         "/opt/backups"
  script:      "/opt/scripts/backup.sh"   # opcional; crie seu script aqui
```

### Passo 4 — Executar o playbook

```bash
ansible-playbook -i inventory/hosts.ini site.yml
```

O playbook executa em ordem:
1. **common** — pacotes base, locale, timezone, NTP
2. **network** — hostname, /etc/hosts
3. **storage** — cria RAID, formata, monta em /mnt/raid, adiciona ao /etc/fstab
4. **samba** — instala smbd/nmbd, configura smb.conf, cria usuário admin
5. **flask_portal** — instala Python venv, gunicorn, nginx, TLS autoassinado, serviço systemd
6. **security** — nftables (firewall), fail2ban

---

## 2. Acesso ao Portal Web

Abra no navegador:
```
https://192.168.2.11:8443
```

> O certificado TLS é autoassinado — o navegador pedirá confirmação de exceção de segurança. Isso é normal. Clique em "Avançado → Continuar".

**Usuário padrão de administrador:** o valor de `server.admin_user` (padrão: `admin`).  
A senha inicial é definida pelo Ansible — veja `group_vars/all.yml` ou redefina pelo próprio portal.

---

## 3. Funções do Portal

### 3.1 Compartilhamentos (Arquivos)

Acesso via menu lateral → **Compartilhamentos**.

- Lista todos os shares Samba que o usuário tem permissão de acessar
- Administradores veem todos os shares
- Permite navegar, fazer upload, criar pastas, renomear e excluir arquivos

### 3.2 Dashboard

Acesso restrito a administradores. Mostra:

| Indicador | Fonte |
|-----------|-------|
| CPU % | /proc (via `top -bn1`) |
| RAM % | /proc/meminfo |
| Uptime | /proc/uptime |
| Sessões Samba ativas | `smbstatus --brief` |
| Uso de disco | `df -h` |
| Status de serviços | `systemctl is-active` |

### 3.3 Usuários

Cria, lista e remove usuários Linux + Samba em um único passo.

**Criar usuário:**
1. Clique em **➕ Novo Usuário**
2. Preencha usuário, senha e confirme
3. Selecione "Adicionar ao Samba: Sim" para permitir acesso via Windows
4. Clique em **Criar**

> O portal executa internamente: `useradd -m -s /bin/bash USER` + `chpasswd` + `smbpasswd -a -s USER`

**Redefinir senha:**
- Clique em **🔑 Senha** ao lado do usuário
- Preencha a nova senha e confirme
- Selecione se deve atualizar o Samba também

**Excluir usuário:**
- Clique em **🗑** ao lado do usuário
- Remove do sistema Linux e do Samba (`userdel -r` + `smbpasswd -x`)
- **Não é possível excluir o próprio usuário logado**

### 3.4 Grupos

Gerencia grupos Linux (usados pelo Samba para controle de acesso).

**Criar grupo:**
1. Clique em **➕ Novo Grupo**
2. Informe o nome (letras minúsculas, números, _ e -)

**Editar membros:**
- Clique em **✏ Editar** ao lado do grupo
- Liste os membros separados por vírgula: `user1,user2,user3`
- Clique em **Salvar**

> Para dar acesso a um share a um grupo, adicione `@nomedogrupo` em "Usuários/grupos válidos" na configuração do share.

### 3.5 Shares Samba

Gerencia os compartilhamentos diretamente no `smb.conf`.

**Criar share:**
1. Clique em **➕ Novo Share**
2. Preencha: nome, caminho, usuários/grupos válidos
3. Selecione somente leitura se necessário
4. Se marcar "Criar diretório", o portal cria o diretório automaticamente
5. O Samba é recarregado automaticamente após salvar

**Editar share:**
- Clique em **✏ Editar** para alterar qualquer configuração

**Excluir share:**
- Clique em **🗑** — remove apenas do smb.conf, não apaga os arquivos no disco

**testparm:**
- Clique em **🔍 testparm** para validar o smb.conf atual

**Reload Samba:**
- Clique em **🔄 Reload Samba** para forçar recarregamento sem reiniciar

### 3.6 RAID / Discos

Monitora arrays RAID e discos físicos.

- **Arrays RAID** — lidos de `/proc/mdstat`; badge verde = saudável, vermelho = degradado
- **Discos/Partições** — lista todas as partições com uso em percentual e barra visual
- **SMART** — clique em **🔬** ao lado de qualquer disco para ver dados SMART do `smartctl`

> Se o array aparecer como **DEGRADADO**, substitua o disco com falha com urgência.

### 3.7 Backups

Lista arquivos `.tar.gz` no diretório de backup (`/opt/backups` por padrão).

**Executar backup manual:**
- Clique em **▶ Executar Backup Agora**
- Se existir `/opt/scripts/backup.sh`, ele é chamado via `sudo bash`
- Se não existir, o portal faz um `tar -czf` dos shares automaticamente

**Baixar backup:**
- Clique em **⬇** ao lado do arquivo

**Excluir backup:**
- Clique em **🗑** ao lado do arquivo

**Agendar backups automáticos:**
Crie `/opt/scripts/backup.sh` e adicione ao cron do root:
```bash
# /etc/cron.d/cdpni-backup
0 2 * * * root /opt/scripts/backup.sh >> /var/log/cdpni_backup.log 2>&1
```

### 3.8 Logs de Acesso

Exibe os últimos registros dos logs do Samba:
- `/var/log/samba/log.smbd`
- `/var/log/samba/log.nmbd`
- `/var/log/samba/audit.log` (se auditoria estiver habilitada)

Selecione 50, 200 ou 500 linhas conforme necessário.

### 3.9 Configurações do Portal

- **Aviso/Notícia** — texto exibido na tela inicial para todos os usuários
- **Banner** — imagem JPG/PNG exibida no topo do portal (máx. 160px altura)

---

## 4. Gerenciamento via Linha de Comando

### Acessar o servidor

```bash
ssh admin@192.168.2.11
```

### Verificar status do Samba

```bash
sudo systemctl status smbd nmbd
sudo smbstatus
```

### Reiniciar serviços

```bash
sudo systemctl restart smbd nmbd
sudo systemctl restart cdpni-portal
sudo systemctl restart nginx
```

### Ver logs em tempo real

```bash
sudo journalctl -fu smbd
sudo journalctl -fu cdpni-portal
sudo tail -f /var/log/samba/log.smbd
```

### Verificar RAID

```bash
cat /proc/mdstat
sudo mdadm --detail /dev/md0
```

### Verificar disco com falha

```bash
sudo smartctl -a /dev/sdb
sudo mdadm --detail /dev/md0 | grep -E "State|Failed"
```

### Substituir disco com falha no RAID-1

```bash
# 1. Marcar disco com falha (se não automático)
sudo mdadm /dev/md0 --fail /dev/sdb
# 2. Remover disco
sudo mdadm /dev/md0 --remove /dev/sdb
# 3. Substituir fisicamente o disco, inicializar a partição
sudo parted /dev/sdb mklabel gpt
sudo parted /dev/sdb mkpart primary 0% 100%
# 4. Adicionar novo disco ao array
sudo mdadm /dev/md0 --add /dev/sdb1
# 5. Acompanhar reconstrução
watch cat /proc/mdstat
```

---

## 5. Verificação Pós-instalação

Após executar o playbook, verifique:

```bash
# No servidor
systemctl is-active smbd nmbd cdpni-portal nginx
cat /proc/mdstat
df -h /mnt/raid
```

```bash
# No Windows (clientes)
net use * \\192.168.2.11\compartilhado /user:admin
```

```bash
# No Linux (clientes)
smbclient //192.168.2.11/compartilhado -U admin
```

Portal web:
```
https://192.168.2.11:8443  → deve abrir a tela de login
```

---

## 6. Solução de Problemas

### Portal não abre (Connection refused ou Timeout)

```bash
sudo systemctl status cdpni-portal nginx
sudo journalctl -u cdpni-portal --no-pager -n 50
```

### Erro "Worker failed to boot" no portal

```bash
source /opt/cdpni-portal/venv/bin/activate
python -c "import pam; import flask; import six; print('OK')"
# Se falhar, reinstalar dependências:
pip install flask==3.1.0 python-pam==2.0.2 gunicorn==23.0.0 werkzeug==3.1.3 six
```

### Usuário não consegue acessar o share pelo Windows

```bash
# Verificar se o usuário tem senha Samba
sudo pdbedit -L | grep USUARIO
# Resetar senha Samba
echo -e "NOVASENHA\nNOVASENHA" | sudo smbpasswd -s USUARIO
```

### Permissão negada ao criar arquivos no share

```bash
# Verificar permissões do diretório
ls -la /mnt/raid/shares/
# Corrigir
sudo chmod 0775 /mnt/raid/shares/NOME_DO_SHARE
sudo chown root:sambashare /mnt/raid/shares/NOME_DO_SHARE
```

### RAID degradado

```bash
cat /proc/mdstat
sudo mdadm --detail /dev/md0
# Ver qual disco falhou e substituir conforme seção 4
```

---

## 6.1 Trocar o IP do Servidor

Use **sempre** o script dedicado — nunca edite `/etc/network/interfaces` na mão:

```bash
sudo bash change-ip.sh 10.14.29.8
# ou interativo:
sudo bash change-ip.sh
```

Garantias do script:

1. Lê e grava o `group_vars/all.yml` com YAML de verdade (python3) — se algum valor não puder ser lido, **aborta sem alterar nada**
2. Valida que o gateway pertence à sub-rede nova (gateway errado = servidor sem rota no boot)
3. Se a rede nova não estiver nas redes permitidas do firewall, adiciona automaticamente a `network_ranges`
4. Em sessão SSH, roda o playbook via `systemd-run` — **desacoplado da sessão**: se o SSH cair na troca, a aplicação continua até o fim (`tail -f /var/log/cdpni_change_ip.log` para acompanhar)
5. O role de rede valida o novo `interfaces` com `ifquery` antes de gravar, aplica com `ip addr replace` (novo IP antes de remover o antigo) e **nunca** reinicia o serviço networking

**Redes suportadas:** a padrão é `10.14.29.0/24` (privada RFC 1918). As faixas `172.14.29.0/24` e `192.14.29.0/24` também já estão liberadas no firewall (`network_ranges` no `group_vars/all.yml`) — atenção: são endereços **públicos** reutilizados internamente; funciona atrás do gateway GWOS, mas sites reais da internet nessas faixas ficam inacessíveis a partir da rede local.

Depois da troca, atualize o DNS no gateway: `gwos dns update cdpni <novo-ip>`.

---

## 7. Segurança

### Firewall (nftables)

Acesso permitido apenas das redes internas definidas em `network_ranges`
(`group_vars/all.yml`): faixas RFC 1918 + `172.14.29.0/24` + `192.14.29.0/24`.

Portas abertas por padrão:
- **22** — SSH (altere para outra porta em produção)
- **445** — SMB (Samba)
- **139** — NetBIOS (Samba legado)
- **8443** — Portal web HTTPS

### fail2ban

Protege contra tentativas de força bruta:
- SSH: bloqueio após 5 tentativas em 10 min
- Portal web: bloqueio após 5 tentativas em 10 min

```bash
# Ver IPs banidos
sudo fail2ban-client status sshd
sudo fail2ban-client status cdpni-portal

# Desbanir um IP
sudo fail2ban-client set sshd unbanip 192.168.1.100
```

### TLS do Portal

O certificado autoassinado é gerado pelo Ansible. Para usar um certificado válido (Let's Encrypt ou CA própria), substitua em:
- `/etc/ssl/cdpni/portal.crt`
- `/etc/ssl/cdpni/portal.key`

E recarregue o Nginx:
```bash
sudo systemctl reload nginx
```

---

## 8. Atualizar o Portal Após Mudanças no Repositório

No servidor:
```bash
cd /opt/cdpni-portal
sudo -u cdpni-portal git pull    # se instalado via git
# ou copie o novo app.py e reinicie:
sudo systemctl restart cdpni-portal
```

Via Ansible (recomendado):
```bash
ansible-playbook -i inventory/hosts.ini site.yml --tags flask_portal
```

---

## 9. Estrutura do Repositório

```
smb/
├── ansible.cfg
├── inventory/
│   └── hosts.ini          ← endereços dos servidores
├── group_vars/
│   └── all.yml            ← variáveis globais (IP, discos, shares...)
├── site.yml               ← playbook principal
├── roles/
│   ├── common/            ← pacotes base, locale, NTP
│   ├── network/           ← hostname, /etc/hosts
│   ├── storage/           ← RAID, formatação, montagem
│   ├── samba/             ← smb.conf, usuários Samba
│   ├── flask_portal/      ← portal web (app.py, nginx, systemd)
│   └── security/          ← nftables, fail2ban
└── MANUAL.md              ← este arquivo
```
