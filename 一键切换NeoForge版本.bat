@echo off
rem ============================================================================
rem  NeoForge version switcher - double-click entry
rem
rem  This file is deliberately pure ASCII. cmd.exe decodes a batch file with the
rem  console code page, so any non-ASCII byte in here can break parsing on some
rem  setups. All Chinese UI text lives in NeoForgeSwitch.ps1 instead.
rem
rem  Double-click -> interactive menu.
rem  With an argument -> runs once and exits (handy for shortcuts / other scripts):
rem      status | list | latest | rollback
rem      target <version>     e.g. target 21.1.266
rem      dryrun <version>
rem ============================================================================

setlocal
set "PS1=%~dp0NeoForgeSwitch.ps1"
set "PSEXE=powershell"
where pwsh >nul 2>&1
if not errorlevel 1 set "PSEXE=pwsh"

if not exist "%PS1%" (
    echo.
    echo [ERROR] NeoForgeSwitch.ps1 not found next to this file:
    echo         %PS1%
    echo.
    pause
    exit /b 1
)

if "%~1"=="" (
    "%PSEXE%" -NoProfile -ExecutionPolicy Bypass -File "%PS1%" -Menu
    exit /b 0
)

set "ARG="
if /i "%~1"=="status"   set "ARG=-Status"
if /i "%~1"=="list"     set "ARG=-List"
if /i "%~1"=="latest"   set "ARG=-Latest"
if /i "%~1"=="rollback" set "ARG=-Rollback"
if /i "%~1"=="target"   set "ARG=-Target %~2"
if /i "%~1"=="dryrun"   set "ARG=-Target %~2 -DryRun"

if not defined ARG (
    echo Usage: %~nx0 [status^|list^|latest^|target ^<version^>^|dryrun ^<version^>^|rollback]
    exit /b 2
)

"%PSEXE%" -NoProfile -ExecutionPolicy Bypass -File "%PS1%" %ARG%
exit /b %errorlevel%