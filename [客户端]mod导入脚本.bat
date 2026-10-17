@echo off
rem 开启 VT 转义支持（部分系统无效，但无副作用）
for /f "delims=" %%A in ('echo prompt $E^| cmd') do set "ESC=%%A"

setlocal enabledelayedexpansion

set "mc_path=."
set "installer_path=%mc_path%/packwiz-installer-bootstrap.jar"
set "server_url=http://127.0.0.1:8080/pack.toml"

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

:: ── 3) 查询 Windows 注册表 (最可靠的自动发现方法) ──────────────
if not defined java_path call :find_java_in_registry

:: ── 4) 常见目录扫描 (最终兜底) ──────────────────────────────────
if not defined java_path call :scan_common_dirs

if not defined java_path (
    echo [错误] 未找到 Java 21。请安装 Java 21 或将 JAVA_HOME 指向 Java 21。
    exit /b 1
)
echo [信息] 已找到 Java 21: %ESC%[96m  !java_path!  %ESC%[0m
"!java_path!" -version 2>&1 | findstr /i version

echo.
echo [信息] 正在执行 Packwiz 更新，请稍候...
"!java_path!" -jar "%installer_path%" %server_url%
set "rc=!errorlevel!"

if !rc! neq 0 (
    echo [错误] Packwiz 安装器执行失败，错误码：!rc!
) else (
    echo [成功] Packwiz 更新完成！
)


rem ── 生成 PCL 启动前执行命令所需指令并复制到剪贴板 ──
set "SCRIPT_DIR=%~dp0"
set "SCRIPT_DIR=%SCRIPT_DIR:~0,-1%"
set "PCL_CMD=cd /d "%SCRIPT_DIR%" && call "%~nx0""



echo %ESC%[93m============================================================%ESC%[0m
echo %ESC%[97;41m  [提示] 已生成启动前命令并复制到剪贴板, 不要移动脚本本身, 保持放在整合包版本文件夹下  %ESC%[0m
echo %ESC%[93m============================================================%ESC%[0m
echo.
echo 粘贴到：PCL -^> 版本设置 -^> 设置 -^> 高级选项 -^> 启动前执行指令
echo.
echo   %ESC%[92m!PCL_CMD!%ESC%[0m
echo.

>"%TEMP%\pcl_prelaunch_cmd.txt" echo !PCL_CMD!
clip < "%TEMP%\pcl_prelaunch_cmd.txt"
echo %ESC%[96m（已自动复制到剪贴板, 存档: %TEMP%\pcl_prelaunch_cmd.txt）%ESC%[0m
echo %ESC%[93m============================================================%ESC%[0m

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


:: ── 子过程: 判断指定 java.exe 是否为主版本 21 ────────────────────
:is_java21
set "jv="
for /f "tokens=3" %%v in ('"%~1" -version 2^>^&1') do (
    if not defined jv set "jv=%%~v"
)
if not defined jv exit /b 1
echo !jv! | findstr /b "21" >nul
exit /b !errorlevel!
