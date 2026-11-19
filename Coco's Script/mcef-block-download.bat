@echo off
chcp 936 >nul 2>&1
rem ============================================================================
rem  Coco's 整合包 · MCEF 依赖下载通道封闭
rem
rem  作用 : MCEF(Chromium) 每次启动都会去 mcef-download.cinemamod.com 校验并可能
rem         重下 100MB+ 的 java-cef 依赖. 本脚本做两件事:
rem           1) 把 MCEFDownloader.downloadJavaCefChecksum() 改成 return true
rem              (纯本地判断, 直接声明本地已是最新, 那个后台线程不再发请求)
rem           2) config\mcef\mcef.properties 里写 skip-download=true 双保险
rem  调用 : [客户端]mod后处理修复脚本.bat 按顺序 call 本脚本, 也可单独双击.
rem  用法 : mcef-block-download.bat [-GameDir <实例目录>] [-Quiet] [--help]
rem  返回 : 0 已封闭 / 本来就已封闭 / 没装 mcef     1 出错
rem ============================================================================

setlocal
set "RC=0"
set "TARGET_PS1=%~dp0mcef-block-download.ps1"
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