@echo off
chcp 936 >nul 2>&1
rem ============================================================================
rem  Coco's 整合包 · MuoniumConfig 声音事件补丁
rem
rem  作用 : MuoniumConfig(内置精简 OneConfig) 的 Mixin_SoundPlayedEvent 会调
rem         SoundInstance.getSound(), AmbientSounds 的 SoundStream 还没 resolve,
rem         soundeventaccessor 为 null, 一播环境音效就 NPE 崩客户端.
rem         本脚本从 mixins.oneconfigv1.json 里去掉这条 mixin, 不再注入即不崩.
rem         (本整合包没有 mod 订阅 SoundPlayedEvent, 功能无损)
rem  调用 : [客户端]mod后处理修复脚本.bat 按顺序 call 本脚本, 也可单独双击.
rem  用法 : muoniumconfig-patch-soundevent.bat [-GameDir <实例目录>] [-Quiet] [--help]
rem  返回 : 0 已打补丁 / 本来就没有 / 没装 muoniumconfig     1 出错
rem ============================================================================

setlocal
set "RC=0"
set "TARGET_PS1=%~dp0muoniumconfig-patch-soundevent.ps1"
set "PS=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if not exist "%PS%" set "PS=powershell.exe"

if not exist "%TARGET_PS1%" (
    echo [错误] 缺少 %TARGET_PS1%
    echo        bat 与 ps1 必须成对放在同一个目录
    endlocal & exit /b 1
)

"%PS%" -NoProfile -ExecutionPolicy Bypass -File "%TARGET_PS1%" %*
set "RC=%errorlevel%"
endlocal & exit /b %RC%