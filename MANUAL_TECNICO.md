# Manual Técnico — Servidor de Arquivos CDPNI

> **Público-alvo:** administradores que queiram entender **como o servidor funciona
> por dentro** — cada comando, arquivo e ferramenta explicados para estudo.
> Para instalação e uso do dia a dia, veja o [MANUAL.md](MANUAL.md).

---

## 1. Arquitetura geral

### 1.1 Fluxo de provisionamento

```
bootstrap.sh  ──gera──►  group_vars/all.yml  ──lido por──►  site.yml (Ansible)
 (perguntas)              (toda a config)                        │
                                                 ┌───────────────┼────────────────┐
                                                 ▼               ▼                ▼
                                              roles/         roles/           roles/
                                              common         network          security
                                              (pacotes,      (IP fixo,       (nftables,
                                               hora, hosts)   resolv.conf)    fail2ban, SSL)
                                                 ▼               ▼                ▼
                                              roles/         roles/           roles/
                                              storage        samba            flask_portal
                                              (RAID, XFS)    (shares,         (portal web,
                                                              usuários)        wrappers)
```

A ordem importa: o **firewall sobe antes do storage** — se algo falhar no meio da
instalação, a máquina já está protegida.

### 1.2 Serviços e portas

| Serviço | Unit systemd | Porta | Função |
|---|---|---|---|
| Samba (arquivos) | `smbd` | 445/tcp | SMB/CIFS — os compartilhamentos |
| Samba (nomes) | `nmbd` | 137,138/udp | Resolução de nomes NetBIOS p/ Windows antigos |
| Portal (aplicação) | `cdpni-portal` | 5000/tcp (só localhost) | Flask + gunicorn |
| Portal (HTTPS) | `nginx` | 8443/tcp | Proxy TLS na frente do gunicorn |
| Firewall | `nftables` | — | Regras carregadas de `/etc/nftables.conf` |
| Anti-brute-force | `fail2ban` | — | Bane IPs após erros de login |
| Hora | `chrony` | 123/udp (cliente) | Sincroniza com o NTP institucional |
| Auditoria | `rsyslog` | — | Grava o log de acessos do Samba em arquivo |
| Ajuste de IP no boot | `cdpni-update-ip` | — | Oneshot: atualiza config/nginx/SSL se o IP mudou |

### 1.3 Caminhos importantes

| Caminho | Conteúdo |
|---|---|
| `/opt/smb` | Este repositório (código + configuração) |
| `/opt/smb/group_vars/all.yml` | **Configuração real** (fora do git!) — backup em `/root/all.yml.bak` |
| `/mnt/raid/shares/<Share>` | Os arquivos de cada compartilhamento |
| `/mnt/raid/recycle/<usuário>/<Share>/…` | Lixeira (vfs recycle) |
| `/opt/cdpni-portal` | Aplicação do portal (app.py, config.py, venv) |
| `/etc/samba/smb.conf` | Configuração do Samba (gerada — não editar na mão) |
| `/etc/nftables.conf` | Regras de firewall (geradas) |
| `/var/log/samba/audit.log` | Log de acessos a arquivos (full_audit) |
| `/var/log/cdpni_backup.log` | Log das execuções de backup |
| `/usr/local/bin/cdpni-*` | Wrappers privilegiados usados pelo portal |

---

## 2. Ansible — a ferramenta de provisionamento

### 2.1 O comando principal

```bash
ansible-playbook -i inventory/hosts.ini site.yml --diff
#                │                      │        └─ mostra o "antes/depois" de cada arquivo alterado
#                │                      └─ o playbook: a lista de roles a aplicar, em ordem
#                └─ inventário: onde rodar — aqui, "localhost ansible_connection=local"
#                   (o Ansible roda na própria máquina, sem SSH)
```

### 2.2 Tags — aplicar só uma parte

Cada role tem uma tag. Rodar só o que interessa economiza tempo:

```bash
ansible-playbook -i inventory/hosts.ini site.yml --tags portal --diff
#                                                └─ só o role flask_portal
```

| Tag | Aplica |
|---|---|
| `common` | Pacotes base, hostname, /etc/hosts, chrony (NTP), logrotate |
| `network` | IP fixo, resolv.conf — **valida antes de gravar, nunca reinicia o networking** |
| `security` | nftables, fail2ban, smartd, certificado SSL |
| `storage` | RAID (com travas anti-destruição), fstab, monitoramento |
| `samba` | Pacotes, usuários/grupos, smb.conf, rsyslog da auditoria |
| `portal` | Portal web, wrappers, sudoers, nginx, serviços |

### 2.3 Idempotência — por que re-executar é seguro

O playbook foi construído para poder rodar mil vezes sem estragar nada:

- **Senhas** só são definidas na **criação** do usuário (`update_password: on_create`
  no Linux; `pdbedit -u` confere antes do `smbpasswd` no Samba) — senhas trocadas
  pelos usuários nunca são resetadas;
- **RAID**: se `/mnt/raid` está montado (produção), **nenhuma** operação destrutiva
  roda; a primeira task tenta montar um filesystem `SAMBA_DATA` íntegro antes de
  qualquer decisão; e se o disco do S.O. aparecer na lista de discos, o play **aborta**;
- **Config local** (`all.yml`) fica fora do git — `git pull` nunca a sobrescreve.

---

## 3. group_vars/all.yml — a configuração, campo a campo

```yaml
org:                          # Identidade exibida no portal e no certificado
  name:     "CDPNI"           #   sigla (título, login, rodapé)
  fullname: "Centro de..."    #   nome por extenso (cabeçalho do portal)

server:
  ip:         "10.14.29.9"    # IP fixo do servidor na LAN
  mask:       "24"            # prefixo CIDR (24 = 255.255.255.0)
  gateway:    "10.14.29.1"    # rota padrão — PRECISA estar dentro da rede ip/mask
  dns:        "10.14.29.1"    # gravado no /etc/resolv.conf
  ntp:        "10.14.8.20"    # fonte de hora da intranet (chrony); sem ela o relógio
                              # deriva e o apt rejeita assinaturas
  hostname:   "smb"           # nome da máquina → smb.cdpni.local
  domain:     "cdpni.local"
  admin_user: "sambadmin"     # usuário com bypass de permissões no Samba
  iface:      "enp9s0f0"      # placa de rede da LAN

network_ranges:               # redes com acesso ao servidor (firewall)
  - "10.0.0.0/8"              #   faixas privadas RFC 1918...
  - "172.16.0.0/12"
  - "192.168.0.0/16"
  - "172.14.29.0/24"          #   ...e as faixas legadas CDPNI, que são endereços
  - "192.14.29.0/24"          #   PÚBLICOS reutilizados na intranet (por isso
                              #   precisam ser liberadas explicitamente)

raid:
  level:   5                  # nível do RAID (0 = modo disco único, SEM mdadm:
                              # o XFS vai direto no disco; sem tolerância a falhas)
  mount:   /mnt/raid          # ponto de montagem
  device:  /dev/md0           # dispositivo do array
  devices:                    # discos-membros por caminho ESTÁVEL (/dev/disk/by-id):
    - /dev/disk/by-id/wwn-0x…  # os nomes sdX MUDAM entre boots; o by-id é gravado
    - /dev/disk/by-id/wwn-0x…  # no hardware do disco e nunca muda.
                               # Gere com: sudo bash scripts/raid_ids.sh

samba:
  workgroup:    "WORKGROUP"
  default_pass: "…"           # senha INICIAL de usuários novos (só na criação)
  log_dir:      /var/log/samba
  extra_admins: []            # logins extras com bypass de permissão

portal:
  dir:  /opt/cdpni-portal     # onde a aplicação vive
  user: cdpni                 # usuário de serviço (o portal NÃO roda como root)
  port: 5000                  # porta interna do gunicorn (nginx faz o TLS em 8443)
```

---

## 4. Rede

### 4.1 /etc/network/interfaces (gerado pelo role network)

```
source /etc/network/interfaces.d/*   # inclui configurações extras desse diretório

auto lo                              # "auto" = sobe no boot
iface lo inet loopback               # interface de loopback (127.0.0.1)

auto enp9s0f0
iface enp9s0f0 inet static           # IP FIXO (nada de DHCP em servidor)
    address 10.14.29.9/24            # IP + prefixo na mesma linha (forma moderna)
    gateway 10.14.29.1               # rota padrão
```

**Como o role aplica sem derrubar a rede** (a lição do incidente que formatou uma máquina):

1. Valida que a interface existe e que o gateway pertence à sub-rede;
2. Gera o arquivo em `/etc/network/interfaces.cdpni.new` e valida com
   `ifquery --list -i <arquivo>` — sintaxe errada = **aborta sem tocar em nada**;
3. Faz backup do arquivo atual e só então instala o novo;
4. Aplica em runtime com `ip addr replace` (adiciona o novo IP **antes** de
   remover os antigos — a interface nunca fica sem IP);
5. **Nunca** executa `systemctl restart networking`.

### 4.2 Comandos de diagnóstico

```bash
ip -4 addr show                # IPs atribuídos a cada interface
#  └─ "-4" = só IPv4; "addr" = endereços

ip route                       # tabela de rotas; a linha "default via X" é o gateway

ip -o link show                # interfaces físicas e estado (UP/DOWN)
#  └─ "-o" = uma linha por interface (fácil de filtrar)

ss -tlnp                       # portas TCP abertas e quem escuta
#  └─ t=tcp, l=listening, n=numérico (sem resolver nomes), p=processo
```

### 4.3 change-ip.sh — troca de IP segura

```bash
sudo bash /opt/smb/change-ip.sh [novo-ip] [máscara]
```

O que ele faz, em ordem:

1. **Lê o all.yml com YAML de verdade** (python3), nunca com grep/sed — se algum
   campo não puder ser lido, aborta antes de alterar qualquer coisa;
2. Valida o novo IP, a máscara e que o **gateway pertence à nova sub-rede**;
3. Se a rede nova não estiver em `network_ranges`, **adiciona** (senão o firewall
   bloquearia todo o acesso após a troca);
4. Atualiza o all.yml (com backup `.bak.<data>`);
5. Remove o certificado SSL (será regerado com o novo IP);
6. Roda o playbook (tags network,security,samba). **Em sessão SSH**, roda via
   `systemd-run` — desacoplado da sessão: se o SSH cair na troca do IP, a
   aplicação continua até o fim (`tail -f /var/log/cdpni_change_ip.log`).

---

## 5. RAID (mdadm)

### 5.1 Ler o /proc/mdstat

```
md0 : active raid5 sdf[4] sde[3] sdd[2] sdc[1] sda[0]
      3906764800 blocks level 5, 512k chunk, algorithm 2 [5/5] [UUUUU]
```

- `active raid5` — array funcionando, nível 5;
- `[5/5]` — 5 discos esperados, 5 presentes. `[5/4]` = **degradado** (1 faltando);
- `[UUUUU]` — um `U` (up) por disco; `[UUU_U]` = o 4º disco caiu;
- Durante reconstrução/expansão aparece uma barra: `[==>....] recovery = 12.3%`.

### 5.2 Comandos mdadm anotados

```bash
mdadm --detail /dev/md0
#     └─ raio-x do array: estado, discos, quem falhou, progresso de rebuild

mdadm --manage /dev/md0 --fail /dev/sdX
#     └─ marca um disco como falho (necessário antes de remover um disco "meio vivo")

mdadm --manage /dev/md0 --remove /dev/sdX
#     └─ remove o disco falho do array

mdadm --manage /dev/md0 --add /dev/sdX
#     └─ adiciona um disco: se o array está degradado, inicia a RECONSTRUÇÃO;
#        se está completo, o disco vira HOT SPARE (reserva automática)

mdadm --grow /dev/md0 --raid-devices=6
#     └─ expande o array para 6 discos de trabalho (reshape — leva horas);
#        depois do reshape: xfs_growfs /mnt/raid para o filesystem crescer

mdadm --detail --scan > /etc/mdadm/mdadm.conf && update-initramfs -u
#     └─ persiste a definição do array para o boot reconhecê-lo sempre igual

watch cat /proc/mdstat
#     └─ acompanha reconstrução/reshape em tempo real (Ctrl+C sai)
```

### 5.3 Substituir um disco que falhou

```bash
cat /proc/mdstat                                  # confirme qual caiu ([U_UUU])
mdadm --manage /dev/md0 --fail   /dev/sdX         # se ainda não marcado
mdadm --manage /dev/md0 --remove /dev/sdX
# troque o disco fisicamente (anote o serial! ls -l /dev/disk/by-id ajuda)
mdadm --manage /dev/md0 --add    /dev/sdY         # o novo assume e reconstrói
watch cat /proc/mdstat                            # espere chegar a 100%
sudo bash /opt/smb/scripts/raid_ids.sh            # regenere a lista by-id
nano /opt/smb/group_vars/all.yml                  # atualize raid.devices
```

> **Pelo portal é mais simples:** RAID/Discos → o disco novo aparece em
> "Discos novos detectados" → Hot spare (assume na hora se o RAID está degradado).

### 5.4 Por que /dev/disk/by-id e não /dev/sdX

Os nomes `sda`, `sdb`… são atribuídos pela **ordem de detecção no boot** — e ela
muda (nesta máquina, o disco do S.O. já foi `sda` e `sdb` em boots diferentes).
Os links em `/dev/disk/by-id/` derivam do **WWN/serial gravado no hardware** e
apontam sempre para o mesmo disco físico:

```bash
ls -l /dev/disk/by-id/ | grep -v part
# wwn-0x50014ee2b1234567 -> ../../sda    ← este link segue o disco, não a letra
```

O `scripts/raid_ids.sh` automatiza: lê o array em uso e imprime o bloco
`devices:` pronto para colar no all.yml, indicando também o disco do S.O.

### 5.5 O wrapper cdpni-raid (usado pelo portal)

```bash
sudo /usr/local/bin/cdpni-raid candidatos   # JSON dos discos fora do RAID e sem uso
sudo /usr/local/bin/cdpni-raid saude        # JSON: estado do array + SMART por membro
sudo /usr/local/bin/cdpni-raid add-spare /dev/sdX   # limpa assinaturas e adiciona como spare
sudo /usr/local/bin/cdpni-raid expandir  /dev/sdX   # add + grow; agenda o xfs_growfs
sudo /usr/local/bin/cdpni-raid concluir-growfs      # roda o xfs_growfs quando o reshape acaba
#    └─ chamado de hora em hora pelo cron (raid_check.sh) — a expansão termina sozinha
```

Proteções embutidas: recusa o disco do S.O., membros do RAID, discos com
partições montadas e dispositivos sem mídia (leitores de cartão vazios = 0 bytes).

---

## 6. Samba

### 6.1 smb.conf — as seções que importam (anotado)

```ini
[global]
   security = user                     # autenticação por usuário/senha (não por máquina)
   map to guest = bad user             # usuário inexistente → convidado (para shares públicos)
   admin users = sambadmin             # estes logins ignoram permissões (agem como root)

   interfaces = lo enp9s0f0            # escuta só na LAN e no loopback
   bind interfaces only = yes
   hosts allow = 127.0.0.1 10. 172. 192.168. 192.14.29.
   #             └─ 2ª camada de defesa (a 1ª é o nftables): só estas faixas conectam

   # ── Lixeira ────────────────────────────────────────────
   vfs objects = recycle full_audit    # plugins: lixeira + auditoria
   recycle:repository = /mnt/raid/recycle/%U/%S
   #                    └─ %U = usuário, %S = share → a lixeira sabe DE ONDE veio
   #                       cada arquivo (é o que permite o botão Restaurar)
   recycle:keeptree = yes              # preserva a árvore de pastas dentro da lixeira
   recycle:directory_mode = 0770       # 0770 (não 0700): mantém a máscara de ACL que
   recycle:subdir_mode   = 0770        # dá ao portal permissão de leitura

   # ── Auditoria ──────────────────────────────────────────
   full_audit:prefix  = %u|%I|%S       # cada evento: usuário|IP|share
   full_audit:success = connect disconnect openat renameat unlinkat mkdirat
   #                    └─ nomes das syscalls modernas (Samba ≥4.15 usa *at)
   full_audit:failure = connect openat # também loga tentativas que falharam
   full_audit:facility = local5        # envia ao syslog na "facility" local5…
   # …e o rsyslog (regra /etc/rsyslog.d/49-samba-audit.conf) grava a local5 em
   # /var/log/samba/audit.log — que a página "Logs de acesso" do portal lê.

[Recycle]                              # o share oculto da lixeira
   path = /mnt/raid/recycle
   valid users = sambadmin             # só admins
   writable = yes                      # permite restaurar recortando de volta
   browseable = no                     # não aparece na lista \\servidor
   vfs objects = full_audit            # SEM recycle aqui (evita lixeira da lixeira)
```

### 6.2 Comandos Samba anotados

```bash
testparm -s
#  └─ valida a sintaxe do smb.conf e imprime a config efetiva (rode após editar)

smbstatus
#  └─ quem está conectado agora, de qual IP, e quais arquivos estão abertos/travados

pdbedit -L
#  └─ lista os usuários do banco do Samba (quem pode autenticar nos shares)
pdbedit -u fulano -v
#  └─ detalhes de um usuário (última troca de senha, flags)

smbpasswd -a fulano     # -a = adiciona o usuário ao Samba (pede a senha 2x)
smbpasswd fulano        # troca a senha
smbpasswd -e fulano     # -e = enable (habilita); -d = disable (desabilita)

smbclient -L localhost -U fulano
#  └─ lista os shares como um cliente veria (teste rápido de autenticação)
smbclient //10.14.29.129/Backups -U usuario%senha -c 'ls'
#  └─ conecta num share REMOTO e executa "ls" — é o teste que o portal usa
#     antes de iniciar um backup de rede ("usuário%senha" na mesma string)

smbcontrol smbd reload-config
#  └─ recarrega o smb.conf sem derrubar as conexões ativas
```

### 6.3 Permissões — como as camadas se somam

Um usuário só acessa um arquivo se passar por **todas** as camadas:

1. **nftables**: o IP dele está numa rede permitida?
2. **hosts allow** do Samba: idem (redundância proposital);
3. **valid users** do share: ele (ou seu grupo `grp_*`) está na lista?
4. **Permissões do filesystem**: os arquivos nascem `0664`/grupo do share
   (`force create mode`/`force group` no smb.conf), então quem está no grupo
   Linux `grp_<share>` lê e escreve.

O portal gerencia os grupos Linux via wrappers (`cdpni-setgroup` etc.) — as
mudanças feitas nele são as mesmas que você faria com `usermod`/`gpasswd`.

---

## 7. Firewall (nftables) e fail2ban

### 7.1 /etc/nftables.conf anotado

```nft
flush ruleset                          # zera tudo e recomeça (o arquivo é a verdade)

define SSH_PORT  = 22
define SMB_PORTS = { 139, 445 }
define WEB_PORTS = { 80, 443, 8443 }

table inet cdpni {                     # "inet" = vale para IPv4 e IPv6

    set redes_internas {               # conjunto nomeado com as redes permitidas
        type ipv4_addr
        flags interval                 # aceita faixas CIDR
        auto-merge                     # faixas sobrepostas são fundidas (10.14.29.0/24
        elements = { 10.0.0.0/8, … }   # dentro de 10/8 não dá erro)
    }

    set ssh_ratelimit {                # conjunto DINÂMICO p/ limitar brute-force SSH
        type ipv4_addr
        flags dynamic, timeout
        timeout 60s                    # cada IP fica registrado por 60s
    }

    chain input {                      # tráfego DESTINADO ao servidor
        type filter hook input priority filter; policy drop;
        #                                        └─ POLÍTICA: o que não for
        #                                           explicitamente aceito, CAI

        ct state invalid drop                    # pacotes malformados: fora
        ct state { established, related } accept # respostas de conexões já feitas
        iifname "lo" accept                      # loopback sempre livre

        ip protocol icmp ip saddr @redes_internas accept
        #  └─ ping/diagnóstico só da rede interna ("@" referencia o set)

        tcp dport $SSH_PORT ip saddr @redes_internas \
            ct state new add @ssh_ratelimit { ip saddr limit rate 4/minute } accept
        #  └─ SSH: aceita conexões NOVAS só até 4/minuto por IP de origem…
        tcp dport $SSH_PORT ip saddr @redes_internas ct state new drop
        #  └─ …a 5ª em diante no mesmo minuto é descartada (anti brute-force)

        tcp dport $SMB_PORTS ip saddr @redes_internas accept   # Samba
        udp dport { 137, 138 } ip saddr @redes_internas accept # NetBIOS
        tcp dport $WEB_PORTS ip saddr @redes_internas accept   # portal
        tcp dport 5000 ip saddr 127.0.0.1 accept               # gunicorn: só local

        limit rate 5/minute log prefix "nft-cdpni-drop: " flags all
        drop                            # o resto: loga (com limite) e descarta
    }

    chain forward { type filter hook forward priority filter; policy drop; }
    #  └─ este servidor não roteia tráfego de terceiros: forward tudo bloqueado

    chain output { type filter hook output priority filter; policy accept; }
    #  └─ tráfego DE SAÍDA do próprio servidor: liberado
}
```

```bash
nft list ruleset          # regras em vigor agora
nft -c -f /etc/nftables.conf
#   └─ "-c" = só CHECA a sintaxe, não aplica (o Ansible valida assim antes de instalar)
systemctl reload nftables # reaplica o arquivo
```

### 7.2 fail2ban

```bash
fail2ban-client status                      # jails ativas
fail2ban-client status cdpni-portal        # IPs banidos na jail do portal
#   └─ regra: 5 logins errados em 5 min → banido por 30 min
fail2ban-client set cdpni-portal unbanip 10.14.29.50   # desbanir na mão
```

A jail lê `/var/log/cdpni_portal_access.log`: login que falha devolve HTTP 200
(com a mensagem de erro) e login certo devolve 302 (redirect) — o filtro conta
os 200 do `POST /login`. A jail `samba` vem **desativada** de propósito: o
fail2ban não traz filtro para Samba e o log por máquina não tem caminho fixo.

---

## 8. O Portal por dentro

### 8.1 Unit do systemd anotado (`cdpni-portal.service`)

```ini
[Unit]
Description=CDPNI Portal Flask
After=network.target smbd.service cdpni-update-ip.service
Wants=cdpni-update-ip.service     # start do portal puxa o ajustador de IP antes

[Service]
User=cdpni                        # NÃO roda como root — privilégios só via sudo pontual
WorkingDirectory=/opt/cdpni-portal
ExecStart=/opt/cdpni-portal/venv/bin/gunicorn --workers 3 --bind 127.0.0.1:5000 \
          --timeout 120 app:app
#         │                        │            │
#         │                        │            └─ só escuta no localhost (o nginx
#         │                        │               é quem expõe o 8443 com TLS)
#         │                        └─ 3 processos atendendo em paralelo
#         └─ gunicorn = servidor de aplicação Python de produção
AmbientCapabilities=CAP_SETUID CAP_SETGID
#  └─ o processo precisa disso para o login PAM validar senhas.
#     NUNCA usar CapabilityBoundingSet aqui: limitaria os poderes de TODOS os
#     descendentes — inclusive root via sudo, que ficaria sem CAP_DAC_OVERRIDE
#     (rm em pasta 0700 falha!) e sem CAP_SYS_ADMIN (mount/mdadm falham).
Restart=on-failure
```

### 8.2 Os wrappers privilegiados (`/usr/local/bin/cdpni-*`)

O portal roda como usuário comum. Quando precisa de root, chama um **wrapper**:
um script pequeno, de dono root e modo 0700, que faz **uma coisa só**, com
validação de entrada — e o sudoers permite ao usuário `cdpni` executar
exatamente esses caminhos, sem senha:

| Wrapper | Faz | Por que existe |
|---|---|---|
| `cdpni-setpass <user> <senha>` | Grava o hash no /etc/shadow | trocar senha Linux sem expor o passwd interativo |
| `cdpni-useradd/userdel` | Cria/remove usuário | valida o nome (regex) e conserta o gshadow |
| `cdpni-groupadd/groupdel/setgroup` | Gerencia grupos | idem |
| `cdpni-smart <disco>` | `smartctl -a` | valida que o argumento é `/dev/sdX` antes de executar |
| `cdpni-raid <subcomando>` | mdadm/xfs_growfs | todas as travas da seção 5.5 |

Princípio: **nunca** dar `sudo` amplo à aplicação web; cada privilégio passa por
um funil estreito e auditável.

### 8.3 Como o login do portal funciona

O portal usa **PAM**: valida usuário/senha contra as contas Linux do servidor —
as mesmas contas do Samba. Uma senha trocada no portal vale nos dois mundos
(o portal troca via `cdpni-setpass` + `smbpasswd`).

---

## 9. Lixeira e auditoria — o ciclo de um arquivo excluído

```
usuário exclui X do share  ─►  vfs recycle move para
                               /mnt/raid/recycle/<usuário>/<share>/<caminho>/X
                               (nada é apagado de verdade)
        └─ ao mesmo tempo, full_audit registra:
           "sambadmin|10.14.29.34|Administrativo|unlinkat|ok|X"
           → syslog local5 → rsyslog → /var/log/samba/audit.log
                                        └─ página "Logs de acesso" do portal

portal → Lixeira: navega essa árvore como o Explorer
  Restaurar  = mv (ou cp -a + rm se a pasta já existir no share = mescla)
  Excluir    = rm -rf (aí sim apaga de verdade)
  Esvaziar   = find … -mtime +30 -delete (itens com +30 dias)
```

Detalhe de permissões: as pastas da lixeira são `0700` de cada usuário; o portal
lê graças a uma **ACL** (`setfacl -m u:cdpni:rx`) aplicada pelo playbook — e o
`recycle:directory_mode = 0770` garante que a máscara de ACL das pastas novas
não anule essa permissão.

```bash
getfacl /mnt/raid/recycle/sambadmin   # ver as ACLs de um diretório
setfacl -m u:cdpni:rx <dir>           # -m = modifica; u:usuário:permissões
```

---

## 10. Backup

### 10.1 Local

```bash
tar -czf /opt/backups/backup_X.tar.gz -C / mnt/raid/shares etc/samba
#   │ │ │                              │  └─ caminhos RELATIVOS (sem a / inicial)
#   │ │ │                              └─ "-C /" muda para a raiz antes de arquivar
#   │ │ └─ f = nome do arquivo de saída      (evita o aviso "Removendo /")
#   │ └─ z = comprime com gzip
#   └─ c = criar arquivo
```

### 10.2 Em rede (o que o portal executa)

```bash
mount -t cifs //10.14.29.129/Backups /run/smb_backup_X -o username=U,password=S,uid=0,gid=0
#     │       │                       │                  └─ credenciais do Windows;
#     │       │                       │                     sem "vers=" o kernel negocia
#     │       │                       │                     a melhor versão SMB
#     │       │                       └─ ponto de montagem temporário
#     │       └─ \\máquina\compartilhamento do Windows
#     └─ CIFS/SMB — requer o pacote cifs-utils (mount.cifs)

tar -czf /run/smb_backup_X/backup.tar.gz -C / mnt/raid/shares …   # grava DIRETO na rede
umount /run/smb_backup_X                                          # desmonta ao final
```

O portal ainda: testa o destino com `smbclient` **antes** de iniciar (erro
aparece na hora, traduzido), aplica `timeout 90` no mount (porta filtrada não
pendura a tela) e grava tudo em `/var/log/cdpni_backup.log`.

### 10.3 Restaurar um backup

```bash
tar -tzf backup_X.tar.gz | head          # t = listar conteúdo (conferir antes!)
tar -xzf backup_X.tar.gz -C /tmp/rest    # x = extrair, para um local neutro
# copie de volta só o que precisar — restaurar por cima de tudo raramente é o que se quer
```

---

## 11. Hora certa (chrony)

```bash
chronyc sources
#  └─ fontes de hora; "^*" = sincronizado com esta; "^?" = inalcançável
chronyc tracking
#  └─ "System time: 0.00003 seconds fast" = offset atual (quer-se perto de zero)
chronyc makestep
#  └─ força o acerto IMEDIATO por salto (use após corrigir uma fonte)
```

Config em `/etc/chrony/chrony.conf` (gerada): NTP institucional preferido →
gateway como reserva → `pool.ntp.br` como última opção. **Sintoma clássico de
relógio errado**: `apt update` falha com "Not live until…".

---

## 12. Diagnóstico geral

```bash
systemctl status <serviço> --no-pager   # estado, PID, últimas linhas de log
systemctl restart <serviço>             # reinicia
systemctl list-jobs                     # jobs travados/pendentes do systemd

journalctl -u cdpni-portal -n 50 --no-pager
#          │                └─ últimas 50 linhas
#          └─ log de UM serviço (o journal guarda tudo)
journalctl -u smbd --since "1 hour ago" # filtro por tempo
journalctl -f                           # acompanha tudo ao vivo (como tail -f)

dmesg | tail -30                        # mensagens do kernel (discos, CIFS, RAID)
df -h                                   # espaço em disco por partição
lsblk -o NAME,SIZE,TYPE,MOUNTPOINTS     # mapa de discos e partições
htop                                    # processos, CPU e memória (F10 sai)
```

### Roteiro de diagnóstico do portal

```bash
systemctl status cdpni-portal nginx --no-pager   # os dois de pé?
ss -tlnp | grep -E '5000|8443'                   # gunicorn no 5000, nginx no 8443?
journalctl -u cdpni-portal -n 30 --no-pager      # erro do Python aparece aqui
tail -5 /var/log/cdpni_portal_error.log          # erro do gunicorn/aplicação
nginx -t                                         # config do nginx válida?
```

---

## 13. Mapa de scripts do repositório

| Script | Uso |
|---|---|
| `bootstrap.sh` | Instalação do zero (interativo) — só na primeira vez |
| `change-ip.sh` | Troca de IP segura (seção 4.3) |
| `scripts/raid_ids.sh` | Gera `raid.devices` com caminhos by-id a partir do array em uso |
| `fix_vars.sh` | Completa um all.yml antigo com seções novas (org, network_ranges…) |
| `scripts/fix_*.sh` | Correções pontuais de grupos Samba (legado) |
| `uninstall.sh` | Remove tudo (⚠️ destrutivo) |

---

*Documento gerado a partir do estado real do repositório — cada trecho de
configuração citado corresponde ao que os roles do Ansible instalam.*
