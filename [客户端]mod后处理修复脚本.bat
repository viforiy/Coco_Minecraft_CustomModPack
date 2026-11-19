@echo off
chcp 65001 >nul

pushd "%~dp0"
set "RC=0"
set "QUIET="
if /i "%~1"=="-Quiet" set "QUIET=1"

if not defined QUIET (
    echo.
    echo ============================================================
    echo   模组后处理修复脚本
    echo   目录: %~dp0
    echo ============================================================
)

call :step "Grand Teleport 版本号修正" fix-grand-teleport-version.bat
call :step "MCEF 依赖下载通道封闭" mcef-block-download.bat
call :step "MuoniumConfig 声音事件补丁" muoniumconfig-patch-soundevent.bat

if not defined QUIET (
    echo.
    if "%RC%"=="0" (echo === 全部完成 ===) else (echo === 有步骤失败，见上面输出 ===)
)

popd
if not defined QUIET pause
exit /b %RC%


rem ---------------------------------------------------------------------------
rem  参数1 显示名，参数2 同目录下的 bat 文件
rem ---------------------------------------------------------------------------
:step
set "STEP_NAME=%~1"
set "STEP_FILE=%~2"
if not exist "%~dp0%STEP_FILE%" (
    if not defined QUIET echo    [skip] %STEP_NAME%  缺少 %STEP_FILE%
    exit /b 0
)
if not defined QUIET echo.
if not defined QUIET echo --- %STEP_NAME% ---
if defined QUIET goto :step_quiet
call "%~dp0%STEP_FILE%" < nul
goto :step_check
:step_quiet
call "%~dp0%STEP_FILE%" -Quiet
:step_check
if errorlevel 1 goto :step_fail
if not defined QUIET echo    [ok] %STEP_NAME%
exit /b 0
:step_fail
echo    [fail] %STEP_NAME%  返回码 %errorlevel%
set "RC=1"
exit /b 0