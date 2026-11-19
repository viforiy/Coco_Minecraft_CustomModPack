#requires -version 5
<#
  Coco's 整合包 · Grand Teleport 版本号修正
  ---------------------------------------------------------------------------
  作用 : GrandTeleport*.jar 的 META-INF/neoforge.mods.toml 里版本字段写成了
         "neoforge-1.0.1", 而 FML 要求版本号必须数字开头, 于是整份 mod 被判无效:
           InvalidModFileException: Illegal version number specified neoforge-1.0.1
         -> mod 加载整体失败(broken mod state) -> Quark/Zeta 迟到初始化
         -> ModLoadingContext.getActiveContainer() 抛 "Where is minecraft???!" -> 崩.
  处理 : 只把 version 这一行改回 1.0.1, 其余条目原样保留; 改前备份 *.bak-versionbug
  幂等 : version 已经是数字开头就直接跳过, 不写盘
  回滚 : 把 <jar>.bak-versionbug 改名回原 jar 即可
  用法 : fix-grand-teleport-version.ps1 [-GameDir <实例目录>] [-Jar <jar路径>] [-Version 1.0.1] [-Quiet] [-Help]
#>
param(
    [string]$GameDir,
    [string]$Jar,
    [string]$Version = '1.0.1',
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

$ENTRY = 'META-INF/neoforge.mods.toml'

if ($Help) {
    Write-Host ''
    Write-Host "  Coco's 整合包 · Grand Teleport 版本号修正"
    Write-Host ''
    Write-Host '  用法  fix-grand-teleport-version.ps1 [-GameDir <实例目录>] [-Jar <jar路径>] [-Version 1.0.1] [-Quiet] [-Help]'
    Write-Host ''
    Write-Host '    -GameDir   实例目录(含 mods), 默认从脚本位置往上自动找'
    Write-Host '    -Jar       直接指定 jar, 跳过自动查找'
    Write-Host '    -Version   要写回去的版本号, 默认 1.0.1'
    Write-Host '    -Quiet     静默, 不打印细节也不等待回车'
    Write-Host ''
    Write-Host '  返回码 0 = 已修好 / 本来就合法 / 没装这个 mod    1 = 出错'
    Write-Host ''
    exit 0
}

Add-Type -AssemblyName System.IO.Compression.FileSystem

$GameDir = Resolve-InstanceDir $GameDir
if ([string]::IsNullOrWhiteSpace($Jar)) {
    if (-not $GameDir) { Fail '找不到实例目录(需含 mods); 用 -GameDir 指定' }
    $mods = Join-Path $GameDir 'mods'
    if (-not (Test-Path -LiteralPath $mods)) { Fail "找不到 mods 目录: $mods" }
    $cand = @(Get-ChildItem -LiteralPath $mods -Filter 'GrandTeleport*.jar' -ErrorAction SilentlyContinue | Where-Object { $_.Extension -eq '.jar' })
    if ($cand.Count -eq 0) { Skip 'mods 里没有 GrandTeleport*.jar, 本机没有这个 mod' }
    if ($cand.Count -gt 1) { Warn "有多个候选, 用第一个: $($cand[0].Name)" }
    $Jar = $cand[0].FullName
}
if (-not (Test-Path -LiteralPath $Jar)) { Fail "找不到 jar: $Jar" }
Info "实例目录: $GameDir"
Info "jar     : $Jar"

function Find-Entry($zip, $want) {
    foreach ($e in $zip.Entries) {
        if (($e.FullName -replace '\\', '/') -eq $want) { return $e }
    }
    return $null
}

# 1) 只读探测
$zip = [System.IO.Compression.ZipFile]::OpenRead($Jar)
try {
    $entry = Find-Entry $zip $ENTRY
    if ($null -eq $entry) { Skip "$ENTRY 不存在, 这不是 NeoForge 模组: $Jar" }
    $reader = New-Object System.IO.StreamReader($entry.Open(), [System.Text.Encoding]::UTF8)
    $toml = $reader.ReadToEnd()
    $reader.Close()
} finally { $zip.Dispose() }

$m = [regex]::Match($toml, '(?m)^version\s*=\s*"([^"\r\n]*)"')
if (-not $m.Success) { Fail '没找到 version = "..." 字段' }
$old = $m.Groups[1].Value

if ($old -match '^\d') {
    Say "[信息] 版本号已是合法形式 ($old), 无需修改"
    Skip 'jar 已经是修好的状态'
}

# 2) 备份, 再原地改写该条目
$bak = "$Jar.bak-versionbug"
if (-not (Test-Path -LiteralPath $bak)) { Copy-Item -LiteralPath $Jar -Destination $bak -Force }

$newToml = $toml.Substring(0, $m.Groups[1].Index) + $Version + $toml.Substring($m.Groups[1].Index + $old.Length)

$zip = [System.IO.Compression.ZipFile]::Open($Jar, 'Update')
try {
    $entry = Find-Entry $zip $ENTRY
    $entry.Delete()
    $new = $zip.CreateEntry($ENTRY, [System.IO.Compression.CompressionLevel]::Optimal)
    $stream = $new.Open()
    $writer = New-Object System.IO.StreamWriter($stream, (New-Object System.Text.UTF8Encoding($false)))
    $writer.Write($newToml)
    $writer.Flush()
    $writer.Dispose()
    $stream.Dispose()
} finally { $zip.Dispose() }

# 3) 复核
$zip = [System.IO.Compression.ZipFile]::OpenRead($Jar)
try {
    $count = $zip.Entries.Count
    $entry = Find-Entry $zip $ENTRY
    $reader = New-Object System.IO.StreamReader($entry.Open(), [System.Text.Encoding]::UTF8)
    $check = $reader.ReadToEnd()
    $reader.Close()
} finally { $zip.Dispose() }

$now = [regex]::Match($check, '(?m)^version\s*=\s*"([^"\r\n]*)"').Groups[1].Value
if ($now -ne $Version) { Fail "[错误] 复核不一致, 请用 $bak 回滚" }
Done "version: $old -> $now   (zip 条目数: $count)"
Say "[信息] 已写入: $Jar"
Say "[信息] 备份  : $bak"
if (-not $Quiet) { Read-Host '按回车完成' | Out-Null }
exit 0