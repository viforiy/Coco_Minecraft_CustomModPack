@echo off
chcp 65001 >nul
rem 开启 VT 转义支持（部分系统无效，但无副作用）
for /f "delims=" %%A in ('echo prompt $E^| cmd') do set "ESC=%%A"
setlocal enabledelayedexpansion

set "installer_path=./packwiz-installer-bootstrap.jar"

if not exist "%installer_path%" (
    echo [错误] 找不到安装器: %installer_path%
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

echo.
echo [信息] 正在执行 Packwiz 更新，请稍候...
"!java_path!" -jar "%installer_path%" -g -s server http://localhost:8080/pack.toml
set "rc=!errorlevel!"

if !rc! neq 0 (
    echo [错误] Packwiz 安装器执行失败，错误码：!rc!
) else (
    echo [成功] Packwiz 更新完成！
)

exit /b !rc!


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