#requires -version 5
<#
  Coco's 整合包 · 维护脚本: 把修好的 Grand Teleport 托管进 packwiz 仓库
  ---------------------------------------------------------------------------
  作用 : mods\grand-teleport.pw.toml 仍指向 Modrinth 的 Fabric 构建, 会把
         grand-teleport-1.21.1-build252.jar 拉回来, 与本地修好版本号的 NeoForge 构建
         同 modId(gtalike_teleport) 撞车, 又是启动崩溃.
         本脚本把 NeoForge 构建作为"托管文件"放进元数据仓(带 hash), 删掉旧 metafile,
         再 packwiz refresh, 让客户端同步到修好的那一份.
  幂等 : 重复跑只会重算 hash 并覆盖同名文件, 不会重复加条目
  回滚 : git -C <元数据仓> restore --staged . ; git -C <元数据仓> restore .
         Remove-Item <元数据仓>\mods\<文件名>
  用法 : packwiz-manage-grand-teleport.ps1           预览(默认, 不改任何东西)
         packwiz-manage-grand-teleport.ps1 -Apply    真改仓库(仍然不会 commit)
  注意 : 这是维护仓库用的, 不进 PCL 启动前指令; 改完自己 git commit / push.
#>
param(
    [switch]$Apply,
    [string]$MetaDir,
    [string]$FixedJar,
    [string]$GameDir,
    [switch]$Quiet,
    [switch]$Help
)

$ErrorActionPreference = 'Stop'

# ===== 统一路径: 从脚本位置往上最多 3 层, 找含 mods 的实例目录 =====
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

if ($Help) {
    Write-Host ''
    Write-Host "  Coco's 整合包 · packwiz 托管 Grand Teleport"
    Write-Host ''
    Write-Host '  用法  packwiz-manage-grand-teleport.ps1 [-Apply] [-MetaDir <元数据仓>] [-FixedJar <jar>] [-Quiet] [-Help]'
    Write-Host ''
    Write-Host '    -Apply      真改仓库(复制 jar + 删旧 metafile + packwiz refresh); 不加就是预览'
    Write-Host '    -MetaDir    packwiz 元数据仓, 默认 %LOCALAPPDATA%\CocoPackwiz\meta'
    Write-Host '    -FixedJar   要托管的那份 jar, 默认到 <实例目录>\mods 里找 GrandTeleport*.jar'
    Write-Host '    -Quiet      静默, 不等待回车'
    Write-Host ''
    Write-Host '  改完不会自动提交, 自己 git add / commit / push'
    Write-Host ''
    exit 0
}

Add-Type -AssemblyName System.IO.Compression.FileSystem

$GameDir = Resolve-InstanceDir $GameDir
if ([string]::IsNullOrWhiteSpace($MetaDir)) { $MetaDir = Join-Path $env:LOCALAPPDATA 'CocoPackwiz\meta' }
if (-not (Test-Path -LiteralPath $MetaDir)) { Fail "找不到 packwiz 元数据仓: $MetaDir" }
$MetaDir = (Resolve-Path -LiteralPath $MetaDir).Path.TrimEnd('\')

$packwizExe = Join-Path $MetaDir 'packwiz.exe'
if (-not (Test-Path -LiteralPath $packwizExe)) { $packwizExe = Join-Path $env:LOCALAPPDATA 'CocoPackwiz\tools\packwiz.exe' }
if (-not (Test-Path -LiteralPath $packwizExe)) {
    $cmd = Get-Command 'packwiz.exe' -ErrorAction SilentlyContinue
    if ($cmd) { $packwizExe = $cmd.Source }
}
if (-not (Test-Path -LiteralPath $packwizExe)) { Fail '找不到 packwiz.exe, 先跑一次 [客户端]mod更新脚本.bat 让它下好' }

if ([string]::IsNullOrWhiteSpace($FixedJar)) {
    if (-not $GameDir) { Fail '找不到实例目录(需含 mods); 用 -GameDir 指定' }
    $modsDir = Join-Path $GameDir 'mods'
    if (-not (Test-Path -LiteralPath $modsDir)) { Fail "找不到 mods 目录: $modsDir" }
    $cand = @(Get-ChildItem -LiteralPath $modsDir -Filter 'GrandTeleport*.jar' -ErrorAction SilentlyContinue |
              Where-Object { $_.Extension -eq '.jar' } | Sort-Object Name)
    if ($cand.Count -eq 0) { Fail "mods 里没有 GrandTeleport*.jar: $modsDir" }
    $neo = @($cand | Where-Object { $_.Name -match '(?i)neoforge' })
    if ($neo.Count -gt 0) { $FixedJar = $neo[0].FullName } else { $FixedJar = $cand[0].FullName }
}
if (-not (Test-Path -LiteralPath $FixedJar)) { Fail "找不到 jar: $FixedJar" }
Info "实例目录  : $GameDir"
Info "元数据仓  : $MetaDir"
Info "packwiz   : $packwizExe"

# 1) 校验待托管 jar 的版本字段
$zip = [System.IO.Compression.ZipFile]::OpenRead($FixedJar)
try {
    $entry = $null
    foreach ($e in $zip.Entries) { if (($e.FullName -replace '\\', '/') -eq 'META-INF/neoforge.mods.toml') { $entry = $e; break } }
    if ($null -eq $entry) { Fail "这不是 NeoForge 模组(没有 META-INF/neoforge.mods.toml): $FixedJar" }
    $reader = New-Object System.IO.StreamReader($entry.Open(), [System.Text.Encoding]::UTF8)
    $toml = $reader.ReadToEnd()
    $reader.Close()
} finally { $zip.Dispose() }
$ver = [regex]::Match($toml, '(?m)^version\s*=\s*"([^"\r\n]*)"').Groups[1].Value
$modId = [regex]::Match($toml, '(?m)^modId\s*=\s*"([^"\r\n]*)"').Groups[1].Value
if ($ver -notmatch '^\d') { Fail "jar 里的版本号仍非法 ($ver), 先跑 fix-grand-teleport-version.ps1" }
Info "待托管 jar : $FixedJar"
Info "modId/版本 : $modId / $ver"

# 2) 仓库现状
$metaFile = Join-Path $MetaDir 'mods\grand-teleport.pw.toml'
$hasMeta = Test-Path -LiteralPath $metaFile
$oldFile = ''
$oldUrl = ''
if ($hasMeta) {
    $oldText = Get-Content -LiteralPath $metaFile -Raw
    $oldFile = [regex]::Match($oldText, '(?m)^filename\s*=\s*"([^"\r\n]*)"').Groups[1].Value
    $oldUrl = [regex]::Match($oldText, '(?m)^url\s*=\s*"([^"\r\n]*)"').Groups[1].Value
    Info "现有 metafile: mods\grand-teleport.pw.toml -> $oldFile"
    Info "现有下载源  : $oldUrl"
} else {
    Info '仓库里没有 grand-teleport.pw.toml, 直接作为普通文件加入'
}

$fileName = Split-Path -Leaf $FixedJar
$dest = Join-Path $MetaDir ('mods\' + $fileName)
$sha = (Get-FileHash -LiteralPath $FixedJar -Algorithm SHA256).Hash.ToLower()

Say ''
Say '将要执行:'
if ($hasMeta) { Say ("  1) 删除 metafile  mods\grand-teleport.pw.toml  (原 $oldFile)") }
Say ("  2) 复制 jar      -> mods\{0}   sha256={1}" -f $fileName, $sha)
Say ("  3) packwiz refresh (重建 index.toml, 写 internal hash)")
Say  '  4) git add -A && git commit && git push  (这一条留给你手动执行)'
Say ''

if (-not $Apply) {
    Say '[信息] 预览模式, 什么都没改. 加 -Apply 真做(仍然不会 commit).'
    if (-not $Quiet) { Read-Host '按回车退出' | Out-Null }
    exit 0
}

if ($hasMeta) { Remove-Item -LiteralPath $metaFile -Force }
Copy-Item -LiteralPath $FixedJar -Destination $dest -Force
Done "已放置: $dest"

Push-Location -LiteralPath $MetaDir
try {
    & $packwizExe refresh
    $rc = $LASTEXITCODE
    Info "packwiz refresh 退出码: $rc"
    $idx = Get-Content -LiteralPath (Join-Path $MetaDir 'index.toml') -Raw
    $hit = [regex]::Match($idx, '\[\[files\]\]\s*file\s*=\s*"mods/' + [regex]::Escape($fileName) + '"\s*hash\s*=\s*"([0-9a-f]+)"(\s*metafile\s*=\s*true)?')
    if ($hit.Success) {
        Done ("index.toml 已收录, hash={0} metafile={1}" -f $hit.Groups[1].Value, [bool]$hit.Groups[2].Success)
        if ($hit.Groups[1].Value -ne $sha) { Warn 'index 里的 hash 与本地文件不一致, 检查 packwiz 版本/缓存' }
    } else {
        Warn 'index.toml 里没找到该条目, 手动检查'
    }
    Say ''
    Say '=== git status ==='
    & git -C $MetaDir status --short
    Say ''
    Say '确认无误后自行提交:'
    Say ('  git -C "{0}" add -A' -f $MetaDir)
    Say ('  git -C "{0}" commit -m "grand-teleport: 换成修好版本字段的 NeoForge 构建"' -f $MetaDir)
    Say ('  git -C "{0}" push' -f $MetaDir)
} finally { Pop-Location }

if (-not $Quiet) { Read-Host '按回车完成' | Out-Null }
exit 0