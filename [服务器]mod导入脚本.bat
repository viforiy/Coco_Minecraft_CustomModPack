@echo off
chcp 65001 >nul
rem 开启 VT 转义支持（部分系统无效，但无副作用）
for /f "delims=" %%A in ('echo prompt $E^| cmd') do set "ESC=%%A"
setlocal enabledelayedexpansion

:: ══════════════════════════════════════════════════════════════════════════
::  服务器 Mod 导入流程
::   1) 检测 Java 21，缺失则从国内镜像下载便携版
::   2) git pull 拉取最新模组元数据（Coco_Minecraft_CustomModPack，pack.toml 层级)
::   3) 在元数据目录启动 packwiz server（本地包服务，端口 8080)
::   4) packwiz-installer-bootstrap.jar 从本地包服务拉取 mod 到 mods 目录
:: ══════════════════════════════════════════════════════════════════════════

rem 统一工作目录到脚本所在目录（mod 会安装到该目录下的 mods）
cd /d "%~dp0"


set "installer_path=packwiz-installer-bootstrap.jar"

rem 模组元数据仓库目录（pack.toml / index.toml 所在层级，由 git 管理）
set "modpack_dir=%~dp0Coco_Minecraft_CustomModPack"

rem pack 服务端口，以及交给安装器的包地址
set "packwiz_port=8080"
set "pack_url=http://localhost:%packwiz_port%/pack.toml"

rem packwiz CLI 路径；留空则自动探测（脚本目录 → 元数据目录 → PW-GUI 自带 → PATH）
set "packwiz_exe="

rem 安装完成后是否保留 pack 服务：1=保留（局域网其它机器可继续拉取）；0=自动关闭
set "keep_pack_server=1"

rem 等待 pack 服务就绪的最长秒数
set "pack_wait_seconds=30"

rem git pull 失败时：0=只警告并继续使用本地元数据；1=直接中止
set "git_pull_strict=0"

rem 运行期状态
set "git_rc=0"
set "pack_server_started=0"
set "pack_server_ready=0"
set "pack_server_pid="
set "serve_title=packwiz-server"
set "serve_out=%~dp0packwiz-serve.log"
set "serve_err=%~dp0packwiz-serve.err.log"
set "serve_pid=%~dp0packwiz-serve.pid"

if not exist "%installer_path%" (
    echo [错误] 找不到安装器: %installer_path%
    exit /b 1
)

if not exist "%modpack_dir%\pack.toml" (
    echo [错误] 找不到模组元数据目录（缺少 pack.toml）: %modpack_dir%
    exit /b 1
)

set "java_path="

:: ── 1) 优先检查 JAVA_HOME ───────────────────────────────────────
if defined JAVA_HOME if exist "%JAVA_HOME%\bin\java.exe" (
    call :is_java21 "%JAVA_HOME%\bin\java.exe"
    if !errorlevel! equ 0 set "java_path=%JAVA_HOME%\bin\java.exe"
)

:: ── 2) 检查系统 PATH (where java) ───────────────────────────────
if not defined java_path (
    for /f "delims=" %%J in ('where java 2^>nul') do (
        if not defined java_path (
            call :is_java21 "%%J"
            if !errorlevel! equ 0 set "java_path=%%J"
        )
    )
)

:: ── 3) 查询 Windows 注册表 ──────────────────────────────────────
if not defined java_path call :find_java_in_registry

:: ── 4) 常见目录扫描 ─────────────────────────────────────────────
if not defined java_path call :scan_common_dirs

:: ── 5) 国内镜像下载便携 Java 21 ──────────────────────────────────
if not defined java_path call :download_java

if not defined java_path (
    echo [错误] 未找到 Java 21，且自动下载失败。
    echo         请手动安装 Java 21，或将 JAVA_HOME 指向 Java 21。
    exit /b 1
)

echo [信息] 已找到 Java 21: %ESC%[96m !java_path! %ESC%[0m
"!java_path!" -version 2>&1 | findstr /i version

:: ── 6) 拉取最新模组元数据（git pull） ────────────────────────────
call :git_update_metadata

if !git_rc! neq 0 if "%git_pull_strict%"=="1" (
    echo [错误] git pull 失败（错误码 !git_rc!），git_pull_strict=1，已中止。
    exit /b !git_rc!
)

:: ── 7) 在元数据目录启动 packwiz server ───────────────────────────
call :start_pack_server

if not "!pack_server_ready!"=="1" (
    echo [错误] pack 服务未能在端口 %packwiz_port% 就绪，已中止。
    exit /b 1
)

:: ── 8) 执行 Packwiz 更新 ─────────────────────────────────────────
echo.
echo [信息] 包地址: !pack_url!
echo [信息] 正在执行 Packwiz 更新，请稍候...
"!java_path!" -Djava.net.useSystemProxies=true -jar "%installer_path%" -g -s server "!pack_url!"
set "rc=!errorlevel!"

:: ── 9) 收尾：按配置保留 / 关闭 pack 服务 ─────────────────────────
call :stop_pack_server

if !rc! neq 0 (
    echo [错误] Packwiz 安装器执行失败，错误码：!rc!
) else (
    echo [成功] Packwiz 更新完成！
)

exit /b !rc!


:: ══════════════════════════════════════════════════════════════════════════
::  子过程: git 拉取最新模组元数据
::  在 %modpack_dir%（pack.toml 所在层级）下执行 git pull
:: ══════════════════════════════════════════════════════════════════════════
:git_update_metadata
set "git_rc=0"
set "git_exe="

for /f "delims=" %%G in ('where git 2^>nul') do if not defined git_exe set "git_exe=%%G"
if not defined git_exe if exist "%ProgramFiles%\Git\cmd\git.exe" set "git_exe=%ProgramFiles%\Git\cmd\git.exe"
if not defined git_exe if exist "%ProgramFiles(x86)%\Git\cmd\git.exe" set "git_exe=%ProgramFiles(x86)%\Git\cmd\git.exe"
if not defined git_exe if exist "%LocalAppData%\Programs\Git\cmd\git.exe" set "git_exe=%LocalAppData%\Programs\Git\cmd\git.exe"

echo.
if not defined git_exe (
    echo [警告] 未找到 git，跳过模组元数据更新（使用本地已有元数据继续）。
    goto :eof
)

if not exist "%modpack_dir%\.git" (
    echo [警告] %modpack_dir% 不是 git 仓库，跳过模组元数据更新。
    goto :eof
)

echo [信息] 拉取最新模组元数据: cd /d "%modpack_dir%" ^&^& git pull
pushd "%modpack_dir%"
rem 网络异常时不要无限卡住：低于 1KB/s 持续 20 秒即判定失败；禁止自动合并提交弹编辑器
set "GIT_HTTP_LOW_SPEED_LIMIT=1024"
set "GIT_HTTP_LOW_SPEED_TIME=20"
set "GIT_MERGE_AUTOEDIT=no"
"%git_exe%" pull
set "git_rc=!errorlevel!"
popd

if !git_rc! neq 0 (
    echo [警告] git pull 失败（错误码 !git_rc!），继续使用本地元数据。
) else (
    echo [信息] 模组元数据已是最新。
)
goto :eof


:: ══════════════════════════════════════════════════════════════════════════
::  子过程: 启动 pack 服务（packwiz server；失败则退回 Java 内置静态服务）
:: ══════════════════════════════════════════════════════════════════════════
:start_pack_server
set "pack_server_started=0"
set "pack_server_ready=0"
set "pack_server_pid="

:: 端口已被占用 → 直接复用已经在跑的 pack 服务
call :is_port_listening
if !errorlevel! equ 0 (
    echo.
    echo [信息] 端口 %packwiz_port% 已有 pack 服务在监听，直接复用（不新建进程）。
    set "pack_server_ready=1"
    goto :eof
)

call :find_packwiz
if defined packwiz_exe (
    echo.
    echo [信息] 启动 packwiz server: "!packwiz_exe!" serve -p %packwiz_port%
    echo         工作目录: %modpack_dir%
    set "SPAWN_EXE=!packwiz_exe!"
    set "SPAWN_ARGS=serve -p %packwiz_port%"
    call :spawn_detached
    set "pack_server_started=1"
    call :wait_pack_server
)

:: packwiz 不可用或未就绪 → 退回 Java 21 内置静态文件服务（对安装器功能等价）
if not "!pack_server_ready!"=="1" (
    if "!pack_server_started!"=="1" (
        echo [警告] packwiz server 未就绪，查看日志: %serve_out%
        call :stop_pack_server force
    ) else (
        echo.
        echo [警告] 未找到 packwiz CLI（可放到脚本目录，或安装 PW-GUI）。
    )
    echo [信息] 改用 Java 内置静态文件服务提供包: %modpack_dir%
    rem 注意: jwebserver 的 -d 只接受绝对路径
    set "SPAWN_EXE=!java_path!"
    set "SPAWN_ARGS=-m jdk.httpserver -p %packwiz_port% -d "%modpack_dir%" -b 0.0.0.0 -o none"
    call :spawn_detached
    set "pack_server_started=1"
    call :wait_pack_server
)

if not "!pack_server_ready!"=="1" (
    echo [错误] pack 服务启动失败，日志: %serve_out% / %serve_err%
    call :stop_pack_server force
    goto :eof
)

if not defined pack_server_pid call :capture_server_pid
echo [信息] pack 服务已就绪: %pack_url%  (PID !pack_server_pid!)
goto :eof


:: ══════════════════════════════════════════════════════════════════════════
::  子过程: 分离启动后台服务
::  调用前设置 SPAWN_EXE / SPAWN_ARGS；成功时 PID 存入 pack_server_pid
::  用 WMI 创建进程：不继承调用方的 stdout 句柄，避免脚本输出被管道/日志占用
:: ══════════════════════════════════════════════════════════════════════════
:spawn_detached
set "pack_server_pid="
set "SPAWN_LOG=%serve_out%"
set "SPAWN_ERR=%serve_err%"
set "SPAWN_DIR=%modpack_dir%"
set "SPAWN_PID=%serve_pid%"
del /q "%serve_pid%" >nul 2>&1

powershell -NoProfile -ExecutionPolicy Bypass -Command "$q=[char]34; $c=$env:ComSpec+' /c '+$q+$q+$env:SPAWN_EXE+$q+' '+$env:SPAWN_ARGS+' 1>>'+$q+$env:SPAWN_LOG+$q+' 2>>'+$q+$env:SPAWN_ERR+$q; $a=@{CommandLine=$c; CurrentDirectory=$env:SPAWN_DIR}; $r=Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments $a; if ($r.ReturnValue -eq 0 -and $r.ProcessId) { Set-Content -LiteralPath $env:SPAWN_PID -Value $r.ProcessId }" >nul 2>&1

for /f "delims=" %%P in ('type "%serve_pid%" 2^>nul') do if not defined pack_server_pid set "pack_server_pid=%%P"
del /q "%serve_pid%" >nul 2>&1

if not defined pack_server_pid (
    rem WMI 不可用时的兜底：普通 start 启动（会带一个最小化窗口）
    echo [警告] 分离启动失败，改用普通方式启动。
    start "%serve_title%" /min /d "%modpack_dir%" cmd /c ""!SPAWN_EXE!" !SPAWN_ARGS! 1>>"%serve_out%" 2>>"%serve_err%""
)
goto :eof


:: ══════════════════════════════════════════════════════════════════════════
::  子过程: 等待 pack 服务就绪（端口监听 + pack.toml 可访问）
:: ══════════════════════════════════════════════════════════════════════════
:wait_pack_server
set /a pack_wait=0
:wait_pack_loop
call :is_port_listening
if !errorlevel! equ 0 (
    call :probe_pack_url
    if "!http_ok!"=="1" (
        set "pack_server_ready=1"
        goto :eof
    )
)
if !pack_wait! geq %pack_wait_seconds% (
    set "pack_server_ready=0"
    goto :eof
)
set /a pack_wait+=1
timeout /t 1 /nobreak >nul 2>&1 || ping -n 2 127.0.0.1 >nul
goto :wait_pack_loop


:: ══════════════════════════════════════════════════════════════════════════
::  子过程: 关闭由本脚本启动的 pack 服务
:: ══════════════════════════════════════════════════════════════════════════
:stop_pack_server
if not "!pack_server_started!"=="1" goto :eof

rem 传 force 时忽略 keep_pack_server，直接结束（用于启动失败后的清理）
if /i "%~1"=="force" goto :stop_pack_server_kill

if "%keep_pack_server%"=="1" (
    echo.
    echo [信息] 已保留 pack 服务（keep_pack_server=1），端口 %packwiz_port%
    echo [信息] 已保留 pack 服务供其他机器访问模组元数据
    for /f "tokens=2 delims=:" %%I in ('ipconfig ^| findstr /i "IPv4"') do (
        set "lan_ip=%%I"
        set "lan_ip=!lan_ip: =!"
        echo             http://!lan_ip!:%packwiz_port%/pack.toml
    )
    echo         关闭方式: taskkill /PID !pack_server_pid! /T /F
    goto :eof
)

:stop_pack_server_kill
if not defined pack_server_pid call :capture_server_pid
if defined pack_server_pid (
    taskkill /PID !pack_server_pid! /T /F >nul 2>&1
    echo [信息] 已关闭 pack 服务（PID !pack_server_pid!）。
)
taskkill /FI "WINDOWTITLE eq %serve_title%*" /F /T >nul 2>&1
set "pack_server_started=0"
set "pack_server_pid="
goto :eof


:: ══════════════════════════════════════════════════════════════════════════
::  子过程: 定位 packwiz CLI（脚本目录 → 元数据目录 → PW-GUI 自带 → PATH）
:: ══════════════════════════════════════════════════════════════════════════
:find_packwiz
if defined packwiz_exe goto :eof
for %%P in (
    "%~dp0packwiz.exe"
    "%modpack_dir%\packwiz.exe"
    "%AppData%\pwgui\bin\packwiz.exe"
    "%LocalAppData%\Programs\pwgui\bin\packwiz.exe"
    "%ProgramFiles%\pwgui\bin\packwiz.exe"
) do if not defined packwiz_exe if exist "%%~P" set "packwiz_exe=%%~P"
if not defined packwiz_exe for /f "delims=" %%P in ('where packwiz 2^>nul') do if not defined packwiz_exe set "packwiz_exe=%%P"
goto :eof


:: ── 子过程: 判断端口是否已在监听 ─────────────────────────────────
:is_port_listening
netstat -ano -p tcp | findstr /i "LISTENING" | findstr ":%packwiz_port% " >nul 2>&1
exit /b !errorlevel!


:: ── 子过程: HTTP 探测包地址（pack.toml 是否可访问） ──────────────
:probe_pack_url
set "http_ok=0"
where curl >nul 2>&1
if !errorlevel! equ 0 (
    curl -fsS --max-time 8 -o NUL "%pack_url%" >nul 2>&1
    if !errorlevel! equ 0 set "http_ok=1"
) else (
    powershell -NoProfile -ExecutionPolicy Bypass -Command "try { $r = Invoke-WebRequest -UseBasicParsing -TimeoutSec 8 -Uri '%pack_url%'; if ($r.StatusCode -eq 200) { exit 0 } else { exit 1 } } catch { exit 1 }" >nul 2>&1
    if !errorlevel! equ 0 set "http_ok=1"
)
goto :eof


:: ── 子过程: 取监听该端口的进程 PID ───────────────────────────────
:capture_server_pid
set "pack_server_pid="
for /f "tokens=5" %%P in ('netstat -ano -p tcp ^| findstr /i "LISTENING" ^| findstr ":%packwiz_port% "') do (
    if not defined pack_server_pid set "pack_server_pid=%%P"
)
goto :eof


:: ── 子过程: 从注册表查找 Java ───────────────────────────────────
:find_java_in_registry
for %%K in (
    "HKLM\SOFTWARE\JavaSoft\JDK"
    "HKLM\SOFTWARE\JavaSoft\Java Development Kit"
    "HKLM\SOFTWARE\JavaSoft\Java Runtime Environment"
    "HKLM\SOFTWARE\Wow6432Node\JavaSoft\JDK"
    "HKLM\SOFTWARE\Wow6432Node\JavaSoft\Java Development Kit"
    "HKLM\SOFTWARE\Wow6432Node\JavaSoft\Java Runtime Environment"
) do (
    if not defined java_path (
        set "cur_ver="
        set "reg_home="
        for /f "tokens=2*" %%A in ('reg query %%K /v CurrentVersion 2^>nul') do set "cur_ver=%%B"
        if defined cur_ver (
            for /f "tokens=2*" %%A in ('reg query "%%~K\!cur_ver!" /v JavaHome 2^>nul') do set "reg_home=%%B"
            if defined reg_home if exist "!reg_home!\bin\java.exe" (
                call :is_java21 "!reg_home!\bin\java.exe"
                if !errorlevel! equ 0 set "java_path=!reg_home!\bin\java.exe"
            )
        )
    )
)
goto :eof


:: ── 子过程: 扫描常见目录 ────────────────────────────────────────
:scan_common_dirs
call :scan_dir "%ProgramFiles%\Java"
call :scan_dir "%ProgramFiles%\Eclipse Adoptium"
call :scan_dir "%ProgramFiles%\Microsoft"
call :scan_dir "%ProgramFiles%\Amazon Corretto"
call :scan_dir "%ProgramFiles%\Zulu"
call :scan_dir "%ProgramFiles%\BellSoft"
call :scan_dir "%ProgramFiles%\Semeru"
call :scan_dir "%ProgramFiles%\IBM"
call :scan_dir "C:\Program Files (x86)\Java"
call :scan_dir "C:\Program Files (x86)\Eclipse Adoptium"
call :scan_dir "C:\Program Files (x86)\Microsoft"
call :scan_dir "D:\Program Files\Java"
call :scan_dir "D:\Program Files\jdk21"
goto :eof


:: ── 子过程: 扫描单个父目录下所有子目录 ──────────────────────────
:scan_dir
if defined java_path goto :eof
if not exist "%~1" goto :eof
for /d %%V in ("%~1\*") do (
    if not defined java_path if exist "%%~V\bin\java.exe" (
        call :is_java21 "%%~V\bin\java.exe"
        if !errorlevel! equ 0 set "java_path=%%~V\bin\java.exe"
    )
)
goto :eof


:: ── 子过程: 从国内镜像下载 Java 21 ───────────────────────────────
:: 主源: 华为云 openjdk-21_windows-x64_bin.zip
:: 备源: 清华 TUNA Adoptium 镜像目录（需解析目录页）
:download_java
set "java_root=%CD%\java21"
set "java_zip=%CD%\java21.zip"

:: 若已存在解压后的 Java，直接复用
if exist "%java_root%\bin\java.exe" (
    call :is_java21 "%java_root%\bin\java.exe"
    if !errorlevel! equ 0 (
        set "java_path=%java_root%\bin\java.exe"
        echo [信息] 复用已下载的 Java 21: !java_path!
        goto :eof
    )
)
for /d %%D in ("%java_root%\*") do (
    if not defined java_path if exist "%%~D\bin\java.exe" (
        call :is_java21 "%%~D\bin\java.exe"
        if !errorlevel! equ 0 set "java_path=%%~D\bin\java.exe"
    )
)
if defined java_path (
    echo [信息] 复用已下载的 Java 21: !java_path!
    goto :eof
)

:: 华为云镜像：OpenJDK 21 Windows x64 zip
set "java_url_primary=https://mirrors.huaweicloud.com/openjdk/21/openjdk-21_windows-x64_bin.zip"

:: 清华 TUNA 备源：Adoptium 21 Windows x64 zip（需从目录页提取具体文件名）
set "java_url_backup="

echo [信息] 本地未找到 Java 21，正在从国内镜像下载...
echo         主源: !java_url_primary!
echo         这可能需要几分钟，请耐心等待。

:: 优先使用 curl（Win10 1803+ 内置），否则退回到 PowerShell
where curl >nul 2>&1
if !errorlevel! equ 0 (
    curl -L --fail --retry 3 --connect-timeout 15 -o "%java_zip%" "!java_url_primary!"
) else (
    powershell -NoProfile -ExecutionPolicy Bypass -Command ^
        "try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12; Invoke-WebRequest -Uri '!java_url_primary!' -OutFile '!java_zip!' -UseBasicParsing } catch { Write-Host $_.Exception.Message; exit 1 }"
)

:: 主源失败时尝试清华备源（如已配置）
if not exist "%java_zip%" if defined java_url_backup (
    echo [警告] 主源失败，尝试清华 TUNA 备源...
    if !errorlevel! equ 0 (
        curl -L --fail --retry 3 --connect-timeout 15 -o "%java_zip%" "!java_url_backup!"
    ) else (
        powershell -NoProfile -ExecutionPolicy Bypass -Command ^
            "try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12; Invoke-WebRequest -Uri '!java_url_backup!' -OutFile '!java_zip!' -UseBasicParsing } catch { Write-Host $_.Exception.Message; exit 1 }"
    )
)

if not exist "%java_zip%" (
    echo [错误] Java 下载失败，请检查网络连接或手动下载。
    echo         华为云镜像: !java_url_primary!
    echo         清华镜像: https://mirrors.tuna.tsinghua.edu.cn/Adoptium/21/jdk/x64/windows/
    goto :eof
)

:: 检查文件大小（防止下载到错误页面）
for %%A in ("%java_zip%") do set "zip_size=%%~zA"
if !zip_size! LSS 10000000 (
    echo [错误] 下载的文件异常（大小 !zip_size! 字节），可能不是有效压缩包。
    del /q "%java_zip%" 2>nul
    goto :eof
)

echo [信息] 下载完成 (!zip_size! 字节)，正在解压...

if not exist "%java_root%" mkdir "%java_root%"
powershell -NoProfile -ExecutionPolicy Bypass -Command ^
    "try { Expand-Archive -Path '%java_zip%' -DestinationPath '%java_root%' -Force } catch { Write-Host $_.Exception.Message; exit 1 }"

if not exist "%java_root%" (
    echo [错误] 解压失败。
    goto :eof
)

:: 华为云 zip 解压后通常为 java_root\jdk-21.x.x\bin\java.exe
:: 也兼容直接解压到 java_root\bin 的情况
for /d %%D in ("%java_root%\*") do (
    if not defined java_path if exist "%%~D\bin\java.exe" (
        call :is_java21 "%%~D\bin\java.exe"
        if !errorlevel! equ 0 set "java_path=%%~D\bin\java.exe"
    )
)
if not defined java_path if exist "%java_root%\bin\java.exe" (
    call :is_java21 "%java_root%\bin\java.exe"
    if !errorlevel! equ 0 set "java_path=%java_root%\bin\java.exe"
)

if defined java_path (
    echo [信息] 已使用下载的 Java: !java_path!
) else (
    echo [错误] 解压后仍未找到可用的 java.exe。
)

:: 清理压缩包
del /q "%java_zip%" 2>nul
goto :eof


:: ── 子过程: 判断指定 java.exe 是否为主版本 21 ────────────────────
:is_java21
set "jv="
for /f "tokens=3" %%v in ('"%~1" -version 2^>^&1') do (
    if not defined jv set "jv=%%~v"
)
if not defined jv exit /b 1
echo !jv! | findstr /b "21" >nul
exit /b !errorlevel!
