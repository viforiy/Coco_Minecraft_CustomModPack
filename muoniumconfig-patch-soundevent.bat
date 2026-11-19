@echo off
chcp 65001 >nul
rem 启动前执行 去掉 MuoniumConfig 内置 OneConfig 的 Mixin_SoundPlayedEvent
rem 修 AmbientSounds 播放音效时的 NPE soundeventaccessor is null
setlocal
set "PS=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
"%PS%" -NoProfile -ExecutionPolicy Bypass -File "%~dp0muoniumconfig-patch-soundevent.ps1" %*
endlocal