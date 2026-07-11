# Manual do Servidor de Arquivos — CDPNI

> **Público-alvo:** qualquer pessoa que precise instalar o servidor ou usá-lo no dia a dia.
> Para detalhes técnicos, comandos avançados e explicações linha a linha, consulte o [MANUAL_TECNICO.md](MANUAL_TECNICO.md).

---

## 1. O que é este servidor

Um servidor de arquivos completo para a rede local da unidade, com:

| Componente | O que faz |
|---|---|
| **Samba** | Compartilhamentos de rede acessíveis pelo Windows (`\\IP-do-servidor`) |
| **RAID** | Os dados ficam gravados em vários discos ao mesmo tempo — se um disco queimar, nada se perde |
| **Portal Web** | Administração completa pelo navegador: `https://IP-do-servidor:8443` |
| **Lixeira** | Todo arquivo excluído dos compartilhamentos pode ser restaurado |
| **Backup** | Cópia dos dados para pasta local ou para outra máquina Windows da rede |
| **Firewall** | Só a rede interna acessa o servidor; proteção contra tentativas de senha |
| **Logs de acesso** | Registro de quem abriu, renomeou ou excluiu cada arquivo |

---

## 2. Instalação do zero

### 2.1 O que você precisa

- Máquina com **1 ou mais discos além do disco do sistema** — com 2+ o instalador monta RAID (recomendado); com apenas 1, instala em **modo disco único**, sem tolerância a falhas (⚠️ backups tornam-se ainda mais importantes);
- **Debian 13** instalado no disco do sistema (instalação padrão, sem interface gráfica);
- Acesso à internet durante a instalação (para baixar os pacotes);
- Os IPs da sua rede em mãos: IP fixo para o servidor, gateway, DNS e NTP.

> ⚠️ **Os discos escolhidos para o RAID serão totalmente apagados.**
> Confira duas vezes qual é o disco do sistema antes de confirmar.

### 2.2 Passo a passo

```bash
# 1. Entre como root
su -

# 2. Instale o git e clone o repositório
apt install -y git
git clone https://github.com/jpfagiani/smb /opt/smb
cd /opt/smb

# 3. Execute o instalador
bash bootstrap.sh
```

O instalador é interativo. O que cada pergunta significa:

| Pergunta | O que responder |
|---|---|
| **Interface de rede** | A placa de rede conectada à rede local (o instalador lista todas, mesmo sem IP) |
| **IP fixo do servidor** | O endereço que o servidor terá para sempre (ex.: `10.14.29.9`) |
| **Máscara CIDR** | Quase sempre `24` (rede /24 = 254 endereços) |
| **Gateway** | O roteador da rede — precisa estar na mesma faixa do IP (o instalador valida) |
| **DNS** | Servidor de nomes (Enter = usa o gateway) |
| **Servidor NTP** | Fonte de hora da intranet — padrão `10.14.8.20` (GPU). Hora errada quebra o apt e bagunça os logs |
| **Nome do servidor** | Ex.: `smb` — vira o endereço `smb.dominio` |
| **Domínio local** | Ex.: `cdpni.local` |
| **Sigla da unidade** | Ex.: `CDPNI`, `PLAVII` — aparece no portal e no certificado |
| **Nome por extenso** | Ex.: `Centro de Detenção Provisória de Nova Independência` |
| **Login do administrador** | Usuário com acesso total (padrão `sambadmin`) |
| **Senha padrão dos usuários Samba** | Senha inicial de todos os usuários (cada um troca depois no portal) |
| **Senha do painel web** | Reservada ao painel legado — anote mesmo assim |
| **Discos para o RAID** | Os números dos discos de dados (⚠️ nunca o disco do sistema — o instalador o marca com `[SO]`) |
| **Nível de RAID** | `1` = espelho (2 discos) · `5` = paridade (3+, tolera 1 falha) · `6` = tolera 2 falhas (4+) · `10` = espelho+velocidade (4+ pares). Com **1 disco só**, o instalador pula esta pergunta e usa o modo disco único (sem RAID) |

Ao confirmar, a instalação roda sozinha (10–20 min). O RAID continua sincronizando em segundo plano por algumas horas depois — o servidor já funciona normalmente nesse período.

### 2.3 Conferência pós-instalação

```bash
# Todos devem aparecer "active (running)":
systemctl status smbd nmbd nginx cdpni-portal nftables fail2ban --no-pager

# RAID montado e sincronizando:
cat /proc/mdstat
df -h /mnt/raid
```

No navegador de qualquer máquina da rede: `https://IP-do-servidor:8443` → tela de login do portal.
No Windows: `Win+R` → `\\IP-do-servidor` → lista dos compartilhamentos.

> O navegador avisa "conexão não segura" porque o certificado é autoassinado.
> Para remover o aviso, baixe `https://IP-do-servidor:8443/cdpni-ca.crt` e instale
> como "Autoridade de Certificação Raiz Confiável" nas máquinas.

---

## 3. O Portal — dia a dia

Acesse `https://IP-do-servidor:8443` e entre com **usuário e senha do Samba** (os mesmos dos compartilhamentos). Administradores veem todos os menus; usuários comuns veem apenas seus arquivos.

### 3.1 Compartilhamentos (arquivos)

Navegue pelas pastas dos shares direto no navegador: baixar, enviar, renomear, criar pasta e excluir — útil quando não se está numa máquina com o share mapeado.

### 3.2 Lixeira 🗑️ (administradores)

Tudo que é excluído de qualquer compartilhamento vem parar aqui. A navegação é igual ao Explorer do Windows:

- A tela inicial mostra **o que foi excluído** (pastas e arquivos), por quem, de qual share, quando e o tamanho;
- **Clique numa pasta para entrar nela** e continue navegando (o caminho no topo é clicável para voltar);
- **↩️ Restaurar** devolve o item ao local exato de onde foi excluído — funciona para uma pasta inteira ou para um único arquivo. Se a pasta já existir no share, o conteúdo é mesclado;
- **⬇️** baixa o arquivo; **✖** exclui definitivamente;
- **Esvaziar itens > 30 dias** limpa exclusões antigas para liberar espaço.

Também dá para acessar pelo Windows: digite `\\IP-do-servidor\Recycle` na barra do Explorer (só administradores; para restaurar, recorte e cole de volta no share).

### 3.3 Usuários e Grupos (administradores)

- **Criar usuário**: define login e senha — a pessoa já consegue acessar os shares dos grupos dela;
- **Permissões**: marque de quais compartilhamentos o usuário participa;
- **Trocar senha / desativar**: pelos botões da lista;
- Cada usuário pode trocar a própria senha no botão **Senha** (canto superior direito).

### 3.4 Compartilhamentos Samba (administradores)

Criar novos shares, definir se são restritos (por grupo) ou públicos, e editar as permissões dos existentes.

### 3.5 RAID / Discos (administradores)

- **Saúde**: estado do RAID (Saudável/Degradado/Reconstruindo) e S.M.A.R.T. resumido de cada disco (OK/Atenção/FALHA, temperatura, horas de uso);
- **Disco novo**: ao plugar um disco vazio, ele aparece em "Discos novos detectados" com duas opções:
  - **🛟 Hot spare** — fica de reserva; se um disco do RAID falhar, assume **automaticamente**;
  - **📈 Expandir capacidade** — junta-se ao RAID e aumenta o espaço útil (a redistribuição leva horas; o espaço aparece sozinho ao terminar);
- **🔬** roda o teste S.M.A.R.T. completo de um disco.

> Se o RAID aparecer **DEGRADADO**, um disco falhou: o sistema continua funcionando,
> mas troque o disco o quanto antes (veja o manual técnico, seção RAID).

### 3.6 Backups (administradores)

Dois destinos:

- **Local (no servidor)** — grava um `.tar.gz` numa pasta do próprio servidor;
- **Rede Windows (SMB)** — grava direto numa pasta compartilhada de outra máquina:
  1. Na máquina de destino (Windows): botão direito na pasta → **Propriedades → Compartilhamento → Compartilhamento Avançado** → marque "Compartilhar esta pasta" → em **Permissões**, dê "Alteração" ao seu usuário;
  2. No portal: informe o **IP** da máquina, o **nome do compartilhamento**, usuário e senha do Windows;
  3. **📂 Navegar** lista as pastas do destino para escolher onde gravar;
  4. **Executar Backup** — o destino é testado antes de iniciar; qualquer problema aparece na hora, em português.

Marque o que incluir: arquivos dos shares, configuração do Samba, usuários e portal. O card **"Última execução"** mostra o resultado do último backup.

> **RAID não é backup.** O RAID protege contra defeito de disco; o backup protege
> contra exclusão acidental, ransomware e desastres. Faça backup em outra máquina.

### 3.7 Logs de acesso (administradores)

A tabela **"Acessos a arquivos"** mostra quem **Abriu / Renomeou / Excluiu / Criou pasta** em cada share, com data, IP e o arquivo.

- Badge amarelo **"(falhou)"** = a tentativa retornou erro — nem sempre é acesso negado: o Windows faz sondagens normais que falham (arquivos de miniatura, travas do Office). Falha seguida de sucesso no mesmo segundo é acesso normal;
- **Falhas repetidas** de um usuário num share onde ele não deveria entrar, isso sim merece atenção.

---

## 4. Tarefas comuns

### Trocar o IP do servidor

```bash
cd /opt/smb
sudo bash change-ip.sh
```

O script pergunta o novo IP/gateway/DNS, valida tudo **antes** de aplicar e, se você estiver via SSH, roda em segundo plano para sobreviver à queda da conexão. Depois, atualize o DNS no gateway (`gwos dns update smb <novo-ip>`).

### Atualizar o sistema (novas versões deste repositório)

```bash
cd /opt/smb
git pull
ansible-playbook -i inventory/hosts.ini site.yml --diff
```

É seguro re-executar quantas vezes quiser: o playbook **nunca** apaga o RAID em uso nem reseta senhas já alteradas.

### Passar de disco único para RAID (depois de instalado)

Dá para fazer sem perder os dados. O caminho simples: **Backups** (portal) →
adicione o disco novo → reinstale com `bootstrap.sh` escolhendo 2+ discos →
restaure o backup. Há também uma conversão avançada sem reinstalar (RAID 1 em
funcionamento) — veja o [MANUAL_TECNICO.md](MANUAL_TECNICO.md) seção 5.6.
Faça backup antes, de qualquer forma.

### Adicionar um disco novo ao RAID

Plugue o disco → portal → **RAID / Discos** → "Discos novos detectados" → escolha Hot spare ou Expandir. Depois de expandir, atualize a lista de discos do arquivo de configuração:

```bash
sudo bash /opt/smb/scripts/raid_ids.sh   # gera o bloco devices: atualizado
nano /opt/smb/group_vars/all.yml         # cole no lugar do bloco antigo
cp /opt/smb/group_vars/all.yml /root/all.yml.bak
```

### Guardar a configuração

O arquivo `/opt/smb/group_vars/all.yml` contém toda a configuração do servidor (IPs, senhas, discos) e **fica fora do git**. Depois de qualquer mudança:

```bash
cp /opt/smb/group_vars/all.yml /root/all.yml.bak
```

---

## 5. Problemas comuns

| Sintoma | Causa provável | Solução |
|---|---|---|
| Portal não abre (502) | Serviço do portal parado | `systemctl restart cdpni-portal` |
| Portal não abre (timeout) | nginx parado ou firewall | `systemctl restart nginx` · confira se a máquina está numa rede permitida |
| Usuário não acessa o share | Sem senha Samba ou senha errada | Portal → Usuários → Trocar senha |
| "Conta bloqueada" ao errar senha no portal | fail2ban baniu o IP (5 erros/5 min) | Espere 30 min ou `fail2ban-client set cdpni-portal unbanip <IP>` |
| `apt update` reclama de assinatura "Not live until" | Relógio atrasado | `chronyc makestep` e confira o NTP (`chronyc sources`) |
| RAID degradado | Disco falhou | Manual técnico, seção "Substituir disco" |
| Backup SMB falha na hora | Compartilhamento/senha errados | A mensagem do portal diz exatamente o quê; confira o compartilhamento no Windows |
| Arquivo sumiu | Alguém excluiu | Portal → Lixeira → Restaurar |

---

## 6. Instalando em outra unidade (ex.: PLAVII)

O sistema é genérico: rode o `bootstrap.sh` na máquina nova e responda com os dados da unidade (IP, hostname, domínio, sigla e nome por extenso). Tudo — portal, certificado, rede — se adapta às respostas. Nada precisa ser editado no código.
