@echo off
chcp 936 >nul 2>&1
rem ============================================================================
rem  Coco's 整合包 · 客户端 Mod 前置裁剪脚本(在 packwiz 安装器之前执行)
rem
rem  角色 : 和 [客户端]mod后处理修复脚本.bat 配对
rem           后处理修复 = mod 装好之后修 jar 和配置
rem           前置裁剪   = mod 装之前动元数据, 决定哪些模组根本不落地
rem  作用 : 按 [客户端]模组裁剪清单.txt 把元数据里的客户端模组删减掉, 并删掉 mods
rem         里已经落地的 jar, 让不同的人只装自己想要的那部分. 逻辑都在同名 ps1 里.
rem         分类依据是 packwiz 元数据里的 side 字段:
rem           client = 仅客户端    both 或无 side = 双端    server = 仅服务端
rem  调用 : 1) [客户端]mod更新脚本.bat 在 packwiz refresh 之后自动 call 本脚本 -InPlace
rem         2) 双击 = 带编号的交互挑选, 选完立即生效
rem  用法 : [客户端]mod前置裁剪脚本.bat [-Quiet] [-List] [-Plan] [-Reset] [-Profile 名字] [--help]
rem  返回 : 0 正常(含没有可裁剪的模组)     1 出错, 只影响本步骤
rem ============================================================================

setlocal
set "RC=0"
set "PRE_PS1=%~dp0[客户端]mod前置裁剪脚本.ps1"
set "PS=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if not exist "%PS%" set "PS=powershell.exe"

if not exist "%PRE_PS1%" (
    echo [错误] 缺少 %PRE_PS1%
    echo        bat 与 ps1 必须成对放在同一个目录
    endlocal & exit /b 1
)

if /i "%~1"=="--help" goto :pre_help
if /i "%~1"=="-h" goto :pre_help
if /i "%~1"=="-help" goto :pre_help
if /i "%~1"=="/?" goto :pre_help
if /i "%~1"=="/help" goto :pre_help

rem 无参数 = 有人双击, 进交互挑选, 结束后停一下窗口好让人看完
if "%~1"=="" goto :pre_interactive

rem 有参数 = 被更新脚本或命令行调用, 原样透传
"%PS%" -NoProfile -ExecutionPolicy Bypass -File "%PRE_PS1%" %*
set "RC=%errorlevel%"
goto :pre_done

:pre_interactive
"%PS%" -NoProfile -ExecutionPolicy Bypass -File "%PRE_PS1%" -Pick
set "RC=%errorlevel%"
echo.
pause
goto :pre_done

:pre_help
"%PS%" -NoProfile -ExecutionPolicy Bypass -File "%PRE_PS1%" -Help
set "RC=%errorlevel%"

:pre_done
endlocal & exit /b %RC%