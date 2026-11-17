#requires -version 5
<#
  muoniumconfig-patch-soundevent.ps1 —— 启动前执行
  修 MuoniumConfig(内置精简版 OneConfig) 与 AmbientSounds 的崩溃:

    java.lang.NullPointerException:
      Cannot invoke "WeighedSoundEvents.getSound(RandomSource)" because "this.soundeventaccessor" is null
        at AmbientSound$SoundStream.getSound(...)
        at SoundManager.localvar$ehf000$muoniumconfigv1$onPlaySoundCallback(...)

  原因: OneConfig 的 Mixin_SoundPlayedEvent 在 SoundManager.play() 里对 SoundInstance 调 getSound()
        (代码形如 `if (sound != null && sound.getSound() != null) {...}`)。
        AmbientSounds 的 SoundStream 在 resolve() 之前 soundeventaccessor 还是 null,
        被这么一调就 NPE, 整个客户端崩溃。

  做法: 从 muoniumconfig jar 的 mixins.oneconfigv1.json 里去掉
        "events.Mixin_SoundPlayedEvent" 这一条 —— 不注入, 就不再有那个回调。
        本整合包里没有任何 mod 订阅 SoundPlayedEvent(MuoniumPlayer 也不订阅),
        所以功能上没有损失。

  幂等; 改前备份 *.bak-soundevent; JSON 用 ConvertFrom-Json 校验过才写回。
#>
param(
    [string]$GameDir,
    [string]$Jar,
    [switch]$Quiet
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression.FileSystem

$CFG = 'mixins.oneconfigv1.json'
$TOKEN = 'events.Mixin_SoundPlayedEvent'

function Say($m) { if (-not $Quiet) { Write-Host $m } }
function Fail($m) { Write-Host "[x] $m"; if (-not $Quiet) { Read-Host '按回车退出' | Out-Null }; exit 1 }

if ([string]::IsNullOrWhiteSpace($GameDir)) {
    foreach ($c in @($PSScriptRoot, (Split-Path -Parent $PSScriptRoot))) {
        if ($c -and (Test-Path -LiteralPath (Join-Path $c 'mods'))) { $GameDir = $c; break }
    }
}
if (-not $GameDir -or -not (Test-Path -LiteralPath (Join-Path $GameDir 'mods'))) { Fail "找不到游戏目录(需含 mods): $GameDir" }
if ([string]::IsNullOrWhiteSpace($Jar)) {
    $j = @(Get-ChildItem -LiteralPath (Join-Path $GameDir 'mods') -Filter 'muoniumconfig*.jar' -ErrorAction SilentlyContinue) |
         Select-Object -First 1
    if (-not $j) { Fail 'mods 里没有 muoniumconfig*.jar' }
    $Jar = $j.FullName
}
if (-not (Test-Path -LiteralPath $Jar)) { Fail "找不到 jar: $Jar" }
Say "[i] 游戏目录: $GameDir"
Say "[i] jar     : $Jar"

$zip = [System.IO.Compression.ZipFile]::OpenRead($Jar)
try {
    $entry = @($zip.Entries | Where-Object { ($_.FullName -replace '\\', '/') -eq $CFG })[0]
    if (-not $entry) { Fail "jar 里没有 $CFG (MuoniumConfig 版本可能变了)" }
    $sr = New-Object System.IO.StreamReader($entry.Open(), [System.Text.Encoding]::UTF8)
    $json = $sr.ReadToEnd(); $sr.Close()
} finally { $zip.Dispose() }

if ($json -notmatch [regex]::Escape($TOKEN)) {
    Say "[v] $CFG 里已经没有 $TOKEN, 无需修改"
} else {
    $new = [regex]::Replace($json, '(?m)^[ \t]*"' + [regex]::Escape($TOKEN) + '"[ \t]*,?[ \t]*\r?\n', '')
    if ($new -match [regex]::Escape($TOKEN)) { Fail '删除失败(格式不认识), 未做修改' }
    try { $null = $new | ConvertFrom-Json } catch { Fail "改完 JSON 解析失败: $($_.Exception.Message)" }

    $bak = "$Jar.bak-soundevent"
    if (-not (Test-Path -LiteralPath $bak)) { Copy-Item -LiteralPath $Jar -Destination $bak -Force }
    $tmp = "$Jar.tmp"
    if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force }

    $src = [System.IO.Compression.ZipFile]::OpenRead($Jar)
    $dst = [System.IO.Compression.ZipFile]::Open($tmp, 'Create')
    try {
        foreach ($e in $src.Entries) {
            $name = $e.FullName -replace '\\', '/'
            $zi = $dst.CreateEntry($name, [System.IO.Compression.CompressionLevel]::Optimal)
            $o = $zi.Open()
            if ($name -eq $CFG) {
                $bytes = [System.Text.Encoding]::UTF8.GetBytes($new)
                $o.Write($bytes, 0, $bytes.Length)
            } else {
                $i = $e.Open(); $i.CopyTo($o); $i.Dispose()
            }
            $o.Dispose()
        }
    } finally { $src.Dispose(); $dst.Dispose() }
    Move-Item -LiteralPath $tmp -Destination $Jar -Force

    # 复核
    $zip = [System.IO.Compression.ZipFile]::OpenRead($Jar)
    try {
        $e2 = @($zip.Entries | Where-Object { ($_.FullName -replace '\\', '/') -eq $CFG })[0]
        $sr = New-Object System.IO.StreamReader($e2.Open(), [System.Text.Encoding]::UTF8)
        $check = $sr.ReadToEnd(); $sr.Close()
    } finally { $zip.Dispose() }
    if ($check -match [regex]::Escape($TOKEN)) { Fail '复核失败: jar 里仍含该 mixin, 请用 .bak-soundevent 回滚' }
    $null = $check | ConvertFrom-Json
    Say "[v] 已从 $CFG 移除 $TOKEN"
    Say "[i] 备份: $bak"
}

Say ''
Say '[v] AmbientSounds 播放音效时不会再触发 OneConfig 的 SoundPlayedEvent 回调 (崩溃已消除)'
if (-not $Quiet) { Read-Host '按回车完成' | Out-Null }
