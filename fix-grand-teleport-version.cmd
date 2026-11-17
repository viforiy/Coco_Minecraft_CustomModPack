@echo off
chcp 65001 >nul
rem Fix GrandTeleport (NeoForge port) invalid version string in neoforge.mods.toml
rem Crash: InvalidModFileException: Illegal version number specified neoforge-1.0.1
setlocal
set "PS=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
"%PS%" -NoProfile -ExecutionPolicy Bypass -File "%~dp0fix-grand-teleport-version.ps1" %*
endlocal
