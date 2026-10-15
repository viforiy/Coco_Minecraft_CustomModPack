@echo off
:: 禁用命令回显，放在第一行
setlocal

:: 设置变量（推荐使用 set "var=value" 格式，避免引号被包含进变量值）
set "mc_path=D:\Program Files\Minecraft\[Client]MultiIntergationPack\.minecraft\versions\1.21.1-NeoForge_21.1.259"
set "java_path=D:\Program Files\jdk21\bin\java.exe"
set "installer_path=%mc_path%\packwiz-installer-bootstrap.jar"

:: 切换到 PCL2 的版本隔离目录
cd /d "%mc_path%"
if %errorlevel% neq 0 (
    echo [错误] 无法进入版本目录，请检查路径：%mc_path%
    exit /b 1
)

echo [信息] 正在执行 Packwiz 更新，请稍候...
:: 执行 packwiz 安装器（注意 URL 要改成你自己的，如果你本地开了 packwiz serve 就是 http://localhost:8080/pack.toml）
"%java_path%" -jar "%installer_path%" http://localhost:8080/pack.toml

:: 捕获 Java 执行结果
if %errorlevel% neq 0 (
    echo [错误] Packwiz 安装器执行失败，错误码：%errorlevel%
) else (
    echo [成功] Packwiz 更新完成！
)

:: 保持退出码，让 PCL2 知道执行成功还是失败
exit /b %errorlevel%