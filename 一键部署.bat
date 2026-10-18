@echo off
rem ============================================================================
rem  Coco 整合包 - Mod 更新脚本 一键部署
rem
rem  给刚拿到本仓库的新用户用: 把对应平台的更新脚本放到正确位置, 并生成
rem  配置文件与启动前命令。两种用法:
rem
rem   双击运行                     交互式, 一路回车即可
rem   带参数运行                   无人值守, 适合批量部署
rem     一键部署.bat 1 "版本文件夹" ["仓库" "分支" /y /run]
rem     一键部署.bat 2 "开服目录"   ["仓库" "分支" /y /run]
rem
rem   1=客户端 2=服务端   /y=同名文件直接覆盖   /run=部署完立刻试跑
rem ============================================================================

chcp 936 >nul 2>&1
for /f "delims=" %%A in ('echo prompt $E^| cmd') do set "ESC=%%A"
setlocal enabledelayedexpansion

set "C_RST=%ESC%[0m"
set "C_RED=%ESC%[91m"
set "C_GRN=%ESC%[92m"
set "C_YEL=%ESC%[93m"
set "C_BLU=%ESC%[96m"
set "C_DIM=%ESC%[90m"
set "C_WHT=%ESC%[97m"
set "C_STEP=%ESC%[30;106m"
set "C_BIG=%ESC%[97;45m"

set "E_INFO=echo %C_BLU%[信息]%C_RST%"
set "E_OK=echo %C_GRN%[完成]%C_RST%"
set "E_WARN=echo %C_YEL%[警告]%C_RST%"
set "E_ERR=echo %C_RED%[错误]%C_RST%"
set "E_SUB=%C_DIM%  -%C_RST%"

if /i "%~1"=="--help" goto :usage
if /i "%~1"=="/?" goto :usage
if /i "%~1"=="-h" goto :usage

cd /d "%~dp0"
set "REPO_DIR=%~dp0"
if "%REPO_DIR:~-1%"=="\" set "REPO_DIR=%REPO_DIR:~0,-1%"
set "CLIENT_BAT=%REPO_DIR%\[客户端]mod更新脚本.bat"
set "SERVER_BAT=%REPO_DIR%\[服务端]mod更新脚本.bat"
set "CFG_NAME=mod更新源.cfg"

rem 默认源取本仓库的 origin, 拿不到再退回写死的地址
set "DEFAULT_REPO=https://github.com/viforiy/Coco_Minecraft_CustomModPack.git"
set "GIT_ORIGIN="
for /f "delims=" %%R in ('git -C "%REPO_DIR%" remote get-url origin 2^>nul') do if not defined GIT_ORIGIN set "GIT_ORIGIN=%%R"
if defined GIT_ORIGIN set "DEFAULT_REPO=!GIT_ORIGIN!"
set "DEFAULT_BRANCH=main"

rem ---- 命令行参数 ----
set "ARG_MODE=%~1"
set "ARG_TARGET=%~2"
set "ARG_REPO=%~3"
set "ARG_BRANCH=%~4"
set "AUTO_YES=0"
set "AUTO_RUN=0"
if not "%~1"=="" for %%A in (%*) do (
    if /i "%%~A"=="/y" set "AUTO_YES=1"
    if /i "%%~A"=="/run" set "AUTO_RUN=1"
)
set "NONINTERACTIVE="
if defined ARG_MODE set "NONINTERACTIVE=1"

set "TS="
for /f "delims=" %%T in ('powershell -NoProfile -Command "Get-Date -Format yyyyMMdd-HHmmss" 2^>nul') do if not defined TS set "TS=%%T"
if not defined TS set "TS=T%RANDOM%"

set "MODE="
set "SIDE="
set "SCRIPT_NAME="
set "SCRIPT_SRC="
set "TARGET="
set "REPO="
set "BRANCH="
set "CFG="
set "NORM="
set "RAW="

title Coco 整合包 - Mod 更新脚本 一键部署

echo.
echo %C_BIG%  Coco 整合包 - Mod 更新脚本 一键部署  %C_RST%
echo %C_DIM%  ==================================================================%C_RST%
echo.
echo %C_WHT%  背景%C_RST%
echo     这个仓库是 Coco 的 Minecraft 整合包模组清单, 用 packwiz 管理, 用 git 托管
echo     pack.toml 与 mods 下面的 .pw.toml 只是元数据, jar 不在这里
echo     真正的模组由 packwiz-installer 按清单从 Modrinth 与 CurseForge 下载
echo.
echo %C_WHT%  这个脚本做什么%C_RST%
echo     把 每次启动前自动对齐模组 这件事装进你的游戏目录
echo     客户端 装到 PCL 版本文件夹, 启动游戏前自动更新 mods
echo     服务端 装到开服目录, 开服前自动更新 mods
echo     装好后只多一个脚本和一个 cfg, 不动存档, 不动配置, 不动整合包本体
echo.
echo %C_WHT%  调用流程%C_RST%
echo     %C_DIM%第 1 步  一键部署.bat  放好脚本 写好 mod更新源.cfg  只跑一次%C_RST%
echo     %C_DIM%第 2 步  PCL 启动前调用 [客户端]mod更新脚本.bat%C_RST%
echo     %C_DIM%第 3 步  开服脚本 java 之前调用 [服务端]mod更新脚本.bat%C_RST%
echo     %C_DIM%第 4 步  更新脚本内部 拉元数据 刷新索引 差异同步 mods%C_RST%
echo.
echo %C_WHT%  装完要做什么%C_RST%
echo     客户端 把最后打印的 call 行粘到 PCL 的启动前执行指令
echo     服务端 把最后打印的两行 call 粘到开服脚本 java 那一行之前
echo     就这两件事, 之后每次启动都会自动更新
echo.
echo %C_WHT%  不需要做什么 也别做%C_RST%
echo     不要手动往 mods 里塞 jar, 下次同步会按清单把它清掉或覆盖
echo     不要把这两个更新脚本复制到元数据仓目录里运行
echo     不要改脚本本体, 要换源改 mod更新源.cfg 就行
echo     不需要自己装 packwiz 或 git, 脚本会自己准备, 没有 git 也能更新
echo     不要在这里按 Ctrl+C 强退, 中途退出不会损坏 mods, 重跑会接着来
echo.
echo %C_DIM%  ==================================================================%C_RST%
if defined NONINTERACTIVE echo %C_DIM%  当前为参数模式, 不会提问%C_RST%
if defined NONINTERACTIVE goto :intro_done

set "_go="
set /p "_go=看明白了就按回车开始, 输入 n 退出 : "
if /i "!_go!"=="n" goto :bye

:intro_done

rem ===========================================================================
rem  第一步 选择平台
rem ===========================================================================
echo.
echo %C_STEP%  [1/5]  选择要部署的平台  %C_RST%
echo.
echo     %C_GRN%[1]%C_RST% 客户端  装到 PCL 的版本文件夹, 每次启动前自动更新 mod
echo     %C_GRN%[2]%C_RST% 服务端  装到开服目录, 每次开服前自动更新 mod
echo.

if defined NONINTERACTIVE (
    set "MODE=!ARG_MODE!"
    goto :mode_gate
)

:ask_mode
set "MODE="
set /p "MODE=请输入 1 或 2, 回车默认 1 : "
if not defined MODE set "MODE=1"

:mode_gate
if "!MODE!"=="1" goto :mode_client
if "!MODE!"=="2" goto :mode_server
%E_ERR% 平台只能填 1 或 2, 收到的是 !MODE!
if defined NONINTERACTIVE goto :bye
%E_WARN% 请重新输入
goto :ask_mode

:mode_client
set "SIDE=客户端"
set "SCRIPT_NAME=[客户端]mod更新脚本.bat"
set "SCRIPT_SRC=!CLIENT_BAT!"
set "SIDE_TIP=PCL 的版本文件夹, 例如 .minecraft\versions\某个整合包"
set "SIDE_CHECK=client"
goto :mode_ready

:mode_server
set "SIDE=服务端"
set "SCRIPT_NAME=[服务端]mod更新脚本.bat"
set "SCRIPT_SRC=!SERVER_BAT!"
set "SIDE_TIP=开服目录, 也就是里面有 mods 文件夹和 server.jar 的那一层"
set "SIDE_CHECK=server"

:mode_ready
if not exist "!SCRIPT_SRC!" (
    echo.
    %E_ERR% 仓库里找不到 !SCRIPT_NAME!
    echo        %E_SUB% 请把本脚本和两个更新脚本放在同一个目录, 也就是仓库根目录
    echo        %E_SUB% 当前查找位置 !SCRIPT_SRC!
    goto :bye
)
echo.
%E_OK% 已选择 !SIDE!

rem ===========================================================================
rem  第二步 游戏目录
rem ===========================================================================
echo.
echo %C_STEP%  [2/5]  填写游戏目录  %C_RST%
echo.
echo     !SIDE_TIP!
echo     %C_DIM%把文件夹直接拖进本窗口, 路径会自动带上双引号, 不用手删%C_RST%
echo.

if defined NONINTERACTIVE (
    set "RAW=!ARG_TARGET!"
    if not defined RAW (
        %E_ERR% 参数模式缺少游戏目录
        echo        %E_SUB% 用法 一键部署.bat 1 "版本文件夹"
        goto :bye
    )
    call :norm_path "!RAW!"
    if not defined NORM (
        %E_ERR% 目录参数不合法 !RAW!
        goto :bye
    )
    set "TARGET=!NORM!"
    if not exist "!TARGET!" (
        %E_INFO% 目录不存在, 自动创建
        mkdir "!TARGET!" >nul 2>&1
        if not exist "!TARGET!" (
            %E_ERR% 创建目录失败 !TARGET!
            goto :bye
        )
    )
    goto :target_ready
)

:ask_target
set "RAW="
set /p "RAW=游戏目录 : "
if not defined RAW (
    %E_WARN% 目录不能为空
    goto :ask_target
)
call :norm_path "!RAW!"
if not defined NORM (
    %E_WARN% 没解析出有效路径
    goto :ask_target
)
set "TARGET=!NORM!"

if not exist "!TARGET!" (
    echo.
    %E_WARN% 目录不存在 !TARGET!
    call :confirm "要现在创建这个目录吗"
    if not "!errorlevel!"=="0" goto :ask_target
    mkdir "!TARGET!" >nul 2>&1
    if not exist "!TARGET!" (
        %E_ERR% 创建失败, 换个路径试试
        goto :ask_target
    )
    %E_OK% 目录已创建
)

:target_ready
if exist "!TARGET!\pack.toml" (
    echo.
    %E_ERR% 这个目录里有 pack.toml, 看起来是模组元数据仓, 不是游戏目录
    echo        %E_SUB% 更新脚本会把 mod 装到目录下的 mods, 放错位置会污染仓库
    echo        %E_SUB% 请填游戏目录, 元数据仓只用来当源
    if not defined NONINTERACTIVE goto :ask_target
    goto :bye
)

if not exist "!TARGET!\mods" (
    echo.
    %E_WARN% 这个目录下没有 mods 文件夹
    if /i "!SIDE_CHECK!"=="client" (
        echo        %E_SUB% 客户端目标通常是 .minecraft\versions\版本名 , 里面应该有 mods
    ) else (
        echo        %E_SUB% 服务端目标应该是 mods 与 server.jar 所在的那一层
    )
    echo        %E_SUB% 如果是全新的整合包, 继续也没问题, 脚本会自己建 mods
    call :confirm "仍然使用这个目录吗"
    if not "!errorlevel!"=="0" (
        if not defined NONINTERACTIVE goto :ask_target
        %E_INFO% 参数模式, 按继续处理
    )
)
echo.
%E_OK% 目标目录 !TARGET!

rem ===========================================================================
rem  第三步 元数据仓
rem ===========================================================================
echo.
echo %C_STEP%  [3/5]  模组元数据仓  %C_RST%
echo.
echo     必须是 packwiz 规范的仓库, 根目录要有 pack.toml 和 index.toml
echo     可以直接填 用户名/仓库名 这种简写, 脚本会补成完整的 GitHub 地址
echo %C_DIM%     默认 !DEFAULT_REPO!%C_RST%
echo.

if defined NONINTERACTIVE (
    set "RAW=!ARG_REPO!"
    if not defined RAW set "RAW=!DEFAULT_REPO!"
    goto :repo_gate
)

:ask_repo
set "RAW="
set /p "RAW=元数据仓, 回车用默认 : "
if not defined RAW set "RAW=!DEFAULT_REPO!"

:repo_gate
call :norm_repo "!RAW!"
if not defined NORM (
    %E_WARN% 这个地址看起来不像仓库: !RAW!
    if defined NONINTERACTIVE goto :bye
    goto :ask_repo
)
set "REPO=!NORM!"
echo.
%E_OK% 元数据仓 !REPO!

if defined NONINTERACTIVE (
    set "BRANCH=!ARG_BRANCH!"
) else (
    echo %C_DIM%  分支名, 一般就是 main, 老仓库可能是 master%C_RST%
    set "RAW="
    set /p "RAW=分支, 回车默认 main : "
    set "BRANCH=!RAW!"
)
if not defined BRANCH set "BRANCH=!DEFAULT_BRANCH!"
echo    %E_SUB% 分支 !BRANCH!

rem ===========================================================================
rem  第四步 复制脚本
rem ===========================================================================
echo.
echo %C_STEP%  [4/5]  放置更新脚本  %C_RST%

set "DST=!TARGET!\!SCRIPT_NAME!"
if exist "!DST!" (
    echo.
    %E_WARN% 目标位置已经有 !SCRIPT_NAME!
    call :confirm "覆盖它吗, 旧文件会先备份"
    if not "!errorlevel!"=="0" (
        %E_INFO% 保留原脚本, 只更新配置文件
        goto :after_copy
    )
    copy /y "!DST!" "!DST!.bak-!TS!" >nul 2>&1
    echo    %E_SUB% 旧脚本已备份 !DST!.bak-!TS!
)
copy /y "!SCRIPT_SRC!" "!DST!" >nul 2>&1
if not exist "!DST!" (
    %E_ERR% 复制失败, 检查目录权限或是否被杀软拦截
    goto :bye
)
%E_OK% 已放置 !DST!
:after_copy

rem ===========================================================================
rem  第五步 写配置与启动命令
rem ===========================================================================
echo.
echo %C_STEP%  [5/5]  生成配置与启动命令  %C_RST%

set "CFG=!TARGET!\!CFG_NAME!"
if exist "!CFG!" (
    echo.
    %E_WARN% 已有配置文件 !CFG_NAME!
    set "OLD_URL="
    for /f "usebackq eol=# tokens=1,* delims==" %%a in ("!CFG!") do if /i "%%a"=="PACK_GIT_URL" (
        if not defined OLD_URL set "OLD_URL=%%b"
    )
    if defined OLD_URL echo    %E_SUB% 里面记的源 !OLD_URL!
    call :confirm "用本次填的源覆盖它吗"
    if not "!errorlevel!"=="0" (
        %E_INFO% 保留原有配置
        goto :after_cfg
    )
    copy /y "!CFG!" "!CFG!.bak-!TS!" >nul 2>&1
)
> "!CFG!" echo # Coco 整合包 Mod 更新源配置
>>"!CFG!" echo # 由 一键部署.bat 生成, 手工改完下次运行自动生效
>>"!CFG!" echo # 以 # 开头的行会被忽略, 等号后面不要留多余空格
>>"!CFG!" echo # 元数据仓地址, 必须是 packwiz 规范仓库, 根目录要有 pack.toml
>>"!CFG!" echo PACK_GIT_URL=!REPO!
>>"!CFG!" echo # 分支名
>>"!CFG!" echo PACK_GIT_BRANCH=!BRANCH!
>>"!CFG!" echo # 同步方式 auto 优先用 git, 没装 git 时自动改用 zip 压缩包
>>"!CFG!" echo META_SOURCE=auto
>>"!CFG!" echo # 以下为可选项, 需要时去掉行首的 # 再用
>>"!CFG!" echo #PACK_SOURCE=serve
>>"!CFG!" echo #PROXY_PORT=7890
>>"!CFG!" echo #BACKUP_MODS=0
>>"!CFG!" echo #FAIL_HARD=0
%E_OK% 已写入 !CFG!
:after_cfg

if /i "!SIDE_CHECK!"=="client" (
    set "CMDFILE=!TARGET!\PCL启动前命令.txt"
    > "!CMDFILE!" echo call "{verpath}\!SCRIPT_NAME!" "$INST_JAVA"
%E_OK% 已写入 !CMDFILE!
) else (
    set "CMDFILE=!TARGET!\开服前命令.txt"
    > "!CMDFILE!" echo call "!SCRIPT_NAME!"
    >>"!CMDFILE!" echo if errorlevel 1 exit /b 1
%E_OK% 已写入 !CMDFILE!
)

rem 记一笔知情标记, 之后更新脚本单独跑时不再拦人
set "ACK_DIR=%LOCALAPPDATA%\CocoPackwiz"
if defined COCO_CACHE_ROOT set "ACK_DIR=%COCO_CACHE_ROOT%"
set "ACKFILE=!ACK_DIR!\ack-!SIDE_CHECK!.txt"
if not exist "!ACK_DIR!" mkdir "!ACK_DIR!" >nul 2>&1
> "!ACKFILE!" echo ack by 一键部署 !TS!
>>"!ACKFILE!" echo target=!TARGET!
>>"!ACKFILE!" echo repo=!REPO!
rem ===========================================================================
rem  收尾
rem ===========================================================================
echo.
echo %C_BIG%  部署完成  %C_RST%
echo.
if /i "!SIDE_CHECK!"=="client" (
    echo   %C_WHT%接下来做一件事%C_RST%
    echo     打开 PCL 版本设置 - 设置 - 高级选项 - 启动前执行指令
    echo     粘贴下面这一行
    echo.
    echo       %C_GRN%call "{verpath}\!SCRIPT_NAME!" "$INST_JAVA"%C_RST%
    echo.
    echo     %C_DIM%{verpath} 由 PCL 换成版本文件夹, 原文在 !CMDFILE!%C_RST%
) else (
    echo   %C_WHT%接下来做一件事%C_RST%
    echo     打开你的开服脚本, 在 java 那一行之前加两行
    echo.
    echo       %C_GRN%call "!SCRIPT_NAME!"%C_RST%
    echo       %C_GRN%if errorlevel 1 exit /b 1%C_RST%
    echo.
    echo     %C_DIM%这两行也存成了 !CMDFILE!%C_RST%
)
echo.
echo   %C_WHT%配置文件%C_RST%
echo     !CFG!
echo     %C_DIM%换源, 改分支, 开备份, 都在这里改, 不用动脚本%C_RST%
echo.
echo   %C_WHT%日志与缓存%C_RST%
echo     %LOCALAPPDATA%\CocoPackwiz
echo     %C_DIM%日志在 logs, 元数据仓缓存在 meta, 失败会写 更新失败报告-时间.txt%C_RST%
echo.
echo   %C_WHT%别做这些%C_RST%
echo     %C_DIM%1 手动往 mods 塞 jar, 下次同步会按清单清掉或覆盖%C_RST%
echo     %C_DIM%2 把更新脚本复制到元数据仓目录里跑, 那会把 mod 装进仓库%C_RST%
echo     %C_DIM%3 改更新脚本本体, 要换源改 !CFG_NAME! 就行%C_RST%
echo.

if "!AUTO_RUN!"=="1" goto :do_run
if defined NONINTERACTIVE goto :done

call :confirm "现在试跑一次吗, 会联网更新 mods, 可能需要几分钟"
if not "!errorlevel!"=="0" goto :done

:do_run
echo.
%E_INFO% 开始试跑, 输出较多属正常
echo.
call "!DST!"
echo.
%E_OK% 试跑结束, 退出码 !errorlevel!
goto :done

:done
echo.
echo %C_DIM%  窗口可以关闭了%C_RST%
endlocal
exit /b 0

:bye
echo.
echo %C_DIM%  部署没有完成, 窗口可以关闭了%C_RST%
endlocal
exit /b 1


rem ###########################################################################
rem  子过程
rem ###########################################################################

rem 去掉拖拽带来的双引号与尾部空格, 顺便去掉多余的反斜杠
:norm_path
set "_p=%~1"
set "_p=!_p:"=!"
for /l %%i in (1,1,3) do if "!_p:~-1!"==" " set "_p=!_p:~0,-1!"
if not "!_p:~3!"=="" if "!_p:~-1!"=="\" set "_p=!_p:~0,-1!"
if "!_p:~-1!"==":" set "_p=!_p!\"
set "NORM=!_p!"
goto :eof

rem 允许填 用户名/仓库名 简写, 也接受完整 URL 与本地 file 路径
:norm_repo
set "_r=%~1"
set "_r=!_r:"=!"
for /l %%i in (1,1,3) do if "!_r:~-1!"==" " set "_r=!_r:~0,-1!"
if not defined _r goto :eof
set "_pre=!_r:~0,4!"
rem 已知协议前缀直接白名单放行
if /i "!_pre!"=="http" goto :norm_ok
if /i "!_pre!"=="file" goto :norm_ok
if /i "!_pre!"=="git@" goto :norm_ok
rem 本地绝对路径 C:\xxx 也放行
if "!_r:~1,1!"==":" if "!_r:~2,1!"=="\" goto :norm_ok
rem 剩下的若带斜杠, 按 用户名/仓库名 简写处理
echo !_r! | findstr /c:"/" >nul 2>&1
if errorlevel 1 set "NORM=" & goto :eof
set "_r=https://github.com/!_r!"
:norm_ok
set "NORM=!_r!"
goto :eof

:confirm
if defined NONINTERACTIVE (
    if "!AUTO_YES!"=="1" exit /b 0
    exit /b 1
)
set "_ans="
set /p "_ans=%~1 [y/N] : "
if /i "!_ans!"=="y" exit /b 0
if /i "!_ans!"=="yes" exit /b 0
exit /b 1

rem ---------------------------------------------------------------------------
rem  帮助
rem ---------------------------------------------------------------------------
:usage
echo.
echo %C_BIG%  Coco 整合包 - Mod 更新脚本 一键部署  %C_RST%
echo.
echo   交互式
echo     双击本文件, 按提示一路回车即可
echo.
echo   参数式, 适合批量部署
echo     一键部署.bat 1 "PCL版本文件夹" ["仓库地址" "分支" /y /run]
echo     一键部署.bat 2 "开服目录"     ["仓库地址" "分支" /y /run]
echo       1 客户端  2 服务端
echo       仓库地址 可省略, 也可以只写 用户名/仓库名
echo       /y    遇到同名脚本与配置直接覆盖, 覆盖前会备份
echo       /run  部署完立刻试跑一次更新
echo.
echo   目标目录里会生成
echo     [客户端]mod更新脚本.bat 或 [服务端]mod更新脚本.bat
echo     mod更新源.cfg          源地址与选项, 换源改这里
echo     PCL启动前命令.txt 或 开服前命令.txt
echo.
echo   缓存与日志固定在 %LOCALAPPDATA%\CocoPackwiz
echo.
exit /b 0
