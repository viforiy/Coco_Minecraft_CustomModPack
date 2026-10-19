@echo off
rem ============================================================================
rem  Coco 整合包 - 添加模组 (启动器)
rem
rem  用法
rem    添加模组.bat                          交互输入链接或 slug
rem    添加模组.bat sodium                   直接按 slug 添加
rem    添加模组.bat https://modrinth.com/mod/iris
rem    添加模组.bat sodium -DryRun           只解析与检查, 不写文件
rem    添加模组.bat sodium -PackDir "D:\包"  指定其它包目录
rem ============================================================================

chcp 936 >nul 2>&1
setlocal

set "PS1=%~dp0添加模组.ps1"
if not exist "%PS1%" (
    echo [错误] 找不到 添加模组.ps1
    pause
    exit /b 1
)

title Coco 整合包 - 添加模组
powershell -NoProfile -ExecutionPolicy Bypass -File "%PS1%" %*
set "RC=%errorlevel%"

if not "%RC%"=="0" (
    if not defined COCO_NO_PAUSE (
        echo.
        if "%RC%"=="2" (
            echo [提示] 该模组已在包内, 未做改动
        ) else (
            echo [提示] 退出码 %RC%, 按任意键关闭窗口
        )
        pause >nul
    )
)
endlocal
exit /b %RC%