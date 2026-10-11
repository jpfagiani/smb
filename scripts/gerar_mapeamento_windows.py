#!/usr/bin/env python3
"""
Gera os scripts .bat de mapeamento de pastas para os PCs Windows, a partir da
lista de compartilhamentos do projeto (roles/samba/vars/main.yml).

Uso:  python3 scripts/gerar_mapeamento_windows.py [IP_DO_SERVIDOR]
Saida: pasta mapeamento_windows/  (Mapear_<Pasta>.bat para cada pasta
       + Mapear_VARIAS_pastas.bat + Desconectar_pastas.bat + LEIA-ME.txt)

Os .bat NAO contem senha: ela e digitada na hora (e guardada pelo Windows).
Arquivos em ASCII com quebra CRLF, para abrir em qualquer Windows sem
problema de acentuacao.
"""
import os
import re
import sys
import unicodedata

import yaml

RAIZ = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
VARS = os.path.join(RAIZ, "roles", "samba", "vars", "main.yml")
SAIDA = os.path.join(RAIZ, "mapeamento_windows")
SERVIDOR = sys.argv[1] if len(sys.argv) > 1 else "10.14.29.12"


def ascii_(t):
    return unicodedata.normalize("NFKD", t).encode("ascii", "ignore").decode()


def grava(nome, linhas):
    texto = "\r\n".join(linhas) + "\r\n"
    with open(os.path.join(SAIDA, nome), "w", encoding="ascii", newline="") as f:
        f.write(ascii_(texto))


def cabecalho_mapa(pasta, usuario, rotulo):
    return [
        "@echo off",
        "setlocal",
        f"title Mapear pasta {rotulo}",
        "rem ============================================================",
        f"rem  Conecta a pasta {rotulo} como unidade de rede.",
        "rem  Pede a SENHA do usuario uma unica vez; o Windows guarda.",
        "rem  Para mudar o IP do servidor ou a letra, edite as linhas abaixo.",
        "rem ============================================================",
        f'set "SERVIDOR={SERVIDOR}"',
        f'set "PASTA={pasta}"',
        f'set "USUARIO={usuario}"',
        'set "LETRA=Z:"',
        "",
        "rem letra ocupada? deixa o Windows escolher a proxima livre",
        'if exist %LETRA%\\ set "LETRA=*"',
        "",
        'net use | find /i "\\\\%SERVIDOR%\\%PASTA%" >nul && (',
        "    echo Esta pasta ja esta conectada neste computador.",
        "    pause & exit /b 0",
        ")",
        "",
        "echo Conectando \\\\%SERVIDOR%\\%PASTA% como %USUARIO% ...",
        'net use %LETRA% "\\\\%SERVIDOR%\\%PASTA%" * /user:%USUARIO% /savecred /persistent:yes',
        "if errorlevel 1 goto erro",
        "echo.",
        "echo Pronto! A pasta aparece em Este Computador.",
        "pause & exit /b 0",
        "",
        ":erro",
        "echo.",
        "echo NAO foi possivel conectar. Causas comuns:",
        "echo  - Erro 1219: este PC ja esta conectado ao servidor com OUTRO usuario.",
        "echo    Rode Desconectar_pastas.bat e tente de novo.",
        "echo  - Senha ou usuario incorretos (confira com o CPD).",
        "echo  - Servidor desligado ou fora da rede.",
        "pause & exit /b 1",
    ]


def main():
    with open(VARS, encoding="utf-8") as f:
        dados = yaml.safe_load(f)
    shares = dados["samba_shares"]
    os.makedirs(SAIDA, exist_ok=True)
    for velho in os.listdir(SAIDA):
        if velho.endswith((".bat", ".txt")):
            os.remove(os.path.join(SAIDA, velho))

    lista = []
    for s in shares:
        nome = s["name"]
        usuario = s.get("user", nome.lower())
        lista.append((nome, usuario, s.get("type", "regular")))
        # CPD e guest_hidden tambem ganham script; so nao aparece na lista
        grava(f"Mapear_{nome}.bat", cabecalho_mapa(nome, usuario, nome.replace("_", " ")))

    # Varias pastas com UM usuario (jpfagiani, rcborges, cpd, supervisao...)
    pastas = [n for n, _, t in lista if t in ("regular",)]
    grava("Mapear_VARIAS_pastas.bat", [
        "@echo off",
        "setlocal enabledelayedexpansion",
        "title Mapear varias pastas",
        "rem ============================================================",
        "rem  Para quem acessa VARIAS pastas com UM unico usuario",
        "rem  (ex.: supervisao, ou usuarios operacionais do CPD).",
        "rem  Edite USUARIO e a lista PASTAS (separadas por espaco).",
        "rem  Cada pasta recebe a proxima letra livre.",
        "rem ============================================================",
        f'set "SERVIDOR={SERVIDOR}"',
        'set "USUARIO=supervisao"',
        'set "PASTAS=' + " ".join(p for p in pastas if p != "Diretoria_Geral") + '"',
        "",
        "echo Usuario: %USUARIO%",
        "set PRIMEIRA=1",
        "for %%P in (%PASTAS%) do (",
        '    net use | find /i "\\\\%SERVIDOR%\\%%P" >nul || (',
        "        if defined PRIMEIRA (",
        '            net use * "\\\\%SERVIDOR%\\%%P" * /user:%USUARIO% /savecred /persistent:yes',
        "            set PRIMEIRA=",
        "        ) else (",
        '            net use * "\\\\%SERVIDOR%\\%%P" /persistent:yes',
        "        )",
        "    )",
        ")",
        "echo.",
        "echo Concluido. Pastas conectadas:",
        "net use",
        "pause",
    ])

    grava("Desconectar_pastas.bat", [
        "@echo off",
        "setlocal",
        "title Desconectar pastas do servidor",
        f'set "SERVIDOR={SERVIDOR}"',
        "rem Remove as unidades de rede e as credenciais guardadas deste servidor.",
        "rem Use quando aparecer o erro 1219 ou ao trocar de usuario.",
        "echo Desconectando tudo de \\\\%SERVIDOR% ...",
        "for /f \"tokens=2,3\" %%A in ('net use ^| find /i \"\\\\%SERVIDOR%\\\\\"') do net use %%A /delete /y >nul 2>&1",
        "net use \\\\%SERVIDOR% /delete /y >nul 2>&1",
        "cmdkey /delete:%SERVIDOR% >nul 2>&1",
        "echo Pronto. Agora rode o Mapear_... da pasta desejada.",
        "pause",
    ])

    linhas = ["MAPEAMENTO DE PASTAS - COMO USAR", "=" * 34, "",
              f"Servidor: {SERVIDOR}  (edite no topo do .bat se o IP mudar)", "",
              "1) Copie esta pasta para o PC (ou deixe em um compartilhamento).",
              "2) De dois cliques em Mapear_<SUA PASTA>.bat.",
              "3) Digite a senha quando pedir. A pasta vira uma unidade (Z:) em",
              "   Este Computador e volta sozinha a cada login.", "",
              "IMPORTANTE - um usuario por servidor:",
              "O Windows nao aceita dois usuarios DIFERENTES conectados ao mesmo",
              "servidor no mesmo PC (erro 1219). Por isso:",
              " - PC de setor: use so o Mapear_ da pasta do setor.",
              " - Quem acessa varias pastas: use Mapear_VARIAS_pastas.bat (um usuario).",
              " - Trocar de usuario: rode Desconectar_pastas.bat antes.", "",
              "Pastas e usuarios:", ""]
    for n, u, t in lista:
        marca = "  (convidado: o Windows bloqueia sem usuario; use este mesmo)" if t.startswith("guest") else ""
        linhas.append(f"  {n:<20} usuario: {u}{marca}")
    grava("LEIA-ME.txt", linhas)
    print(f"{len(lista)} pastas -> {SAIDA}")


main()
