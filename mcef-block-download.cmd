@echo off
chcp 65001 >nul
rem 启动前执行: 封死 MCEF(Chromium) 的依赖下载通道
rem 1) 把 MCEFDownloader.downloadJavaCefChecksum() 改成 return true (不再请求 sha256/mirror)
rem 2) config\mcef\mcef.properties 里 skip-download=true (双保险)
setlocal
set "PS=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
"%PS%" -NoProfile -ExecutionPolicy Bypass -File "%~dp0mcef-block-download.ps1" %*
endlocal
