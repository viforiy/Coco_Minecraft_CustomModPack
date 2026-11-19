@echo off
chcp 936 >nul 2>&1
rem ============================================================================
rem  Coco's 整合包 - 客户端 Mod 前置裁剪脚本 - 在 packwiz 安装器之前执行
rem
rem  角色: 和 [客户端]mod后处理修复脚本.bat 配对
rem        后处理修复 = mod 装好之后修 jar 和配置
rem        前置裁剪   = mod 装之前动元数据, 决定哪些模组根本不落地
rem
rem  做什么: 按 [客户端]模组裁剪清单.txt 把元数据里的客户端模组删减掉, 并删掉 mods
rem          里已经落地的 jar, 让不同的人只装自己想要的那部分. 逻辑都在同名 ps1 里.
rem          分类来源是 packwiz 元数据里的 side 字段:
rem            client = 仅客户端   both 或无 side = 双端   server = 仅服务端
rem
rem  调用方:
rem    1) [客户端]mod更新脚本.bat 在 packwiz refresh 之后自动 call 本脚本 -InPlace,
rem       作用在本次刚拉下来的元数据上, 索引刷新由更新脚本收尾
rem    2) 双击 = 交互挑选, 带编号的客户端模组列表, 选完立即生效
rem
rem  用法:
rem    本脚本.bat                 交互挑选
rem    本脚本.bat -Quiet          静默按清单执行, 给启动前指令链用
rem    本脚本.bat -List           只打印分类, 不动元数据与 mods
rem    本脚本.bat -Plan           只出清单与报告, 不删文件
rem    本脚本.bat -Reset          备份旧清单后重建, 全部保留
rem    本脚本.bat -Profile 小霸王  用另一份清单
rem    本脚本.bat --help          看全部参数
rem
rem  返回码: 0 = 正常, 含没有可裁剪的模组  1 = 出错, 只影响本步骤
rem ============================================================================

setlocal
set "RC=0"
set "PRE_PS1=%~dp0[客户端]mod前置裁剪脚本.ps1"
set "PS=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if not exist "%PS%" set "PS=powershell.exe"

if not exist "%PRE_PS1%" (
    echo [错误] 缺少 %PRE_PS1%
    echo        前置裁剪脚本要 bat 与 ps1 成对放在整合包实例目录里
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
goto :pre_done

:pre_done
endlocal & exit /b %RC%
