@echo off
setlocal enabledelayedexpansion
title Mapear varias pastas
rem ============================================================
rem  Para quem acessa VARIAS pastas com UM unico usuario
rem  (ex.: supervisao, ou usuarios operacionais do CPD).
rem  Edite USUARIO e a lista PASTAS (separadas por espaco).
rem  Cada pasta recebe a proxima letra livre.
rem ============================================================
set "SERVIDOR=10.14.29.12"
set "USUARIO=supervisao"
set "PASTAS=Administrativo Aevp Almoxarifado Cadastro Canil Chefia_Turno_I Chefia_Turno_II Chefia_Turno_III Chefia_Turno_IV Cipa Conexao_Familiar Csd Educacao Financas Inclusao Infraestrutura Nucleo_de_Pessoal Planilhas Portaria_Turno_I Portaria_Turno_II Portaria_Turno_III Portaria_Turno_IV Rol_de_Visitas Saude Simic Sindicancia Supervisao"

echo Usuario: %USUARIO%
set PRIMEIRA=1
for %%P in (%PASTAS%) do (
    net use | find /i "\\%SERVIDOR%\%%P" >nul || (
        if defined PRIMEIRA (
            net use * "\\%SERVIDOR%\%%P" * /user:%USUARIO% /savecred /persistent:yes
            set PRIMEIRA=
        ) else (
            net use * "\\%SERVIDOR%\%%P" /persistent:yes
        )
    )
)
echo.
echo Concluido. Pastas conectadas:
net use
pause
