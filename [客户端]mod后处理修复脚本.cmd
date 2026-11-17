@echo off
chcp 65001 >nul
rem ============================================================================
rem  模组后处理修复脚本  (Mod post-process fix entry)
rem
rem  统一入口，依次执行三个启动前补丁：
rem    1) fix-grand-teleport-version.cmd        Grand Teleport 版本号 (neoforge-1.0.1 -> 1.0.1)
rem    2) mcef-block-download.cmd              MCEF(Chromium) 依赖下载通道封闭
rem    3) muoniumconfig-patch-soundevent.cmd   MuoniumConfig 声音事件注入移除(修 AmbientSounds NPE)
rem
rem  PCL 启动前执行指令里填这一行：
rem    call "{verpath}\模组后处理修复脚本.cmd" -Quiet
rem
rem  -Quiet : 只有失败才输出(PCL 用)
rem  不带参数: 手动双击用, 打印每一步的详细结果, 最后停一下
rem  任一补丁失败 -> 返回非 0, 配合 && 链可让启动中止并看到原因
rem ============================================================================

setlocal enabledelayedexpansion
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

call :step "Grand Teleport 版本号修正" fix-grand-teleport-version.cmd
call :step "MCEF 依赖下载通道封闭" mcef-block-download.cmd
call :step "MuoniumConfig 声音事件补丁" muoniumconfig-patch-soundevent.cmd

if not defined QUIET (
    echo.
    if "%RC%"=="0" (echo === 全部完成 ===) else (echo === 有步骤失败, 见上面输出 ===)
)

popd
if not defined QUIET pause
exit /b %RC%


rem ---------------------------------------------------------------------------
rem  %1 = 显示名, %2 = 同目录下的 .cmd
rem ---------------------------------------------------------------------------
:step
set "STEP_NAME=%~1"
set "STEP_FILE=%~2"
if not exist "%~dp0%STEP_FILE%" (
    if not defined QUIET echo    [skip] %STEP_NAME%  - 缺少 %STEP_FILE%
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
echo    [fail] %STEP_NAME%  (返回码 %errorlevel%)
set "RC=1"
exit /b 0
