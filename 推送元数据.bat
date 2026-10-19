@echo off
rem ============================================================================
rem  Coco 整合包 - 元数据推送 (启动器)
rem
rem  用法
rem    双击                        交互式, 自动找同级的 Coco_Minecraft_CustomModPack
rem    推送元数据.bat -NoPrompt    不询问, 直接提交并推送
rem    推送元数据.bat -DryRun      只看将要提交的内容
rem    推送元数据.bat -Message "..."  指定提交标题
rem    推送元数据.bat -PackDir "D:\包目录"
rem ============================================================================

chcp 936 >nul 2>&1
setlocal

set "PS1=%~dp0推送元数据.ps1"
if not exist "%PS1%" (
    echo [错误] 找不到 推送元数据.ps1
    pause
    exit /b 1
)

title Coco 整合包 - 元数据推送
powershell -NoProfile -ExecutionPolicy Bypass -File "%PS1%" %*
set "RC=%errorlevel%"

if not "%RC%"=="0" (
    echo.
    echo [提示] 退出码 %RC%, 按任意键关闭窗口
    pause >nul
)
endlocal
exit /b %RC%
