@echo off
setlocal
set EXTRA=
set /p AUTO=Iniciar con Windows? [s/N]:
if /i "%AUTO%"=="s" set EXTRA=-Autostart
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0install.ps1" %EXTRA% %*
echo.
pause
