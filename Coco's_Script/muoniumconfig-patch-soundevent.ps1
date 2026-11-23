#requires -version 5
<#
  Coco's 整合包 · MuoniumConfig 声音事件补丁
  ---------------------------------------------------------------------------
  作用 : MuoniumConfig(内置精简 OneConfig) 的 Mixin_SoundPlayedEvent 会在
         SoundManager.play() 里对 SoundInstance 调 getSound()
         (代码形如 `if (sound != null && sound.getSound() != null) {...}`),
         而 AmbientSounds 的 SoundStream 在 resolve() 之前 soundeventaccessor 还是 null,
         被这么一调就 NPE, 整个客户端崩:
           java.lang.NullPointerException: Cannot invoke "WeighedSoundEvents.getSound(RandomSource)"
             because "this.soundeventaccessor" is null
               at AmbientSound$SoundStream.getSound(...)
               at SoundManager.localvar$ehf000$muoniumconfigv1$onPlaySoundCallback(...)
  处理 : 从 muoniumconfig jar 的 mixins.oneconfigv1.json 里去掉
         "events.Mixin_SoundPlayedEvent" 这一条 —— 不注入, 就不再有那个回调.
         本整合包里没有任何 mod 订阅 SoundPlayedEvent(MuoniumPlayer 也不订阅), 功能无损.
  幂等 : 已经去掉的 jar 直接跳过; 改前备份 *.bak-soundevent
  回滚 : 把 <jar>.bak-soundevent 改名回原 jar 即可
  用法 : muoniumconfig-patch-soundevent.ps1 [-GameDir <实例目录>] [-Jar <jar路径>] [-Quiet] [-Help]
#>
param(
    [string]$GameDir,
    [string]$Jar,
    [switch]$Quiet,
    [switch]$Help
)

$ErrorActionPreference = 'Stop'

# ===== 统一路径: 从脚本位置往上最多 3 层, 找含 mods 的实例目录 =====
# 脚本住在 <实例目录>\Coco's Script\ 里(当前布局); 直接放根目录(老布局)也兼容
function Resolve-InstanceDir([string]$p) {
    if ($p -and (Test-Path -LiteralPath (Join-Path $p 'mods'))) { return (Resolve-Path -LiteralPath $p).Path.TrimEnd('\') }
    if ($env:COCO_GAME_DIR -and (Test-Path -LiteralPath (Join-Path $env:COCO_GAME_DIR 'mods'))) {
        return (Resolve-Path -LiteralPath $env:COCO_GAME_DIR).Path.TrimEnd('\')
    }
    $cur = $PSScriptRoot
    for ($i = 0; $i -lt 4 -and $cur; $i++) {
        if (Test-Path -LiteralPath (Join-Path $cur 'mods')) { return $cur.TrimEnd('\') }
        $parent = Split-Path -Parent $cur
        if (-not $parent -or $parent -eq $cur) { break }
        $cur = $parent
    }
    return ''
}

# ===== 统一输出 =====
function Say([string]$m) { if (-not $Quiet) { Write-Host $m } }
function Info([string]$m) { Write-Host "[信息] $m" }
function Done([string]$m) { Write-Host "[完成] $m" }
function Warn([string]$m) { Write-Host "[警告] $m" }
function Skip([string]$m) { Write-Host "[跳过] $m"; exit 0 }
function Fail([string]$m) {
    Write-Host "[错误] $m"
    if (-not $Quiet) { Read-Host '按回车退出' | Out-Null }
    exit 1
}

$CFG = 'mixins.oneconfigv1.json'
$TOKEN = 'events.Mixin_SoundPlayedEvent'

if ($Help) {
    Write-Host ''
    Write-Host "  Coco's 整合包 · MuoniumConfig 声音事件补丁"
    Write-Host ''
    Write-Host '  用法  muoniumconfig-patch-soundevent.ps1 [-GameDir <实例目录>] [-Jar <jar路径>] [-Quiet] [-Help]'
    Write-Host ''
    Write-Host '    -GameDir   实例目录(含 mods), 默认从脚本位置往上自动找'
    Write-Host '    -Jar       直接指定 muoniumconfig 的 jar'
    Write-Host '    -Quiet     静默, 不打印细节也不等待回车'
    Write-Host ''
    Write-Host '  返回码 0 = 已打补丁 / 本来就是干净的 / 没装这个 mod    1 = 出错'
    Write-Host ''
    exit 0
}

Add-Type -AssemblyName System.IO.Compression.FileSystem

$GameDir = Resolve-InstanceDir $GameDir
if ([string]::IsNullOrWhiteSpace($Jar)) {
    if (-not $GameDir) { Fail '找不到实例目录(需含 mods); 用 -GameDir 指定' }
    $modsDir = Join-Path $GameDir 'mods'
    if (-not (Test-Path -LiteralPath $modsDir)) { Fail "找不到 mods 目录: $modsDir" }
    $j = @(Get-ChildItem -LiteralPath $modsDir -Filter 'muoniumconfig*.jar' -ErrorAction SilentlyContinue |
           Where-Object { $_.Extension -eq '.jar' } | Select-Object -First 1)
    if ($j.Count -eq 0) { Skip 'mods 里没有 muoniumconfig*.jar, 本机没有这个 mod' }
    $Jar = $j[0].FullName
}
if (-not (Test-Path -LiteralPath $Jar)) { Fail "找不到 jar: $Jar" }
Info "实例目录: $GameDir"
Info "jar     : $Jar"

$zip = [System.IO.Compression.ZipFile]::OpenRead($Jar)
try {
    $entry = @($zip.Entries | Where-Object { ($_.FullName -replace '\\', '/') -eq $CFG })[0]
    if (-not $entry) { Fail "jar 里没有 $CFG (MuoniumConfig 版本可能变了)" }
    $sr = New-Object System.IO.StreamReader($entry.Open(), [System.Text.Encoding]::UTF8)
    $json = $sr.ReadToEnd(); $sr.Close()
} finally { $zip.Dispose() }

if ($json -notmatch [regex]::Escape($TOKEN)) {
    Say "[信息] $CFG 里已经没有 $TOKEN, 无需修改"
    Skip 'jar 已经是干净的状态'
}

$new = [regex]::Replace($json, '(?m)^[ \t]*"' + [regex]::Escape($TOKEN) + '"[ \t]*,?[ \t]*\r?\n', '')
if ($new -match [regex]::Escape($TOKEN)) { Fail '删除失败(格式不认识), 未做任何修改' }
try { $null = $new | ConvertFrom-Json } catch { Fail "改完 JSON 解析失败, 未做任何修改: $($_.Exception.Message)" }

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

Done "已从 $CFG 移除 $TOKEN"
Say "[信息] 备份: $bak"
Say '[完成] AmbientSounds 播环境音效时不会再触发 OneConfig 的 SoundPlayedEvent 回调'
if (-not $Quiet) { Read-Host '按回车完成' | Out-Null }
exit 0