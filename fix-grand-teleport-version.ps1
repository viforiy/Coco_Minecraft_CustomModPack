#requires -version 5
<#
  修正 Grand Teleport (NeoForge 移植版) 的 META-INF/neoforge.mods.toml 版本号。

  故障: 该 jar 的 version 写成了 "neoforge-1.0.1"。
        FML 用正则 ^\d+.* 校验版本号(必须数字开头), 于是整份 mod 文件被判无效:
        InvalidModFileException: Illegal version number specified neoforge-1.0.1
        -> mod 加载阶段整体失败(broken mod state) -> Quark/Zeta 迟到初始化
        -> ModLoadingContext.getActiveContainer() 抛 "Where is minecraft???!" -> 启动崩溃。
  修复: 只把这一行版本号改回 1.0.1, 其余条目原样保留, 并留 .bak 备份。
#>
param(
    [string]$Jar,
    [string]$Version = '1.0.1',
    [switch]$Quiet
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression.FileSystem

$ENTRY = 'META-INF/neoforge.mods.toml'

if ([string]::IsNullOrWhiteSpace($Jar)) {
    $mods = Join-Path (Split-Path -Parent $PSScriptRoot) 'mods'
    if (-not (Test-Path -LiteralPath $mods)) { $mods = Join-Path $PSScriptRoot 'mods' }
    if (-not (Test-Path -LiteralPath $mods)) { Write-Host "[x] 找不到 mods 目录: $mods"; exit 1 }
    $cand = @(Get-ChildItem -LiteralPath $mods -Filter 'GrandTeleport*.jar' -ErrorAction SilentlyContinue)
    if ($cand.Count -eq 0) { Write-Host "[x] mods 里没有 GrandTeleport*.jar: $mods"; exit 1 }
    if ($cand.Count -gt 1) { Write-Host "[!] 有多个候选, 用第一个: $($cand[0].Name)" }
    $Jar = $cand[0].FullName
}
if (-not (Test-Path -LiteralPath $Jar)) { Write-Host "[x] 找不到 jar: $Jar"; exit 1 }

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
    if ($null -eq $entry) {
        Write-Host "[x] $ENTRY 不存在, 这不是 NeoForge 模组: $Jar"
        exit 1
    }
    $reader = New-Object System.IO.StreamReader($entry.Open(), [System.Text.Encoding]::UTF8)
    $toml = $reader.ReadToEnd()
    $reader.Close()
} finally { $zip.Dispose() }

$m = [regex]::Match($toml, '(?m)^version\s*=\s*"([^"\r\n]*)"')
if (-not $m.Success) { Write-Host '[x] 没找到 version = "..." 字段'; exit 1 }
$old = $m.Groups[1].Value

if ($old -match '^\d') {
    if (-not $Quiet) {
        Write-Host "[v] 版本号已是合法形式 ($old), 无需修改:"
        Write-Host "    $Jar"
        Read-Host '按回车退出' | Out-Null
    }
    exit 0
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
if (-not $Quiet) {
    Write-Host "[v] version: $old -> $now   (zip 条目数: $count)"
    Write-Host ("[i] 已写入: {0}" -f $Jar)
    Write-Host ("[i] 备份  : {0}" -f $bak)
}
if ($now -ne $Version) { Write-Host '[!] 复核不一致, 请改用备份'; exit 1 }

if (-not $Quiet) { Read-Host '按回车完成' | Out-Null }
exit 0
