@echo off
rem Compila la APK de farmanorte. El registro queda en _build_logs\build.log
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0tools\compilar-apk.ps1"
