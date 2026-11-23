@echo off
chcp 936 >nul 2>&1
rem ============================================================================
rem  Coco's 整合包 · NeoForge 版本一键切换
rem
rem  作用 : PCL2 没有"换一个 NeoForge 版本"的入口, 本脚本直接改磁盘上的三处记录:
rem           1) versions\<版本>\<版本>.json   (--fml.* 参数 / loader 库 / mainClass)
rem           2) PCL\Setup.ini                 (VersionNeoForge)
rem           3) PCL\config.json                (MinecraftInstallManifest)
rem         然后补齐 libraries 下缺失的 loader jar; 全部逻辑在同名 ps1 里,
rem         含 12 步流程、往返切换 SHA1 一致性验收、失败自动从备份还原.
rem  调用 : 菜单式操作, 不进 PCL 启动前指令; 跑完必须重启 PCL2 才生效.
rem  用法 : 一键切换NeoForge版本.bat                     交互菜单
rem         一键切换NeoForge版本.bat status               看当前状态
rem         一键切换NeoForge版本.bat list                 列出可用 NeoForge 版本
rem         一键切换NeoForge版本.bat latest               换到最新
rem         一键切换NeoForge版本.bat rollback             回滚上一次切换
rem         一键切换NeoForge版本.bat target 21.1.266      换到指定版本
rem         一键切换NeoForge版本.bat dryrun 21.1.266      只演练不写盘
rem         一键切换NeoForge版本.bat javas                列出本机扫到的所有 Java(带来源与版本)
rem         一键切换NeoForge版本.bat javas-deep           同上, 额外全盘深度扫描
rem  返回 : 0 成功 / 已取消     2 参数不认识     1 出错
rem ============================================================================

setlocal
set "NEO_PS1=%~dp0NeoForgeSwitch.ps1"
set "PS=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if not exist "%PS%" set "PS=powershell.exe"

if not exist "%NEO_PS1%" (
    echo [错误] 缺少 %NEO_PS1%
    echo        bat 与 ps1 必须成对放在同一个目录
    endlocal & exit /b 1
)

if "%~1"=="" (
    "%PS%" -NoProfile -ExecutionPolicy Bypass -File "%NEO_PS1%" -Menu
    endlocal & exit /b %errorlevel%
)
if /i "%~1"=="--help" goto :neo_usage
if /i "%~1"=="-h" goto :neo_usage
if /i "%~1"=="/?" goto :neo_usage

set "NEO_ARG="
if /i "%~1"=="status"   set "NEO_ARG=-Status"
if /i "%~1"=="list"     set "NEO_ARG=-List"
if /i "%~1"=="latest"   set "NEO_ARG=-Latest"
if /i "%~1"=="rollback" set "NEO_ARG=-Rollback"
if /i "%~1"=="target"   set "NEO_ARG=-Target %~2"
if /i "%~1"=="dryrun"   set "NEO_ARG=-Target %~2 -DryRun"
if /i "%~1"=="javas"      set "NEO_ARG=-ListJava"
if /i "%~1"=="javas-deep" set "NEO_ARG=-ListJava -DeepScan"

if not defined NEO_ARG (
    echo [错误] 不认识的参数: %~1
    echo        可用: status / list / latest / rollback / target ^<版本^> / dryrun ^<版本^>
    echo              javas / javas-deep / --help
    endlocal & exit /b 2
)

"%PS%" -NoProfile -ExecutionPolicy Bypass -File "%NEO_PS1%" %NEO_ARG%
endlocal & exit /b %errorlevel%

:neo_usage
echo.
echo   Coco's 整合包 · NeoForge 版本一键切换
echo.
echo   用法  一键切换NeoForge版本.bat [子命令]
echo.
echo     不带参数            交互菜单
echo     status              看当前 NeoForge 版本 + 三处记录是否一致
echo     list                列出该 Minecraft 版本可用的 NeoForge 版本
echo     javas               列出本机扫到的所有 Java(PCL 启动历史 + 环境变量 + 注册表
echo                         + 常见目录 + 启动器自带), 带来源和版本
echo     javas-deep          同上, 再加一遍全盘深度扫描(慢)
echo     latest              切到最新版
echo     rollback            回滚上一次切换
echo     target ^<版本^>       切到指定版本, 例如 target 21.1.266
echo     dryrun ^<版本^>       只演练, 不写盘
echo     --help              看这份帮助
echo.
echo   切换完成必须重启 PCL2 才生效: PCL 启动时用的是内存里缓存的版本信息
echo.
endlocal & exit /b 0