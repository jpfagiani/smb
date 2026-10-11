@echo off
setlocal
title Desconectar pastas do servidor
set "SERVIDOR=10.14.29.12"
rem Remove as unidades de rede e as credenciais guardadas deste servidor.
rem Use quando aparecer o erro 1219 ou ao trocar de usuario.
echo Desconectando tudo de \\%SERVIDOR% ...
for /f "tokens=2,3" %%A in ('net use ^| find /i "\\%SERVIDOR%\\"') do net use %%A /delete /y >nul 2>&1
net use \\%SERVIDOR% /delete /y >nul 2>&1
cmdkey /delete:%SERVIDOR% >nul 2>&1
echo Pronto. Agora rode o Mapear_... da pasta desejada.
pause
