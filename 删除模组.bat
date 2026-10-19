@echo off
rem ============================================================================
rem  Coco 整合包 - 删除模组 (启动器)
rem
rem  用法
rem    删除模组.bat                       交互输入中文名或 slug
rem    删除模组.bat 苹果皮                按中文名查找(先查别名表)
rem    删除模组.bat appleskin             按 slug
rem    删除模组.bat appleskin -DryRun     只看将删除什么
rem
rem  流程: 删除清单文档中的该行 -> 移除 mods/ 下的元数据(确认后备份再删)
rem ============================================================================

chcp 936 >nul 2>&1
setlocal

set "PS1=%~dp0删除模组.ps1"
if not exist "%PS1%" (
    echo [错误] 找不到 删除模组.ps1
    pause
    exit /b 1
)

title Coco 整合包 - 删除模组
powershell -NoProfile -ExecutionPolicy Bypass -File "%PS1%" %*
set "RC=%errorlevel%"

if not "%RC%"=="0" (
    if not defined COCO_NO_PAUSE (
        echo.
        if "%RC%"=="2" (
            echo [提示] 清单文档里没有该模组, 未做改动
        ) else (
            echo [提示] 退出码 %RC%, 按任意键关闭窗口
        )
        pause >nul
    )
)
endlocal
exit /b %RC%