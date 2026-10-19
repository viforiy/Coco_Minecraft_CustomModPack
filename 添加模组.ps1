#Requires -Version 5.1
<#
.SYNOPSIS
    添加模组: 从 Modrinth 链接或 slug 录入, 写入 mods/<slug>.pw.toml

.DESCRIPTION
    1. 解析输入: 支持项目链接、slug、项目 ID
    2. 校验项目存在, 并检查是否已在包内
    3. 按 pack.toml 的加载器与游戏版本筛选可用版本, 无匹配时列出已有版本
    4. 调用 packwiz 写入元数据并刷新索引
    5. 输出结果与后续动作提示

    packwiz 采用 --project-id 与 --version-id 显式指定, 不使用其搜索模式,
    避免 -y 盲选到不相关项目。

.PARAMETER Target
    项目链接、slug 或项目 ID; 省略时交互输入

.PARAMETER Search
    按关键词搜索候选项目, 结果按包设定的加载器与游戏版本过滤, 选择后录入

.PARAMETER PackDir
    packwiz 包目录, 解析顺序与其它工具一致

.PARAMETER NoPrompt
    装完不询问是否补录, 直接打印待办事项

.PARAMETER DryRun
    只解析与检查, 打印将要执行的 packwiz 命令, 不写任何文件

.PARAMETER Proxy
    HTTP 代理, 例如 http://127.0.0.1:7890; 省略时先直连再试本机 7890
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string]$Target,

    # 按关键词搜索候选, 从结果中选择后录入
    [string]$Search,

    [string]$PackDir,
    [string]$Proxy,

    # 跳过补录询问, 只打印待办
    [switch]$NoPrompt,

    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::GetEncoding(936)
$ToolHome = $PSScriptRoot
. (Join-Path $ToolHome '工具配置.ps1')
. (Join-Path $ToolHome '工具函数.ps1')

Say ''
Say '=========================================================='
Say '  Coco 整合包 · 添加模组'
Say '=========================================================='
Say '  输入 Modrinth 链接、slug 或项目 ID, 按包设定写入元数据'
Say ''

# 1) 包目录与 pack.toml
try {
    $PackDir = Resolve-PackDir -ToolRoot $ToolHome -CliValue $PackDir -NonInteractive:([bool]$DryRun)
} catch {
    Fail $_.Exception.Message
    exit 1
}
$meta = Read-PackMeta -PackDir $PackDir
Info "包目录     $PackDir"
Info "包设定     MC $($meta.Minecraft) / $($meta.Loaders -join ',')"

if (-not $meta.Minecraft -or $meta.Loaders.Count -eq 0) {
    Fail 'pack.toml 缺少 [versions] 配置, 无法确定加载器与游戏版本'
    Say  '  请检查 pack.toml 的 [versions] 段, 至少包含 minecraft 与一个加载器'
    exit 1
}

# 搜索并选择候选: 返回 slug, 取消或失败返回 $null
function Show-Hits {
    param($Hits, [string]$Note)
    Say ''
    for ($i = 0; $i -lt $Hits.Count; $i++) {
        $h = $Hits[$i]
        $inst = ''
        if ($script:installedIds.Contains([string]$h.project_id) -or $script:installedSlugs.Contains([string]$h.slug)) { $inst = '[已装]' }
        $when = ''
        if ($h.date_modified) { $when = ([string]$h.date_modified).Substring(0, 10) }
        Say ("  {0,2}. {1} {2}" -f ($i + 1), $h.title, $inst)
        Say ("      {0,-24} 下载 {1,12}   更新 {2}" -f $h.slug, (Format-Count $h.downloads), $when)
    }
    if ($Note) { Say ("      {0}" -f $Note) }
    Say '   0. 取消'
    Say ''
}

# 搜索并选择候选: 返回 slug; 取消或无结果返回 $null
function Select-Candidate {
    param([string]$Query)

    $script:installedIds = New-Object System.Collections.Generic.List[string]
    $script:installedSlugs = New-Object System.Collections.Generic.List[string]
    foreach ($f in Get-ChildItem -LiteralPath (Join-Path $PackDir 'mods') -Filter '*.pw.toml' -ErrorAction SilentlyContinue) {
        $m0 = Read-PwFile $f.FullName
        if ($m0.MrId) { $script:installedIds.Add($m0.MrId) }
        $script:installedSlugs.Add($m0.Key)
    }

    $hits = @()
    $note = ''

    # 一档: 按包的加载器与游戏版本过滤
    $res = Get-MrSearch -Query $Query -Loaders $meta.Loaders -GameVersions @($meta.Minecraft) -Limit 10
    if ($res -and $res.hits -and $res.hits.Count -gt 0) {
        $hits = @($res.hits)
        Info ("共 {0} 条匹配(已按 MC {1} / {2} 过滤)" -f $res.total_hits, $meta.Minecraft, ($meta.Loaders -join ','))
    } else {
        # 二档: 放宽版本与加载器, 找出「项目存在但版本不适配」的情况
        $res2 = Get-MrSearch -Query $Query -Limit 10
        if ($res2 -and $res2.hits -and $res2.hits.Count -gt 0) {
            $hits = @($res2.hits)
            Warn ("没有适配 MC {0} / {1} 的结果, 以下为全站匹配" -f $meta.Minecraft, ($meta.Loaders -join ','))
            $note = '选择后可能提示无适配版本'
        } else {
            # 三档: 中文按两字片段再试一次
            if ($Query -match '[\u4e00-\u9fa5]') {
                $grams = @(Get-CjkGrams -Text $Query -Max 3)
                foreach ($g in $grams) {
                    $res3 = Get-MrSearch -Query $g -Loaders $meta.Loaders -GameVersions @($meta.Minecraft) -Limit 5
                    if ($res3 -and $res3.hits -and $res3.hits.Count -gt 0) {
                        $hits = @($res3.hits)
                        Warn ("按关键词片段「$g」匹配到以下结果")
                        $note = '片段匹配, 结果可能不相关'
                        break
                    }
                }
            }
        }
    }

    if ($hits.Count -eq 0) {
        Warn "没有匹配「$Query」的项目"
        $sugg = @(Get-AliasSuggestions -PackDir $PackDir -Text $Query)
        if ($sugg.Count -gt 0) {
            Say  '  别名表里有相近的中文名:'
            foreach ($sv in $sugg) { Say ("    {0,-20} -> {1}" -f $sv.Alias, $sv.Slug) }
        }
        Say  '  也可以直接粘贴 Modrinth 链接, 或改用英文关键词(如 create / iris)'
        return $null
    }

    Show-Hits -Hits $hits -Note $note
    $pick = Read-Host '  选择序号'
    if (-not $pick -or $pick -match '^0+$') { Info '已取消, 未做任何改动'; return $null }
    if ($pick -notmatch '^\d+$' -or [int]$pick -lt 1 -or [int]$pick -gt $hits.Count) {
        Fail "无效的序号: $pick"
        return $null
    }
    return [string]$hits[[int]$pick - 1].slug
}
# 2) 输入
$raw = $Target
if (-not $raw) { $raw = Read-Host '  请输入 Modrinth 链接 / slug / 项目 ID / 关键词' }
if (-not $raw) { Fail '未提供输入, 已中止'; exit 1 }

$key = ConvertTo-MrSlug -InputText $raw
$isUrl = $raw -match '^https?://'

# 含中文时先查别名表; 命中即用, 未命中且未指定 -Search 时转按关键词搜索
if (-not $Search -and $raw -match '[\u4e00-\u9fa5]') {
    $hit = Resolve-Alias -PackDir $PackDir -Text $raw
    if ($hit) {
        Info "别名命中   $raw -> $hit"
        $key = $hit
    } else {
        Info "别名表里没有「$raw」, 改为按关键词搜索"
        $Search = $raw
    }
}

# 2.5) 搜索并选择
if ($Search) {
    Head "搜索 $Search"
    $chosen = Select-Candidate -Query $Search
    if (-not $chosen) { exit 0 }
    $key = $chosen
    Info "已选择     $key"
}

Info "解析结果   $key"
# 3) 校验项目
$proj = Get-MrProject -IdOrSlug $key
if (-not $proj) {
    Fail "无法解析项目: $key"
    Say  '  可能原因: slug 拼写错误, 该模组不在 Modrinth, 或网络不可用'
    Say  '  CurseForge 项目将在后续版本支持'
    exit 1
}
Info "项目       $($proj.title)  (slug: $($proj.slug), id: $($proj.id))"
Info "官方标注   client=$($proj.client_side) server=$($proj.server_side)"

# 4) 是否已在包内
$modsDir = Join-Path $PackDir 'mods'
$existing = @()
foreach ($f in Get-ChildItem -LiteralPath $modsDir -Filter '*.pw.toml' -ErrorAction SilentlyContinue) {
    $m = Read-PwFile $f.FullName
    if ($m.MrId -eq $proj.id -or $m.Key -eq $proj.slug) { $existing += $m }
}
if ($existing.Count -gt 0) {
    $hit = $existing[0]
    Warn "已在包内: $($hit.Key)  ($($hit.Filename))"
    Say  '  若要更新版本, 请使用 packwiz update; 若要改 side, 运行 维护模组清单.bat'
    exit 2
}

# 5) 版本筛选
$versions = Get-MrProjectVersions -Id $proj.id -Loaders $meta.Loaders -GameVersions @($meta.Minecraft)
if (-not $versions -or $versions.Count -eq 0) {
    Fail "没有适配 MC $($meta.Minecraft) / $($meta.Loaders -join ',') 的版本"
    $all = Get-MrProjectVersions -Id $proj.id
    if ($all -and $all.Count -gt 0) {
        $gv = @($all | ForEach-Object { $_.game_versions } | Sort-Object -Unique)
        $ld = @($all | ForEach-Object { $_.loaders } | Sort-Object -Unique)
        Say  ("  该项目已有版本支持: MC {0}" -f (($gv | Select-Object -Last 6) -join ', '))
        Say  ("  加载器: {0}" -f ($ld -join ', '))
        Say  '  可选做法: 换用其它模组, 或调整 pack.toml 的版本设定(需评估整体兼容)'
    }
    exit 1
}

$pick = Select-PreferredVersion -Versions $versions
Info ("匹配版本   {0} 个, 选用 {1} ({2}, {3})" -f $versions.Count, $pick.version_number, $pick.version_type, $pick.date_published)

# 6) packwiz
$packwiz = Resolve-Packwiz
if (-not $packwiz) {
    Fail '找不到 packwiz.exe'
    Say  '  请先运行一次客户端更新脚本以下载缓存, 或把 packwiz 放进 PATH'
    exit 1
}
$cmdArgs = @('modrinth','add','--project-id',$proj.id,'--version-id',$pick.id,'-y')

Say ''
Info '将执行    packwiz modrinth add --project-id <id> --version-id <vid> -y'
if ($DryRun) {
    Say ''
    Warn 'DryRun 结束, 未写入任何文件'
    exit 0
}

# 7) 执行
Push-Location $PackDir
$prevProxyHttps = $env:HTTPS_PROXY
$prevProxyHttp  = $env:HTTP_PROXY
try {
    $out = & $packwiz @cmdArgs 2>&1
    $code = $LASTEXITCODE
    if ($code -ne 0) {
        # 网络类失败时挂代理重试一次
        $text = ($out | ForEach-Object { "$_" }) -join "`n"
        if ($text -match 'proxy|connect|timeout|dial|network') {
            Warn '直连失败, 尝试经本机代理重试'
            $env:HTTPS_PROXY = 'http://127.0.0.1:7890'
            $env:HTTP_PROXY  = 'http://127.0.0.1:7890'
            $out = & $packwiz @cmdArgs 2>&1
            $code = $LASTEXITCODE
        }
    }
} finally {
    $env:HTTPS_PROXY = $prevProxyHttps
    $env:HTTP_PROXY  = $prevProxyHttp
    Pop-Location
}

if ($code -ne 0) {
    Fail "packwiz 执行失败 (退出码 $code)"
    $out | ForEach-Object { Say "  $_" }
    exit 1
}

# 8) 结果
$target = Join-Path $modsDir "$($proj.slug).pw.toml"
if (-not (Test-Path $target)) {
    $found = Get-ChildItem -LiteralPath $modsDir -Filter '*.pw.toml' |
        Where-Object { (Read-PwFile $_.FullName).MrId -eq $proj.id } | Select-Object -First 1
    if ($found) { $target = $found.FullName }
}

if (Test-Path $target) {
    $newMod = Read-PwFile $target
    Ok "已写入 $($newMod.Key).pw.toml"
    Say  "  文件名 $($newMod.Filename)"
    Say  "  安装端 $($newMod.Side)"
    $sideText = switch ($newMod.Side) { 'client' { '客户端' } 'server' { '服务端' } default { '双端' } }
    if ($sideText -ne '') { Say  "  提示   packwiz 生成的 side 未必准确, 同步清单时会按官方标注校正" }
} else {
    Warn '未找到新生成的 .pw.toml, 请检查 mods 目录'
    exit 1
}

# 9) 询问是否立即补录: 直接调用共用函数, 不再起子进程
Say ''
$docPath = Join-Path $PackDir '模组列表介绍.md'
$doRecord = $false

if (-not (Test-Path $docPath)) {
    Warn '未找到清单文档, 跳过补录'
} elseif ($NoPrompt) {
    Info '已指定 -NoPrompt, 跳过补录询问'
} else {
    $ans = Read-Host '  现在补录到清单文档吗 [Y/n]'
    if (-not $ans -or $ans -match '^[Yy]') { $doRecord = $true }
}

if ($doRecord) {
    Head '补录清单'
    $docLines = [IO.File]::ReadAllText($docPath, [Text.Encoding]::UTF8) -split "`r?`n"
    $sections = @(Read-DocSections $docLines)
    $entry = Invoke-ModEntry -Mod $newMod -Sections $sections -DocLines $docLines
    $rows = @{}
    $rows[$entry.Category] = @($entry.Row)
    [void](Save-DocWithRows $docPath $entry.DocLines $sections $rows)
    if ($entry.DocLines.Count -ne $docLines.Count) {
        # 新建了分类, 节列表已变, 保存时按最新节重算
        $sections2 = @(Read-DocSections $entry.DocLines)
        [void](Save-DocWithRows $docPath $entry.DocLines $sections2 $rows)
    }
    Ok '补录完成'
} else {
    Say ''
    Say  "[待办] 已安装 $($proj.slug), 但尚未写入清单"
    Say  '       运行 维护模组清单.bat 补录, 或在 开发工具.bat 里选 3'
    Say  '       未补录时文档与 mods/ 不一致, 推送前的一致性校验会拦截'
}

Say ''
Head '下一步'
if ($doRecord) {
    Say  '  运行 推送元数据.bat 提交推送, 或在 开发工具.bat 里选 4'
} else {
    Say  '  1. 运行 维护模组清单.bat 补录清单文档'
    Say  '  2. 运行 推送元数据.bat 提交推送'
}
Say ''
Ok '添加流程结束'
