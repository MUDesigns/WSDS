@echo off
rem Witchspire Dedicated Server - opens a console that shows the live server log.
rem Add  -AllLogs  to see every engine log line instead of the important ones.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0StartServer.ps1" %*
pause
