#Requires -Version 5.1
<#
.SYNOPSIS
    新增模组后, 自动校正 side 并把条目补进 模组列表介绍.md

.DESCRIPTION
    流程:
      1. 扫描 mods/*.pw.toml, 与 模组列表介绍.md 比对, 找出尚未记录的模组
      2. 逐个用 Modrinth API 判定 client_side / server_side, 与文件里的 side 对照
      3. 交互式录入中文名、分类、功能说明, 依赖项由 Modrinth 版本信息自动带出
      4. 需要时写回 .pw.toml 的 side, 并把行插入文档对应的分类表格
      5. 末尾重算各节计数, 可选执行 packwiz refresh

.PARAMETER PackDir
    packwiz 包目录 (pack.toml 所在层), 默认取脚本同级的 ..\Coco_Minecraft_CustomModPack

.PARAMETER DocPath
    清单文档路径, 默认为 PackDir\模组列表介绍.md

.PARAMETER Proxy
    下载代理, 例如 http://127.0.0.1:7890; 省略时先直连, 失败再试该端口

.PARAMETER DryRun
    只看结果, 不写任何文件

.PARAMETER NoSide
    跳过 side 校正, 只补文档

.PARAMETER All
    不逐个询问是否处理, 直接处理全部新增模组
#>
[CmdletBinding()]
param(
    [string]$PackDir,
    [string]$DocPath,
    [string]$Proxy,
    [switch]$DryRun,
    [switch]$NoSide,
    [switch]$All
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::GetEncoding(936)
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)

function Say    { param($m) Write-Host $m }
function Head   { param($m) Write-Host ''; Write-Host "== $m ==" -ForegroundColor Cyan }
function Ok     { param($m) Write-Host "[完成] $m" -ForegroundColor Green }
function Info   { param($m) Write-Host "[信息] $m" -ForegroundColor Gray }
function Warn   { param($m) Write-Host "[注意] $m" -ForegroundColor Yellow }
function Fail   { param($m) Write-Host "[错误] $m" -ForegroundColor Red }

# ---------------------------------------------------------------------------
#  HTTP
# ---------------------------------------------------------------------------
$script:ApiProxy = $Proxy

function Invoke-Api {
    param([string]$Url, [int]$Retry = 0)
    $headers = @{ 'User-Agent' = 'CocoPackTool/1.0 (packwiz modlist helper)' }
    $attempts = @()
    if ($script:ApiProxy) { $attempts += $script:ApiProxy }
    else { $attempts += ''; $attempts += 'http://127.0.0.1:7890' }

    foreach ($p in $attempts) {
        try {
            if ($p) { return Invoke-RestMethod -Uri $Url -Headers $headers -Proxy $p -TimeoutSec 25 }
            return Invoke-RestMethod -Uri $Url -Headers $headers -TimeoutSec 25
        } catch {
            $lastErr = $_.Exception.Message
        }
    }
    throw "接口请求失败 $Url : $lastErr"
}

function Get-MrProject {
    param([string]$IdOrSlug)
    try { return Invoke-Api "https://api.modrinth.com/v2/project/$IdOrSlug" } catch { return $null }
}

function Get-MrVersion {
    param([string]$VersionId)
    try { return Invoke-Api "https://api.modrinth.com/v2/version/$VersionId" } catch { return $null }
}

function Get-MrProjectTitles {
    param([string[]]$Ids)
    if (-not $Ids -or $Ids.Count -eq 0) { return @() }
    $json = '[' + (($Ids | ForEach-Object { '"' + $_ + '"' }) -join ',') + ']'
    $url = 'https://api.modrinth.com/v2/projects?ids=' + [uri]::EscapeDataString($json)
    try { return Invoke-Api $url } catch { return @() }
}

# ---------------------------------------------------------------------------
#  pw.toml 读写
# ---------------------------------------------------------------------------
function Read-PwFile {
    param([string]$Path)
    $text = [IO.File]::ReadAllText($Path, [Text.Encoding]::UTF8)
    $o = [ordered]@{ Path = $Path; Key = ''; Name = ''; Filename = ''; Side = ''; MrId = ''; MrVersion = ''; CfProject = ''; Download = '' }
    $section = ''
    foreach ($line in ($text -split "`r?`n")) {
        if ($line -match '^\s*\[(.+?)\]\s*$') { $section = $Matches[1].Trim(); continue }
        if ($line -match '^\s*([A-Za-z0-9_\-]+)\s*=\s*"(.*)"\s*$') {
            $k = $Matches[1]; $v = $Matches[2]
            $full = if ($section) { "$section.$k" } else { $k }
            switch ($full) {
                'name'                        { if (-not $o.Name)     { $o.Name = $v } }
                'filename'                    { if (-not $o.Filename) { $o.Filename = $v } }
                'side'                        { if (-not $o.Side)     { $o.Side = $v } }
                'download.url'                { $o.Download = $v }
                'update.modrinth.mod-id'      { $o.MrId = $v }
                'update.modrinth.version'     { $o.MrVersion = $v }
                'update.curseforge.project-id'{ $o.CfProject = $v }
            }
        }
    }
    $o.Key = [IO.Path]::GetFileName($Path) -replace '\.pw\.toml$', ''
    return [pscustomobject]$o
}

function Set-PwSide {
    param([string]$Path, [string]$Side)
    $text = [IO.File]::ReadAllText($Path, [Text.Encoding]::UTF8)
    if ($text -match '(?m)^side\s*=\s*"[^"]*"') {
        $new = [regex]::Replace($text, '(?m)^side\s*=\s*"[^"]*"', ('side = "' + $Side + '"'))
    } else {
        $new = [regex]::Replace($text, '(?m)^\[download\]', ('side = "' + $Side + '"' + "`r`n`r`n[download]"), 1)
    }
    if ($new -ne $text) {
        if (-not $DryRun) { [IO.File]::WriteAllText($Path, $new, $Utf8NoBom) }
        return $true
    }
    return $false
}

# ---------------------------------------------------------------------------
#  文档解析 / 写回
# ---------------------------------------------------------------------------
function Read-DocSections {
    param([string[]]$Lines)
    $list = New-Object System.Collections.Generic.List[object]
    $cur = $null
    for ($i = 0; $i -lt $Lines.Count; $i++) {
        $l = $Lines[$i]
        if ($l -match '^###\s+(.+?)\s*$') {
            $title = $Matches[1] -replace '[（(]\s*\d*\s*[）)]\s*$', ''
            $hadCount = ($Lines[$i] -match "[（(]\s*\d+\s*[）)]\s*$")
            $cur = [pscustomobject]@{ Title = $title.Trim(); Heading = $i; RowStart = -1; RowEnd = -1; HadCount = $hadCount }
            $list.Add($cur)
            continue
        }
        if ($null -eq $cur) { continue }
        if ($l -match '^\|\s*\*\*') {
            if ($cur.RowStart -lt 0) { $cur.RowStart = $i }
            $cur.RowEnd = $i
        }
    }
    return $list
}

function New-DocRow {
    param($Mod, [string]$ChineseName, [string]$Deps, [string]$Desc, [string]$SideText)
    $en = $Mod.Name
    if (-not $en) { $en = $Mod.Key }
    $label = $en
    if ($ChineseName) {
        if ($ChineseName -match [regex]::Escape($en)) { $label = $ChineseName }
        else { $label = "$ChineseName $en" }
    }
    $slugCell = '`' + $Mod.Key + '`'
    $jar = if ($Mod.Filename) { $Mod.Filename } else { '—' }
    if (-not $Deps) { $Deps = '—' }
    if (-not $Desc) { $Desc = '—' }
    return ('| **{0}** | {1} | {2} | {3} | {4} | {5} |' -f $label.Trim(), $slugCell, $jar, $Deps, $Desc, $SideText)
}

function Save-DocWithRows {
    param([string]$Path, [string[]]$Lines, $Sections, [hashtable]$NewRows)

    # 从后往前插, 避免行号漂移
    $work = New-Object System.Collections.Generic.List[string]
    foreach ($l in $Lines) { $work.Add($l) }

    $ordered = $Sections | Sort-Object Heading -Descending
    foreach ($sec in $ordered) {
        if (-not $NewRows.ContainsKey($sec.Title)) { continue }
        $add = $NewRows[$sec.Title]
        if ($sec.RowEnd -ge 0) {
            $insertAt = $sec.RowEnd + 1
        } else {
            # 该节还没有表格: 在标题后插入表头
            $insertAt = $sec.Heading + 1
            $work.Insert($insertAt, '')
            $work.Insert($insertAt + 1, '| 名称 | slug | jar 文件名 | 前置 | 功能 | 端 |')
            $work.Insert($insertAt + 2, '| --- | --- | --- | --- | --- | --- |')
            $insertAt = $insertAt + 3
        }
        foreach ($row in $add) { $work.Insert($insertAt, $row); $insertAt++ }
    }

    # 重算每节计数
    $arr = $work.ToArray()
    $secs = Read-DocSections $arr
    for ($i = $secs.Count - 1; $i -ge 0; $i--) {
        $sec = $secs[$i]
        $n = if ($sec.RowStart -ge 0) { $sec.RowEnd - $sec.RowStart + 1 } else { 0 }
        $head = $arr[$sec.Heading]
        if ($n -gt 0) {
            $arr[$sec.Heading] = '### ' + $sec.Title + '（' + $n + '）'
        } elseif ($sec.HadCount) {
            $arr[$sec.Heading] = '### ' + $sec.Title + '（0）'
        } else {
            $arr[$sec.Heading] = '### ' + $sec.Title
        }
    }

    if (-not $DryRun) { [IO.File]::WriteAllText($Path, ($arr -join "`r`n"), $Utf8NoBom) }
    return $arr
}

function Get-SideText {
    param([string]$Side, [bool]$Disabled)
    $t = switch ($Side) { 'client' { '客户端' } 'server' { '服务端' } default { '双端' } }
    if ($Disabled) { $t = $t + '（已禁用）' }
    return $t
}

function Get-SuggestedSide {
    param($Proj)
    if (-not $Proj) { return $null }
    $cOk = ($Proj.client_side -eq 'required' -or $Proj.client_side -eq 'optional')
    $sOk = ($Proj.server_side -eq 'required' -or $Proj.server_side -eq 'optional')
    if ($cOk -and -not $sOk) { return 'client' }
    if ($sOk -and -not $cOk) { return 'server' }
    if ($cOk -and $sOk)      { return 'both' }
    return $null
}

function Get-RequiredDeps {
    param($Mod)
    if (-not $Mod.MrVersion) { return @() }
    $ver = Get-MrVersion $Mod.MrVersion
    if (-not $ver -or -not $ver.dependencies) { return @() }
    $ids = @()
    foreach ($d in $ver.dependencies) {
        if ($d.dependency_type -eq 'required' -and $d.project_id) { $ids += $d.project_id }
    }
    if ($ids.Count -eq 0) { return @() }
    $projs = Get-MrProjectTitles $ids
    return @($projs | ForEach-Object { $_.title })
}

# ---------------------------------------------------------------------------
#  主流程
# ---------------------------------------------------------------------------
Say ''
Say '=========================================================='
Say '  Coco 整合包 · 新增模组同步工具'
Say '=========================================================='
Say '  作用: 找出尚未写入清单的模组, 校正 side, 交互补全中文名与分类'
Say '  只读模式加 -DryRun; 跳过 side 校正加 -NoSide'
Say ''

# 1) 定位包目录
if (-not $PackDir) {
    $guess = Join-Path (Split-Path -Parent $PSScriptRoot) 'Coco_Minecraft_CustomModPack'
    if (Test-Path (Join-Path $guess 'pack.toml')) { $PackDir = $guess }
}
while (-not $PackDir -or -not (Test-Path (Join-Path $PackDir 'pack.toml'))) {
    $PackDir = Read-Host '  packwiz 包目录 (含 pack.toml)'
    if ($PackDir) { $PackDir = $PackDir.Trim('"').TrimEnd('\') }
}
$PackDir = (Resolve-Path $PackDir).Path
if (-not $DocPath) { $DocPath = Join-Path $PackDir '模组列表介绍.md' }
if (-not (Test-Path $DocPath)) { Fail "找不到清单文档 $DocPath"; exit 1 }
Info "包目录 $PackDir"
Info "清单   $DocPath"
if ($DryRun) { Warn 'DryRun 模式, 不会写入任何文件' }

# 2) 读元数据与文档
$mods = @(Get-ChildItem (Join-Path $PackDir 'mods') -Filter '*.pw.toml' | ForEach-Object { Read-PwFile $_.FullName } | Sort-Object Key)
$docLines = [IO.File]::ReadAllText($DocPath, [Text.Encoding]::UTF8) -split "`r?`n"
$sections = Read-DocSections $docLines
$docKeys = @()
foreach ($l in $docLines) {
    if ($l -notmatch '^\|') { continue }
    foreach ($mm in [regex]::Matches($l, '[`]([A-Za-z0-9][A-Za-z0-9_\-\.]*)[`]')) { $docKeys += $mm.Groups[1].Value }
}
$docKeys = $docKeys | Sort-Object -Unique
Info ("元数据 {0} 个, 文档记录 {1} 个" -f $mods.Count, $docKeys.Count)

# 3) 差异
$newMods = @($mods | Where-Object { $docKeys -notcontains $_.Key })
if ($newMods.Count -eq 0) {
    Ok '没有发现未记录的模组, 无需操作'
    exit 0
}
Head "发现 $($newMods.Count) 个尚未记录在清单里的模组"
$i = 0
foreach ($m in $newMods) {
    $i++
    $s = if ($m.Side) { $m.Side } else { '(未设)' }
    Say ("  {0,2}. {1,-32} side={2,-8} {3}" -f $i, $m.Key, $s, $m.Filename)
}
Say ''
if (-not $All) {
    $go = Read-Host '  现在逐个处理吗 [Y/n]'
    if ($go -and $go -notmatch '^[Yy]') { Info '已取消'; exit 0 }
}

# 4) 逐个处理
$newRows = @{}
$sideChanged = 0
$skipped = 0
foreach ($m in $newMods) {
    Head ("[$($m.Key)]  " + $(if ($m.Name) { $m.Name } else { '(无名称)' }))

    $proj = $null
    if ($m.MrId) { $proj = Get-MrProject $m.MrId }
    if (-not $proj -and $m.Key) { $proj = Get-MrProject $m.Key }

    $suggest = $null
    if ($proj) {
        Info ("Modrinth: client={0} server={1}" -f $proj.client_side, $proj.server_side)
        $suggest = Get-SuggestedSide $proj
    } else {
        Warn '拿不到 Modrinth 信息, 需要人工判断端'
    }

    # side 校正
    $finalSide = $m.Side
    if (-not $NoSide) {
        $want = if ($suggest) { $suggest } else { $m.Side }
        if ($suggest -and $suggest -ne $m.Side) {
            $ans = Read-Host ("  当前 side={0}, 按 API 建议改为 {1}? [Y/n]" -f $m.Side, $suggest)
            if (-not $ans -or $ans -match '^[Yy]') { $want = $suggest }
            else { $want = Read-Host '  那你要设成什么 (client/server/both)' }
        }
        $want = $want.Trim().ToLower()
        if ($want -notin @('client', 'server', 'both')) { $want = $m.Side }
        if ($want -and $want -ne $m.Side) {
            $changed = Set-PwSide $m.Path $want
            if ($changed) { $sideChanged++; Ok "side 已改为 $want"; $finalSide = $want }
        } else { $finalSide = $m.Side }
    }

    # 依赖
    $deps = @()
    if ($m.MrVersion) { $deps = Get-RequiredDeps $m }
    $depText = if ($deps.Count -gt 0) { ($deps -join '、') } else { '' }
    if ($depText) { Info "前置(Modrinth required): $depText" } else { Info '前置: 未取到, 可留空' }
    $depInput = Read-Host ("  前置 [回车沿用: {0}]" -f $(if ($depText) { $depText } else { '—' }))
    if ($depInput) { $depText = $depInput }

    # 中文名
    $cnFull = if ($m.Name) { $m.Name } else { $m.Key }
    $cn = Read-Host ("  中文名 [回车留空, 英文名会自动带上: {0}]" -f $cnFull)

    # 分类
    Say ''
    Say '  选择分类:'
    for ($k = 0; $k -lt $sections.Count; $k++) {
        Say ("    {0,2}. {1}" -f ($k + 1), $sections[$k].Title)
    }
    Say ("    {0,2}. 新建分类" -f ($sections.Count + 1))
    $pick = Read-Host '  序号'
    if (-not $pick) { $pick = '1' }
    $cat = $null
    if ($pick -match '^\d+$' -and [int]$pick -ge 1 -and [int]$pick -le $sections.Count) {
        $cat = $sections[[int]$pick - 1].Title
    } else {
        $cat = Read-Host '  新分类名称'
        if (-not $cat) { $cat = '未分类' }
        # 追加一个空节到文档末尾
        $docLines += ''
        $docLines += '### ' + $cat
        $docLines += ''
        $sections = Read-DocSections $docLines
    }

    # 功能描述
    $desc = Read-Host '  功能描述 (一句话)'

    $row = New-DocRow $m $cn $depText $desc (Get-SideText $finalSide $false)
    if (-not $newRows.ContainsKey($cat)) { $newRows[$cat] = @() }
    $newRows[$cat] += $row
    Ok "已加入分类: $cat"
}

if ($newRows.Count -eq 0) { Warn '没有新增任何条目'; exit 0 }

# 5) 写回文档
$finalLines = Save-DocWithRows $DocPath $docLines $sections $newRows
if ($DryRun) { Warn 'DryRun, 文档未写入' } else { Ok "文档已更新 $DocPath" }
if ($sideChanged -gt 0) { Info "共修改 $sideChanged 个 .pw.toml 的 side" }

# 6) packwiz refresh
if (-not $DryRun -and ($sideChanged -gt 0)) {
    $pwz = $null
    $cached = Join-Path $env:LOCALAPPDATA 'CocoPackwiz\meta\packwiz.exe'
    if (Test-Path $cached) { $pwz = $cached }
    elseif (Get-Command packwiz -ErrorAction SilentlyContinue) { $pwz = (Get-Command packwiz).Source }
    if ($pwz) {
        Head '执行 packwiz refresh'
        Push-Location $PackDir
        & $pwz refresh
        $rc = $LASTEXITCODE
        Pop-Location
        if ($rc -eq 0) { Ok 'index.toml 已刷新' } else { Warn "refresh 返回 $rc" }
    } else {
        Warn '找不到 packwiz, 请手动在包目录执行 packwiz refresh'
    }
}

# 7) 后续提示
Head '下一步'
Say '  1. 核对 模组列表介绍.md 的表格与计数'
Say '  2. packwiz refresh  (若上面已自动执行可跳过)'
Say '  3. git status 确认只动了 mods\*.pw.toml、index.toml、pack.toml 与清单文档'
Say '  4. git add -A 并提交推送'
Say '     main 分支的改动会让玩家在下次启动时自动同步'
Say ''
Ok '处理结束'
