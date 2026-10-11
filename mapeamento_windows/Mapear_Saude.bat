@echo off
setlocal
title Mapear pasta Saude
rem ============================================================
rem  Conecta a pasta Saude como unidade de rede.
rem  Pede a SENHA do usuario uma unica vez; o Windows guarda.
rem  Para mudar o IP do servidor ou a letra, edite as linhas abaixo.
rem ============================================================
set "SERVIDOR=10.14.29.12"
set "PASTA=Saude"
set "USUARIO=saude"
set "LETRA=Z:"

rem letra ocupada? deixa o Windows escolher a proxima livre
if exist %LETRA%\ set "LETRA=*"

net use | find /i "\\%SERVIDOR%\%PASTA%" >nul && (
    echo Esta pasta ja esta conectada neste computador.
    pause & exit /b 0
)

echo Conectando \\%SERVIDOR%\%PASTA% como %USUARIO% ...
net use %LETRA% "\\%SERVIDOR%\%PASTA%" * /user:%USUARIO% /savecred /persistent:yes
if errorlevel 1 goto erro
echo.
echo Pronto! A pasta aparece em Este Computador.
pause & exit /b 0

:erro
echo.
echo NAO foi possivel conectar. Causas comuns:
echo  - Erro 1219: este PC ja esta conectado ao servidor com OUTRO usuario.
echo    Rode Desconectar_pastas.bat e tente de novo.
echo  - Senha ou usuario incorretos (confira com o CPD).
echo  - Servidor desligado ou fora da rede.
pause & exit /b 1
