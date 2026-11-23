@echo off
chcp 936 >nul 2>&1
rem ============================================================================
rem  Coco's 整合包 · 客户端 Mod 后处理修复脚本
rem
rem  作用 : mod 装好之后按顺序修三处会崩的地方, 每一步都是一个独立 bat+ps1,
rem         幂等, 已经修过的会跳过:
rem           1) Grand Teleport 版本号非法(neoforge-1.0.1)
rem           2) MCEF 每次启动都去下载站校验/下载 Chromium 依赖
rem           3) MuoniumConfig x AmbientSounds 的 SoundPlayedEvent NPE
rem  调用 : PCL 启动前执行指令第二段, 紧跟更新脚本之后:
rem           call "...\Coco's Script\[客户端]mod更新脚本.bat" "$INST_JAVA" && call "...\本脚本.bat" -Quiet
rem  用法 : [客户端]mod后处理修复脚本.bat [-Quiet] [--help]
rem  返回 : 0 全部完成或跳过     1 有步骤失败
rem ============================================================================

setlocal
set "RC=0"
set "QUIET="
set "SCRIPT_DIR=%~dp0"
if "%SCRIPT_DIR:~-1%"=="\" set "SCRIPT_DIR=%SCRIPT_DIR:~0,-1%"

rem 实例目录 = 脚本目录的上一级(脚本都在 Coco's Script 里); 老布局(脚本在根目录)也兼容
set "GAME_DIR=%SCRIPT_DIR%"
for %%D in ("%SCRIPT_DIR%\..") do set "GAME_DIR=%%~fD"
if exist "%SCRIPT_DIR%\mods" set "GAME_DIR=%SCRIPT_DIR%"
if defined COCO_GAME_DIR set "GAME_DIR=%COCO_GAME_DIR%"

if /i "%~1"=="--help" goto :usage
if /i "%~1"=="-h" goto :usage
if /i "%~1"=="/?" goto :usage
if /i "%~1"=="-Quiet" set "QUIET=1"

if not defined QUIET (
    echo.
    echo ============================================================
    echo   客户端 Mod 后处理修复
    echo   实例目录: %GAME_DIR%
    echo   脚本目录: %SCRIPT_DIR%
    echo ============================================================
)

call :step "Grand Teleport 版本号修正" fix-grand-teleport-version.bat
call :step "MCEF 依赖下载通道封闭" mcef-block-download.bat
call :step "MuoniumConfig 声音事件补丁" muoniumconfig-patch-soundevent.bat

if not defined QUIET (
    echo.
    if "%RC%"=="0" (echo === 全部完成 ===) else (echo === 有步骤失败, 见上面输出 ===)
    echo.
    pause
)
endlocal & exit /b %RC%


rem ---------------------------------------------------------------------------
rem  参数1 显示名, 参数2 同目录下的 bat
rem  静默时把 -Quiet 传下去; 交互时把 stdin 接到 nul, 免得 helper 的"按回车"卡住
rem ---------------------------------------------------------------------------
:step
set "STEP_NAME=%~1"
set "STEP_FILE=%~2"
if not exist "%SCRIPT_DIR%\%STEP_FILE%" (
    if not defined QUIET echo    [跳过] %STEP_NAME%  缺少 %STEP_FILE%
    exit /b 0
)
if not defined QUIET echo.
if not defined QUIET echo --- %STEP_NAME% ---
if defined QUIET (
    call "%SCRIPT_DIR%\%STEP_FILE%" -Quiet -GameDir "%GAME_DIR%"
) else (
    call "%SCRIPT_DIR%\%STEP_FILE%" -GameDir "%GAME_DIR%" < nul
)
if errorlevel 1 goto :step_fail
if not defined QUIET echo    [完成] %STEP_NAME%
exit /b 0
:step_fail
echo    [失败] %STEP_NAME%  返回码 %errorlevel%
set "RC=1"
exit /b 0


:usage
echo.
echo   客户端 Mod 后处理修复脚本
echo.
echo   用法  [客户端]mod后处理修复脚本.bat [-Quiet] [--help]
echo.
echo     -Quiet    静默: 只打印结果, 不暂停(给 PCL 启动前指令用)
echo     --help    看这份帮助
echo.
echo   三件事依次执行, 每个都是独立 bat+ps1, 幂等, 已修过的会跳过:
echo     fix-grand-teleport-version.bat        Grand Teleport 版本号修正
echo     mcef-block-download.bat               MCEF 不再联网校验/下载 Chromium 依赖
echo     muoniumconfig-patch-soundevent.bat    去掉 OneConfig 的 SoundPlayedEvent mixin
echo.
echo   实例目录默认取脚本目录的上一级, 也可用环境变量 COCO_GAME_DIR 指定
echo.
endlocal & exit /b 0