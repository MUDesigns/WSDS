@echo off
rem Join a Witchspire dedicated server (settings in ClientConfig.json).
rem Optional:  JoinServer.bat -Server 203.0.113.5:7777 -Name Morgana
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0JoinServer.ps1" %*
