@echo off
chcp 936 >nul 2>&1
rem ============================================================================
rem  Coco's 整合包 · 维护脚本: 把修好的 Grand Teleport 托管进 packwiz 仓库
rem
rem  作用 : mods\grand-teleport.pw.toml 仍指向 Modrinth 的 Fabric 构建, 会和本地
rem         修好版本号的 NeoForge 构建同 modId(gtalike_teleport) 撞车, 又是启动崩溃.
rem         本脚本把 NeoForge 构建复制进元数据仓, 删掉旧 metafile, 再 refresh.
rem  调用 : 维护仓库时手动跑, 不进 PCL 启动前指令; 默认只看不动手.
rem  用法 : packwiz-manage-grand-teleport.bat                 预览(默认)
rem         packwiz-manage-grand-teleport.bat -Apply          真改仓库(不 commit)
rem         packwiz-manage-grand-teleport.bat -Apply -Quiet
rem  返回 : 0 正常      1 出错
rem ============================================================================

setlocal
set "RC=0"
set "TARGET_PS1=%~dp0packwiz-manage-grand-teleport.ps1"
set "PS=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if not exist "%PS%" set "PS=powershell.exe"

if not exist "%TARGET_PS1%" (
    echo [错误] 缺少 %TARGET_PS1%
    echo        bat 与 ps1 必须成对放在同一个目录
    endlocal & exit /b 1
)

"%PS%" -NoProfile -ExecutionPolicy Bypass -File "%TARGET_PS1%" %*
set "RC=%errorlevel%"
endlocal & exit /b %RC%