#Requires -Version 5.1
<#
    开发工具共用的领域函数

    供 维护模组清单.ps1 / 添加模组.ps1 / 推送元数据.ps1 点引用:

        $ToolHome = $PSScriptRoot
        . (Join-Path $ToolHome '工具函数.ps1')

    内容
      - 输出:   Say / Head / Ok / Info / Warn / Fail
      - 接口:   Invoke-Api / Get-MrProject / Get-MrVersion / Get-MrProjectTitles
      - 元数据: Read-PwFile / Set-PwSide
      - 文档:   Read-DocSections / New-DocRow / Save-DocWithRows / Repair-DocCounts /
                Get-SideText / New-DocSkeleton
      - 语义:   Get-SuggestedSide / Get-RequiredDeps

    说明: 部分函数依赖调用方的 $DryRun 与 $Utf8NoBom, 依赖 PowerShell 的动态作用域解析;
          $Utf8NoBom 在本文件内也有定义, 点引用后会覆盖为同值, 不影响调用方。
#>

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
    $arr = Repair-DocCounts $work.ToArray() (Read-DocSections $work.ToArray())

    if (-not $DryRun) { [IO.File]::WriteAllText($Path, ($arr -join "`r`n"), $Utf8NoBom) }
    return $arr
}

function Repair-DocCounts {
    param([string[]]$Lines, $Sections)
    $arr = [string[]]$Lines.Clone()
    for ($i = $Sections.Count - 1; $i -ge 0; $i--) {
        $sec = $Sections[$i]
        $n = if ($sec.RowStart -ge 0) { $sec.RowEnd - $sec.RowStart + 1 } else { 0 }
        if ($n -gt 0) { $arr[$sec.Heading] = '### ' + $sec.Title + '（' + $n + '）' }
        elseif ($sec.HadCount) { $arr[$sec.Heading] = '### ' + $sec.Title + '（0）' }
        else { $arr[$sec.Heading] = '### ' + $sec.Title }
    }
    return $arr
}

function Get-SideText {
    param([string]$Side, [bool]$Disabled)
    $t = switch ($Side) { 'client' { '客户端' } 'server' { '服务端' } default { '双端' } }
    if ($Disabled) { $t = $t + '（已禁用）' }
    return $t
}

function New-DocSkeleton {
    param(
        [Parameter(Mandatory = $true)][string]$PackDir,
        [Parameter(Mandatory = $true)][string]$DocPath,
        [Parameter(Mandatory = $true)]$Mods
    )

    # 标题取 pack.toml 的 name, 缺失时用目录名
    $packName = ''
    $packToml = Join-Path $PackDir 'pack.toml'
    if (Test-Path $packToml) {
        foreach ($l in [IO.File]::ReadAllLines($packToml, [Text.Encoding]::UTF8)) {
            if ($l -match '^\s*name\s*=\s*"(.*)"\s*$') { $packName = $Matches[1]; break }
        }
    }
    if (-not $packName) { $packName = Split-Path -Leaf $PackDir }

    $total = $Mods.Count
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add("# $packName · 模组清单说明")
    $lines.Add('')
    $lines.Add("下文表格与 ``mods/`` 目录一一对应：每个 ``.pw.toml`` 对应一条记录，共 $total 条。")
    $lines.Add('字段为 名称、slug、jar 文件名、前置、功能与安装端；slug 与 jar 文件名以元数据为准。')
    $lines.Add('')
    $lines.Add('> 分类可自行拆分与重排，工具只认 `###` 标题与表格行。')
    $lines.Add('> 新增或删除模组后，运行 `维护模组清单.bat` 同步本文件。')
    $lines.Add('')
    $lines.Add("### 未分类（$total）")
    $lines.Add('')
    $lines.Add('| 名称 | slug | jar 文件名 | 前置 | 功能 | 端 |')
    $lines.Add('| --- | --- | --- | --- | --- | --- |')

    foreach ($m in ($Mods | Sort-Object Key)) {
        $label = if ($m.Name) { $m.Name } else { $m.Key }
        $slugCell = '`' + $m.Key + '`'
        $jar = if ($m.Filename) { $m.Filename } else { '—' }
        $side = Get-SideText $m.Side $false
        $lines.Add(('| **{0}** | {1} | {2} | — | — | {3} |' -f $label, $slugCell, $jar, $side))
    }

    $nl = [Environment]::NewLine
    [IO.File]::WriteAllText($DocPath, (($lines -join $nl).TrimEnd() + $nl), (New-Object Text.UTF8Encoding($false)))
    return $DocPath
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
