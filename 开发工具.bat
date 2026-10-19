@echo off
rem ============================================================================
rem  Coco 整合包 - 开发工具 (统一入口)
rem
rem  日常只有三件事: 添加模组 / 同步清单 / 推送元数据
rem  子脚本仍可单独双击运行, 本菜单只是把它们收在一处
rem
rem  用法
rem    双击                 进入菜单
rem    开发工具.bat 2       直接执行第 2 项, 适合脚本串联
rem    直接回车             退出
rem ============================================================================

chcp 936 >nul 2>&1
setlocal
title Coco 整合包 - 开发工具
set "BASE=%~dp0"

rem 参数直通: 开发工具.bat 2 等价于进入菜单后按 2
set "PICK=%~1"

:menu
if defined PICK goto :dispatch
echo.
echo ==========================================================
echo   Coco 整合包 · 开发工具
echo ==========================================================
if defined LAST_ACT (
    echo   上一动作: %LAST_ACT%   退出码 %LAST_RC%
) else (
    echo   上一动作: 无
)
if exist "%BASE%菜单状态.ps1" powershell -NoProfile -ExecutionPolicy Bypass -File "%BASE%菜单状态.ps1"
echo.
echo   1  添加模组      录入新模组, 只改 mods/
echo   2  同步清单      对齐 mods/ 与文档, 改动待提交
echo   3  推送元数据    提交并推送, 须在同步之后
echo   0  退出
echo.
echo   顺序 1 - 2 - 3; 先推送会把未同步状态写进基线
echo.
set "PICK="
set /p "PICK=请选择: "
if not defined PICK goto :bye
goto :dispatch

:dispatch
rem 分发后立即清空, 否则返回菜单时会被旧值再次分发而死循环
set "CUR=%PICK%"
set "PICK="
if "%CUR%"=="1" goto :add
if "%CUR%"=="2" goto :sync
if "%CUR%"=="3" goto :push
if "%CUR%"=="0" goto :bye
echo.
echo [注意] 无效的序号: %CUR%
timeout /t 2 >nul
goto :menu

:add
echo.
echo [执行] 添加模组
if not exist "%BASE%添加模组.bat" (
    echo [信息] 添加模组尚未提供, 计划在 F3 交付
    echo        当前请用 packwiz 命令行录入, 再回到这里选 2 同步清单
    echo.
    set "LAST_ACT=添加模组"
    set "LAST_RC=未实现"
    pause
    goto :menu
)
set "COCO_NO_PAUSE=1"
call "%BASE%添加模组.bat"
set "RC=%errorlevel%"
set "COCO_NO_PAUSE="
set "LAST_ACT=添加模组"
set "LAST_RC=%RC%"
goto :menu

:sync
echo.
echo [执行] 同步清单
set "COCO_NO_PUSH_PROMPT=1"
set "COCO_NO_PAUSE=1"
call "%BASE%维护模组清单.bat"
set "RC=%errorlevel%"
set "COCO_NO_PUSH_PROMPT="
set "COCO_NO_PAUSE="
set "LAST_ACT=同步清单"
set "LAST_RC=%RC%"
if not "%RC%"=="0" goto :sync_failed
echo.
set "GO="
set /p "GO=同步完成, 现在推送吗 [y/N] : "
if /i not "%GO%"=="y" goto :menu
set "PICK=3"
goto :dispatch

:sync_failed
echo.
echo [注意] 同步未成功完成, 退出码 %RC%, 已跳过推送环节
echo        修正问题后重新选择 2
echo.
pause
goto :menu

:push
echo.
echo [执行] 推送元数据
set "COCO_NO_PAUSE=1"
call "%BASE%推送元数据.bat"
set "RC=%errorlevel%"
set "COCO_NO_PAUSE="
set "LAST_ACT=推送元数据"
set "LAST_RC=%RC%"
if "%RC%"=="0" goto :push_ok
echo.
echo [注意] 推送未成功完成, 退出码 %RC%
if "%RC%"=="2" echo        原因是元数据与清单文档不一致, 请先选 2 同步清单
if "%RC%"=="1" echo        可能是网络或代理问题, 提交可能已保留在本地
echo.
pause
goto :menu

:push_ok
echo.
echo [完成] 推送流程已结束, 上方为提交与推送结果
goto :menu

:bye
endlocal
exit /b 0