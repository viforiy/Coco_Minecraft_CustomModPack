@echo off
rem ============================================================================
rem  获取 PW-GUI - packwiz 元数据的图形化编辑器
rem
rem  PW-GUI 是第三方工具, 用来打开一个 packwiz 包目录, 增删改模组元数据
rem  它体积 6MB 以上, 属于开发期工具, 所以不进 git 仓库, 需要时用本脚本下
rem
rem  用法
rem    双击                     下载到本脚本所在目录
rem    获取PW-GUI.bat "包目录"   直接下载到指定的 packwiz 包目录里
rem ============================================================================

chcp 936 >nul 2>&1
for /f "delims=" %%A in ('echo prompt $E^| cmd') do set "ESC=%%A"
setlocal enabledelayedexpansion

set "C_RST=%ESC%[0m"
set "C_GRN=%ESC%[92m"
set "C_YEL=%ESC%[93m"
set "C_RED=%ESC%[91m"
set "C_BLU=%ESC%[96m"
set "C_DIM=%ESC%[90m"
set "C_WHT=%ESC%[97m"
set "C_BIG=%ESC%[97;45m"

set "E_INFO=echo %C_BLU%[信息]%C_RST%"
set "E_OK=echo %C_GRN%[完成]%C_RST%"
set "E_WARN=echo %C_YEL%[警告]%C_RST%"
set "E_ERR=echo %C_RED%[错误]%C_RST%"
set "E_SUB=%C_DIM%  -%C_RST%"

set "PWNAME=PW-GUI-v1.3.0.exe"
set "PWURL=https://github.com/AmberIsFrozen/PW-GUI/releases/download/v1.3.0/PW-GUI-v1.3.0.exe"
set "PWMIRROR=https://ghfast.top/https://github.com/AmberIsFrozen/PW-GUI/releases/download/v1.3.0/PW-GUI-v1.3.0.exe"
set "PROXY_HOST=127.0.0.1"
set "PROXY_PORT=7890"

cd /d "%~dp0"
set "OUTDIR=%~1"
if not defined OUTDIR set "OUTDIR=%~dp0"
if "%OUTDIR:~-1%"=="\" set "OUTDIR=%OUTDIR:~0,-1%"
if not exist "!OUTDIR!" mkdir "!OUTDIR!" >nul 2>&1
set "OUT=!OUTDIR!\%PWNAME%"

set "CURL=%SystemRoot%\System32\curl.exe"
set "CURL_OK=0"
if exist "!CURL!" set "CURL_OK=1"
set "PS_OK=0"
where powershell >nul 2>&1 && set "PS_OK=1"

echo.
echo %C_BIG%  PW-GUI 获取工具  %C_RST%
echo %C_DIM%  ------------------------------------------------------------------%C_RST%
echo   PW-GUI 用来图形化编辑 packwiz 包里的模组元数据
echo   它是第三方工具, 体积大, 属于开发期使用, 所以不放进 git 仓库
echo   下载来源 !PWURL!
echo.
echo   保存到 !OUT!
echo.

if exist "!OUT!" (
    %E_WARN% 目标位置已经有 !PWNAME!
    echo        %E_SUB% 想重新下载就先删掉它, 或换个目录
    goto :bye
)

%E_INFO% 开始下载, 大约 6 到 7 MB
set "OK=0"
call :fetch ""
if exist "!OUT!" call :checksize
if "!OK!"=="1" goto :report

%E_WARN% 直连失败, 改用本机代理 127.0.0.1:!PROXY_PORT! 再试
call :proxy_ready
if "!errorlevel!"=="0" (
    call :fetch "-x"
    if exist "!OUT!" call :checksize
)
if "!OK!"=="1" goto :report

%E_WARN% 代理也不行, 改用 GitHub 加速镜像
set "PWURL=!PWMIRROR!"
set "OK=0"
call :fetch ""
if exist "!OUT!" call :checksize
if "!OK!"=="1" goto :report

%E_ERR% 下载失败, 可以手动打开下面地址下载, 再放到 !OUTDIR!
echo        !PWURL!
goto :bye

:report
%E_OK% 下载完成
for %%A in ("!OUT!") do echo        %E_SUB% 大小 %%~zA 字节
echo        %E_SUB% 位置 !OUT!
for /f "skip=1 tokens=*" %%H in ('certutil -hashfile "!OUT!" SHA256 2^>nul') do (
    if not defined HASH set "HASH=%%H"
)
if defined HASH echo        %E_SUB% SHA256 !HASH!
echo.
echo   %C_WHT%怎么用%C_RST%
echo     1  双击 !PWNAME! 打开
echo     2  选中你的 packwiz 包目录, 也就是 pack.toml 所在的那一层
echo     3  左边加模组 右边改版本, 改完记得回命令行跑 packwiz refresh
echo     4  提交推送之前先看一眼 git status, 确认只动了该动的 toml
echo.
echo   %C_WHT%注意%C_RST%
echo     %E_SUB% 它只改元数据, 不下载 jar, jar 由 packwiz-installer 负责
echo     %E_SUB% 本文件被 .gitignore 的星.exe 规则忽略, 不会误入库
echo     %E_SUB% 换新版本改本脚本里的版本号即可
goto :bye

:fetch
rem %1 = 额外参数, 传 -x 时走代理
if "!CURL_OK!"=="1" (
    if "%~1"=="-x" (
        "!CURL!" -L --fail --retry 2 --connect-timeout 15 -# -o "!OUT!" -x "http://!PROXY_HOST!:!PROXY_PORT!" "!PWURL!"
    ) else (
        "!CURL!" -L --fail --retry 2 --connect-timeout 15 -# -o "!OUT!" "!PWURL!"
    )
    exit /b !errorlevel!
)
if not "!PS_OK!"=="1" exit /b 1
if "%~1"=="-x" (
    powershell -NoProfile -ExecutionPolicy Bypass -Command "try { Invoke-WebRequest -UseBasicParsing -TimeoutSec 600 -Proxy $env:PW_PROXY -Uri $env:PWURL -OutFile $env:OUT; exit 0 } catch { exit 1 }" >nul 2>&1
) else (
    powershell -NoProfile -ExecutionPolicy Bypass -Command "try { Invoke-WebRequest -UseBasicParsing -TimeoutSec 600 -Uri $env:PWURL -OutFile $env:OUT; exit 0 } catch { exit 1 }" >nul 2>&1
)
exit /b !errorlevel!

:checksize
set "_sz=0"
for %%A in ("!OUT!") do set "_sz=%%~zA"
if !_sz! geq 5000000 (
    set "OK=1"
) else (
    %E_WARN% 文件只有 !_sz! 字节, 不像正常的 PW-GUI, 丢掉重下
    del /q "!OUT!" >nul 2>&1
)
goto :eof

:proxy_ready
if "!CURL_OK!"=="1" (
    "!CURL!" -fsS -o NUL --connect-timeout 4 --max-time 8 -x "http://!PROXY_HOST!:!PROXY_PORT!" "https://www.gstatic.com/generate_204" >nul 2>&1
    exit /b !errorlevel!
)
netstat -ano -p tcp 2>nul | findstr /i "LISTENING" | findstr ":!PROXY_PORT! " >nul 2>&1
exit /b !errorlevel!

:bye
echo.
echo %C_DIM%  窗口可以关闭了%C_RST%
endlocal
exit /b 0
