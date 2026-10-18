@echo off
rem ============================================================================
rem  Coco's 整合包 - 客户端 Mod 更新脚本 - PCL 启动前执行
rem
rem  执行链:
rem    1) 定位 Java 21, 缺失时从国内镜像下载便携版
rem    2) git 同步模组元数据仓, 首次 clone, 之后 fetch + reset 强同步
rem       机器没装 git 时自动改为下载仓库 zip 压缩包
rem       元数据仓地址可写在同目录 mod更新源.cfg 里, 不用改本脚本
rem    3) 准备 packwiz.exe, 缺失时从 nightly 构建下载
rem    4) packwiz refresh, 重建 index.toml 与哈希
rem    5) packwiz serve, 本地包服务提供 pack.toml / index.toml
rem    6) packwiz-installer-bootstrap, 按元数据同步 mods 目录
rem    7) 汇总 mods 变动
rem    8) 生成 PCL 启动前执行命令
rem
rem  用法: PCL - 版本设置 - 设置 - 高级选项 - 启动前执行指令
rem        cd /d "本文件夹" ^&^& call "本脚本名"
rem ============================================================================

chcp 936 >nul 2>&1
rem 开启 VT 转义, 用于彩色输出, 老系统上无效但无副作用
for /f "delims=" %%A in ('echo prompt $E^| cmd') do set "ESC=%%A"
setlocal enabledelayedexpansion

set "C_RST=%ESC%[0m"
set "C_RED=%ESC%[91m"
set "C_GRN=%ESC%[92m"
set "C_YEL=%ESC%[93m"
set "C_BLU=%ESC%[96m"
set "C_DIM=%ESC%[90m"
set "C_STEP=%ESC%[30;106m"
set "C_BIG=%ESC%[97;45m"

set "E_INFO=echo %C_BLU%[信息]%C_RST%"
set "E_OK=echo %C_GRN%[完成]%C_RST%"
set "E_WARN=echo %C_YEL%[警告]%C_RST%"
set "E_ERR=echo %C_RED%[错误]%C_RST%"
set "E_SUB=%C_DIM%  -%C_RST%"

rem 第一个参数可以是 PCL 的 $INST_JAVA, 也可以手动传 java.exe 路径
if not "%~1"=="" set "COCO_JAVA=%~1"

if /i "%~1"=="--help" goto :usage
if /i "%~1"=="/?" goto :usage
if /i "%~1"=="-h" goto :usage

rem ---------------------------------------------------------------------------
rem  一. 配置区, 一般只需要改这里
rem ---------------------------------------------------------------------------

rem 模组元数据仓, 自己推送维护的 packwiz 仓库
set "PACK_GIT_URL=https://github.com/viforiy/Coco_Minecraft_CustomModPack.git"
set "PACK_GIT_BRANCH=main"

rem 远端 pack.toml, 例如挂到 GitHub Pages 后填 https://xxx/pack.toml
rem 留空 = 用本地元数据仓 + 本地服务; 填写后直接走远端, 不再拉仓
set "REMOTE_PACK_URL="

rem 包来源模式:
rem   file  = 默认, 不起服务, 安装器直接读本地 pack.toml
rem           不占端口, 也不会触发 Windows 防火墙询问
rem   serve = 拉起 packwiz serve 本地服务, 安装器走 http://127.0.0.1:端口/pack.toml
rem           只有想让局域网其它机器来拉包时才需要, 会监听端口并可能弹防火墙询问
set "PACK_SOURCE=file"

rem 缓存根目录, 元数据仓 / packwiz.exe / 便携 Java / 日志 都在这里
rem 放在整合包版本文件夹之外, 重装整合包不必重复下载
set "CACHE_ROOT=%LOCALAPPDATA%\CocoPackwiz"

rem 系统代理, Clash 默认 127.0.0.1:7890, 直连失败时自动兜底
set "PROXY_HOST=127.0.0.1"
set "PROXY_PORT=7890"

rem 本地包服务起始端口, 被占用则自动往后找
set "PACK_PORT_BASE=8080"

rem 更新失败时是否让 PCL 中止启动: 1=中止, 0=仅告警, 继续用现有 mods 进游戏
set "FAIL_HARD=0"

rem 是否在更新前备份 mods 目录: 1=打包 zip 到缓存目录, 0=不备份
set "BACKUP_MODS=0"

rem 元数据同步方式: auto = 优先 git, 没装 git 或同步失败时改用 zip 压缩包
rem                 git  = 只用 git
rem                 zip  = 只用 zip, 适合机器上没有 git 的情况
set "META_SOURCE=auto"

rem 同目录的 mod更新源.cfg 会覆盖上面的源配置, 由一键部署生成, 手改也生效
rem 这样换元数据仓不用改脚本, 脚本升级时也不会把源配置冲掉
if exist "%~dp0mod更新源.cfg" (
    for /f "usebackq eol=# tokens=1,* delims==" %%a in ("%~dp0mod更新源.cfg") do (
        if /i "%%a"=="PACK_GIT_URL" set "PACK_GIT_URL=%%b"
        if /i "%%a"=="PACK_GIT_BRANCH" set "PACK_GIT_BRANCH=%%b"
        if /i "%%a"=="META_SOURCE" set "META_SOURCE=%%b"
        if /i "%%a"=="PACK_SOURCE" set "PACK_SOURCE=%%b"
        if /i "%%a"=="PROXY_PORT" set "PROXY_PORT=%%b"
        if /i "%%a"=="BACKUP_MODS" set "BACKUP_MODS=%%b"
        if /i "%%a"=="FAIL_HARD" set "FAIL_HARD=%%b"
    )
)
rem 以下为环境变量覆盖, 便于多实例或调试
if defined COCO_GAME_DIR set "GAME_DIR=%COCO_GAME_DIR%"
if defined COCO_CACHE_ROOT set "CACHE_ROOT=%COCO_CACHE_ROOT%"
if defined COCO_PACK_GIT_URL set "PACK_GIT_URL=%COCO_PACK_GIT_URL%"
if defined COCO_PACK_SOURCE set "PACK_SOURCE=%COCO_PACK_SOURCE%"
if defined COCO_META_SOURCE set "META_SOURCE=%COCO_META_SOURCE%"
if defined COCO_REMOTE_PACK_URL set "REMOTE_PACK_URL=%COCO_REMOTE_PACK_URL%"
if defined COCO_PROXY_PORT set "PROXY_PORT=%COCO_PROXY_PORT%"

rem ---------------------------------------------------------------------------
rem  二. 路径与运行期变量
rem ---------------------------------------------------------------------------

cd /d "%~dp0"
set "_GAME_DIR_ARG=%~dp0"
if "%_GAME_DIR_ARG:~-1%"=="\" set "_GAME_DIR_ARG=%_GAME_DIR_ARG:~0,-1%"
if not defined GAME_DIR set "GAME_DIR=%_GAME_DIR_ARG%"
if "%GAME_DIR:~-1%"=="\" set "GAME_DIR=%GAME_DIR:~0,-1%"

set "SCRIPT_NAME=%~nx0"
set "PROXY_URL=http://%PROXY_HOST%:%PROXY_PORT%"

set "META_DIR=%CACHE_ROOT%\meta"
set "LOG_DIR=%CACHE_ROOT%\logs"
set "TMP_DIR=%CACHE_ROOT%\tmp"
set "BAK_DIR=%CACHE_ROOT%\backup"
set "JRE_DIR=%CACHE_ROOT%\jre"
set "TOOLS_DIR=%CACHE_ROOT%\tools"

set "BOOTSTRAP_JAR=%GAME_DIR%\packwiz-installer-bootstrap.jar"
set "INSTALLER_JAR=%GAME_DIR%\packwiz-installer.jar"
set "PACKWIZ_EXE=%META_DIR%\packwiz.exe"
set "MODS_DIR=%GAME_DIR%\mods"

set "PACK_URL="
set "PACK_PORT=%PACK_PORT_BASE%"
set "STEP=0"
set "STEP_TOTAL=8"
set "FINAL_RC=0"
set "PROXY_AUTO=1"
set "CURL_OK=0"
set "PS_OK=0"
set "HAVE_META=0"
set "HAVE_PACKWIZ=0"
set "SERVE_STARTED=0"
set "SERVE_PID="
set "INS_RC=1"
set "BOOTSTRAP_OPTS="
set "GIT_EXE="
set "GIT_RC=0"
set "GIT_HEAD="
set "JAVA_EXE="
set "JAVA_MAJOR="
set "MODS_COUNT_BEFORE=0"
set "MODS_COUNT_AFTER=0"
set "MODS_ADDED=0"
set "MODS_REMOVED=0"
set "PCL_CMD_DONE=0"
set "FAIL_STEP=0"

title Coco's 整合包 - Mod 更新

rem ---------------------------------------------------------------------------
rem  三. 环境自检: 目录 / 时间戳 / curl / 日志
rem ---------------------------------------------------------------------------

call :make_dirs
if not exist "%CACHE_ROOT%" (
    rem 缓存目录不可写时退回整合包目录
    set "CACHE_ROOT=%GAME_DIR%\.packwiz-cache"
    set "META_DIR=!CACHE_ROOT!\meta"
    set "LOG_DIR=!CACHE_ROOT!\logs"
    set "TMP_DIR=!CACHE_ROOT!\tmp"
    set "BAK_DIR=!CACHE_ROOT!\backup"
    set "JRE_DIR=!CACHE_ROOT!\jre"
    set "TOOLS_DIR=!CACHE_ROOT!\tools"
    set "PACKWIZ_EXE=!META_DIR!\packwiz.exe"
    call :make_dirs
)

set "TS="
for /f "delims=" %%T in ('powershell -NoProfile -Command "Get-Date -Format yyyyMMdd-HHmmss" 2^>nul') do if not defined TS set "TS=%%T"
if not defined TS set "TS=T%RANDOM%"
set "LOG_FILE=%LOG_DIR%\mod-update-%TS%.log"
set "STATE_FILE=%CACHE_ROOT%\last-run.txt"
set "FAIL_FILE="

where powershell >nul 2>&1
if not errorlevel 1 set "PS_OK=1"
set "CURL=%SystemRoot%\System32\curl.exe"
if exist "%CURL%" set "CURL_OK=1"

>>"%LOG_FILE%" echo === Coco 整合包 Mod 更新 %TS% ===
>>"%LOG_FILE%" echo GAME_DIR=%GAME_DIR%
>>"%LOG_FILE%" echo CACHE_ROOT=%CACHE_ROOT%
>>"%LOG_FILE%" echo PACK_SOURCE=%PACK_SOURCE%

echo.
echo %C_BIG%  Coco's 整合包 - 客户端 Mod 更新  %C_RST%
echo %C_DIM%  ------------------------------------------------------------------%C_RST%
echo %C_DIM%  整合包目录 :%C_RST% %GAME_DIR%
echo %C_DIM%  元数据仓   :%C_RST% %META_DIR%
echo %C_DIM%  日志文件   :%C_RST% %LOG_FILE%
echo %C_DIM%  ------------------------------------------------------------------%C_RST%

if "!CURL_OK!"=="1" (
    %E_INFO% 下载工具 curl, 系统内置
) else (
    %E_WARN% 未找到 curl.exe, 下载改走 PowerShell, 会慢一些
)
call :resume_hint


rem ===========================================================================
rem  步骤 1/8 - Java
rem ===========================================================================
rem 防呆: 元数据仓目录里也有 pack.toml, 在那里跑会把 mod 装进元数据仓
if exist "!GAME_DIR!\pack.toml" (
    echo.
    %E_ERR% 本目录里有 pack.toml, 看起来是模组元数据仓, 不是整合包实例
    echo        %E_SUB% 本脚本要放在实例目录里, mod 会装到脚本所在目录的 mods
    echo        %E_SUB% 仓库里那一份只用于推送分发, 请不要在仓库目录里运行
    echo        %E_SUB% 确实要在本目录运行, 先把 pack.toml 挪走
    exit /b 1
)
rem 单独裸跑时先拦一道: 由部署器放的 ack 文件 或 传入 java 路径 或 设了 COCO_NO_PROMPT 时跳过
set "ACK_FILE=%CACHE_ROOT%\ack-client.txt"
if "%~1"=="" if not defined COCO_NO_PROMPT if not exist "!ACK_FILE!" (
    echo.
    echo %C_BIG%  注意 这是 客户端 Mod 更新脚本本体  %C_RST%
    echo   它会按当前目录的 mod更新源.cfg 拉取元数据, 并改写本目录的 mods
    echo   正常流程是用仓库里的 一键部署.bat 把它放到正确位置并配好源
    echo   如果你只是想装上用, 请退出并运行 一键部署.bat
    echo   确认继续的话, 之后本机不再提示
    echo.
    call :confirm "我确认知道自己在做什么, 继续"
    if not "!errorlevel!"=="0" (
        echo   已取消, 没有修改任何文件
        set "FINAL_RC=1"
        goto :finish
    )
    > "!ACK_FILE!" echo ack manual !TS!
)

call :step "定位 Java 运行环境"

call :find_java
if not defined JAVA_EXE (
    %E_WARN% 没找到 Java 17 及以上版本, 从国内镜像下载便携 Java 21
    call :download_java
)

if not defined JAVA_EXE (
    set "FAIL_STEP=1"
    set "FAIL_MSG=没有可用的 Java 运行环境"
    goto :fail
)
echo    %C_GRN%Java 路径:%C_RST% !JAVA_EXE!
echo    %C_DIM%Java 版本:%C_RST% !JAVA_MAJOR!
if not "!JAVA_MAJOR!"=="21" (
    %E_WARN% 主版本是 !JAVA_MAJOR! 而不是 21, 仅用于跑安装器, 游戏本体 Java 由 PCL 指定
)
>>"%LOG_FILE%" echo JAVA_EXE=!JAVA_EXE! major=!JAVA_MAJOR!

rem ===========================================================================
rem  步骤 2/8 - 模组元数据
rem ===========================================================================
call :step "同步模组元数据仓 git"

if defined REMOTE_PACK_URL (
    %E_INFO% 已配置远端 pack.toml, 跳过本地元数据仓
    set "PACK_SOURCE=remote"
    set "PACK_URL=%REMOTE_PACK_URL%"
    set "HAVE_META=1"
    goto :meta_done
)

call :git_sync
if "!HAVE_META!"=="1" (
    %E_OK% 元数据就绪, pack.toml 位于 !META_DIR!
) else (
    set "FAIL_STEP=2"
    set "FAIL_MSG=拿不到模组元数据"
    goto :fail
)
:meta_done

rem ===========================================================================
rem  步骤 3/8 - packwiz.exe
rem ===========================================================================
call :step "准备 packwiz.exe"

if exist "!PACKWIZ_EXE!" (
    set "_pwz_size=0"
    for %%A in ("!PACKWIZ_EXE!") do set "_pwz_size=%%~zA"
    if !_pwz_size! geq 5000000 (
        set "HAVE_PACKWIZ=1"
        %E_OK% 缓存命中, 直接复用
        echo        %E_SUB% !PACKWIZ_EXE!
    ) else (
        %E_WARN% 现有文件体积异常 !_pwz_size! 字节, 重新下载
        del /q "!PACKWIZ_EXE!" >nul 2>&1
    )
)
if "!HAVE_PACKWIZ!"=="0" call :find_packwiz_on_path
if "!HAVE_PACKWIZ!"=="0" call :download_packwiz

if "!HAVE_PACKWIZ!"=="1" (
    echo    %C_GRN%packwiz:%C_RST% !PACKWIZ_EXE!
) else (
    %E_WARN% packwiz.exe 不可用, 跳过本地服务, 直接把本地 pack.toml 交给安装器
    if /i not "!PACK_SOURCE!"=="remote" set "PACK_SOURCE=file"
)

rem ===========================================================================
rem  步骤 4/8 - 刷新索引
rem ===========================================================================
call :step "刷新模组索引 packwiz refresh"

if /i "!PACK_SOURCE!"=="remote" (
    %E_INFO% 远端模式, 无需刷新本地索引
) else if "!HAVE_META!"=="0" (
    %E_WARN% 没有本地元数据, 跳过刷新
) else if "!HAVE_PACKWIZ!"=="0" (
    %E_WARN% 没有 packwiz, 直接用仓内 index.toml, 若哈希过期安装器会报 hash 无效
) else (
    call :refresh_index
    if not "!REF_RC!"=="0" (
        set "FAIL_STEP=4"
        set "FAIL_MSG=索引刷新失败, 错误码 !REF_RC!"
        goto :fail
    )
)

rem ===========================================================================
rem  步骤 5/8 - 包来源
rem ===========================================================================
call :step "准备包来源 packwiz serve"

if /i "!PACK_SOURCE!"=="remote" (
    %E_INFO% 使用远端包 !PACK_URL!
    goto :serve_done
)
if "!HAVE_META!"=="0" (
    %E_ERR% 没有可用的本地元数据, 无法提供包服务
    goto :serve_done
)
if /i "!PACK_SOURCE!"=="file" (
    %E_INFO% 配置为 file 模式, 不起本地服务
    goto :serve_file_mode
)
if "!HAVE_PACKWIZ!"=="0" goto :serve_file_mode

rem serve 模式会监听端口, 有管理员权限就先放行, 没有就提示一次
call :fw_ensure "!PACKWIZ_EXE!"
if "!errorlevel!"=="1" call :fw_warn_once

call :pick_port
call :start_serve
call :wait_serve
if defined PACK_URL (
    %E_OK% 本地包服务就绪, PID !SERVE_PID!
    echo        %E_SUB% !PACK_URL!
    goto :serve_done
)

%E_WARN% 本地包服务 40 秒内未就绪, 日志 %TMP_DIR%\packwiz-serve.log
call :stop_serve

:serve_file_mode
if not exist "!META_DIR!\pack.toml" (
    %E_ERR% 本地缺少 pack.toml, 包来源不可用
    goto :serve_done
)
set "PACK_SOURCE=file"
set "PACK_URL=!META_DIR!\pack.toml"
%E_INFO% 使用 file 模式, 安装器直接读本地 pack.toml
:serve_done

rem ===========================================================================
rem  步骤 6/8 - 执行安装器
rem ===========================================================================
call :step "执行 packwiz 安装器, 同步 mods 目录"

call :ensure_bootstrap
call :ensure_installer_jar

if not defined PACK_URL (
    set "FAIL_STEP=5"
    set "FAIL_MSG=没有可用的包地址"
    goto :fail
)
if not exist "!BOOTSTRAP_JAR!" (
    set "FAIL_STEP=6"
    set "FAIL_MSG=缺少 packwiz-installer-bootstrap.jar"
    goto :fail
)

call :snapshot_mods before
if "%BACKUP_MODS%"=="1" call :backup_mods

echo    %C_DIM%包地址  :%C_RST% !PACK_URL!
echo    %C_DIM%目标目录:%C_RST% !GAME_DIR!
echo    %C_DIM%执行命令:%C_RST% java -jar packwiz-installer-bootstrap.jar !BOOTSTRAP_OPTS! -g -s client --pack-folder "%GAME_DIR%"
echo.
>>"%LOG_FILE%" echo ---- installer ----
>>"%LOG_FILE%" echo PACK_URL=!PACK_URL!

call :run_installer direct
if "!INS_RC!"=="0" goto :install_ok
%E_WARN% 直连失败, 错误码 !INS_RC!, 尝试启用 Java 系统代理
call :run_installer sysproxy
if "!INS_RC!"=="0" goto :install_ok
call :proxy_ready
if "!errorlevel!"=="0" (
    %E_WARN% 系统代理模式仍失败, 显式指定 !PROXY_URL! 重试
    call :run_installer explicit
) else (
    %E_WARN% !PROXY_URL! 未在监听, 无法走显式代理重试
)
if "!INS_RC!"=="0" goto :install_ok

set "FAIL_STEP=6"
set "FAIL_MSG=安装器执行失败, 错误码 !INS_RC!"
goto :fail

:install_ok

rem ===========================================================================
rem  步骤 7/8 - 汇总变动
rem ===========================================================================
call :step "汇总 mods 变动"

call :snapshot_mods after
call :diff_mods
call :report_mods
call :stop_serve

rem ===========================================================================
rem  步骤 8/8 - PCL 启动前命令
rem ===========================================================================
call :step "生成 PCL 启动前命令"
call :write_pcl_cmd

:finish
call :stop_serve
call :write_pcl_cmd
echo.
if "!FINAL_RC!"=="0" (
    echo %C_BIG%  更新完成   日志 !LOG_FILE!  %C_RST%
) else (
    echo %C_BIG%  更新未完成   日志 !LOG_FILE!  %C_RST%
)
>>"%LOG_FILE%" echo === done rc=!FINAL_RC! ===
if "!FINAL_RC!"=="0" (
    >"!STATE_FILE!" echo STEP=!STEP!
    >>"!STATE_FILE!" echo STAGE=ok
    >>"!STATE_FILE!" echo TS=!TS!
    >>"!STATE_FILE!" echo TITLE=全部完成
)

if "!FINAL_RC!"=="0" exit /b 0
if "%FAIL_HARD%"=="1" exit /b !FINAL_RC!
exit /b 0


rem ###########################################################################
rem  子过程区
rem ###########################################################################

:make_dirs
for %%D in ("%CACHE_ROOT%" "%META_DIR%" "%LOG_DIR%" "%TMP_DIR%" "%BAK_DIR%" "%JRE_DIR%" "%TOOLS_DIR%") do (
    if not exist "%%~D" mkdir "%%~D" >nul 2>&1
)
goto :eof


rem ---------------------------------------------------------------------------
rem  续接提示 - 读上次运行留下的状态文件
rem ---------------------------------------------------------------------------
:resume_hint
if not exist "!STATE_FILE!" goto :eof
set "_ps="
set "_pst="
set "_pd="
set "_pm="
for /f "usebackq tokens=1,* delims==" %%a in ("!STATE_FILE!") do (
    if /i "%%a"=="STEP" set "_ps=%%b"
    if /i "%%a"=="STAGE" set "_pst=%%b"
    if /i "%%a"=="TS" set "_pd=%%b"
    if /i "%%a"=="MSG" set "_pm=%%b"
)
if not defined _ps goto :eof
if /i "!_pst!"=="fail" (
    echo %C_YEL%[续接]%C_RST% 上次运行失败, 停在第 !_ps! 步, 时间 !_pd!
    echo        原因 !_pm!
    echo        本次会跳过已完成的步骤, 未下完的文件断点续传
    >>"%LOG_FILE%" echo resume: last failed at step !_ps! - !_pm!
    goto :eof
)
if /i "!_pst!"=="running" (
    echo %C_YEL%[续接]%C_RST% 上次运行好像中途退出, 停在第 !_ps! 步, 时间 !_pd!
    echo        本次会跳过已完成的步骤继续
    >>"%LOG_FILE%" echo resume: interrupted at step !_ps!
)
goto :eof


rem ---------------------------------------------------------------------------
rem  统一失败报告 - 步骤号 + 原因 + 怎么修 + 日志落点 + 续接说明
rem ---------------------------------------------------------------------------
:fail
rem 调用点先 set FAIL_STEP / FAIL_MSG 再 goto :fail, 不能用 call 否则收尾后会回到调用点
set "FINAL_RC=1"
set "FAIL_FILE=%CACHE_ROOT%\更新失败报告-!TS!.txt"
>"!STATE_FILE!" echo STEP=!FAIL_STEP!
>>"!STATE_FILE!" echo STAGE=fail
>>"!STATE_FILE!" echo TS=!TS!
>>"!STATE_FILE!" echo MSG=!FAIL_MSG!
echo.
echo %C_RED%  ==================== 失 败 报 告 ====================%C_RST%
echo   失败步骤  [!FAIL_STEP!/!STEP_TOTAL!]  !FAIL_MSG!
echo   整合包    !GAME_DIR!
echo   缓存目录  !CACHE_ROOT!
echo   元数据仓  !META_DIR!
echo   元数据方式 !META_SOURCE!   包来源 !PACK_SOURCE!
if defined PACK_URL echo   包地址    !PACK_URL!
echo   日志      !LOG_FILE!
echo %C_YEL%  --------------------------------------------------------%C_RST%
call :fail_hint !FAIL_STEP!
echo %C_YEL%  --------------------------------------------------------%C_RST%
echo %C_GRN%  修好后直接重跑本脚本就能续接%C_RST%
echo          已完成的步骤自动跳过, 未下完的文件断点续传, 已装好的 mod 校验后跳过
echo %C_GRN%  失败报告 %FAIL_FILE%%C_RST%
>"!FAIL_FILE!" echo === Coco 整合包 Mod 更新失败报告 ===
>>"!FAIL_FILE!" echo 时间        !TS!
>>"!FAIL_FILE!" echo 失败步骤    [!FAIL_STEP!/!STEP_TOTAL!] !FAIL_MSG!
>>"!FAIL_FILE!" echo 脚本        %~f0
>>"!FAIL_FILE!" echo 整合包目录  !GAME_DIR!
>>"!FAIL_FILE!" echo 缓存目录    !CACHE_ROOT!
>>"!FAIL_FILE!" echo 元数据仓    !META_DIR!
>>"!FAIL_FILE!" echo 包地址      !PACK_URL!
>>"!FAIL_FILE!" echo 日志        !LOG_FILE!
>>"!FAIL_FILE!" echo.
>>"!FAIL_FILE!" echo 处理办法与下载源已同时打印在控制台, 并写入上面的日志文件
>>"!FAIL_FILE!" echo 修好后直接重跑本脚本即可续接, 已完成的步骤会跳过, 下载断点续传
goto :finish


rem 单行提示 - 同时打到控制台和日志
:hint
echo   %C_WHT%%~1%C_RST%
>>"%LOG_FILE%" echo [hint] %~1
goto :eof


rem ---------------------------------------------------------------------------
rem  按失败步骤给出手动处置指引
rem ---------------------------------------------------------------------------
:fail_hint
if "%~1"=="1" goto :hint_java
if "%~1"=="2" goto :hint_meta
if "%~1"=="3" goto :hint_pwz
if "%~1"=="4" goto :hint_refresh
if "%~1"=="5" goto :hint_src
if "%~1"=="6" goto :hint_inst
call :hint 这一步没有专门的手动方案, 看日志里的最后几行即可
goto :eof

:hint_java
call :hint "怎么修 装一个 Java 21, 或把 JAVA_HOME 指到 Java 21"
call :hint "       也可以把便携版解压到下面的目录, 脚本会在子目录里自动找 bin\java.exe"
call :hint "       !JRE_DIR!"
call :hint "       或把 java.exe 路径当作第一个参数传给本脚本"
call :hint "国内源 http://mirrors.huaweicloud.com/openjdk/21/openjdk-21_windows-x64_bin.zip"
call :hint "备用源 https://api.adoptium.net/v3/binary/latest/21/ga/windows/x64/jre/hotspot/normal/eclipse?project=jdk"
call :hint "镜像站 http://mirrors.tuna.tsinghua.edu.cn/Adoptium/21/jre/x64/windows/"
goto :eof

:hint_meta
call :hint "怎么修 手动下载仓库压缩包, 解压后把含 pack.toml 的那一层内容整体放进下面的目录"
call :hint "       !META_DIR!"
call :hint "下载源 https://github.com/viforiy/Coco_Minecraft_CustomModPack/archive/refs/heads/main.zip"
call :hint "       放好后重跑本脚本, 会直接跳过下载, 从刷新索引继续"
call :hint "其它办法 用 COCO_META_SOURCE=zip 强制压缩包模式, 或 COCO_PACK_GIT_URL 换个仓库"
goto :eof

:hint_pwz
call :hint "怎么修 下载 packwiz 的 Windows 压缩包, 解压出 packwiz.exe 放到下面的路径"
call :hint "       !META_DIR!\packwiz.exe"
call :hint "下载源 https://nightly.link/packwiz/packwiz/workflows/go/main/ 里的 Windows 64-bit 产物"
call :hint "       完整地址见上面第 3 步打印的下载源, 也已写入日志"
call :hint "       其实没有 packwiz 也能更新, 脚本会自动降级 file 模式, 不影响装 mod"
goto :eof

:hint_refresh
call :hint "怎么修 在元数据仓里跑一次 packwiz refresh, 把 index.toml 与 pack.toml 的改动提交推送, 再回本机重跑"
call :hint "       若 !META_DIR! 里 pack.toml 和 index.toml 都在还报这个错, 删掉该目录让脚本重新拉一份"
goto :eof

:hint_src
call :hint "怎么修 五选一"
call :hint "       1 用 COCO_META_SOURCE=zip 强制压缩包模式重跑"
call :hint "       2 用 COCO_REMOTE_PACK_URL 指向远端 pack.toml, 直接下载安装"
call :hint "       3 用 PACK_SOURCE=file 跳过本地服务, 让安装器直接读本地 pack.toml"
call :hint "       4 端口被别的程序占着, 把 PACK_PORT_BASE 改成 8090 之类的值"
call :hint "       5 服务日志在 !TMP_DIR!\packwiz-serve.log"
goto :eof

:hint_inst
call :hint "怎么修 先确认网络 打开 Clash 并开启系统代理, 或把脚本里的 PROXY_PORT 改成本机实际端口"
call :hint "       命令行前面能确认 Modrinth 与 CurseForge 可达的话, 直接重跑, 已下好的 mod 会校验跳过"
call :hint "       手动补齐两个 jar 到 !GAME_DIR!"
call :hint "       packwiz-installer-bootstrap.jar https://github.com/packwiz/packwiz-installer-bootstrap/releases"
call :hint "       packwiz-installer.jar https://github.com/packwiz/packwiz-installer/releases/latest/download/packwiz-installer.jar"
call :hint "       具体哪个 mod 失败, 看控制台 Downloaded 断在哪里, 与日志 !LOG_FILE!"
goto :eof

rem 询问 y/n, 返回 0 表示 y
:confirm
set "_ans="
set /p "_ans=%~1 [y/N] : "
if /i "!_ans!"=="y" exit /b 0
if /i "!_ans!"=="yes" exit /b 0
exit /b 1
:step
set /a STEP+=1
echo.
echo %C_STEP%  [%STEP%/%STEP_TOTAL%]  %~1  %C_RST%
>>"%LOG_FILE%" echo [%STEP%/%STEP_TOTAL%] %~1
>"!STATE_FILE!" echo STEP=!STEP!
>>"!STATE_FILE!" echo STAGE=running
>>"!STATE_FILE!" echo TS=!TS!
>>"!STATE_FILE!" echo TITLE=%~1
goto :eof


rem ---------------------------------------------------------------------------
rem  Java 探测: 先只认 21, 找不到再放宽到 17 以上
rem ---------------------------------------------------------------------------
:find_java
set "JAVA_EXE="
set "JAVA_MAJOR="
rem 优先使用外部传入的 java, 例如 PCL 的 $INST_JAVA
if defined COCO_JAVA if exist "%COCO_JAVA%" (
    call :java_major "%COCO_JAVA%"
    if defined JMAJOR if !JMAJOR! geq 17 (
        set "JAVA_EXE=%COCO_JAVA%"
        set "JAVA_MAJOR=!JMAJOR!"
        %E_INFO% 使用外部传入的 Java, 来源 PCL 或参数
    )
)
if defined JAVA_EXE goto :eof
set "REQ_21=1"
call :find_java_pass
if not defined JAVA_EXE (
    set "REQ_21=0"
    call :find_java_pass
)
goto :eof

:find_java_pass
rem 0) 本脚本缓存下来的便携 Java
if exist "%JRE_DIR%\bin\java.exe" call :try_java "%JRE_DIR%\bin\java.exe"
for /d %%V in ("%JRE_DIR%\*") do if not defined JAVA_EXE if exist "%%~V\bin\java.exe" call :try_java "%%~V\bin\java.exe"
rem 1) JAVA_HOME
if not defined JAVA_EXE if defined JAVA_HOME if exist "%JAVA_HOME%\bin\java.exe" call :try_java "%JAVA_HOME%\bin\java.exe"
rem 2) PATH
if not defined JAVA_EXE for /f "delims=" %%J in ('where java 2^>nul') do if not defined JAVA_EXE call :try_java "%%J"
rem 3) 注册表
if not defined JAVA_EXE call :find_java_in_registry
rem 4) 常见安装目录
if not defined JAVA_EXE call :scan_common_dirs
goto :eof

:try_java
rem %1 = java.exe 路径, 命中则写入 JAVA_EXE 与 JAVA_MAJOR
if defined JAVA_EXE goto :eof
if not exist "%~1" goto :eof
call :java_major "%~1"
if not defined JMAJOR goto :eof
if !JMAJOR! lss 17 goto :eof
if "!REQ_21!"=="1" if not "!JMAJOR!"=="21" goto :eof
set "JAVA_EXE=%~1"
set "JAVA_MAJOR=!JMAJOR!"
goto :eof

:java_major
rem 解析 java -version 首行的主版本号到 JMAJOR
set "JMAJOR="
set "_jv="
for /f "tokens=3" %%v in ('"%~1" -version 2^>^&1') do if not defined _jv set "_jv=%%~v"
if not defined _jv goto :eof
for /f "tokens=1,2 delims=._-" %%a in ("!_jv!") do (
    if "%%a"=="1" ( set "JMAJOR=%%b" ) else ( set "JMAJOR=%%a" )
)
goto :eof

:find_java_in_registry
for %%K in (
    "HKLM\SOFTWARE\JavaSoft\JDK"
    "HKLM\SOFTWARE\JavaSoft\Java Development Kit"
    "HKLM\SOFTWARE\JavaSoft\Java Runtime Environment"
    "HKLM\SOFTWARE\Wow6432Node\JavaSoft\JDK"
    "HKLM\SOFTWARE\Wow6432Node\JavaSoft\Java Development Kit"
    "HKLM\SOFTWARE\Wow6432Node\JavaSoft\Java Runtime Environment"
) do (
    if not defined JAVA_EXE (
        set "cur_ver="
        set "reg_home="
        for /f "tokens=2*" %%A in ('reg query %%K /v CurrentVersion 2^>nul') do set "cur_ver=%%B"
        if defined cur_ver (
            for /f "tokens=2*" %%A in ('reg query "%%~K\!cur_ver!" /v JavaHome 2^>nul') do set "reg_home=%%B"
            if defined reg_home call :try_java "!reg_home!\bin\java.exe"
        )
    )
)
goto :eof

:scan_common_dirs
call :scan_dir "%ProgramFiles%\Java"
call :scan_dir "%ProgramFiles%\Eclipse Adoptium"
call :scan_dir "%ProgramFiles%\Microsoft"
call :scan_dir "%ProgramFiles%\Amazon Corretto"
call :scan_dir "%ProgramFiles%\Zulu"
call :scan_dir "%ProgramFiles%\BellSoft"
call :scan_dir "%ProgramFiles%\Semeru"
call :scan_dir "%ProgramFiles%\IBM"
call :scan_dir "%ProgramFiles%\Android\Android Studio\jbr"
call :scan_dir "%ProgramFiles(x86)%\Java"
call :scan_dir "%ProgramFiles(x86)%\Eclipse Adoptium"
call :scan_dir "%LocalAppData%\Programs\Eclipse Adoptium"
call :scan_dir "%LocalAppData%\Programs\Microsoft"
call :scan_dir "%LocalAppData%\Programs\Java"
call :scan_dir "%UserProfile%\.jdks"
call :scan_dir "C:\Java"
call :scan_dir "D:\Java"
call :scan_dir "D:\Program Files\Java"
call :scan_dir "D:\Program Files\jdk21"
goto :eof

:scan_dir
if defined JAVA_EXE goto :eof
if not exist "%~1" goto :eof
for /d %%V in ("%~1\*") do if not defined JAVA_EXE if exist "%%~V\bin\java.exe" call :try_java "%%~V\bin\java.exe"
goto :eof


rem ---------------------------------------------------------------------------
rem  便携 Java 21 下载: 华为云优先, Adoptium API 兜底
rem ---------------------------------------------------------------------------
:download_java
for /d %%V in ("%JRE_DIR%\*") do if not defined JAVA_EXE if exist "%%~V\bin\java.exe" call :try_java "%%~V\bin\java.exe"
if defined JAVA_EXE goto :eof

set "JAVA_SRC=http://mirrors.huaweicloud.com/openjdk/21/openjdk-21_windows-x64_bin.zip"
set "JAVA_SRC2=https://api.adoptium.net/v3/binary/latest/21/ga/windows/x64/jre/hotspot/normal/eclipse?project=jdk"
set "JAVA_ZIP=%TMP_DIR%\java21.zip"

%E_INFO% 下载源 1, 华为云镜像
echo        %E_SUB% !JAVA_SRC!
set "DL_URL=!JAVA_SRC!"
set "DL_OUT=!JAVA_ZIP!"
set "DL_MIN=30000000"
call :dl
if not exist "!JAVA_ZIP!" (
    %E_WARN% 华为云失败, 改用 Adoptium 官方 API
    echo        %E_SUB% !JAVA_SRC2!
    set "DL_URL=!JAVA_SRC2!"
    set "DL_OUT=!JAVA_ZIP!"
    set "DL_MIN=30000000"
    call :dl
)
if not exist "!JAVA_ZIP!" (
    %E_ERR% 便携 Java 下载失败
    goto :eof
)

%E_INFO% 解压便携 Java, 只需做一次
if "!PS_OK!"=="1" (
    powershell -NoProfile -ExecutionPolicy Bypass -Command "try { Expand-Archive -LiteralPath $env:JAVA_ZIP -DestinationPath $env:JRE_DIR -Force -ErrorAction Stop; exit 0 } catch { exit 1 }" >nul 2>&1
) else (
    tar -xf "!JAVA_ZIP!" -C "%JRE_DIR%" >nul 2>&1
)
del /q "!JAVA_ZIP!" >nul 2>&1

if exist "%JRE_DIR%\bin\java.exe" call :try_java "%JRE_DIR%\bin\java.exe"
for /d %%V in ("%JRE_DIR%\*") do if not defined JAVA_EXE if exist "%%~V\bin\java.exe" call :try_java "%%~V\bin\java.exe"
if defined JAVA_EXE (
    %E_OK% 便携 Java 就绪
    echo        %E_SUB% !JAVA_EXE!
    rem jmods 与 include 只有开发期需要, 删掉省 100MB 以上
    for /d %%V in ("%JRE_DIR%\*") do (
        if exist "%%~V\jmods" rd /s /q "%%~V\jmods" >nul 2>&1
        if exist "%%~V\include" rd /s /q "%%~V\include" >nul 2>&1
    )
) else (
    %E_ERR% 解压后仍未找到 java.exe
)
goto :eof


rem ---------------------------------------------------------------------------
rem  元数据仓同步
rem ---------------------------------------------------------------------------
:git_sync
set "HAVE_META=0"
set "GIT_RC=0"

if /i "!META_SOURCE!"=="zip" (
    call :zip_sync
    goto :eof
)

call :find_git
if not defined GIT_EXE (
    %E_WARN% 没找到 git.exe - 自动改用 zip 压缩包模式
    call :zip_sync
    if "!HAVE_META!"=="0" if exist "!META_DIR!\pack.toml" (
        %E_INFO% 使用缓存里已有的元数据继续
        set "HAVE_META=1"
    )
    goto :eof
)
echo    %C_DIM%git:%C_RST% !GIT_EXE!

set "GIT_TERMINAL_PROMPT=0"
set "GIT_HTTP_LOW_SPEED_LIMIT=1024"
set "GIT_HTTP_LOW_SPEED_TIME=20"
set "GIT_MERGE_AUTOEDIT=no"

if exist "!META_DIR!\.git" goto :git_pull

rem 目录存在但不是 git 仓, 先备份再重建, 避免 clone 失败
if exist "!META_DIR!\pack.toml" (
    %E_WARN% 已有元数据但不是 git 仓, 先备份到 !BAK_DIR!\meta-!TS!
    if exist "!BAK_DIR!\meta-!TS!" rd /s /q "!BAK_DIR!\meta-!TS!" >nul 2>&1
    move "!META_DIR!" "!BAK_DIR!\meta-!TS!" >nul 2>&1
)
set "PWZ_KEEP="
if exist "!META_DIR!\packwiz.exe" (
    copy /y "!META_DIR!\packwiz.exe" "%TOOLS_DIR%\packwiz.exe" >nul 2>&1
    set "PWZ_KEEP=1"
)
if exist "!META_DIR!" rd /s /q "!META_DIR!" >nul 2>&1

%E_INFO% 首次克隆元数据仓, 浅克隆分支 !PACK_GIT_BRANCH!
echo        %E_SUB% !PACK_GIT_URL!
>>"%LOG_FILE%" echo git clone !PACK_GIT_URL! branch=!PACK_GIT_BRANCH!
"%GIT_EXE%" -c core.autocrlf=false clone --depth 1 --single-branch --branch "!PACK_GIT_BRANCH!" "!PACK_GIT_URL!" "!META_DIR!" >>"%LOG_FILE%" 2>&1
set "GIT_RC=!errorlevel!"
if "!GIT_RC!"=="0" goto :git_verify
call :proxy_ready
if "!errorlevel!"=="0" (
    %E_WARN% clone 失败 !GIT_RC!, 改用代理 !PROXY_URL! 重试
    if exist "!META_DIR!" rd /s /q "!META_DIR!" >nul 2>&1
    "%GIT_EXE%" -c core.autocrlf=false -c "http.proxy=!PROXY_URL!" clone --depth 1 --single-branch --branch "!PACK_GIT_BRANCH!" "!PACK_GIT_URL!" "!META_DIR!" >>"%LOG_FILE%" 2>&1
    set "GIT_RC=!errorlevel!"
)
goto :git_verify

:git_pull
%E_INFO% 增量同步, fetch 后 reset 到 origin/!PACK_GIT_BRANCH!
rem 源地址可能被 mod更新源.cfg 改过, 先把 remote 纠正过来再拉
"%GIT_EXE%" -C "!META_DIR!" remote set-url origin "!PACK_GIT_URL!" >nul 2>&1
>>"%LOG_FILE%" echo git fetch in !META_DIR! from !PACK_GIT_URL!
pushd "!META_DIR!"
"%GIT_EXE%" fetch --depth 1 origin "!PACK_GIT_BRANCH!" >>"%LOG_FILE%" 2>&1
set "GIT_RC=!errorlevel!"
popd
if not "!GIT_RC!"=="0" (
    call :proxy_ready
    if "!errorlevel!"=="0" (
        %E_WARN% fetch 失败 !GIT_RC!, 改用代理重试
        pushd "!META_DIR!"
        "%GIT_EXE%" -c "http.proxy=!PROXY_URL!" fetch --depth 1 origin "!PACK_GIT_BRANCH!" >>"%LOG_FILE%" 2>&1
        set "GIT_RC=!errorlevel!"
        popd
    )
)
if "!GIT_RC!"=="0" (
    rem 客户端上的元数据只读, 用 reset 强同步, 顺便清掉 refresh 造成的脏改动
    pushd "!META_DIR!"
    "%GIT_EXE%" -c core.autocrlf=false reset --hard FETCH_HEAD >>"%LOG_FILE%" 2>&1
    set "GIT_RC=!errorlevel!"
    popd
)
goto :git_verify

:git_verify
if not "!GIT_RC!"=="0" (
    %E_WARN% git 同步失败, 错误码 !GIT_RC!
    if /i not "!META_SOURCE!"=="git" (
        %E_INFO% 改用 zip 压缩包模式重试
        call :zip_sync
    )
    if "!HAVE_META!"=="0" if exist "!META_DIR!\pack.toml" (
        %E_INFO% 退回使用本地已有元数据
        set "HAVE_META=1"
    )
    goto :eof
)
if not exist "!META_DIR!\pack.toml" (
    %E_ERR% 同步完成但仓库根目录没有 pack.toml, 请检查仓库结构
    goto :eof
)
set "HAVE_META=1"
set "GIT_HEAD="
for /f "delims=" %%C in ('"%GIT_EXE%" -C "!META_DIR!" rev-parse --short HEAD 2^>nul') do if not defined GIT_HEAD set "GIT_HEAD=%%C"
if defined GIT_HEAD (
    %E_INFO% 元数据版本 !GIT_HEAD!
    >>"%LOG_FILE%" echo metadata head=!GIT_HEAD!
)
goto :eof

rem ---------------------------------------------------------------------------
rem  zip 模式同步元数据 - 机器上没有 git 时直接下 GitHub 压缩包
rem ---------------------------------------------------------------------------
:zip_sync
set "HAVE_META=0"
call :parse_repo
if not defined ZIP_URL (
    %E_WARN% 元数据仓地址不是 GitHub 仓库, zip 模式不可用
    goto :eof
)
%E_INFO% 用 zip 压缩包拉取元数据, 不需要 git
echo        %E_SUB% !ZIP_URL!
set "ZIP_FILE=%TMP_DIR%\meta.zip"
set "ZIP_OUT=%TMP_DIR%\meta_zip"
set "DL_URL=!ZIP_URL!"
set "DL_OUT=!ZIP_FILE!"
set "DL_MIN=20000"
call :dl
if not exist "!ZIP_FILE!" (
    %E_WARN% codeload 直连失败, 改用 GitHub 加速镜像
    set "DL_URL=https://ghfast.top/https://github.com/!REPO_OWNER!/!REPO_NAME!/archive/refs/heads/!PACK_GIT_BRANCH!.zip"
    call :dl
)
if not exist "!ZIP_FILE!" (
    %E_ERR% 元数据 zip 下载失败
    goto :eof
)

%E_INFO% 解压元数据快照
if exist "!ZIP_OUT!" rd /s /q "!ZIP_OUT!" >nul 2>&1
mkdir "!ZIP_OUT!" >nul 2>&1
tar -xf "!ZIP_FILE!" -C "!ZIP_OUT%" >nul 2>&1
set "_any="
for /f "delims=" %%A in ('dir /b "!ZIP_OUT!" 2^>nul') do if not defined _any set "_any=1"
if not defined _any if "!PS_OK!"=="1" (
    powershell -NoProfile -ExecutionPolicy Bypass -Command "try { Expand-Archive -LiteralPath $env:ZIP_FILE -DestinationPath $env:ZIP_OUT -Force -ErrorAction Stop; exit 0 } catch { exit 1 }" >nul 2>&1
)
del /q "!ZIP_FILE!" >nul 2>&1

rem 压缩包一般带一层 仓库名-分支 顶层目录, 两种结构都兼容
set "ZIP_SRC="
if exist "!ZIP_OUT!\pack.toml" set "ZIP_SRC=!ZIP_OUT!"
if not defined ZIP_SRC for /d %%D in ("!ZIP_OUT!\*") do if not defined ZIP_SRC if exist "%%~D\pack.toml" set "ZIP_SRC=%%~D"
if not defined ZIP_SRC (
    %E_ERR% 压缩包里没有 pack.toml, 请检查仓库结构
    goto :eof
)

rem 元数据仓根目录里的 packwiz.exe 要先保住, 重建后放回
set "PWZ_STASH="
if exist "!META_DIR!\packwiz.exe" (
    copy /y "!META_DIR!\packwiz.exe" "%TOOLS_DIR%\packwiz.exe" >nul 2>&1
    set "PWZ_STASH=1"
)
if exist "!META_DIR!" rd /s /q "!META_DIR!" >nul 2>&1
mkdir "!META_DIR!" >nul 2>&1
xcopy "!ZIP_SRC!\*" "!META_DIR!\" /e /i /y /q >nul 2>&1
if "!PWZ_STASH!"=="1" copy /y "%TOOLS_DIR%\packwiz.exe" "!META_DIR!\packwiz.exe" >nul 2>&1
if exist "!META_DIR!\packwiz.exe" set "PACKWIZ_EXE=!META_DIR!\packwiz.exe"
if exist "!ZIP_OUT!" rd /s /q "!ZIP_OUT!" >nul 2>&1

if not exist "!META_DIR!\pack.toml" (
    %E_ERR% 部署元数据快照失败
    goto :eof
)
set "HAVE_META=1"
%E_OK% 元数据快照就绪 - zip 模式
>>"%LOG_FILE%" echo zip sync !ZIP_URL!
goto :eof


:parse_repo
rem 从 PACK_GIT_URL 解析 GitHub 的 owner / repo, 拼出 codeload 地址
set "REPO_HOST="
set "REPO_OWNER="
set "REPO_NAME="
set "ZIP_URL="
set "_u=!PACK_GIT_URL!"
if /i "!_u:~0,8!"=="https://" set "_u=!_u:~8!"
if /i "!_u:~0,7!"=="http://" set "_u=!_u:~7!"
if /i "!_u:~0,4!"=="git@" (
    set "_u=!_u:git@=!"
    set "_u=!_u::=/!"
)
for /f "tokens=1,2,3 delims=/" %%a in ("!_u!") do (
    set "REPO_HOST=%%a"
    set "REPO_OWNER=%%b"
    set "REPO_NAME=%%c"
)
if defined REPO_NAME set "REPO_NAME=!REPO_NAME:.git=!"
if not defined REPO_OWNER goto :eof
if not defined REPO_NAME goto :eof
if /i not "!REPO_HOST!"=="github.com" goto :eof
set "ZIP_URL=https://codeload.github.com/!REPO_OWNER!/!REPO_NAME!/zip/refs/heads/!PACK_GIT_BRANCH!"
goto :eof

:find_git
set "GIT_EXE="
for /f "delims=" %%G in ('where git 2^>nul') do if not defined GIT_EXE set "GIT_EXE=%%G"
if not defined GIT_EXE if exist "%ProgramFiles%\Git\cmd\git.exe" set "GIT_EXE=%ProgramFiles%\Git\cmd\git.exe"
if not defined GIT_EXE if exist "%ProgramFiles(x86)%\Git\cmd\git.exe" set "GIT_EXE=%ProgramFiles(x86)%\Git\cmd\git.exe"
if not defined GIT_EXE if exist "%LocalAppData%\Programs\Git\cmd\git.exe" set "GIT_EXE=%LocalAppData%\Programs\Git\cmd\git.exe"
goto :eof


rem ---------------------------------------------------------------------------
rem  packwiz.exe
rem ---------------------------------------------------------------------------
:find_packwiz_on_path
set "PACKWIZ_FOUND="
for /f "delims=" %%P in ('where packwiz 2^>nul') do if not defined PACKWIZ_FOUND set "PACKWIZ_FOUND=%%P"
if defined PACKWIZ_FOUND (
    set "PACKWIZ_EXE=!PACKWIZ_FOUND!"
    set "HAVE_PACKWIZ=1"
    %E_INFO% 使用 PATH 中的 packwiz
)
goto :eof

:download_packwiz
set "PWZ_ZIP=%TMP_DIR%\packwiz.zip"
set "PWZ_URL=https://nightly.link/packwiz/packwiz/workflows/go/main/Windows%%2064-bit.zip"

%E_INFO% 下载 packwiz.exe, nightly 构建
echo        %E_SUB% !PWZ_URL!
set "DL_URL=!PWZ_URL!"
set "DL_OUT=!PWZ_ZIP!"
set "DL_MIN=1000000"
call :dl
if not exist "!PWZ_ZIP!" (
    %E_WARN% packwiz 下载失败, 本次改用 file 模式
    goto :eof
)

%E_INFO% 解压 packwiz.exe
tar -xf "!PWZ_ZIP!" -C "%TOOLS_DIR%" >nul 2>&1
if not exist "%TOOLS_DIR%\packwiz.exe" if "!PS_OK!"=="1" (
    powershell -NoProfile -ExecutionPolicy Bypass -Command "try { Expand-Archive -LiteralPath $env:PWZ_ZIP -DestinationPath $env:TOOLS_DIR -Force -ErrorAction Stop; exit 0 } catch { exit 1 }" >nul 2>&1
)
del /q "!PWZ_ZIP!" >nul 2>&1

set "_pwz_ok=0"
if exist "%TOOLS_DIR%\packwiz.exe" (
    set "_pwz_sz=0"
    for %%A in ("%TOOLS_DIR%\packwiz.exe") do set "_pwz_sz=%%~zA"
    if !_pwz_sz! geq 5000000 set "_pwz_ok=1"
)
if "!_pwz_ok!"=="0" (
    %E_WARN% 解压出来的 packwiz.exe 不正常, 可能是断点续传把包接坏了
    echo        %E_SUB% 删掉残留并整份重下一次
    del /q "%TOOLS_DIR%\packwiz.exe" >nul 2>&1
    set "DL_NO_RESUME=1"
    set "DL_URL=!PWZ_URL!"
    set "DL_OUT=!PWZ_ZIP!"
    set "DL_MIN=1000000"
    call :dl
    if exist "!PWZ_ZIP!" tar -xf "!PWZ_ZIP!" -C "%TOOLS_DIR%" >nul 2>&1
    del /q "!PWZ_ZIP!" >nul 2>&1
    set "_pwz_ok=0"
    if exist "%TOOLS_DIR%\packwiz.exe" (
        set "_pwz_sz=0"
        for %%A in ("%TOOLS_DIR%\packwiz.exe") do set "_pwz_sz=%%~zA"
        if !_pwz_sz! geq 5000000 set "_pwz_ok=1"
    )
)
if "!_pwz_ok!"=="0" (
    %E_ERR% packwiz 解压失败
    goto :eof
)
rem 按约定把 packwiz.exe 放在元数据仓根目录
if not exist "!META_DIR!" mkdir "!META_DIR!" >nul 2>&1
copy /y "%TOOLS_DIR%\packwiz.exe" "!PACKWIZ_EXE!" >nul 2>&1
if not exist "!PACKWIZ_EXE!" set "PACKWIZ_EXE=%TOOLS_DIR%\packwiz.exe"
set "HAVE_PACKWIZ=1"
%E_OK% packwiz.exe 就位
echo        %E_SUB% !PACKWIZ_EXE!
goto :eof


rem ---------------------------------------------------------------------------
rem  packwiz refresh
rem ---------------------------------------------------------------------------
:refresh_index
set "REF_RC=0"
if not exist "!META_DIR!\pack.toml" goto :eof
if not exist "!META_DIR!\index.toml" (
    %E_WARN% 缺少 index.toml, 建空索引后再 refresh
    type nul > "!META_DIR!\index.toml"
)
pushd "!META_DIR!"
"!PACKWIZ_EXE!" refresh >>"%LOG_FILE%" 2>&1
set "REF_RC=!errorlevel!"
popd
if "!REF_RC!"=="0" (
    %E_OK% index.toml 已刷新
) else (
    %E_WARN% refresh 返回 !REF_RC!, 继续尝试起服务, 交给服务端刷新
)
goto :eof


rem ---------------------------------------------------------------------------
rem  端口选择与残留服务清理
rem ---------------------------------------------------------------------------
rem ---------------------------------------------------------------------------
rem  防火墙: serve 模式会监听端口, 先尝试静默放行, 免得开游戏时弹窗打断
rem ---------------------------------------------------------------------------
:fw_ensure
rem %1 = 程序路径, 返回 0 表示已有规则或已加好, 1 表示没有管理员权限
set "_fw_name=CocoPackwizServe"
netsh advfirewall firewall show rule name="!_fw_name!" >nul 2>&1
if not errorlevel 1 exit /b 0
net session >nul 2>&1
if errorlevel 1 exit /b 1
netsh advfirewall firewall add rule name="!_fw_name!" dir=in action=allow program="%~1" enable=yes profile=any >nul 2>&1
netsh advfirewall firewall add rule name="!_fw_name!-out" dir=out action=allow program="%~1" enable=yes profile=any >nul 2>&1
exit /b 0

:fw_warn_once
rem 只提示一次, 免得每次启动都刷屏
set "FW_FLAG=%CACHE_ROOT%\firewall-notice.txt"
if exist "!FW_FLAG!" goto :eof
echo    %E_WARN% 本地包服务会让 packwiz.exe 监听端口, Windows 可能弹一次防火墙询问
echo           %E_SUB% 点允许就行, 点取消也不影响本机更新, 走的是 127.0.0.1 回环
echo           %E_SUB% 想彻底不弹, 把 mod更新源.cfg 里的 PACK_SOURCE 设成 file
> "!FW_FLAG!" echo notice %TS%
>>"%LOG_FILE%" echo firewall: no admin, rule not added
goto :eof

:pick_port
set "PACK_PORT=%PACK_PORT_BASE%"
set "_ptry=0"
:pick_port_loop
call :port_busy !PACK_PORT!
if "!errorlevel!" neq "0" goto :pick_port_ok
call :reclaim_port !PACK_PORT!
call :port_busy !PACK_PORT!
if "!errorlevel!" neq "0" goto :pick_port_ok
set /a PACK_PORT+=1
set /a _ptry+=1
if !_ptry! lss 12 goto :pick_port_loop
%E_WARN% 未找到空闲端口, 仍尝试 !PACK_PORT!
goto :eof
:pick_port_ok
if not "!PACK_PORT!"=="%PACK_PORT_BASE%" %E_INFO% 端口 %PACK_PORT_BASE% 被占用, 改用 !PACK_PORT!
goto :eof

:port_busy
netstat -ano -p tcp 2>nul | findstr /i "LISTENING" | findstr ":%~1 " >nul 2>&1
exit /b !errorlevel!

:reclaim_port
rem 只清理上次残留的 packwiz 进程, 不误杀别的服务
set "_rp="
for /f "tokens=5" %%P in ('netstat -ano -p tcp 2^>nul ^| findstr /i "LISTENING" ^| findstr ":%~1 "') do if not defined _rp set "_rp=%%P"
if not defined _rp goto :eof
call :pid_is_packwiz !_rp!
if "!errorlevel!"=="0" (
    %E_INFO% 清理上次残留的 packwiz 服务 PID !_rp!
    taskkill /PID !_rp! /T /F >nul 2>&1
)
goto :eof


rem ---------------------------------------------------------------------------
rem  启动 packwiz serve, 经 WMI 分离启动, 不占用本脚本的 stdout 句柄
rem ---------------------------------------------------------------------------
:start_serve
set "SERVE_STARTED=0"
set "SERVE_PID="
set "SERVE_LOG=%TMP_DIR%\packwiz-serve.log"
set "SERVE_PID_FILE=%TMP_DIR%\packwiz-serve.pid"
del /q "!SERVE_PID_FILE!" >nul 2>&1

set "SPAWN_EXE=!PACKWIZ_EXE!"
set "SPAWN_ARGS=serve -p !PACK_PORT!"
set "SPAWN_DIR=!META_DIR!"
set "SPAWN_LOG=!SERVE_LOG!"
set "SPAWN_PID_FILE=!SERVE_PID_FILE!"
>>"%LOG_FILE%" echo serve: !PACKWIZ_EXE! !SPAWN_ARGS! cwd=!META_DIR!

if "!PS_OK!"=="1" (
    powershell -NoProfile -ExecutionPolicy Bypass -Command "$q=[char]34; $line=$q+$q+$env:SPAWN_EXE+$q+' '+$env:SPAWN_ARGS+' 1>'+$q+$env:SPAWN_LOG+$q+' 2>&1'+$q; $a=@{CommandLine=$env:ComSpec+' /c '+$line; CurrentDirectory=$env:SPAWN_DIR}; $r=Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments $a; if ($r.ReturnValue -eq 0 -and $r.ProcessId) { Set-Content -LiteralPath $env:SPAWN_PID_FILE -Value $r.ProcessId }" >nul 2>&1
)
if exist "!SERVE_PID_FILE!" (
    for /f "delims=" %%P in ('type "!SERVE_PID_FILE!" 2^>nul') do if not defined SERVE_PID set "SERVE_PID=%%P"
    del /q "!SERVE_PID_FILE!" >nul 2>&1
)
if defined SERVE_PID (
    set "SERVE_STARTED=1"
    exit /b 0
)

rem WMI 不可用时退回 start, 会闪一个最小化窗口
echo    %E_SUB% WMI 分离启动失败, 退回 start 启动
start "CocoPackwizServe" /min /d "!META_DIR!" cmd /c ""!PACKWIZ_EXE!" !SPAWN_ARGS! 1>"!SERVE_LOG!" 2>&1"
set "SERVE_STARTED=1"
call :capture_serve_pid
exit /b 0


rem ---------------------------------------------------------------------------
rem  等待服务就绪: 端口监听 + pack.toml 可访问
rem ---------------------------------------------------------------------------
:wait_serve
set "PACK_URL="
set "_wsec=0"
:wait_serve_loop
call :port_busy !PACK_PORT!
if "!errorlevel!"=="0" (
    call :probe "http://127.0.0.1:!PACK_PORT!/pack.toml"
    if "!errorlevel!"=="0" (
        set "PACK_URL=http://127.0.0.1:!PACK_PORT!/pack.toml"
        exit /b 0
    )
)
if !_wsec! geq 40 exit /b 1
set /a _wsec+=1
rem 用 ping 代替 timeout, stdin 被重定向时 timeout 会报错
ping -n 2 127.0.0.1 >nul 2>&1
goto :wait_serve_loop


rem ---------------------------------------------------------------------------
rem  关闭本地包服务
rem ---------------------------------------------------------------------------
:stop_serve
if not "!SERVE_STARTED!"=="1" goto :eof
if not defined SERVE_PID call :capture_serve_pid
if defined SERVE_PID taskkill /PID !SERVE_PID! /T /F >nul 2>&1
taskkill /FI "WINDOWTITLE eq CocoPackwizServe*" /F /T >nul 2>&1
set "_sp="
for /f "tokens=5" %%P in ('netstat -ano -p tcp 2^>nul ^| findstr /i "LISTENING" ^| findstr ":!PACK_PORT! "') do if not defined _sp set "_sp=%%P"
if defined _sp (
    call :pid_is_packwiz !_sp!
    if "!errorlevel!"=="0" taskkill /PID !_sp! /T /F >nul 2>&1
)
set "SERVE_STARTED=0"
set "SERVE_PID="
echo    %E_SUB% 本地包服务已关闭
goto :eof

:capture_serve_pid
rem 只认 packwiz.exe, 避免把端口上的其它程序当成本脚本的服务
set "SERVE_PID="
set "_cand="
for /f "tokens=5" %%P in ('netstat -ano -p tcp 2^>nul ^| findstr /i "LISTENING" ^| findstr ":!PACK_PORT! "') do if not defined _cand set "_cand=%%P"
if not defined _cand goto :eof
call :pid_is_packwiz !_cand!
if "!errorlevel!"=="0" set "SERVE_PID=!_cand!"
goto :eof

:pid_is_packwiz
set "_pname="
for /f "tokens=1" %%N in ('tasklist /fi "PID eq %~1" /nh 2^>nul') do if not defined _pname set "_pname=%%N"
if /i "!_pname!"=="packwiz.exe" exit /b 0
exit /b 1


rem ---------------------------------------------------------------------------
rem  下载 bootstrap 与 installer
rem ---------------------------------------------------------------------------
:ensure_bootstrap
if exist "!BOOTSTRAP_JAR!" (
    set "_bs_size=0"
    for %%A in ("!BOOTSTRAP_JAR!") do set "_bs_size=%%~zA"
    if !_bs_size! geq 50000 (
        %E_OK% bootstrap 执行器已存在
        echo        %E_SUB% packwiz-installer-bootstrap.jar
        goto :eof
    )
)
set "BS_URL=https://github.com/packwiz/packwiz-installer-bootstrap/releases/download/v0.0.3/packwiz-installer-bootstrap.jar"
%E_INFO% 下载 packwiz-installer-bootstrap.jar
echo        %E_SUB% !BS_URL!
set "DL_URL=!BS_URL!"
set "DL_OUT=!BOOTSTRAP_JAR!"
set "DL_MIN=50000"
call :dl
if not exist "!BOOTSTRAP_JAR!" (
    %E_WARN% 直连失败, 改用 GitHub 加速镜像
    set "DL_URL=https://ghfast.top/!BS_URL!"
    call :dl
)
if exist "!BOOTSTRAP_JAR!" (
    %E_OK% bootstrap 执行器就位
) else (
    %E_ERR% bootstrap 执行器下载失败
)
goto :eof

:ensure_installer_jar
set "BOOTSTRAP_OPTS="
if exist "!INSTALLER_JAR!" (
    set "_ij_size=0"
    for %%A in ("!INSTALLER_JAR!") do set "_ij_size=%%~zA"
    if !_ij_size! geq 1000000 (
        set "BOOTSTRAP_OPTS=--bootstrap-no-update --bootstrap-main-jar "!INSTALLER_JAR!""
        %E_OK% 安装器主程序已存在, 跳过 GitHub 版本检查
        echo        %E_SUB% packwiz-installer.jar
        goto :eof
    )
)
set "IJ_URL=https://github.com/packwiz/packwiz-installer/releases/latest/download/packwiz-installer.jar"
%E_INFO% 下载 packwiz-installer.jar
echo        %E_SUB% !IJ_URL!
set "DL_URL=!IJ_URL!"
set "DL_OUT=!INSTALLER_JAR!"
set "DL_MIN=1000000"
call :dl
if not exist "!INSTALLER_JAR!" (
    set "DL_URL=https://ghfast.top/!IJ_URL!"
    call :dl
)
if exist "!INSTALLER_JAR!" (
    set "BOOTSTRAP_OPTS=--bootstrap-no-update --bootstrap-main-jar "!INSTALLER_JAR!""
    %E_OK% 安装器主程序就位
) else (
    %E_WARN% 主程序下载失败, 交给 bootstrap 在线自更新, 需要能访问 GitHub API
)
goto :eof


rem ---------------------------------------------------------------------------
rem  执行安装器: direct / sysproxy / explicit 三种网络模式
rem ---------------------------------------------------------------------------
:run_installer
set "INS_RC=1"
set "JOPT="
if /i "%~1"=="sysproxy" set "JOPT=-Djava.net.useSystemProxies=true"
if /i "%~1"=="explicit" set "JOPT=-Dhttp.proxyHost=!PROXY_HOST! -Dhttp.proxyPort=!PROXY_PORT! -Dhttps.proxyHost=!PROXY_HOST! -Dhttps.proxyPort=!PROXY_PORT!"
echo    %C_DIM%网络模式:%C_RST% %~1  !JOPT!
"!JAVA_EXE!" !JOPT! -jar "!BOOTSTRAP_JAR!" !BOOTSTRAP_OPTS! -g -s client --pack-folder "!GAME_DIR!" "!PACK_URL!"
set "INS_RC=!errorlevel!"
>>"%LOG_FILE%" echo installer mode=%~1 rc=!INS_RC!
exit /b !INS_RC!


rem ---------------------------------------------------------------------------
rem  mods 快照 / 差异 / 汇总 / 备份
rem ---------------------------------------------------------------------------
:snapshot_mods
set "_stamp=%~1"
if exist "!MODS_DIR!" dir /b /a-d "!MODS_DIR!" > "%TMP_DIR%\mods_!_stamp!.txt" 2>nul
if not exist "%TMP_DIR%\mods_!_stamp!.txt" type nul > "%TMP_DIR%\mods_!_stamp!.txt"
set "_cnt=0"
for /f "delims=" %%N in ('type "%TMP_DIR%\mods_!_stamp!.txt" ^| find /c /v ""') do set "_cnt=%%N"
if /i "!_stamp!"=="before" set "MODS_COUNT_BEFORE=!_cnt!"
if /i "!_stamp!"=="after" set "MODS_COUNT_AFTER=!_cnt!"
goto :eof

:file_empty
rem 返回 0 表示文件不存在或没有任何行
if not exist "%~1" exit /b 0
set "_fe=0"
for %%A in ("%~1") do if %%~zA==0 set "_fe=1"
if "!_fe!"=="1" exit /b 0
exit /b 1

:diff_mods
set "MODS_ADDED=0"
set "MODS_REMOVED=0"
set "_before=%TMP_DIR%\mods_before.txt"
set "_after=%TMP_DIR%\mods_after.txt"
set "_added=%TMP_DIR%\mods_added.txt"
set "_removed=%TMP_DIR%\mods_removed.txt"
rem findstr /g: 遇到空模式文件会直接报错, 空列表单独处理
call :file_empty "!_before!"
if "!errorlevel!"=="0" (
    type "!_after!" > "!_added!"
    type nul > "!_removed!"
    goto :diff_count
)
call :file_empty "!_after!"
if "!errorlevel!"=="0" (
    type nul > "!_added!"
    type "!_before!" > "!_removed!"
    goto :diff_count
)
findstr /v /x /l /g:"!_before!" "!_after!" > "!_added!" 2>nul
findstr /v /x /l /g:"!_after!" "!_before!" > "!_removed!" 2>nul
:diff_count
if not exist "!_added!" type nul > "!_added!"
if not exist "!_removed!" type nul > "!_removed!"
for /f "delims=" %%N in ('type "!_added!" ^| find /c /v ""') do set "MODS_ADDED=%%N"
for /f "delims=" %%N in ('type "!_removed!" ^| find /c /v ""') do set "MODS_REMOVED=%%N"
goto :eof

:report_mods
echo    %C_GRN%mods 数量:%C_RST% !MODS_COUNT_BEFORE! -^> !MODS_COUNT_AFTER!
if not "!MODS_ADDED!"=="0" (
    echo    %C_GRN%新增 !MODS_ADDED! 个:%C_RST%
    type "%TMP_DIR%\mods_added.txt"
    >>"%LOG_FILE%" echo ---- added !MODS_ADDED!
    type "%TMP_DIR%\mods_added.txt" >>"%LOG_FILE%"
)
if not "!MODS_REMOVED!"=="0" (
    echo    %C_RED%移除 !MODS_REMOVED! 个:%C_RST%
    type "%TMP_DIR%\mods_removed.txt"
    >>"%LOG_FILE%" echo ---- removed !MODS_REMOVED!
    type "%TMP_DIR%\mods_removed.txt" >>"%LOG_FILE%"
)
if "!MODS_ADDED!"=="0" if "!MODS_REMOVED!"=="0" %E_OK% mods 已是最新, 无新增无移除
goto :eof

:backup_mods
if not exist "!MODS_DIR!" goto :eof
%E_INFO% 备份 mods 目录到 !BAK_DIR!\mods-!TS!.zip
tar -a -c -f "!BAK_DIR!\mods-!TS!.zip" -C "!GAME_DIR!" mods >nul 2>&1
if exist "!BAK_DIR!\mods-!TS!.zip" (
    %E_OK% 备份完成
) else (
    %E_WARN% 备份失败, 跳过
)
goto :eof


rem ---------------------------------------------------------------------------
rem  生成 PCL 启动前命令
rem ---------------------------------------------------------------------------
:write_pcl_cmd
if "!PCL_CMD_DONE!"=="1" goto :eof
set "PCL_CMD_DONE=1"
set "PCL_FILE=!GAME_DIR!\PCL启动前命令.txt"
rem {verpath} 是 PCL 的替换标记, 运行时展开成本版本文件夹, 命令更短
set "PCL_CMD=call "{verpath}\!SCRIPT_NAME!" "$INST_JAVA""
set "PCL_CMD_FULL=cd /d "!GAME_DIR!" ^&^& call "!SCRIPT_NAME!" "$INST_JAVA""
>"!PCL_FILE!" echo !PCL_CMD!
clip < "!PCL_FILE!" >nul 2>&1
%E_OK% 已写入 !PCL_FILE! 并尝试复制到剪贴板
echo    %C_DIM%粘贴到 PCL - 版本设置 - 设置 - 高级选项 - 启动前执行指令%C_RST%
echo    %C_GRN%!PCL_CMD!%C_RST%
echo    %E_SUB% {verpath} 展开为版本文件夹, $INST_JAVA 展开为实例 Java, 路径带空格也不会断
echo    %E_SUB% 老版本 PCL 不认 {verpath} 时, 改用下面这条
echo    %C_DIM%!PCL_CMD_FULL!%C_RST%
>>"%LOG_FILE%" echo PCL_CMD=!PCL_CMD!
goto :eof


rem ---------------------------------------------------------------------------
rem  网络探测
rem ---------------------------------------------------------------------------
:probe
rem %1 = url, 返回 0 表示可访问
if "!CURL_OK!"=="1" (
    "!CURL!" -fsS -o NUL --connect-timeout 5 --max-time 8 "%~1" >nul 2>&1
    exit /b !errorlevel!
)
if "!PS_OK!"=="1" (
    powershell -NoProfile -ExecutionPolicy Bypass -Command "try { $r=Invoke-WebRequest -UseBasicParsing -TimeoutSec 8 -Uri '%~1'; if ($r.StatusCode -lt 400) { exit 0 } else { exit 1 } } catch { exit 1 }" >nul 2>&1
    exit /b !errorlevel!
)
exit /b 1

:proxy_ready
rem 探测 Clash 这类系统代理是否在监听且能出网
if "!CURL_OK!"=="1" (
    "!CURL!" -fsS -o NUL --connect-timeout 4 --max-time 8 -x "!PROXY_URL!" "https://www.gstatic.com/generate_204" >nul 2>&1
    if "!errorlevel!"=="0" exit /b 0
    "!CURL!" -fsS -o NUL --connect-timeout 4 --max-time 8 -x "!PROXY_URL!" "http://cp.cloudflare.com/" >nul 2>&1
    exit /b !errorlevel!
)
netstat -ano -p tcp 2>nul | findstr /i "LISTENING" | findstr ":!PROXY_PORT! " >nul 2>&1
exit /b !errorlevel!


rem ---------------------------------------------------------------------------
rem  下载: 直连失败自动切系统代理
rem ---------------------------------------------------------------------------
:dl
rem 入参走变量, 不经 call 传参, 避免 URL 里的 % 被二次当成参数引用
rem 输入 DL_URL / DL_OUT / DL_MIN
if not defined DL_MIN set "DL_MIN=1024"
if defined DL_NO_RESUME if exist "!DL_OUT!" del /q "!DL_OUT!" >nul 2>&1
set "DL_NO_RESUME="
echo    %E_SUB% 存到 !DL_OUT!
>>"%LOG_FILE%" echo dl !DL_URL! -^> !DL_OUT!
set "NET_PROXY="
call :fetch
call :check_dl "!DL_OUT!" !DL_MIN!
if "!errorlevel!"=="0" exit /b 0
if not "%PROXY_AUTO%"=="1" exit /b 1
call :proxy_ready
if not "!errorlevel!"=="0" exit /b 1
echo    %E_SUB% 直连失败, 改用系统代理 !PROXY_URL! 重试
set "NET_PROXY=1"
call :fetch
call :check_dl "!DL_OUT!" !DL_MIN!
if "!errorlevel!"=="0" exit /b 0
echo    %E_WARN% 下载没完成, 半成品已保留, 重跑会从断点继续
echo    %E_SUB% 文件 !DL_OUT!
echo    %E_SUB% 如果重跑后这个文件大小一直不变, 说明源有问题, 删掉它再重跑
exit /b 1

:fetch
rem 用 DL_URL / DL_OUT 与 NET_PROXY 标记, 已有半成品则断点续传
set "DL_ARG=-L --fail --retry 2 --retry-delay 2 --connect-timeout 15 -#"
if defined NET_PROXY set "DL_ARG=!DL_ARG! -x %PROXY_URL%"
if "!CURL_OK!"=="1" (
    if exist "!DL_OUT!" (
        set "_presz=0"
        for %%A in ("!DL_OUT!") do set "_presz=%%~zA"
        if !_presz! gtr 4096 (
            echo    %E_SUB% 发现没下完的文件, 尝试断点续传
            "%CURL%" !DL_ARG! -C - -o "!DL_OUT!" "!DL_URL!"
            if "!errorlevel!"=="0" exit /b 0
            echo    %E_SUB% 续传失败, 服务器可能不支持断点, 改为整份重下
            del /q "!DL_OUT!" >nul 2>&1
        )
    )
    "%CURL%" !DL_ARG! -o "!DL_OUT!" "!DL_URL!"
    exit /b !errorlevel!
)
if not "!PS_OK!"=="1" exit /b 1
if defined NET_PROXY (
    powershell -NoProfile -ExecutionPolicy Bypass -Command "try { Invoke-WebRequest -UseBasicParsing -TimeoutSec 600 -Proxy $env:PROXY_URL -Uri $env:DL_URL -OutFile $env:DL_OUT; exit 0 } catch { exit 1 }" >nul 2>&1
) else (
    powershell -NoProfile -ExecutionPolicy Bypass -Command "try { Invoke-WebRequest -UseBasicParsing -TimeoutSec 600 -Uri $env:DL_URL -OutFile $env:DL_OUT; exit 0 } catch { exit 1 }" >nul 2>&1
)
exit /b !errorlevel!

:check_dl
rem 返回 0 表示文件已存在且达到最小体积, 半成品一律保留以便续传
if not exist "%~1" exit /b 1
set "_dl_sz="
for %%A in ("%~1") do set "_dl_sz=%%~zA"
if not defined _dl_sz exit /b 1
if !_dl_sz! lss %~2 exit /b 1
exit /b 0
rem ---------------------------------------------------------------------------
rem  帮助
rem ---------------------------------------------------------------------------
:usage
echo.
echo %C_BIG%  Coco's 整合包 - 客户端 Mod 更新脚本  %C_RST%
echo.
echo   用法 双击运行, 或填进 PCL 启动前执行指令
echo        PCL - 版本设置 - 设置 - 高级选项 - 启动前执行指令
echo        call "{verpath}\本脚本名" "$INST_JAVA"
echo.
echo   第一个参数可选, 传 java.exe 路径则优先使用它, 对应 PCL 的 $INST_JAVA
echo.
echo   环境变量覆盖, 可选
echo        COCO_GAME_DIR         整合包目录, 默认脚本所在目录
echo        COCO_CACHE_ROOT       缓存目录, 默认 LOCALAPPDATA 下的 CocoPackwiz
echo        COCO_PACK_GIT_URL     元数据仓地址
echo        COCO_PACK_SOURCE      serve 或 file 或 remote
echo        COCO_META_SOURCE      auto 或 git 或 zip
echo        COCO_REMOTE_PACK_URL  远端 pack.toml, 填写后不再拉本地仓
echo        COCO_PROXY_PORT       系统代理端口, 默认 7890
echo   同目录的 mod更新源.cfg 可覆盖源地址, 分支, 同步方式等, 优先级低于 COCO_ 环境变量
echo.
echo   失败时会打印失败报告: 失败步骤, 原因, 下载源, 手动放置目录, 日志路径
echo   修好后直接重跑本脚本即可续接, 已完成的步骤跳过, 下载断点续传
echo.
exit /b 0
