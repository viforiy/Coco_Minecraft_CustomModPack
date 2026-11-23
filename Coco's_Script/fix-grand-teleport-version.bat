@echo off
chcp 936 >nul 2>&1
rem ============================================================================
rem  Coco's 整合包 · Grand Teleport 版本号修正
rem
rem  作用 : GrandTeleport*.jar 的 META-INF/neoforge.mods.toml 里版本写成了
rem         "neoforge-1.0.1", FML 要求版本号必须数字开头, 于是整份 mod 被判无效:
rem           InvalidModFileException: Illegal version number specified neoforge-1.0.1
rem         本脚本只把这一行改回 "1.0.1", 其余条目原样保留, 改前留 .bak-versionbug.
rem  调用 : [客户端]mod后处理修复脚本.bat 按顺序 call 本脚本, 也可单独双击.
rem  用法 : fix-grand-teleport-version.bat [-GameDir <实例目录>] [-Quiet] [--help]
rem  返回 : 0 已修好 / 本来就合法 / 没装这个 mod     1 出错
rem ============================================================================

setlocal
set "RC=0"
set "TARGET_PS1=%~dp0fix-grand-teleport-version.ps1"
set "PS=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if not exist "%PS%" set "PS=powershell.exe"

if not exist "%TARGET_PS1%" (
    echo [错误] 缺少 %TARGET_PS1%
    echo        bat 与 ps1 必须成对放在同一个目录
    endlocal & exit /b 1
)

"%PS%" -NoProfile -ExecutionPolicy Bypass -File "%TARGET_PS1%" %*
set "RC=%errorlevel%"
endlocal & exit /b %RC%