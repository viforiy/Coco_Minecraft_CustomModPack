@echo off
chcp 936 >nul 2>&1

rem BAT 中文乱码的核心原因是 文件保存编码格式 ≠ CMD当前代码页格式(cmd设置里可以查看)
rem chcp 936是切换cmd为GBK(ANSI)编码, chcp 65001是切换cmd为UTF-8编码
rem <command> /?    可以查看命令参数使用方法


rem 1111
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
rem    4.5) 裁剪, 按 [客户端]模组裁剪清单.txt(在脚本目录)把客户端模组从元数据里删减掉
rem    5) packwiz serve, 本地包服务提供 pack.toml / index.toml
rem    6) packwiz-installer-bootstrap, 按元数据同步 mods 目录
rem    6.5) 脚本归位, 把 packwiz 装到实例根目录的 ps1/bat 挪进 Coco's Script
rem    7) 汇总 mods 变动
rem    8) 生成 PCL 启动前执行命令
rem
rem  位置: 本脚本放在 <整合包目录>\Coco's Script\ 里, 实例目录自动取上一级;
rem        脚本直接放整合包根目录(老布局)也能跑, 靠 INSTANCE_DIR 判断
rem  用法: PCL - 版本设置 - 设置 - 高级选项 - 启动前执行指令
rem        直接粘贴本脚本生成的 PCL启动前命令.txt 内容即可(每次跑完自动刷新)
rem ============================================================================

rem cmd脚本界面信息显示配置
rem 开启 VT 转义, 用于彩色输出, 老系统上无效但无副作用
for /f "delims=" %%A in ('echo prompt $E^| cmd') do set "ESC=%%A"
setlocal enabledelayedexpansion


if "1"== "1" echo true
rem 颜色配置
set "C_RST=%ESC%[0m"
set "C_RED=%ESC%[91m"
set "C_GRN=%ESC%[92m"
set "C_YEL=%ESC%[93m"
set "C_BLU=%ESC%[96m"
set "C_DIM=%ESC%[90m"
set "C_STEP=%ESC%[30;106m"
set "C_BIG=%ESC%[97;45m"

rem 提示信息级别配置
set "E_INFO=%C_BLU%[信息]%C_RST%"
set "E_OK=%C_GRN%[完成]%C_RST%"
set "E_WARN=%C_YEL%[警告]%C_RST%"
set "E_ERR=%C_RED%[错误]%C_RST%"
set "E_SUB=%C_DIM%  -%C_RST%"

rem ===========================================================================
rem  全局变量配置区
rem ===========================================================================

set "PS_OK=1"

rem 脚本名称
set "SCRIPT_NAME=%~nx0"

rem 用户配置,脚本存放父目录名称
set "SCRIPT_DIR_NAME=Coco's_Script"

rem 用户配置,脚本缓存根目录, 元数据仓 / packwiz.exe / 便携 Java / 日志 都在这里
set "CACHE_ROOT=%LOCALAPPDATA%\CocoScript"

rem 缓存目录
set "META_DIR=!CACHE_ROOT!\meta"
set "LOG_DIR=!CACHE_ROOT!\logs"
set "TMP_DIR=!CACHE_ROOT!\tmp"
set "BAK_DIR=!CACHE_ROOT!\backup"
set "JRE_DIR=!CACHE_ROOT!\jre"
set "TOOLS_DIR=!CACHE_ROOT!\tools"
set "PACKWIZ_EXE=!META_DIR!\packwiz.exe"

rem 用户配置,网络工具
set "CURL=%SystemRoot%\System32\curl.exe"

rem 用户配置,git工具可以自己指定,为空则自动寻找
set "GIT_EXE="

rem 用户配置,Java路径
set "TARGET_JAVA=%~1"
set "JAVA_BIN_PATH="
set "JAVA_EXE="
set "TARGET_JAVA_VERSION=21"

rem 用户配置, java下载源
set "JAVA_SRC=http://mirrors.huaweicloud.com/openjdk/21/openjdk-21_windows-x64_bin.zip"
set "JAVA_SRC2=https://api.adoptium.net/v3/binary/latest/21/ga/windows/x64/jre/hotspot/normal/eclipse?project=jdk"
set "JAVA_ZIP=%TMP_DIR%\java21.zip"

rem 用户配置,系统代理, 默认 127.0.0.1:7890
set "PROXY_HOST=127.0.0.1"
set "PROXY_PORT=7890"
set "PROXY_URL=http://%PROXY_HOST%:%PROXY_PORT%"

rem 用户配置,模组元数据仓, 自己推送维护的 packwiz 仓库
set "PACK_GIT_URL=https://github.com/viforiy/Coco_Minecraft_CustomModPack.git"
set "PACK_GIT_BRANCH=main"

rem 用户配置,是否开启裁剪, 0:关闭 1:打开
set "PRE_TRIM=1"

rem 用户配置
rem packwiz server模式下访问远端pack.toml的URL
rem 远端 pack.toml, 例如挂到 GitHub Pages 后填 https://xxx/pack.toml
rem 留空 = 用本地元数据仓 + 本地服务; 填写后直接走远端, 不再拉仓
set "REMOTE_PACK_URL="

rem 用户配置
rem 包来源模式:
rem   file  = 默认, 不起服务, 安装器直接读本地 pack.toml
rem           不占端口, 也不会触发 Windows 防火墙询问
rem   server = 拉起 packwiz server 本地服务, 安装器走 http://127.0.0.1:端口/pack.toml
rem           只有想让局域网其它机器来拉包时才需要, 会监听端口并可能弹防火墙询问
set "PACK_SOURCE=file"

rem 用户配置
rem 元数据同步方式: auto = 优先 git, 没装 git 或同步失败时改用 zip 压缩包
rem                 git  = 只用 git
rem                 zip  = 只用 zip, 适合机器上没有 git 的情况
set "META_SOURCE=auto"

rem 用户配置
rem 本地包服务端口
set "PACK_PORT_BASE=8080"

rem packwiz-installer-bootstrap.jar可以在任意位置,但是packwiz-installer.jar必须在版本文件夹下,拉取mod文件时以packwiz-installer.jar所在目录为根路径
set "BOOTSTRAP_JAR="
set "INSTALLER_JAR="


rem=========================================================
rem	+主流程开始
rem=========================================================

echo.
echo ========================================================
echo 步骤 1/8 - 脚本路径检测,创建缓存目录
echo Target: 
echo 	检测脚本是否放置在版本文件夹的Coco's Script下,创建缓存目录
rem  To do: 
rem  	1. 获取当前脚本路径
rem  	2. 默认脚本上一级路径是整合包版本文件夹路径
rem  	3. 判断options.txt是否存在以确定是否合法版本文件夹,
rem  	4. 核对脚本所在目录是否为Coco's Script
rem  varlist(-代表读取, +代表修改):
rem 	+MC_VERSION_DIR_PATH: MC版本文件夹路径
rem 	-SCRIPT_DIR_NAME: 预期脚本父目录名称
rem 	+CURRENT_SCRIPT_DIR_PATH: 当前脚本所在路径
rem 	+parent_dir_name: 当前脚本父目录名称
echo ========================================================
rem  获取当前脚本路径, 去除""号
set "CURRENT_SCRIPT_DIR_PATH=%~dp0"

rem  去除末尾反斜杠
if "%CURRENT_SCRIPT_DIR_PATH:~-1%"=="\" set "CURRENT_SCRIPT_DIR_PATH=%CURRENT_SCRIPT_DIR_PATH:~0,-1%"
echo %C_DIM%当前脚本路径: %CURRENT_SCRIPT_DIR_PATH%%C_RST%

rem  默认脚本上一级路径是整合包版本文件夹路径并寻找options.txt查证
for %%i in ("%CURRENT_SCRIPT_DIR_PATH%\..") do set "parent_dir_path=%%~fi"
for %%i in ("%CURRENT_SCRIPT_DIR_PATH%") do set "parent_dir_name=%%~ni"
if not "%parent_dir_name%"=="%SCRIPT_DIR_NAME%" (
	echo %E_ERR% %C_RED% 脚本存放路径不正确, 请先把脚本放到MC版本文件夹的Coco's_Script文件夹下,没有则新建一个 %C_RST%
	echo 示例: %C_DIM% D:\Program Files\Minecraft\[Client][PCL2]MultiIntergationPack\.minecraft\versions\Coco's 整合包\Coco's Script %C_RST%
	echo %E_INFO% %C_GRN% 文件名已复制到剪切板,可直接ctrl + v粘贴 %C_RST%
	echo Coco's Script | clip
	exit /b 1
	)
if not exist "!parent_dir_path!\options.txt" (
	echo %E_ERR% %C_RED%脚本存放路径不正确, 脚本父目录不是一个有效整合包版本文件夹
	exit /b 1
	)

echo ==========已定位到整合包版本文件夹==========
set "MC_VERSION_DIR_PATH=!parent_dir_path!"
for %%i in ("!MC_VERSION_DIR_PATH!") do set "mc_pack_name=%%~ni"
echo 整合包名称: %mc_pack_name%
echo %C_GRN% 整合包版本文件夹路径: %C_RST% %C_DIM% !MC_VERSION_DIR_PATH! %C_RST%

for %%i in ("!MC_VERSION_DIR_PATH!\..\..\..") do set "pcl_dir_path=%%~fi"
echo PCL目录: %pcl_dir_path%

rem 为脚本创建临时缓存目录
call :make_dirs
if errorlevel 1 (
	echo %E_ERR% 为脚本创建临时缓存目录失败: %CACHE_ROOT%
)
echo %E_OK% 为脚本创建临时缓存目录成功:
echo %C_DIM% %CACHE_ROOT% %C_RST%


echo.
echo ========================================================
echo 步骤 2/8 - 定位JAVA
echo Target: 
echo 	定位本机可用的JAVA,用于后续启动Packwiz程序
rem  To do:
rem 	1. 判断执行本脚本时是否已经传入指定java路径, 默认第一个参数为java路径
rem 	2. 已指定则直接赋值JAVA_EXE使用
rem     3. 未指定将自动寻找本机可用java
rem  varlist(-代表读取, +代表修改)::
rem 	-TARGET_JAVA: 用户指定的java.exe或目录路径
rem 	+JAVA_EXE: 本脚本将使用的java.exe
rem 	+JAVA_BIN_PATH: 本脚本将使用的java目录路径
echo ========================================================
set "JAVA_EXE="
set "JAVA_BIN_PATH="
rem 使用指定的java路径, 可以指定bin或直接指定bin
if not defined JAVA_EXE if not "%TARGET_JAVA%"=="" if exist "%TARGET_JAVA%\java.exe" (
	set "JAVA_BIN_PATH=%TARGET_JAVA%"
	set "JAVA_EXE=%TARGET_JAVA%\java.exe"
	echo 使用指定的java路径: !JAVA_BIN_PATH!
	echo 使用指定的java: !JAVA_EXE!
)
if not defined JAVA_EXE if defined TARGET_JAVA if exist "%TARGET_JAVA%" (	
	for %%i in ("%TARGET_JAVA%") do set "JAVA_BIN_PATH=%%~dpi"
	set "JAVA_EXE=%TARGET_JAVA%"
	echo 使用指定的java路径: !JAVA_BIN_PATH!
	echo 使用指定的java: !JAVA_EXE!
)

echo 未显式指定java路径, 将自动寻找本机java
if not defined JAVA_EXE call :find_java
if not defined JAVA_EXE (
	echo 未在本机找到合适java,将自动下载java
	rem 下载java
	call :download_java
	if not errorlevel 1 (
		if not defined JAVA_EXE (
			echo 下载Java成功
		)
	) else (
		rem 下载java失败, 脚本运行失败
		echo 下载java失败,无可使用java,请显式指定本脚本所需%TARGET_JAVA_VERSION%版本的java或检查代理或网络是否正常
		exit /b 1
	)
)
echo %E_OK% 定位到合适Java: !JAVA_EXE! 进入下一步



echo.
echo ========================================================
echo 步骤 3/8 - 准备模组元数据
echo Target: 
echo 	准备模组元数据
rem  To do:
rem 	
rem 	
rem    	
rem  varlist(-代表读取, +代表修改)::
rem		
echo ========================================================
if defined REMOTE_PACK_URL (
    echo %E_INFO% 已配置远端 pack.toml, 跳过本地元数据仓
    set "PACK_SOURCE=remote"
    set "PACK_URL=%REMOTE_PACK_URL%"
	set "HAVE_META=1"
	echo %E_OK% 配置远端元数据
) else (
	call :git_sync
	if not errorlevel 1 (
		set "HAVE_META=1"
	    echo %E_OK% 元数据就绪, pack.toml 位于 %C_DIM% !META_DIR!\!REPO_NAME!-main %C_RST%
	) else (
	    echo %E_ERR% 准备模组元数据失败
	    exit /b 1
	)
)




echo.
echo ========================================================
echo 步骤 4/8 - 准备packwiz.exe和附属安装器
echo Target: 
echo 	准备packwiz.exe, 用于后续读取元数据下载整合包模组
rem  To do:
rem 	1. 检测环境变量
rem 	2. 检测缓存目录
rem     3. 联网下载
rem  varlist(-代表读取, +代表修改)::
rem		
echo ========================================================
rem packwiz.exe准备
set "PACKWIZ_EXE="
if not defined PACKWIZ_EXE call :find_packwiz_on_path
if not defined PACKWIZ_EXE call :download_packwiz
if not defined PACKWIZ_EXE (
    echo %E_WARN% packwiz.exe 不可用, 跳过本地服务, 直接把本地 pack.toml 交给安装器
    if /i not "!PACK_SOURCE!"=="remote" set "PACK_SOURCE=file"
) else (
	echo 将使用 %C_GRN% packwiz: %C_RST% %C_DIM% !PACKWIZ_EXE!%C_RST%
)

rem packwiz-installer-bootstrap.jar准备
if not defined BOOTSTRAP_JAR call :find_bootstrap_jar_on_path
if not defined BOOTSTRAP_JAR call :download_bootstrap_jar
if not defined BOOTSTRAP_JAR (
	echo %E_ERR% packwiz-installer-bootstrap.jar下载失败,请尝试手动下载并放到MC版本文件夹中
	echo packwiz-installer-bootstrap.jar 下载链接: https://github.com/packwiz/packwiz-installer-bootstrap/releases/download/v0.0.3/packwiz-installer-bootstrap.jar
	echo %C_GRN% 链接已自动复制到剪切板, 可直接ctrl + v 或 win + v粘贴使用 %C_RST%
	echo https://github.com/packwiz/packwiz-installer-bootstrap/releases/download/v0.0.3/packwiz-installer-bootstrap.jar | clip
	exit /b 0
)

rem packwiz-installer.jar准备
if not defined INSTALLER_JAR call :find_installer_jar_on_path
if not defined INSTALLER_JAR call :download_installer_jar
if not defined INSTALLER_JAR (
	echo %E_ERR% packwiz-installer.jar下载失败,请尝试手动下载并放到MC版本文件夹中
	echo packwiz-installer.jar 下载链接: https://github.com/packwiz/packwiz-installer/releases/latest/download/packwiz-installer.jar
	echo %C_GRN% 链接已自动复制到剪切板, 可直接ctrl + v 或 win + v粘贴使用 %C_RST%
	echo https://github.com/packwiz/packwiz-installer/releases/latest/download/packwiz-installer.jar | clip
	exit /b 0
)





echo.
echo ========================================================
echo 步骤 5/8 - 模组元数据裁剪
echo Target: 	
rem  To do:
rem 	
rem  varlist(-代表读取, +代表修改):
rem		
echo ========================================================
if /i "!PACK_SOURCE!"=="remote" (
    echo %E_INFO% 远端模式, 无需刷新本地索引
) else if "!HAVE_META!"=="0" (
    echo%E_WARN% 没有本地元数据, 跳过刷新
) else if "!HAVE_PACKWIZ!"=="0" (
    echo %E_WARN% 没有 packwiz, 直接用仓内 index.toml, 若哈希过期安装器会报 hash 无效
) else (
	rem 先裁剪在刷新index
	call :trim_client
	if errorlevel 1 (
		echo %E_ERR% 模组元数据裁剪失败
		exit /b 1
	)

    call :refresh_index
    if errorlevel 1 (
        echo %E_ERR% 模组元数据裁剪后刷新index失败
		exit /b 1
    )
)
echo %E_OK% 模组元数据裁剪成功


echo.
echo ========================================================
echo 步骤 6/8 - 启动MOD包服务
echo Target: 	
rem  To do:
rem 	
rem  varlist(-代表读取, +代表修改):
rem		
echo ========================================================

if "!HAVE_META!"=="0" (
    echo %E_ERR% 没有可用的本地元数据, 无法提供包服务
    exit /b 1
)


set "HAS_SERVER=0"
rem 使用packwiz启动包服务,失败则走file模式不启动任何服务
if defined PACKWIZ_EXE (
	echo 使用packwiz启动包服务,失败则走file模式不启动任何服务
	call :start_server
	if not errorlevel 1 (
		set "SERVER_STARTED=1"
		set "PACK_SOURCE=server"
		echo %E_OK% packwiz server启动成功
	)
)


rem 未启动服务
if "!SERVER_STARTED!"=="0" (
	set "PACK_SOURCE=file"
	echo %E_INFO% packwiz当前改为file模式
)








echo.
echo ========================================================
echo 步骤 7/8 - 执行MOD自动安装
echo Target: 	
rem  To do:
rem 	
rem  varlist(-代表读取, +代表修改):
rem		
echo ========================================================

set "JOPT=-Djava.net.useSystemProxies=true"
@REM  if /i "%~1"=="sysproxy" set "JOPT=-Djava.net.useSystemProxies=true"
@REM  if /i "%~1"=="explicit" set "JOPT=-Dhttp.proxyHost=!PROXY_HOST! -Dhttp.proxyPort=!PROXY_PORT! -Dhttps.proxyHost=!PROXY_HOST! -Dhttps.proxyPort=!PROXY_PORT!"

set "BOOTSTRAP_JAR=!MC_VERSION_DIR_PATH!\packwiz-installer-bootstrap.jar"
set "INSTALLER_JAR=%MC_VERSION_DIR_PATH%\packwiz-installer.jar"
rem 禁止检查更新执行器,自定义指定执行器位置
set "BOOTSTRAP_OPTS=--bootstrap-no-update --bootstrap-main-jar "!INSTALLER_JAR!""
set "PACK_URL=http://localhost:!PACK_PORT_BASE!/pack.toml"

echo 网络模式: "%~1"
echo 执行拉包命令: %C_DIM% "!JAVA_EXE!" !JOPT! -jar "!BOOTSTRAP_JAR!" -g -s client  --pack-folder "!MC_VERSION_DIR_PATH!" "!PACK_URL!" %C_RST%
rem 执行拉包命令
"!JAVA_EXE!" !JOPT! -jar "!BOOTSTRAP_JAR!" !BOOTSTRAP_OPTS! -g -s client --pack-folder "!MC_VERSION_DIR_PATH!" "!PACK_URL!"


echo.
echo ========================================================
echo 步骤 8/8 - 生成PCL启动前命令
echo Target: 	
rem  To do:
rem		1. 关闭包服务
rem		2. 汇总模组差异
rem		3. 生成PCL启动前命令
rem 	
rem  varlist(-代表读取, +代表修改):
rem		
echo ========================================================

call :stop_serve
call :write_pcl_cmd

exit /b 0

rem=========================================================
rem	+主流程结束
rem=========================================================



rem=========================================================
rem		+调用方法定义区
rem=========================================================


rem=========================================================
rem			-自动搜寻可用的java
rem========================================================= 
rem 涉及的外部变量(-代表读取, +代表修改):
rem 	-CACHE_ROOT: 下载本脚本所需文件的缓存目录
rem 	+JAVA_EXE: 本脚本将使用的java.exe
:find_java
rem 从本脚本缓存下来的便携Java目录找
echo 开始在缓存目录寻找可用Java
if exist "%CACHE_ROOT%" (
	for /r "%CACHE_ROOT%" %%a in (java.exe) do (
		if not defined JAVA_EXE if exist "%%~a" (
			for %%b in ("%%~dpa.") do (
				if /i "%%~nxb"=="bin" call :try_java "%%~fa"
				if defined JAVA_EXE exit /b 0
			)
		)
	)
)

rem 从环境变量PATH找
if not defined JAVA_EXE (
	echo %E_INFO% 未找到本脚本已缓存的java, 将开始从环境变量寻找
	for /f "delims=" %%J in ('where java 2^>nul') do if not defined JAVA_EXE call :try_java "%%J"
)
rem JAVA_HOME
echo %JAVA_HOME%
if not defined JAVA_EXE (
	echo %E_INFO% 环境变量未找到java, 将检查JAVA_HOME
	if defined JAVA_HOME if exist "%JAVA_HOME%\bin\java.exe" call :try_java "%JAVA_HOME%\bin\java.exe"
)
rem 从注册表找
if not defined JAVA_EXE (
	echo %E_INFO% 未从环境变量里找到合适java, 将开始从注册表寻找
	for %%K in (
		"HKLM\SOFTWARE\JavaSoft\JDK"
    	"HKLM\SOFTWARE\JavaSoft\Java Development Kit"
    	"HKLM\SOFTWARE\JavaSoft\Java Runtime Environment"
    	"HKLM\SOFTWARE\Wow6432Node\JavaSoft\JDK"
    	"HKLM\SOFTWARE\Wow6432Node\JavaSoft\Java Development Kit"
    	"HKLM\SOFTWARE\Wow6432Node\JavaSoft\Java Runtime Environment"
	) do (
        set "cur_ver="
        set "reg_home="
        for /f "tokens=2*" %%A in ('reg query %%K /v CurrentVersion 2^>nul') do set "cur_ver=%%B"
        if defined cur_ver (
            for /f "tokens=2*" %%A in ('reg query "%%~K\!cur_ver!" /v JavaHome 2^>nul') do set "reg_home=%%B"
            if defined reg_home call :try_java "!reg_home!\bin\java.exe"
        )
	)
)

rem 从常见安装目录找
if not defined JAVA_EXE (
	echo %E_INFO% 未在注册表里找到合适的java, 将开始从常见安装目录找
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
	call :scan_dir "D:\Program Files\jdk21 - (副本)"
	call :scan_dir "D:\Program Files\jdk21"
)
if not defined JAVA_EXE (
	rem 未找到合适java
	echo %E_INFO% 未在常见安装目录未找到合适java
	exit /b 1
) else (
	rem 已找到合适java
	exit /b 0
)



rem=========================================================
rem			-尝试运行Java,版本合适将该指定为本脚本所需Java
rem--------------------------------------------------------- 
rem 涉及的外部变量(-代表读取, +代表修改):
rem 	-TARGET_JAVA_VERSION 			本脚本所需的JAVA版本
rem 	-short_version(:java_major)		java版本号,例: 8,9,17,21
rem 	+JAVA_EXE						本脚本将使用的java.exe
rem 自有变量:
rem		try_java 						调用方传入的java绝对路径
rem=========================================================
:try_java
set "try_java=%~1"
echo %C_DIM%尝试运行java: %try_java%%C_RST%
rem 通过java -version结果判断是否合适的版本号
if not exist "%try_java%" exit /b 1
call :java_major "%try_java%"
if not defined short_version (
	echo 获取该Java版本号失败, java.exe: !try_java!
	exit /b 1
)
if not !short_version!==%TARGET_JAVA_VERSION% (
	echo %C_DIM%该Java版本不合适, 该Java版本号: !short_version! 脚本所需版本号: %TARGET_JAVA_VERSION%%C_RST%
	exit /b 1
)
set "JAVA_EXE=%try_java%"
echo %E_INFO%确认到可用java: !JAVA_EXE!
exit /b 0


rem=========================================================
rem			-解析java -version输出获取java版本
rem--------------------------------------------------------- 
rem 涉及的外部变量(-代表读取, +代表修改):
rem		
rem 自有变量:
rem 	full_version		java完整版本号,例: 21.0.11
rem 	short_version		java版本号,例: 8,9,17,21
rem		java_ver_tmp		java -version命令临时输出文件
rem=========================================================
:java_major
rem 解析 java -version 首行的主版本号

echo %C_DIM%开始解析 java -version 首行的主版本号%C_RST%
set "full_version="
set "short_version="
set "java_ver_tmp=%TEMP%\java_ver_%RANDOM%_%RANDOM%.txt"
rem 获取完整版本号
for /f "tokens=3" %%v in ('"%~1" -version 2^>^&1') do if not defined full_version set "full_version=%%~v"
if not defined full_version (
	echo 未正常获取该java版本号
	exit /b 1
)
rem 截取短版本号
for /f "tokens=1,2 delims=._-" %%a in ("!full_version!") do if not defined short_version (
    if "%%a"=="1" ( 
		set "short_version=%%b" 
	) else ( 
		set "short_version=%%a" 
	)
)
if not defined short_version (
	echo 未正常获取到该java短版本号
	exit /b 1
)
echo %C_DIM%获取该java版本号成功: java.exe: %~1 版本号: !short_version!%C_RST%
exit /b 0




rem=========================================================
rem			-扫描目录定位可用Java
rem--------------------------------------------------------- 
rem 涉及的外部变量(-代表读取, +代表修改):
rem		-+JAVA_EXE
rem 自有变量:
rem		search_root		待搜索目录
rem=========================================================
:scan_dir
if defined JAVA_EXE exit /b 1
if not exist "%~1" exit /b 1
echo %C_GRN%开始扫描目录:%C_RST% "%~1"
set "search_root=%~1"
if not exist "%search_root%\" exit /b 1
for /r "%search_root%" %%A in (java.exe) do (
    if not defined JAVA_EXE if exist "%%~A" (
        for %%B in ("%%~dpA.") do (
            if /i "%%~nxB"=="bin" call :try_java "%%~A"
			if defined JAVA_EXE exit /b 0
        )
    )
)
exit /b 0



rem=========================================================
rem			-下载java,决策下载源和本地接收路径
rem--------------------------------------------------------- 
rem 涉及的外部变量(-代表读取, +代表修改):
rem		-+JAVA_EXE
rem		-JAVA_SRC
rem		-JAVA_SRC2
rem		-JRE_DIR
rem		-JAVA_ZIP
rem 自有变量:
rem
rem=========================================================
:download_java
echo %E_INFO% 开始通过国内镜像源下载Java
echo %E_INFO% 下载源 1, 华为云镜像
set "DL_URL=!JAVA_SRC!"
set "DL_OUT=!JAVA_ZIP!"
set "DL_MIN=30000000"
call :dl
if not exist "!JAVA_ZIP!" (
    echo %E_WARN% 华为云失败, 改用下载源 2 Adoptium 官方 API
    echo %E_SUB% !JAVA_SRC2!
    set "DL_URL=!JAVA_SRC2!"
    set "DL_OUT=!JAVA_ZIP!"
    set "DL_MIN=30000000"
    call :dl
)
if not exist "!JAVA_ZIP!" (
    echo %E_ERR% 便携 Java 下载失败
    exit /b 1
)

echo %E_INFO% 解压便携 Java
if "!PS_OK!"=="1" (
    powershell -NoProfile -ExecutionPolicy Bypass -Command "try { Expand-Archive -LiteralPath $env:JAVA_ZIP -DestinationPath $env:JRE_DIR -Force -ErrorAction Stop; exit 0 } catch { exit 1 }" >nul 2>&1
) else (
    tar -xf "!JAVA_ZIP!" -C "%JRE_DIR%" >nul 2>&1
)
rem 解压完成后删除多余zip
del /q "!JAVA_ZIP!" >nul 2>&1

if exist "%JRE_DIR%\bin\java.exe" call :try_java "%JRE_DIR%\bin\java.exe"
for /d %%V in ("%JRE_DIR%\*") do if not defined JAVA_EXE if exist "%%~V\bin\java.exe" call :try_java "%%~V\bin\java.exe"
if defined JAVA_EXE (
    echo %E_OK% 便携 Java 就绪
    echo %E_SUB% !JAVA_EXE!
    rem jmods 与 include 只有开发期需要, 删掉省 100MB 以上
    for /d %%V in ("%JRE_DIR%\*") do (
        if exist "%%~V\jmods" rd /s /q "%%~V\jmods" >nul 2>&1
        if exist "%%~V\include" rd /s /q "%%~V\include" >nul 2>&1
    )
	exit /b 0
) else (
    echo %E_ERR% 解压后仍未找到 java.exe
	exit /b 1
)


rem=========================================================
rem			-下载文件
rem--------------------------------------------------------- 
rem 涉及的外部变量(-代表读取, +代表修改):
rem		-+JAVA_EXE
rem		-JAVA_SRC
rem		-JAVA_SRC2
rem		-JRE_DIR
rem		-JAVA_ZIP
rem		-DL_URL
rem		-DL_OUT
rem 自有变量:
rem
rem=========================================================
:dl
rem 入参走变量, 不经 call 传参, 避免 URL 里的 % 被二次当成参数引用
rem 输入 DL_URL / DL_OUT / DL_MIN
if not defined DL_MIN set "DL_MIN=1024"
echo 下载 !DL_URL! 到文件 !DL_OUT!

call :proxy_ready
if not "!errorlevel!"=="0" exit /b 1
echo 系统代理正常, 正在使用系统代理下载, 失败则改用直连
set "NET_PROXY=1"
call :fetch
call :check_dl "!DL_OUT!" !DL_MIN!
if "!errorlevel!"=="0" exit /b 0

echo 系统代理下载失败, 改用直连
set "NET_PROXY="
call :fetch
call :check_dl "!DL_OUT!" !DL_MIN!
if "!errorlevel!"=="0" exit /b 0

echo %E_SUB% 文件下载未成功
echo %E_WARN% 下载没完成, 半成品清空
echo %E_SUB% 文件 !DL_OUT!
exit /b 1


:proxy_ready
rem 探测 Clash 这类系统代理是否在监听且能出网

rem 1. 先检查本地端口是否在监听（最快，如果没监听直接失败）
netstat -ano -p tcp 2>nul | findstr /i "LISTENING" | findstr ":!PROXY_PORT! " >nul 2>&1
if not "!errorlevel!"=="0" exit /b 1

rem 2. 端口在监听，再测试能否出网
"!CURL!" -fsS -o NUL --connect-timeout 4 --max-time 8 -x"!PROXY_URL!" "https://www.gstatic.com/generate_204" >nul 2>&1
if "!errorlevel!"=="0" exit /b 0

"!CURL!" -fsS -o NUL --connect-timeout 4 --max-time 8 -x"!PROXY_URL!" "http://cp.cloudflare.com/" >nul 2>&1
exit /b !errorlevel!


rem=========================================================
rem			-使用CURL或POWERSHELL下载文件
rem--------------------------------------------------------- 
rem 涉及的外部变量(-代表读取, +代表修改):
rem		-+JAVA_EXE
rem		-JAVA_SRC
rem		-JAVA_SRC2
rem		-JRE_DIR
rem		-JAVA_ZIP
rem		-DL_URL
rem		-DL_OUT
rem 自有变量:
rem
rem=========================================================
:fetch
rem 用 DL_URL / DL_OUT 与 NET_PROXY 标记, 已有半成品则断点续传
set "DL_ARG=-L --fail --retry 2 --retry-delay 2 --connect-timeout 15 -#"
if defined NET_PROXY set "DL_ARG=!DL_ARG! -x !PROXY_URL!"

if exist "!DL_OUT!" (
    set "_presz=0"
    for %%A in ("!DL_OUT!") do set "_presz=%%~zA"
    if !_presz! gtr 4096 (
		rem 下载文件时停止脚本可能有为下载完的文件,先断点续传检查
        echo %E_SUB% 发现已下载文件, 先尝试断点续传确认是否已经完整
		echo %C_YEL%执行的CURL命令: %C_RST%
		echo %C_DIM% "%CURL%" !DL_ARG! -C - -o "!DL_OUT!" "!DL_URL!" %C_RST%
        "%CURL%" !DL_ARG! -C - -o "!DL_OUT!" "!DL_URL!"
		echo ++++++++++++++++++++++!errorlevel!
        set "_cerr=!errorlevel!"
        
        if "!_cerr!"=="0" exit /b 0
        
        rem Curl 错误码 33 表示服务器返回 416 (Range 越界)。
        rem 这通常意味着本地文件实际上已经完整了，直接视为成功。
        if "!_cerr!"=="33" (
            echo %E_SUB% 文件似乎已完整下载, 无需续传
            exit /b 0
        )
        
        echo %E_SUB% 续传失败错误码 !_cerr!, 服务器可能不支持断点,改为整份重下
        del /q "!DL_OUT!" >nul 2>&1
    )
)
echo 执行完整下载
echo %C_YEL%执行的CURL命令%C_RST%
echo %C_DIM% "%CURL%" !DL_ARG! -o "!DL_OUT!" "!DL_URL!" %C_RST%
"%CURL%" !DL_ARG! -o "!DL_OUT!" "!DL_URL!"

set "_cerr=!errorlevel!"

rem 如果最终整份下载依然失败，清理掉产生的残破文件，防止下次误判
if not "!_cerr!"=="0" (
    echo %E_SUB% Curl 下载失败错误码 !_cerr!, 清理半成品文件
    del /q "!DL_OUT!" >nul 2>&1
)
exit /b !_cerr!

rem 降级到 PowerShell 时，给出提示，且不再屏蔽全部输出，以便看到下载进度条
if not "!PS_OK!"=="1" exit /b 1
echo %E_SUB% 正在使用 PowerShell 备用引擎下载 不支持断点续传, 请稍候...
if defined NET_PROXY (
    powershell -NoProfile -ExecutionPolicy Bypass -Command "try { Invoke-WebRequest -UseBasicParsing -TimeoutSec 600 -Proxy $env:PROXY_URL -Uri $env:DL_URL -OutFile $env:DL_OUT; exit 0 } catch { exit 1 }"
) else (
    powershell -NoProfile -ExecutionPolicy Bypass -Command "try { Invoke-WebRequest -UseBasicParsing -TimeoutSec 600 -Uri $env:DL_URL -OutFile $env:DL_OUT; exit 0 } catch { exit 1 }"
)
set "_perr=!errorlevel!"

rem PowerShell 下载失败时，同样清理残件
if not "!_perr!"=="0" (
    echo %E_SUB% PowerShell 下载失败, 清理半成品文件
    del /q "!DL_OUT!" >nul 2>&1
)
exit /b !_perr!


rem=========================================================
rem			-检查文件大小
rem--------------------------------------------------------- 
rem 涉及的外部变量(-代表读取, +代表修改):
rem
rem 自有变量:
rem
rem=========================================================
:check_dl
rem 返回 0 表示文件已存在且达到最小体积, 半成品一律保留以便续传
if not exist "%~1" exit /b 1
set "_dl_sz="
for %%A in ("%~1") do set "_dl_sz=%%~zA"
if not defined _dl_sz exit /b 1
if !_dl_sz! lss %~2 exit /b 1
exit /b 0


rem=========================================================
rem			-创建脚本缓存目录
rem--------------------------------------------------------- 
rem 涉及的外部变量(-代表读取, +代表修改):
rem 
rem 自有变量:
rem
rem=========================================================
:make_dirs
for %%D in ("%CACHE_ROOT%" "%META_DIR%" "%LOG_DIR%" "%TMP_DIR%" "%BAK_DIR%" "%JRE_DIR%" "%TOOLS_DIR%") do (
    if not exist "%%~D" mkdir "%%~D" >nul 2>&1
)
goto :eof


:find_packwiz_on_path
for /f "delims=" %%P in ('where packwiz 2^>nul') do (
	if not defined PACKWIZ_EXE (
		set "PACKWIZ_EXE=%%P"
		echo 找到环境变量里的packwiz: "%%~P"
	)
)
if not defined PACKWIZ_EXE (
	if exist "!META_DIR!\packwiz.exe" (
	    set "_pwz_size=0"
	    for %%A in ("!PACKWIZ_EXE!") do set "_pwz_size=%%~zA"
	    if !_pwz_size! geq 5000000 (
	        set "PACKWIZ_EXE=!META_DIR!\packwiz.exe"
	        echo %E_OK% 缓存命中, 直接复用
	        echo %E_SUB% !PACKWIZ_EXE!
	    ) else (
	        echo %E_WARN% 现有文件体积异常 !_pwz_size! 字节, 需要重新下载
	        del /q "!PACKWIZ_EXE!" >nul 2>&1
	    )
	)
)
goto :eof


:download_packwiz
set "PWZ_ZIP=%TMP_DIR%\packwiz.zip"
set "PWZ_URL=https://nightly.link/packwiz/packwiz/workflows/go/main/Windows%%2064-bit.zip"

echo %E_INFO% 下载 packwiz.exe, nightly 构建
echo %E_SUB% !PWZ_URL!
set "DL_URL=!PWZ_URL!"
set "DL_OUT=!PWZ_ZIP!"
set "DL_MIN=1000000"
call :dl
if not exist "!PWZ_ZIP!" (
    echo %E_WARN% packwiz 下载失败, 本次改用 file 模式
    goto :eof
)
echo %E_INFO% 解压"!PWZ_ZIP!"
if "!PS_OK!"=="1" (
    powershell -NoProfile -ExecutionPolicy Bypass -Command "try { Expand-Archive -LiteralPath $env:PWZ_ZIP -DestinationPath $env:META_DIR -Force -ErrorAction Stop; exit 0 } catch { exit 1 }" >nul 2>&1
) else (
	echo "tar -xf "!PWZ_ZIP!" -C "!META_DIR!" >nul 2>&1"
    tar -xf "!PWZ_ZIP!" -C "!META_DIR!" >nul 2>&1
)
if exist "!META_DIR!\packwiz.exe" (
	set "PACKWIZ_EXE=!META_DIR!\packwiz.exe"
)
rem 解压完成后删除多余zip
del /q "!PWZ_ZIP!" >nul 2>&1
goto :eof

rem C:\Program Files\Zulu
rem C:\Program Files (x86)\Java
rem C:\Users\viforiy\.jdks
rem D:\Program Files\jdk21

rem D:\Program Files\jdk21\bin\java.exe
rem C:\Program Files\Zulu\zulu-17\bin\java.exe
rem C:\Program Files\Zulu\zulu-25\bin\java.exe
rem C:\Program Files (x86)\Java\jdk1.8.0_271\bin\java.exe
rem C:\Program Files (x86)\Java\jre1.8.0_441\bin\java.exe





rem ---------------------------------------------------------------------------
rem  元数据仓同步
rem ---------------------------------------------------------------------------
:git_sync
echo 开始元数据仓同步
set "GIT_RC=0"
rem 解析元数据仓信息
call :parse_repo
if errorlevel 1 (
	echo %E_ERR% 元数据仓远端地址不合规,解析错误
	exit /b 1
)
echo 解析仓库名: %C_DIM% !REPO_NAME! %C_RST%

if /i "!META_SOURCE!"=="zip" (
    call :zip_sync
    goto :eof
)

call :find_git
if not defined GIT_EXE (
	if /i "!META_SOURCE!"=="git" (
		echo %E_ERR% git模式下没有git程序,无法同步元数据
		exit /b 1
	) else (
		echo %E_WARN% 没找到 git.exe auto模式下降级方案为拉取元数据压缩包
		call :zip_sync
    	goto :eof
	)
)


rem git存在,使用git同步元数据
echo %C_GRN%git:%C_RST% %C_DIM%!GIT_EXE!%C_RST%
if exist "!META_DIR!\!REPO_NAME!-main\.git" (
	call :git_pull
	if not errorlevel 1 (
		echo %E_OK% 元数据同步成功
		exit /b 0
	)
) else (
	call :git_clone
	if not errorlevel 1 (
		echo %E_OK% 元数据同步成功
		exit /b 0
	)
)

if /i "!META_SOURCE!"=="auto" (
    call :zip_sync
    goto :eof
)
echo %E_ERR% 元数据同步失败,请检查网络代理
exit /b 1



:git_clone
rem 目录存在但不是 git 仓, 先备份再重建, 避免 clone 失败
if exist "!META_DIR!\!REPO_NAME!-main\pack.toml" (
    echo %E_WARN% 已有元数据但不是 git 仓, 先备份到 !BAK_DIR!\meta
    if exist "!BAK_DIR!\meta\!REPO_NAME!-main" rd /s /q "!BAK_DIR!\meta\!REPO_NAME!-main" >nul 2>&1
    move "!META_DIR!\!REPO_NAME!-main" "!BAK_DIR!\meta" >nul 2>&1
)

if exist "!META_DIR!\!REPO_NAME!-main" rd /s /q "!META_DIR!\!REPO_NAME!-main" >nul 2>&1
mkdir "!META_DIR!\!REPO_NAME!-main"
echo %E_INFO% 首次克隆元数据仓, 浅克隆分支 !PACK_GIT_BRANCH!
echo %E_SUB% !PACK_GIT_URL!
call :proxy_ready
if not errorlevel 1 (
	echo 开始执行git clone命令, 使用系统代理
	echo %C_DIM% "%GIT_EXE%" -c core.autocrlf=false -c "http.proxy=!PROXY_URL!" clone --depth 1 --single-branch --branch "!PACK_GIT_BRANCH!" "!PACK_GIT_URL!" "!META_DIR!\!REPO_NAME!-main" %C_RST%
	rem 执行git clone, 使用系统代理
	"%GIT_EXE%" -c core.autocrlf=false -c "http.proxy=!PROXY_URL!" clone --depth 1 --single-branch --branch "!PACK_GIT_BRANCH!" "!PACK_GIT_URL!" "!META_DIR!\!REPO_NAME!-main" 2>&1
	set "GIT_RC=!errorlevel!"
	if "!GIT_RC!"=="0" (
		echo git clone命令执行成功, 检查clone结果
		call:git_verify
		if "!errorlevel!"=="0" (
			echo 首次克隆元数据仓成功
			exit /b 0
		)
	)
	echo 使用系统代理执行git clone克隆元数据仓失败
)
echo 尝试直连执行git clone
if exist "!META_DIR!\!REPO_NAME!-main" rd /s /q "!META_DIR!" >nul 2>&1
echo 开始执行git clone命令, 直连
echo %C_DIM% "%GIT_EXE%" -c core.autocrlf=false clone --depth 1 --single-branch--branch "!PACK_GIT_BRANCH!" "!PACK_GIT_URL!" "!META_DIR!\!REPO_NAME!-main" %C_RST%
rem 执行git clone命令, 直连
"%GIT_EXE%" -c core.autocrlf=false clone --depth 1 --single-branch --branch "!PACK_GIT_BRANCH!" "!PACK_GIT_URL!" "!META_DIR!\!REPO_NAME!-main" 2>&1
set "GIT_RC=!errorlevel!"
if "!GIT_RC!"=="0" (
	echo 直连, git clone命令执行成功, 检查clone结果
	call:git_verify
	if "!errorlevel!"=="0" (
		echo 直连克隆元数据仓成功
		exit /b 0
	)
)
echo 代理和直连git clone元数据都不成功,使用备份还原元数据
if exist "!META_DIR!\!REPO_NAME!-main" rd /s /q "!META_DIR!\!REPO_NAME!-main" >nul 2>&1
if exist "!BAK_DIR!\meta\!REPO_NAME!" move "!BAK_DIR!\meta\!REPO_NAME!""!META_DIR!\!REPO_NAME!-main\.." >nul 2>&1
exit /b 1

:git_pull
echo %E_INFO% 增量同步, fetch 后 reset 到 origin/!PACK_GIT_BRANCH!
rem 源地址可能被 mod更新源.cfg 改过, 先把 remote 纠正过来再拉
"%GIT_EXE%" -C "!META_DIR!\!REPO_NAME!-main" remote set-url origin "!PACK_GIT_URL!" >nul 2>&1
echo git fetch in !META_DIR!\!REPO_NAME!-main from !PACK_GIT_URL!

call :proxy_ready
if "!errorlevel!"=="0" (
	rem 有代理
    pushd "!META_DIR!\!REPO_NAME!-main"
	echo 使用代理执行git fetch命令
	echo %C_DIM% "%GIT_EXE%" -c "http.proxy=!PROXY_URL!" fetch --depth 1 origin "!PACK_GIT_BRANCH!" %C_RST%
	rem 使用代理执行命令
	"%GIT_EXE%" -c "http.proxy=!PROXY_URL!" fetch --depth 1 origin "!PACK_GIT_BRANCH!" 2>&1
	set "GIT_RC=!errorlevel!"
	popd
	rem 有代理失败,降级直连
	if not "!GIT_RC!"=="0" (
		echo %E_WARN% 使用代理fetch 失败 !GIT_RC!, 改用直连
	    pushd "!META_DIR!\!REPO_NAME!-main"
		echo 直连执行git fetch命令
		echo %C_DIM% "%GIT_EXE%" fetch --depth 1 origin "!PACK_GIT_BRANCH!" %C_RST%
		rem 直连执行命令
	    "%GIT_EXE%" fetch --depth 1 origin "!PACK_GIT_BRANCH!" 2>&1
	    set "GIT_RC=!errorlevel!"
	    popd
	)
) else (
	rem 无代理直连
	echo %E_WARN% 使用代理fetch 失败 !GIT_RC!, 改用直连
	pushd "!META_DIR!\!REPO_NAME!-main"
	echo 直连执行git fetch命令
	echo %C_DIM% "%GIT_EXE%" fetch --depth 1 origin "!PACK_GIT_BRANCH!" %C_RST%
	rem 直连执行命令
	"%GIT_EXE%" fetch --depth 1 origin "!PACK_GIT_BRANCH!" 2>&1
	set "GIT_RC=!errorlevel!"
	popd
)
call :git_verify
if errorlevel 1 (
	echo git pull代理直连都失败
	exit /b 1
)
rem 客户端上的元数据只读, 用 reset 强同步, 顺便清掉 refresh 造成的脏改动
pushd "!META_DIR!\!REPO_NAME!-main"
"%GIT_EXE%" -c core.autocrlf=false reset --hard FETCH_HEAD 2>&1
set "GIT_RC=!errorlevel!"
popd
exit /b 0



rem 查验git执行结果
:git_verify
if not "!GIT_RC!"=="0" (
	rem 同步失败处理
    echo %E_WARN% git 同步失败, 错误码 !GIT_RC!
	exit /b 1
) else (
	rem 同步成功处理
	if not exist "!META_DIR!\!REPO_NAME!-main\pack.toml" (
	    echo %E_ERR% 同步完成但仓库根目录没有 pack.toml, 请检查仓库结构
	    exit /b 1
	)
	set "GIT_HEAD="
	for /f "delims=" %%C in ('"%GIT_EXE%" -C "!META_DIR!\!REPO_NAME!-main" rev-parse --short HEAD 2^>nul') do if not defined GIT_HEAD set "GIT_HEAD=%%C"
	if defined GIT_HEAD (
	    echo %E_INFO% 元数据版本 !GIT_HEAD!
	    echo metadata head=!GIT_HEAD!
	)
	exit /b 0
)



rem ---------------------------------------------------------------------------
rem  zip 模式同步元数据 - 机器上没有 git 时直接下 GitHub 压缩包
rem ---------------------------------------------------------------------------
:zip_sync
if not defined ZIP_URL (
    echo %E_WARN% 元数据仓地址不是 GitHub 仓库, zip 模式不可用
    exit /b 1
)
echo %E_INFO% 用 zip 压缩包拉取元数据, 不需要 git
echo %E_SUB% !ZIP_URL!
rem C:\Users\viforiy\AppData\Local\CocoScript\temp\meta.zip
set "ZIP_FILE=%TMP_DIR%\meta.zip"
rem C:\Users\viforiy\AppData\Local\CocoScript\meta
set "ZIP_OUT=%META_DIR%"
set "DL_URL=!ZIP_URL!"
set "DL_OUT=!ZIP_FILE!"
set "DL_MIN=20000"
call :dl
if not exist "!ZIP_FILE!" (
    echo %E_WARN% GitHub zip 压缩包下载失败, 改用 GitHub 加速镜像源下载
    set "DL_URL=https://ghfast.top/https://github.com/!REPO_OWNER!/!REPO_NAME!/archive/refs/heads/!PACK_GIT_BRANCH!.zip"
    call :dl
)
if not exist "!ZIP_FILE!" (
    echo %E_ERR% 元数据 zip 下载失败
    exit /b 1
)
rem 解压到meta目录前先备份meta目录
if exist "!BAK_DIR!\meta\!REPO_NAME!" rd /s /q "!BAK_DIR!\meta\!REPO_NAME!" >nul 2>&1
if exist "!ZIP_OUT!\!REPO_NAME!" move "!ZIP_OUT!\!REPO_NAME!" "!BAK_DIR!\meta" >nul 2>&1

echo %E_INFO% 解压元数据快照
if exist "!ZIP_OUT!" rd /s /q "!ZIP_OUT!" >nul 2>&1
mkdir "!ZIP_OUT!" >nul 2>&1
tar -xf "!ZIP_FILE!" -C "!ZIP_OUT!" >nul 2>&1
rem 判断是否有文件解压出来
set "_any="
for /f "delims=" %%A in ('dir /b "!ZIP_OUT!" 2^>nul') do if not defined _any set "_any=1"
if not defined _any if "!PS_OK!"=="1" (
    powershell -NoProfile -ExecutionPolicy Bypass -Command "try { Expand-Archive -LiteralPath $env:ZIP_FILE -DestinationPath $env:ZIP_OUT -Force -ErrorAction Stop; exit 0 } catch { exit 1 }" >nul 2>&1
)
rem 删除临时文件zip包
del /q "!ZIP_FILE!" >nul 2>&1

rem 压缩包一般带一层 仓库名-分支 顶层目录, 两种结构都兼容
set "MOD_META_DIR="
if exist "!ZIP_OUT!\pack.toml" set "MOD_META_DIR=!ZIP_OUT!"
if not defined MOD_META_DIR for /d %%D in ("!ZIP_OUT!\*") do if not defined MOD_META_DIR if exist "%%~D\pack.toml" set "MOD_META_DIR=%%~D"
if not defined MOD_META_DIR (
    echo %E_ERR% 压缩包里没有 pack.toml, 请检查仓库结构
	echo 回滚备份模组元数据
	rem 解压到meta目录前先备份meta目录
	if exist "!ZIP_OUT!\!REPO_NAME!-main" rd /s /q "!ZIP_OUT!\!REPO_NAME!-main" >nul 2>&1
	if exist "!BAK_DIR!\meta\!REPO_NAME!-main" move "!BAK_DIR!\meta\!REPO_NAME!-main" "!ZIP_OUT!"  >nul 2>&1
    exit /b 1
)
exit /b 0


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
echo 解析出的git仓zip地址: %C_DIM% !ZIP_URL! %C_RST%
goto :eof



:find_git
for /f "delims=" %%G in ('where git 2^>nul') do if not defined GIT_EXE set "GIT_EXE=%%G"
if not defined GIT_EXE if exist "%ProgramFiles%\Git\cmd\git.exe" set "GIT_EXE=%ProgramFiles%\Git\cmd\git.exe"
if not defined GIT_EXE if exist "%ProgramFiles(x86)%\Git\cmd\git.exe" set "GIT_EXE=%ProgramFiles(x86)%\Git\cmd\git.exe"
if not defined GIT_EXE if exist "%LocalAppData%\Programs\Git\cmd\git.exe" set "GIT_EXE=%LocalAppData%\Programs\Git\cmd\git.exe"
goto :eof




rem 裁剪模组元数据
:trim_client
rem 实际是否裁剪
set "TRIM_APPLY=1"
set "PRE_BAT=!MC_VERSION_DIR_PATH!\!SCRIPT_DIR_NAME!\mod裁剪脚本.bat"
set "PRE_PS1=!MC_VERSION_DIR_PATH!\!SCRIPT_DIR_NAME!\mods-clip.ps1"
if "!PRE_TRIM!"=="0" (
    echo %E_INFO% 配置里关掉了前置裁剪, 跳过
	set "TRIM_APPLY=0"
    exit /b 0
)
if not exist "!PRE_BAT!" (
	echo %E_ERR% 裁剪脚本不存在: !PRE_BAT!
	exit /b 1
)
if not exist "!PRE_PS1!" (
	echo %E_ERR% 裁剪脚本不存在: !PRE_PS1!
	exit /b 1
)
if not defined PACKWIZ_EXE (
	echo %E_WARN% 裁剪功能开启但是没有packwiz.exe,本次裁剪不执行只列出报告
	set "TRIM_APPLY=0"
)

if "!TRIM_APPLY!"=="1" (
    echo 执行命令 %C_DIM% "!PRE_BAT!" -Quiet -InPlace -MetaDir "!META_DIR!" -GameDir "!MC_VERSION_DIR_PATH!" -CacheRoot "!CACHE_ROOT!" -Packwiz "!PACKWIZ_EXE!" %C_RST% 
	rem 执行命令
    call "!PRE_BAT!" -Quiet -InPlace -MetaDir "!META_DIR!" -GameDir "!MC_VERSION_DIR_PATH!" -CacheRoot "!CACHE_ROOT!" -Packwiz "!PACKWIZ_EXE!"
    set "TRIM_RC=!errorlevel!"
) else (
	echo 执行命令 %C_DIM% "!PRE_BAT!" -Quiet -InPlace -Plan -MetaDir "!META_DIR!" -GameDir "!MC_VERSION_DIR_PATH!" -CacheRoot "!CACHE_ROOT!" -Packwiz "!PACKWIZ_EXE!" %C_RST% 
	rem 执行命令
    call "!PRE_BAT!" -Quiet -InPlace -Plan -MetaDir "!META_DIR!" -GameDir "!MC_VERSION_DIR_PATH!" -CacheRoot "!CACHE_ROOT!" -Packwiz "!PACKWIZ_EXE!"
    set "TRIM_RC=0"
)
if "!TRIM_RC!"=="0" (
	if "!TRIM_APPLY!"=="1" (
		echo 执行裁剪成功
		exit /b 0
	)
	echo 为裁剪只生成报告成功
	exit /b 0
)
echo 执行裁剪命令失败
exit /b 1


rem 刷新索引
:refresh_index
set "REF_RC=0"
if not exist "!META_DIR!\!REPO_NAME!-main\pack.toml" (
	echo 元数据不合规无法刷新索引
	exit /b 1
)
if not exist "!META_DIR!\!REPO_NAME!-main\index.toml" (
    echo %E_WARN% 缺少 index.toml, 将建空索引后再 refresh
    type nul > "!META_DIR!\!REPO_NAME!-main\index.toml"
)
pushd "!META_DIR!\!REPO_NAME!-main"
"!PACKWIZ_EXE!" refresh
set "REF_RC=!errorlevel!"
popd
if "!REF_RC!"=="0" (
    echo %E_OK% index.toml 已刷新
	exit /b 0
) else (
    echo %E_WARN% 刷新索引失败
	exit /b 1
)


:start_server
set "SERVE_STARTED=0"
set "SERVER_PID="



@REM  set "SERVER_LOG=%LOG_DIR%\packwiz-serve.log"
@REM  if not exist "!SERVER_LOG!" (
@REM  	type nul > "!SERVER_LOG!"
@REM  )
@REM  set "SPAWN_EXE=!PACKWIZ_EXE!"
set "SPAWN_ARGS=serve -p !PACK_PORT_BASE!"
set "SPAWN_DIR=!META_DIR!\!REPO_NAME!-main"
@REM  set "SPAWN_LOG=!SERVER_LOG!"
@REM  set "SPAWN_PID_FILE=!SERVER_PID_FILE!"

@REM  if "!PS_OK!"=="1" (
@REM  	echo powershell启动packwiz服务执行命令: %C_DIM% powershell -NoProfile -ExecutionPolicy Bypass -Command "$q=[char]34; $line=$q+$q+$env:SPAWN_EXE+$q+' '+$env:SPAWN_ARGS+' 1>'+$q+$env:SPAWN_LOG+$q+' 2>&1'+$q; $a=@{CommandLine=$env:ComSpec+' /c '+$line; CurrentDirectory=$env:SPAWN_DIR}; $r=Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments $a; if ($r.ReturnValue -eq 0 -and $r.ProcessId) { Set-Content -LiteralPath $env:SPAWN_PID_FILE -Value $r.ProcessId }" %C_RST%
@REM      powershell -NoProfile -ExecutionPolicy Bypass -Command "$q=[char]34; $line=$q+$q+$env:SPAWN_EXE+$q+' '+$env:SPAWN_ARGS+' 1>'+$q+$env:SPAWN_LOG+$q+' 2>&1'+$q; $a=@{CommandLine=$env:ComSpec+' /c '+$line; CurrentDirectory=$env:SPAWN_DIR}; $r=Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments $a; if ($r.ReturnValue -eq 0 -and $r.ProcessId) { Set-Content -LiteralPath $env:SPAWN_PID_FILE -Value $r.ProcessId }" >nul 2>&1
@REM  )

@REM  if exist "!SERVER_PID_FILE!" (
@REM      for /f "delims=" %%P in ('type "!SERVER_PID_FILE!" 2^>nul') do if not defined SERVER_PID set "SERVER_PID=%%P"
@REM      del /q "!SERVER_PID_FILE!" >nul 2>&1
@REM  )
@REM  if defined SERVER_PID (
@REM      set "SERVE_STARTED=1"
@REM      exit /b 0
@REM  )


rem WMI 不可用时退回 start, 会闪一个最小化窗口
echo %E_SUB% WMI 分离启动失败, 退回 start 启动
echo cmd start启动packwiz服务,执行命令: %C_DIM% start "CocoPackwizServe" /min /d "!SPAWN_DIR!" cmd /c "!PACKWIZ_EXE! !SPAWN_ARGS!" %C_RST%
start "CocoPackwizServe" /min /d "!SPAWN_DIR!" cmd /c "!PACKWIZ_EXE! !SPAWN_ARGS!"

if not errorlevel 1 (
	set "SERVE_STARTED=1"
	call :capture_server_pid
	exit /b errorlevel
)
exit /b 1


:capture_server_pid
rem 只认 packwiz.exe, 避免把端口上的其它程序当成本脚本的服务
set "SERVER_PID="

cmd /c "netstat -ano | findstr /i "LISTENING" | findstr !PACK_PORT_BASE!"
set "_cand="
for /f "tokens=5" %%P in ('netstat -ano ^| findstr /i "LISTENING" ^| findstr "!PACK_PORT_BASE!"') do if not defined _cand set "_cand=%%P"
echo packwiz PID: !_cand!
tasklist /fi "PID eq !_cand!"
if not defined _cand (
	echo packwiz服务启动失败,未发现监听中的!PACK_PORT_BASE!端口
	exit /b 1
)
call :pid_is_packwiz !_cand!
if not errorlevel 1 (
	set "SERVER_PID=!_cand!"
	echo packwiz服务启动成功,PID: !SERVER_PID!
	exit /b 0
)
echo packwiz服务启动失败,怀疑是!PACK_PORT_BASE!端口已被占用
exit /b 1

rem 检测目标PID是否为进程packwiz.exe
:pid_is_packwiz
set "_pname="
for /f "tokens=1" %%N in ('tasklist /fi "PID eq %~1" /nh 2^>nul') do if not defined _pname set "_pname=%%N"
if /i "!_pname!"=="packwiz.exe" exit /b 0
exit /b 1





rem ---------------------------------------------------------------------------
rem  关闭本地包服务
rem ---------------------------------------------------------------------------
:stop_serve
if not "!SERVER_STARTED!"=="1" goto :eof
if not defined SERVER_PID call :capture_serve_pid
if defined SERVER_PID taskkill /PID !SERVER_PID! /T /F >nul 2>&1
taskkill /FI "WINDOWTITLE eq CocoPackwizServe*" /F /T >nul 2>&1
set "_sp="
for /f "tokens=5" %%P in ('netstat -ano -p tcp 2^>nul ^| findstr /i "LISTENING" ^| findstr ":!PACK_PORT! "') do if not defined _sp set "_sp=%%P"
if defined _sp (
    call :pid_is_packwiz !_sp!
    if "!errorlevel!"=="0" taskkill /PID !_sp! /T /F >nul 2>&1
)
set "SERVER_STARTED=0"
set "SERVER_PID="
echo    %E_SUB% 本地包服务已关闭
goto :eof



rem ---------------------------------------------------------------------------
rem  生成 PCL 启动前命令
rem ---------------------------------------------------------------------------
:write_pcl_cmd
set "SCRIPT_POST_NAME=[客户端]mod后处理修复脚本.bat"
set "PCL_CMD=call "{verpath}\!SCRIPT_DIR_NAME!\!SCRIPT_NAME!" "$INST_JAVA""
set "PCL_POST_CMD=call "{verpath}\!SCRIPT_DIR_NAME!\!SCRIPT_POST_NAME!" -Quiet"
set "PCL_CMD_FULL=!PCL_CMD! && !PCL_POST_CMD!"

set "PCL_TMP=%TEMP%\pcl_precmd_%RANDOM%.txt"
>"!PCL_TMP!" echo(!PCL_CMD_FULL!
clip < "!PCL_TMP!"
del "!PCL_TMP!" >nul 2>&1

echo %E_OK% 已自动复制到剪贴板
echo %C_DIM% 粘贴到 PCL - 版本设置 - 设置 - 高级选项 - 启动前执行指令 %C_RST%
echo %C_GRN% !PCL_CMD_FULL! %C_RST%
echo %E_SUB% {verpath} 展开为版本文件夹, $INST_JAVA 展开为启动器指定的Java
goto :eof


:find_bootstrap_jar_on_path
set "BOOTSTRAP_JAR="
if exist "!MC_VERSION_DIR_PATH!\packwiz-installer-bootstrap.jar" (
	set "BOOTSTRAP_JAR=!MC_VERSION_DIR_PATH!\packwiz-installer-bootstrap.jar"
	echo 在MC版本文件夹定位到packwiz-installer-bootstrap.jar
	exit /b 0
)
exit /b 1


:download_bootstrap_jar
set "BOOTSTRAP_JAR_URL=https://github.com/packwiz/packwiz-installer-bootstrap/releases/download/v0.0.3/packwiz-installer-bootstrap.jar"
echo %E_INFO% 下载 packwiz-installer-bootstrap.jar
set "DL_URL=!BOOTSTRAP_JAR_URL!"
set "DL_OUT=!MC_VERSION_DIR_PATH!\packwiz-installer-bootstrap.jar"
set "DL_MIN=1000000"
call :dl
if not exist "!MC_VERSION_DIR_PATH!\packwiz-installer-bootstrap.jar" (
    echo %E_ERR%  packwiz-installer-bootstrap.jar 下载失败
    exit /b 1
)
echo %E_INFO% 下载 packwiz-installer-bootstrap.jar成功
set "BOOTSTRAP_JAR=!MC_VERSION_DIR_PATH!\packwiz-installer-bootstrap.jar"
exit /b 0


:find_installer_jar_on_path
set "INSTALLER_JAR="
if exist "!MC_VERSION_DIR_PATH!\packwiz-installer.jar" (
	set "INSTALLER_JAR=!MC_VERSION_DIR_PATH!\packwiz-installer.jar"
	echo 在MC版本文件夹定位到packwiz-installer.jar
	exit /b 0
)
exit /b 1



:download_installer_jar
set "INSTALLER_JAR_URL=https://github.com/packwiz/packwiz-installer/releases/latest/download/packwiz-installer.jar"
echo %E_INFO% 下载 packwiz-installer.jar
set "DL_URL=!INSTALLER_JAR_URL!"
set "DL_OUT=!MC_VERSION_DIR_PATH!\packwiz-installer.jar"
set "DL_MIN=1000000"
call :dl
if not exist "!MC_VERSION_DIR_PATH!\packwiz-installer.jar" (
    echo %E_ERR%  packwiz-installer.jar 下载失败
    exit /b 1
)
echo %E_INFO% 下载 packwiz-installer.jar成功
set "INSTALLER_JAR=!MC_VERSION_DIR_PATH!\packwiz-installer.jar"
exit /b 0