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
    packwiz 包目录, 依次取 -PackDir / 环境变量 COCO_PACK_DIR / 工具配置.cfg / 自动探测

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
    [switch]$All,

    [switch]$NoPrune
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::GetEncoding(936)
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$ToolHome = $PSScriptRoot
. (Join-Path $ToolHome '工具配置.ps1')


# 领域函数见 工具函数.ps1, 路径与远端解析见 工具配置.ps1
. (Join-Path $ToolHome '工具函数.ps1')

# ---------------------------------------------------------------------------
#  主流程
# ---------------------------------------------------------------------------
Say ''
Say '=========================================================='
Say '  Coco 整合包 · 模组清单同步工具'
Say '=========================================================='
Say '  作用: 同步清单与 mods/ 元数据, 校正 side, 补录新条目, 清理失效条目'
Say '  只读模式加 -DryRun; 跳过 side 校正加 -NoSide'
Say ''

# 1) 定位包目录: 命令行 -> 环境变量 COCO_PACK_DIR -> 工具配置.cfg -> 自动探测 -> 手工输入
try {
    $PackDir = Resolve-PackDir -ToolRoot $ToolHome -CliValue $PackDir -NonInteractive:([bool]$All)
} catch {
    Fail $_.Exception.Message
    exit 1
}
if (-not $DocPath) { $DocPath = Join-Path $PackDir '模组列表介绍.md' }
if (-not (Test-Path $DocPath)) {
    $allMods = @(Get-ChildItem (Join-Path $PackDir 'mods') -Filter '*.pw.toml' | ForEach-Object { Read-PwFile $_.FullName } | Sort-Object Key)
    Head '清单文档不存在'
    Info "路径 $DocPath"
    Say  ("  将按 mods/ 现有的 {0} 个模组生成空白骨架: 每条含名称、slug、jar 与安装端," -f $allMods.Count)
    Say  '  前置与功能留空, 分类统一为「未分类」, 之后可自行拆分'
    if ($DryRun) {
        Warn 'DryRun, 未生成文档'
        exit 0
    }
    $go = $true
    if (-not $All) {
        $ans = Read-Host '  现在生成吗 [Y/n]'
        if ($ans -and $ans -notmatch '^[Yy]') { Info '已取消'; exit 1 }
    }
    if (-not $allMods.Count) { Fail 'mods 目录里没有 .pw.toml, 无法生成骨架'; exit 1 }
    [void](New-DocSkeleton -PackDir $PackDir -DocPath $DocPath -Mods $allMods)
    Ok "已生成 $DocPath"
    Say ''
}
Info "脚本位置 $PSScriptRoot"
Info "包目录   $PackDir"
Info "清单     $DocPath"
if (Test-Path (Join-Path $PSScriptRoot 'pack.toml')) {
    Warn '这份工具被放进了包目录本身, 建议改从 dev 分支的工作区运行'
}
if ($PSScriptRoot -eq $PackDir) {
    Warn '脚本目录与包目录相同, 工具不属于 main 分支, 请从 Desktop\CocoModPack-dev 运行'
}
if ($DryRun) { Warn 'DryRun 模式, 不会写入任何文件' }

# 2) 读元数据与文档
$mods = @(Get-ChildItem (Join-Path $PackDir 'mods') -Filter '*.pw.toml' | ForEach-Object { Read-PwFile $_.FullName } | Sort-Object Key)
$docLines = [IO.File]::ReadAllText($DocPath, [Text.Encoding]::UTF8) -split "`r?`n"
$sections = @(Read-DocSections $docLines)
$docKeys = @(Get-DocSlugs -DocPath $DocPath)
Info ("元数据 {0} 个, 文档记录 {1} 个" -f $mods.Count, $docKeys.Count)

# 2.5) 文档里存在、但元数据已没有的条目
$modKeys = @($mods | ForEach-Object { $_.Key })
$stale = @()
foreach ($l in $docLines) {
    if ($l -notmatch '^\|\s*\*\*') { continue }
    foreach ($mm in [regex]::Matches($l, '[`]([A-Za-z0-9][A-Za-z0-9_\-\.]*)[`]')) {
        $k = $mm.Groups[1].Value
        if ($modKeys -notcontains $k -and $stale -notcontains $k) { $stale += $k }
    }
}
if ($stale.Count -gt 0) {
    Head "文档里有 $($stale.Count) 个条目在 mods/ 中已不存在"
    foreach ($k in $stale) { Say "  - $k" }
    $doPrune = -not $NoPrune
    if ($doPrune) {
        $ans = Read-Host '  删除这些行吗 (packwiz remove 之后通常选 Y) [Y/n]'
        if ($ans -and $ans -notmatch '^[Yy]') { $doPrune = $false }
    }
    if ($doPrune) {
        $keep = New-Object System.Collections.Generic.List[string]
        foreach ($l in $docLines) {
            $drop = $false
            if ($l -match '^\|\s*\*\*') {
                foreach ($mm in [regex]::Matches($l, '[`]([A-Za-z0-9][A-Za-z0-9_\-\.]*)[`]')) {
                    if ($stale -contains $mm.Groups[1].Value) { $drop = $true }
                }
            }
            if (-not $drop) { $keep.Add($l) }
        }
        $docLines = $keep.ToArray()
        $sections = @(Read-DocSections $docLines)
        if (-not $DryRun) {
            $fixed = Repair-DocCounts $docLines $sections
            [IO.File]::WriteAllText($DocPath, ($fixed -join "`r`n"), $Utf8NoBom)
            $docLines = $fixed
            Ok "已删除 $($stale.Count) 个失效条目并重算计数"
        } else { Warn 'DryRun, 未删除' }
    } else { Info '保留这些行 (可加 -NoPrune 静默跳过)' }
}

# 2.6) 同步已有行的 jar 文件名与端 (模组升级后版本号会变)
$modMap = @{}
foreach ($m in $mods) { $modMap[$m.Key] = $m }
$synced = 0
$newLines = New-Object System.Collections.Generic.List[string]
foreach ($l in $docLines) {
    if ($l -notmatch '^\|\s*\*\*') { $newLines.Add($l); continue }
    $cells = ($l -split '\|'); $cells = $cells[1..($cells.Count - 2)] | ForEach-Object { $_.Trim() }
    if ($cells.Count -lt 6) { $newLines.Add($l); continue }
    $slugCell = $cells[1]
    if ($slugCell -notmatch '[`]([A-Za-z0-9][A-Za-z0-9_\-\.]*)[`]') { $newLines.Add($l); continue }
    $key = $Matches[1]
    if (-not $modMap.ContainsKey($key)) { $newLines.Add($l); continue }
    $m = $modMap[$key]
    $isDisabled = ($cells[2] -match '^disabled/' -or $cells[5] -match '已禁用')
    $newJar = if ($isDisabled) { 'disabled/' + $m.Filename + '.disabled' } else { $m.Filename }
    $newSide = Get-SideText $m.Side $isDisabled
    if ($cells[2] -ne $newJar -or $cells[5] -ne $newSide) {
        $newLines.Add(('| {0} | {1} | {2} | {3} | {4} | {5} |' -f $cells[0], $cells[1], $newJar, $cells[3], $cells[4], $newSide))
        $synced++
    } else { $newLines.Add($l) }
}
if ($synced -gt 0) {
    Info "同步 $synced 行的 jar 文件名与安装端 (按元数据)"
    $docLines = $newLines.ToArray()
    if (-not $DryRun) {
        $fixed = Repair-DocCounts $docLines @(Read-DocSections $docLines)
        [IO.File]::WriteAllText($DocPath, ($fixed -join "`r`n"), $Utf8NoBom)
        $docLines = $fixed
    }
} else { Info '已有条目的 jar 文件名与端均与元数据一致' }

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
if ($DryRun) {
    Info 'DryRun 结束, 未进入交互, 也未写入任何文件'
    exit 0
}
if (-not $All) {
    $go = Read-Host '  现在逐个处理吗 [Y/n]'
    if ($go -and $go -notmatch '^[Yy]') { Info '已取消'; exit 0 }
}

# 4) 逐个处理: 单条录入逻辑见 工具函数.ps1 的 Invoke-ModEntry
$newRows = @{}
$sideChanged = 0
foreach ($m in $newMods) {
    $entry = Invoke-ModEntry -Mod $m -Sections $sections -DocLines $docLines -NoSide:$NoSide -DryRun:$DryRun
    $docLines = $entry.DocLines
    if ($entry.SideChanged) { $sideChanged++ }
    if (-not $newRows.ContainsKey($entry.Category)) { $newRows[$entry.Category] = @() }
    $newRows[$entry.Category] += $entry.Row
}
if ($sideChanged -gt 0) { $sections = @(Read-DocSections $docLines) }

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
