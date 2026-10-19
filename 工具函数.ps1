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
    <#
        请求 Modrinth 接口并解析 JSON

        不使用 Invoke-RestMethod: 它在响应缺少 charset 时按 Latin-1 解码,
        会把中文标题与 emoji 变成乱码; 这里显式取原始字节按 UTF-8 解码。
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Url, [int]$Retry = 0)

    $headers = @{ 'User-Agent' = 'CocoPackTool/1.0 (packwiz modlist helper)' }
    $attempts = @()
    if ($script:ApiProxy) { $attempts += $script:ApiProxy }
    else { $attempts += ''; $attempts += 'http://127.0.0.1:7890' }

    $lastErr = ''
    foreach ($proxyAddr in $attempts) {
        try {
            $params = @{ Uri = $Url; Headers = $headers; TimeoutSec = 25; UseBasicParsing = $true }
            if ($proxyAddr) { $params['Proxy'] = $proxyAddr }
            $resp = Invoke-WebRequest @params
            $bytes = $resp.RawContentStream.ToArray()
            if (-not $bytes -or $bytes.Length -eq 0) { return $null }
            $text = [Text.Encoding]::UTF8.GetString($bytes)
            return ($text | ConvertFrom-Json)
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
    [CmdletBinding()]
    param([string]$Path, [string]$Side, [switch]$DryRun)
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
    return $list.ToArray()
}

function Get-DocSlugs {
    <#
        从清单文档提取已记录的 slug 集合
        只认表格行中的反引号 slug, 附录与正文不参与
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$DocPath)

    $out = New-Object System.Collections.Generic.List[string]
    if (-not (Test-Path $DocPath)) { return $out.ToArray() }
    foreach ($l in [IO.File]::ReadAllLines($DocPath, [Text.Encoding]::UTF8)) {
        if ($l -notmatch '^\|') { continue }
        foreach ($mm in [regex]::Matches($l, '[`]([A-Za-z0-9][A-Za-z0-9_\-\.]*)[`]')) {
            $k = $mm.Groups[1].Value
            if (-not $out.Contains($k)) { $out.Add($k) }
        }
    }
    return $out.ToArray()
}

function New-DocRow {    param($Mod, [string]$ChineseName, [string]$Deps, [string]$Desc, [string]$SideText)
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
    $arr = Repair-DocCounts $work.ToArray() @(Read-DocSections $work.ToArray())

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

# ---------------------------------------------------------------------------
#  pack.toml 与 packwiz
# ---------------------------------------------------------------------------

function Read-PackMeta {
    <#
        读取 pack.toml 的名称与 [versions] 段
        Loaders 为除 minecraft 之外的键, 例如 neoforge / forge / fabric
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$PackDir)

    $meta = [pscustomobject]@{
        Name     = ''
        Minecraft = ''
        Loaders  = @()
        Versions = @{}
    }
    $path = Join-Path $PackDir 'pack.toml'
    if (-not (Test-Path $path)) { return $meta }

    $section = ''
    $loaders = New-Object System.Collections.Generic.List[string]
    foreach ($l in [IO.File]::ReadAllLines($path, [Text.Encoding]::UTF8)) {
        if ($l -match '^\s*\[(.+?)\]\s*$') { $section = $Matches[1].Trim(); continue }
        if ($l -match '^\s*([A-Za-z0-9_\-]+)\s*=\s*"(.*)"\s*$') {
            $k = $Matches[1]; $v = $Matches[2]
            if ($section -eq '' -and $k -eq 'name') { $meta.Name = $v }
            if ($section -eq 'versions') {
                $meta.Versions[$k] = $v
                if ($k -eq 'minecraft') { $meta.Minecraft = $v }
                else { $loaders.Add($k) }
            }
        }
    }
    $meta.Loaders = $loaders.ToArray()
    return $meta
}

function Resolve-Packwiz {
    <#
        依次尝试: 参数 -> 缓存目录 -> PATH
        返回可执行文件路径, 找不到返回 $null
    #>
    [CmdletBinding()]
    param([string]$Explicit)

    foreach ($c in @($Explicit, (Join-Path $env:LOCALAPPDATA 'CocoPackwiz\meta\packwiz.exe'))) {
        if ($c -and (Test-Path $c)) { return $c }
    }
    $cmd = Get-Command packwiz -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    return $null
}

function Get-MrProjectVersions {
    <#
        查询项目版本; 传入 Loaders 与 GameVersions 时按 facets 过滤
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Id,
        [string[]]$Loaders,
        [string[]]$GameVersions
    )

    $url = "https://api.modrinth.com/v2/project/$Id/version"
    $q = @()
    if ($Loaders -and $Loaders.Count -gt 0) {
        $q += 'loaders=' + [uri]::EscapeDataString('[' + (($Loaders | ForEach-Object { '"' + $_ + '"' }) -join ',') + ']')
    }
    if ($GameVersions -and $GameVersions.Count -gt 0) {
        $q += 'game_versions=' + [uri]::EscapeDataString('[' + (($GameVersions | ForEach-Object { '"' + $_ + '"' }) -join ',') + ']')
    }
    if ($q.Count -gt 0) { $url += '?' + ($q -join '&') }

    try { return @(Invoke-Api $url) } catch { return @() }
}

function Select-PreferredVersion {
    <#
        从版本列表选出最合适的一个: 优先 release, 其次按发布时间倒序
    #>
    [CmdletBinding()]
    param([object[]]$Versions)

    if (-not $Versions -or $Versions.Count -eq 0) { return $null }
    $sorted = $Versions | Sort-Object -Property @{ Expression = { $_.date_published } } -Descending
    $release = @($sorted | Where-Object { $_.version_type -eq 'release' })
    if ($release.Count -gt 0) { return $release[0] }
    return $sorted[0]
}

function ConvertTo-MrSlug {
    <#
        从 Modrinth 链接或裸 slug/ID 中提取可查询的项目标识
        支持:
          https://modrinth.com/mod/<slug>
          https://modrinth.com/mod/<slug>/version/<vid>
          <slug> 或 <projectId>
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$InputText)

    $text = $InputText.Trim()
    # slug 段只取到下一个 / ? # 为止, 避免把 /version/<vid> 一起带出来
    if ($text -match '^https?://(?:www\.)?modrinth\.com/(?:mod|project|datapack|plugin|shader|resourcepack)/([^/?#]+)') {
        return $Matches[1].Trim()
    }
    return $text
}

function Invoke-ModEntry {
    <#
        交互录入单个模组的清单行

        供 维护模组清单 与 添加模组 共用: 校正 side、取前置、录中文名/分类/功能,
        返回分类与行文本; 新建分类时会向 DocLines 追加空节并回传最新节列表。

        参数
          Mod       Read-PwFile 返回的元数据对象
          Sections  当前文档的节列表
          DocLines  文档行数组, 新建分类时可能被追加
          NoSide    跳过 side 校正
          DryRun    DryRun 时不写 .pw.toml
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Mod,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Sections,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][AllowEmptyString()][string[]]$DocLines,
        [switch]$NoSide,
        [switch]$DryRun
    )

    Head ("[$($Mod.Key)]  " + $(if ($Mod.Name) { $Mod.Name } else { '(无名称)' }))

    $proj = $null
    if ($Mod.MrId) { $proj = Get-MrProject $Mod.MrId }
    if (-not $proj -and $Mod.Key) { $proj = Get-MrProject $Mod.Key }

    $suggest = $null
    if ($proj) {
        Info ("Modrinth: client={0} server={1}" -f $proj.client_side, $proj.server_side)
        $suggest = Get-SuggestedSide $proj
    } else {
        Warn '拿不到 Modrinth 信息, 需要人工判断端'
    }

    $finalSide = $Mod.Side
    $sideChanged = $false
    if (-not $NoSide) {
        $want = if ($suggest) { $suggest } else { $Mod.Side }
        if ($suggest -and $suggest -ne $Mod.Side) {
            $ans = Read-Host ("  当前 side={0}, 按 API 建议改为 {1}? [Y/n]" -f $Mod.Side, $suggest)
            if (-not $ans -or $ans -match '^[Yy]') { $want = $suggest }
            else { $want = Read-Host '  那你要设成什么 (client/server/both)' }
        }
        $want = $want.Trim().ToLower()
        if ($want -notin @('client', 'server', 'both')) { $want = $Mod.Side }
        if ($want -and $want -ne $Mod.Side) {
            if (Set-PwSide $Mod.Path $want -DryRun:$DryRun) { $sideChanged = $true; $finalSide = $want; Ok "side 已改为 $want" }
        }
    }

    $deps = @()
    if ($Mod.MrVersion) { $deps = Get-RequiredDeps $Mod }
    $depText = if ($deps.Count -gt 0) { ($deps -join '、') } else { '' }
    if ($depText) { Info "前置(Modrinth required): $depText" } else { Info '前置: 未取到, 可留空' }
    $depInput = Read-Host ("  前置 [回车沿用: {0}]" -f $(if ($depText) { $depText } else { '—' }))
    if ($depInput) { $depText = $depInput }

    $cnFull = if ($Mod.Name) { $Mod.Name } else { $Mod.Key }
    $cn = Read-Host ("  中文名 [回车留空, 英文名会自动带上: {0}]" -f $cnFull)

    Say ''
    Say '  选择分类 (顺序取自清单文档, 括号内为现有条目数):'
    for ($k = 0; $k -lt $Sections.Count; $k++) {
        $sc = $Sections[$k]
        $cnt = if ($sc.RowStart -ge 0) { $sc.RowEnd - $sc.RowStart + 1 } else { 0 }
        Say ("    {0,2}. {1} ({2})" -f ($k + 1), $sc.Title, $cnt)
    }
    Say ("    {0,2}. 新建分类" -f ($Sections.Count + 1))
    $pick = Read-Host '  序号'
    if (-not $pick) { $pick = '1' }

    $cat = $null
    $lines = @($DocLines)
    if ($pick -match '^\d+$' -and [int]$pick -ge 1 -and [int]$pick -le $Sections.Count) {
        $cat = $Sections[[int]$pick - 1].Title
    } else {
        $cat = Read-Host '  新分类名称'
        if (-not $cat) { $cat = '未分类' }
        $lines = $lines + @('', ('### ' + $cat), '')
    }

    $desc = Read-Host '  功能描述 (一句话)'

    $row = New-DocRow $Mod $cn $depText $desc (Get-SideText $finalSide $false)
    Ok "已加入分类: $cat"

    return [pscustomobject]@{
        Category    = $cat
        Row         = $row
        DocLines    = $lines
        Side        = $finalSide
        SideChanged = $sideChanged
    }
}

# ---------------------------------------------------------------------------
#  别名表: 中文名 -> slug
# ---------------------------------------------------------------------------

function Get-AliasPath {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$PackDir)
    return (Join-Path $PackDir '别名表.cfg')
}

function Read-AliasTable {
    <#
        读取别名表, 返回 @{ Alias; Slug; Source } 数组
        文件不存在时返回空数组
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$PackDir)

    $out = New-Object System.Collections.Generic.List[object]
    $path = Get-AliasPath $PackDir
    if (-not (Test-Path $path)) { return $out.ToArray() }
    foreach ($line in [IO.File]::ReadAllLines($path, [Text.Encoding]::UTF8)) {
        if ($line -match '^\s*#' -or $line.Trim() -eq '') { continue }
        $parts = $line -split "`t"
        if ($parts.Count -lt 2) { continue }
        $out.Add([pscustomobject]@{
            Alias  = $parts[0].Trim()
            Slug   = $parts[1].Trim()
            Source = if ($parts.Count -ge 3) { $parts[2].Trim() } else { 'manual' }
        })
    }
    return $out.ToArray()
}

function Save-AliasTable {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$PackDir,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Entries
    )

    $sorted = @($Entries | Sort-Object -Property Slug, Alias)
    $lines = @(
        '# Coco 整合包别名表: 中文名 -> slug',
        '# 格式: 中文名 <TAB> slug <TAB> 来源',
        '# 来源取值: doc(清单文档导入) / mcmod(百科查询) / manual(手工录入)',
        '# 由 维护别名表.bat 生成并合并, 不入库; 以清单文档为准, 手工条目会被保留',
        ''
    )
    foreach ($e in $sorted) { $lines += ("{0}`t{1}`t{2}" -f $e.Alias, $e.Slug, $e.Source) }
    [IO.File]::WriteAllText((Get-AliasPath $PackDir), ($lines -join "`r`n"), (New-Object Text.UTF8Encoding($false)))
    return $sorted.Count
}

function Update-AliasTableFromDoc {
    <#
        从清单文档提取中文名并合并进别名表

        提取方式: 行标签形如 **中文 English**, 用元数据里的 name 作为英文锚点剥掉,
        剩余含中文的部分即别名; 剥不出中文的行跳过。

        合并策略: doc 来源整体刷新; mcmod 与 manual 来源原样保留。
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$PackDir,
        [string]$DocPath
    )

    if (-not $DocPath) { $DocPath = Join-Path $PackDir '模组列表介绍.md' }
    $stats = [pscustomobject]@{ Total = 0; FromDoc = 0; Kept = 0; Added = 0; Skipped = 0 }

    if (-not (Test-Path $DocPath)) { return $stats }

    $kept = @(Read-AliasTable $PackDir | Where-Object { $_.Source -ne 'doc' })
    $existingDoc = @(Read-AliasTable $PackDir | Where-Object { $_.Source -eq 'doc' })
    $existingKeys = @{}
    foreach ($e in $existingDoc) { $existingKeys["$($e.Alias)`t$($e.Slug)"] = $true }

    $fresh = New-Object System.Collections.Generic.List[object]
    $seen = @{}
    foreach ($line in [IO.File]::ReadAllLines($DocPath, [Text.Encoding]::UTF8)) {
        if ($line -notmatch '^\|') { continue }
        if ($line -notmatch '\*\*(.+?)\*\*') { continue }
        $label = $Matches[1].Trim()
        if ($label -notmatch '[\u4e00-\u9fa5]') { continue }
        $slug = ''
        if ($line -match '[`]([A-Za-z0-9][A-Za-z0-9_\-\.]*)[`]') { $slug = $Matches[1] }
        if (-not $slug) { $stats.Skipped++; continue }

        $pwPath = Join-Path (Join-Path $PackDir 'mods') "$slug.pw.toml"
        $enName = ''
        if (Test-Path $pwPath) { $enName = (Read-PwFile $pwPath).Name }

        $alias = $label
        if ($enName -and $alias.Contains($enName)) {
            # 首选: 用元数据里的英文名做锚点精确剥离
            $alias = $alias.Replace($enName, '')
        } else {
            # 兜底: 无元数据时只保留含中文的词, 避免把英文名写进别名
            $tokens = @($alias -split '\s+' | Where-Object { $_ -match '[\u4e00-\u9fa5]' })
            if ($tokens.Count -gt 0) { $alias = ($tokens -join ' ') }
        }
        $alias = $alias -replace '^[A-Za-z0-9_\-\.]+', '' -replace '[A-Za-z0-9_\-\.]+$', ''
        $alias = $alias.Trim().Trim([char[]]@(' ', '·', '-', '_', '：', ':', '/', '|', '(', ')', '（', '）'))
        if ($alias -match '[\u4e00-\u9fa5]' -eq $false) { $stats.Skipped++; continue }

        $key = "$alias`t$slug"
        if ($seen.ContainsKey($key)) { continue }
        $seen[$key] = $true
        $fresh.Add([pscustomobject]@{ Alias = $alias; Slug = $slug; Source = 'doc' })
        if (-not $existingKeys.ContainsKey($key)) { $stats.Added++ }
    }

    $merged = @($kept) + @($fresh.ToArray())
    $stats.FromDoc = $fresh.Count
    $stats.Kept = $kept.Count
    $stats.Total = $merged.Count
    [void](Save-AliasTable -PackDir $PackDir -Entries $merged)
    return $stats
}

function Resolve-Alias {
    <#
        按中文名查 slug; 精确匹配优先, 其次忽略大小写的包含匹配(唯一命中才算)
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$PackDir,
        [Parameter(Mandatory = $true)][string]$Text
    )

    $table = @(Read-AliasTable $PackDir)
    if ($table.Count -eq 0) { return $null }
    $q = $Text.Trim()
    $exact = @($table | Where-Object { $_.Alias -eq $q })
    if ($exact.Count -ge 1) { return $exact[0].Slug }
    $loose = @($table | Where-Object { $_.Alias -like "*$q*" -or $q -like "*$($_.Alias)*" })
    if ($loose.Count -eq 1) { return $loose[0].Slug }
    return $null
}

# ---------------------------------------------------------------------------
#  基线: HEAD 里的清单文档
# ---------------------------------------------------------------------------

function Get-SlugsFromLines {
    <#
        从文档行数组中提取表格行的 slug(去重, 保持出现顺序)
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][AllowEmptyCollection()][AllowEmptyString()][string[]]$Lines)

    $out = New-Object System.Collections.Generic.List[string]
    foreach ($l in $Lines) {
        if ($l -notmatch '^\|') { continue }
        foreach ($mm in [regex]::Matches($l, '[`]([A-Za-z0-9][A-Za-z0-9_\-\.]*)[`]')) {
            $k = $mm.Groups[1].Value
            if (-not $out.Contains($k)) { $out.Add($k) }
        }
    }
    return $out.ToArray()
}

function Get-BaselineDocSlugs {
    <#
        读取 HEAD 版本清单文档中的 slug 集合, 作为删除判定的基线

        返回对象:
          Ok     是否取到基线(仓库无提交或文档未跟踪时为 false)
          Slugs  基线 slug 数组
          Reason 失败原因, 用于输出
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$PackDir,
        [Parameter(Mandatory = $true)][string]$DocPath
    )

    $result = [pscustomobject]@{ Ok = $false; Slugs = @(); Reason = '' }
    $rel = [IO.Path]::GetFileName($DocPath)

    $prev = $ErrorActionPreference
    $prevOut = [Console]::OutputEncoding
    $ErrorActionPreference = 'Continue'
    try {
        [Console]::OutputEncoding = [Text.Encoding]::UTF8
        $raw = & git -C $PackDir show "HEAD:$rel" 2>&1
        $code = $LASTEXITCODE
    } finally {
        [Console]::OutputEncoding = $prevOut
        $ErrorActionPreference = $prev
    }

    if ($code -ne 0) {
        $first = @($raw | Where-Object { "$_" -match '\S' } | Select-Object -First 1)
        $result.Reason = if ($first) { "$first".Trim() } else { 'git show 失败' }
        return $result
    }
    $lines = @(($raw | ForEach-Object { "$_" }))
    $result.Slugs = @(Get-SlugsFromLines -Lines $lines)
    $result.Ok = $true
    return $result
}

# ---------------------------------------------------------------------------
#  录入: 调用 packwiz 写入单个项目
# ---------------------------------------------------------------------------

function Invoke-PackwizAdd {
    <#
        调用 packwiz modrinth add 录入指定项目与版本
        直连失败且错误看起来是网络问题时, 临时挂本机代理重试一次
        返回 @{ Ok; Out; Code }
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$PackDir,
        [Parameter(Mandatory = $true)][string]$ProjectId,
        [Parameter(Mandatory = $true)][string]$VersionId
    )

    $packwiz = Resolve-Packwiz
    if (-not $packwiz) {
        return [pscustomobject]@{ Ok = $false; Out = '找不到 packwiz.exe'; Code = -1 }
    }

    $pwArgs = @('modrinth','add','--project-id',$ProjectId,'--version-id',$VersionId,'-y')
    Push-Location $PackDir
    $prevHttps = $env:HTTPS_PROXY
    $prevHttp  = $env:HTTP_PROXY
    try {
        $out = & $packwiz @pwArgs 2>&1
        $code = $LASTEXITCODE
        if ($code -ne 0) {
            $joined = (($out | ForEach-Object { "$_" }) -join ' ')
            if ($joined -match 'proxy|connect|timeout|dial|network') {
                $env:HTTPS_PROXY = 'http://127.0.0.1:7890'
                $env:HTTP_PROXY  = 'http://127.0.0.1:7890'
                $out = & $packwiz @pwArgs 2>&1
                $code = $LASTEXITCODE
            }
        }
    } finally {
        $env:HTTPS_PROXY = $prevHttps
        $env:HTTP_PROXY  = $prevHttp
        Pop-Location
    }

    return [pscustomobject]@{
        Ok   = ($code -eq 0)
        Out  = (($out | ForEach-Object { "$_" }) -join "`n")
        Code = $code
    }
}

# ---------------------------------------------------------------------------
#  删除元数据: 确认 -> 备份 -> 移除 -> 刷新 -> 重算计数
# ---------------------------------------------------------------------------

function Invoke-MetadataRemove {
    <#
        移除一批模组的元数据

        供 维护模组清单 与 删除模组 共用: 确认、备份、packwiz remove、刷新索引与重算计数
        都在这里完成, 避免两处实现分叉。

        参数
          PackDir  包目录
          Targets  Read-PwFile 返回的元数据对象数组
          DocPath  清单文档路径, 删除后重算计数
          DryRun   只打印计划

        返回
          Removed    成功移除数
          Failed     失败数
          BackupDir  备份目录(未确认或 DryRun 时为空)
          DocLines   处理后的文档行
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$PackDir,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Targets,
        [string]$DocPath,
        [switch]$DryRun
    )

    $result = [pscustomobject]@{ Removed = 0; Failed = 0; BackupDir = ''; DocLines = @() }
    if ($Targets.Count -eq 0) { return $result }
    if (-not $DocPath) { $DocPath = Join-Path $PackDir '模组列表介绍.md' }

    if ($DryRun) {
        Say '  将删除以下模组的元数据:'
        foreach ($m in $Targets) { Say ("    - {0}  ({1})" -f $m.Key, $m.Name) }
        Warn 'DryRun: 不执行删除'
        return $result
    }

    Say '  将删除以下模组的元数据:'
    foreach ($m in $Targets) { Say ("    - {0}  ({1})  -> mods/{2}" -f $m.Key, $m.Name, (Split-Path $m.Path -Leaf)) }
    Say  '  删除前会自动备份到缓存目录'

    $ans = Read-Host '  确认删除吗 [y/N]'
    if (-not $ans -or $ans -notmatch '^[Yy]') {
        Info '未确认, 未做任何改动'
        return $result
    }

    # 确认后才备份, 选 N 时不留下痕迹
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $backupRoot = Join-Path $env:LOCALAPPDATA 'CocoPackwiz\backup'
    $backupDir = Join-Path $backupRoot "删除-$stamp"
    New-Item -ItemType Directory -Force -Path $backupDir | Out-Null
    $manifest = @(
        "# 删除备份 $stamp",
        "# 包目录 $PackDir",
        "# 格式: slug <TAB> 名称 <TAB> 文件名",
        ''
    )
    foreach ($m in $Targets) {
        Copy-Item -LiteralPath $m.Path -Destination (Join-Path $backupDir (Split-Path $m.Path -Leaf)) -Force
        $manifest += ("{0}`t{1}`t{2}" -f $m.Key, $m.Name, $m.Filename)
    }
    [IO.File]::WriteAllText((Join-Path $backupDir '清单.txt'), ($manifest -join "`r`n"), (New-Object Text.UTF8Encoding($false)))
    Info "备份目录 $backupDir ($($Targets.Count) 个文件)"
    $result.BackupDir = $backupDir

    $packwiz = Resolve-Packwiz
    $removed = 0
    $failed = 0
    foreach ($m in $Targets) {
        $okDel = $false
        if ($packwiz) {
            Push-Location $PackDir
            [void](& $packwiz remove $m.Key 2>&1)
            if ($LASTEXITCODE -eq 0) { $okDel = $true }
            Pop-Location
        }
        if (-not $okDel) {
            # 缺少 packwiz 或 remove 失败时退化为直接删文件
            Remove-Item -LiteralPath $m.Path -Force -ErrorAction SilentlyContinue
            $okDel = -not (Test-Path $m.Path)
        }
        if ($okDel) { $removed++; Ok "已删除 $($m.Key)" } else { $failed++; Warn "删除失败 $($m.Key)" }
    }

    if (-not $packwiz -and $removed -gt 0) {
        $pwz = Resolve-Packwiz
        if ($pwz) { Push-Location $PackDir; [void](& $pwz refresh 2>&1); Pop-Location }
    }

    # 文档计数可能因手工删行而失真, 统一重算并写回
    $docNow = [IO.File]::ReadAllText($DocPath, [Text.Encoding]::UTF8) -split "`r?`n"
    $fixed = Repair-DocCounts $docNow @(Read-DocSections $docNow)
    [IO.File]::WriteAllText($DocPath, ($fixed -join "`r`n"), (New-Object Text.UTF8Encoding($false)))

    $result.Removed = $removed
    $result.Failed = $failed
    $result.DocLines = $fixed
    Ok "已删除 $removed 个模组的元数据"
    return $result
}

function Get-MrSearch {
    <#
        按关键词搜索 Modrinth, 并按包设定的加载器与游戏版本过滤

        过滤使用 facets: 外层数组为 AND, 内层数组为 OR
        例如 [["categories:neoforge"],["versions:1.21.1"]]

        返回 search 响应对象(hits / total_hits), 失败返回 $null
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Query,
        [string[]]$Loaders,
        [string[]]$GameVersions,
        [int]$Limit = 10,
        # 项目类型, 默认只搜模组; 整合包/光影/资源包会被排除
        [string[]]$ProjectTypes = @('mod')
    )

    $parts = @()
    if ($ProjectTypes -and $ProjectTypes.Count -gt 0) {
        $parts += '[' + (($ProjectTypes | ForEach-Object { '"project_type:' + $_ + '"' }) -join ',') + ']'
    }
    if ($Loaders -and $Loaders.Count -gt 0) {
        $parts += '[' + (($Loaders | ForEach-Object { '"categories:' + $_ + '"' }) -join ',') + ']'
    }
    if ($GameVersions -and $GameVersions.Count -gt 0) {
        $parts += '[' + (($GameVersions | ForEach-Object { '"versions:' + $_ + '"' }) -join ',') + ']'
    }
    $facets = '[' + ($parts -join ',') + ']'

    $url = 'https://api.modrinth.com/v2/search?limit=' + $Limit +
           '&index=relevance' +
           '&query=' + [uri]::EscapeDataString($Query)
    if ($parts.Count -gt 0) { $url += '&facets=' + [uri]::EscapeDataString($facets) }

    try { return (Invoke-Api $url) } catch { return $null }
}

function Format-Count {
    <#
        下载量等数字加千分位
    #>
    [CmdletBinding()]
    param($Value)
    if ($null -eq $Value) { return '0' }
    return ('{0:N0}' -f [int64]$Value)
}

function Get-AliasSuggestions {
    <#
        按片段相似度从别名表里找相近条目

        用于中文关键词搜不到时给提示: 取与查询共有的两字片段
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$PackDir,
        [Parameter(Mandatory = $true)][string]$Text,
        [int]$Max = 5
    )

    $table = @(Read-AliasTable $PackDir)
    if ($table.Count -eq 0) { return @() }
    $q = $Text.Trim()
    if ($q.Length -lt 2) { return @() }

    $grams = @()
    for ($i = 0; $i -le $q.Length - 2; $i++) { $grams += $q.Substring($i, 2) }

    $hits = @()
    foreach ($e in $table) {
        # 双向匹配: 别名含查询片段, 或查询里含别名(如 钠盐 里含 钠)
        if ($e.Alias.Contains($q) -or $q.Contains($e.Alias)) { $hits += $e; continue }
        foreach ($g in $grams) {
            if ($e.Alias.Contains($g)) { $hits += $e; break }
        }
    }
    return @($hits | Select-Object -First $Max)
}

function Get-CjkGrams {
    <#
        取中文查询的两字片段, 用于降级搜索
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Text, [int]$Max = 3)

    $grams = New-Object System.Collections.Generic.List[string]
    for ($i = 0; $i -le $Text.Length - 2; $i++) {
        $g = $Text.Substring($i, 2)
        if (-not $grams.Contains($g)) { $grams.Add($g) }
    }
    return @($grams | Select-Object -First $Max)
}

function Get-RequiredDepProjects {
    <#
        取某个版本声明的必需前置项目

        返回 @{ Id; Slug; Title }, 已按项目去重; 取不到时返回空数组
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$VersionId)

    $ver = Get-MrVersion $VersionId
    if (-not $ver -or -not $ver.dependencies) { return @() }

    $ids = New-Object System.Collections.Generic.List[string]
    foreach ($d in $ver.dependencies) {
        if ($d.dependency_type -ne 'required') { continue }
        if (-not $d.project_id) { continue }
        if (-not $ids.Contains([string]$d.project_id)) { $ids.Add([string]$d.project_id) }
    }
    if ($ids.Count -eq 0) { return @() }

    $out = New-Object System.Collections.Generic.List[object]
    foreach ($id in $ids) {
        $proj = Get-MrProject -IdOrSlug $id
        if ($proj) {
            $out.Add([pscustomobject]@{ Id = [string]$proj.id; Slug = [string]$proj.slug; Title = [string]$proj.title })
        } else {
            $out.Add([pscustomobject]@{ Id = $id; Slug = $id; Title = $id })
        }
    }
    return $out.ToArray()
}
