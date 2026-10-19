@echo off
rem ============================================================================
rem  Coco 整合包 - 维护别名表 (启动器)
rem
rem  用法
rem    维护别名表.bat                  从清单文档刷新中文名对照
rem    维护别名表.bat -DryRun          只统计, 不写文件
rem    维护别名表.bat -PackDir "D:\包" 指定其它包目录
rem ============================================================================

chcp 936 >nul 2>&1
setlocal

set "PS1=%~dp0维护别名表.ps1"
if not exist "%PS1%" (
    echo [错误] 找不到 维护别名表.ps1
    pause
    exit /b 1
)

title Coco 整合包 - 维护别名表
powershell -NoProfile -ExecutionPolicy Bypass -File "%PS1%" %*
set "RC=%errorlevel%"

if not "%RC%"=="0" (
    if not defined COCO_NO_PAUSE (
        echo.
        echo [提示] 退出码 %RC%, 按任意键关闭窗口
        pause >nul
    )
)
endlocal
exit /b %RC%