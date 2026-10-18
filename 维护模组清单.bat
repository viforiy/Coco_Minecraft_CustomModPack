@echo off
rem ============================================================================
rem  Coco 整合包 - 新增模组同步工具 (启动器)
rem
rem  用法
rem    双击                          交互式, 自动找同级的 Coco_Minecraft_CustomModPack
rem    维护模组清单.bat -DryRun       只看差异, 不写文件
rem    维护模组清单.bat -NoSide       跳过 side 校正
rem    维护模组清单.bat -All          不逐个询问, 直接处理全部新增模组
rem    维护模组清单.bat -PackDir "D:\包目录"   指定其他 packwiz 包
rem ============================================================================

chcp 936 >nul 2>&1
setlocal

set "PS1=%~dp0维护模组清单.ps1"
if not exist "%PS1%" (
    echo [错误] 找不到 维护模组清单.ps1
    echo        请把它和本 bat 放在同一个目录
    pause
    exit /b 1
)

title Coco 整合包 - 新增模组同步工具
powershell -NoProfile -ExecutionPolicy Bypass -File "%PS1%" %*
set "RC=%errorlevel%"

if not "%RC%"=="0" (
    echo.
    echo [提示] 退出码 %RC%, 按任意键关闭窗口
    pause >nul
)
endlocal
exit /b %RC%
