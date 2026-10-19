#Requires -Version 5.1
<#
.SYNOPSIS
    维护别名表: 中文名 -> slug

.DESCRIPTION
    从清单文档提取中英对照, 生成或更新 别名表.cfg。

    提取方式: 文档行标签形如 **中文 English**, 用 mods/<slug>.pw.toml 里的 name
    作为英文锚点剥掉, 剩余含中文的部分即别名。

    合并策略:
      - doc 来源每次整体刷新
      - mcmod 与 manual 来源原样保留, 不会被覆盖

    别名表位于包目录, 由本工具生成, 不入库; 换机器后重新运行即可。

.PARAMETER PackDir
    packwiz 包目录, 解析顺序与其它工具一致

.PARAMETER DryRun
    只统计与预览, 不写文件
#>
[CmdletBinding()]
param(
    [string]$PackDir,
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::GetEncoding(936)
$ToolHome = $PSScriptRoot
. (Join-Path $ToolHome '工具配置.ps1')
. (Join-Path $ToolHome '工具函数.ps1')

Say ''
Say '=========================================================='
Say '  Coco 整合包 · 别名表'
Say '=========================================================='
Say '  从清单文档提取中文名, 生成 中文名 -> slug 的对照表'
Say ''

try {
    $PackDir = Resolve-PackDir -ToolRoot $ToolHome -CliValue $PackDir -NonInteractive:([bool]$DryRun)
} catch {
    Fail $_.Exception.Message
    exit 1
}
Info "包目录   $PackDir"

$docPath = Join-Path $PackDir '模组列表介绍.md'
if (-not (Test-Path $docPath)) {
    Fail "找不到清单文档 $docPath"
    Say  '  请先运行 维护模组清单.bat 生成或补录清单'
    exit 1
}

$aliasPath = Get-AliasPath $PackDir
$before = @(Read-AliasTable $PackDir).Count

if ($DryRun) {
    Warn 'DryRun 模式: 只统计, 不写文件'
    # 统计需要解析文档, 但不落盘
    $stats = [pscustomobject]@{ Total = 0; FromDoc = 0; Kept = 0; Added = 0; Skipped = 0 }
    $rows = 0
    $withCjk = 0
    foreach ($line in [IO.File]::ReadAllLines($docPath, [Text.Encoding]::UTF8)) {
        if ($line -notmatch '^\|') { continue }
        if ($line -notmatch '\*\*(.+?)\*\*') { continue }
        $rows++
        if ($Matches[1] -match '[\u4e00-\u9fa5]') { $withCjk++ }
    }
    Info "文档表格行 $rows 行, 其中标签含中文 $withCjk 行"
    Info "现有别名表 $before 条"
    Warn 'DryRun 结束, 未写入'
    exit 0
}

$stats = Update-AliasTableFromDoc -PackDir $PackDir -DocPath $docPath

Info "现有别名表   $before 条"
Info "文档提取     $($stats.FromDoc) 条"
Info "保留非 doc   $($stats.Kept) 条(来自 mcmod / manual)"
if ($stats.Added -gt 0) { Ok "新增 $($stats.Added) 条" } else { Info '没有新增条目' }
if ($stats.Skipped -gt 0) { Info "跳过       $($stats.Skipped) 行(标签不含中文或无法定位 slug)" }
Ok "别名表已写入 $aliasPath ($($stats.Total) 条)"

# 抽样展示, 便于确认提取质量
$sample = @(Read-AliasTable $PackDir | Where-Object { $_.Source -eq 'doc' } | Select-Object -First 5)
if ($sample.Count -gt 0) {
    Say ''
    Say '  抽样:'
    foreach ($e in $sample) { Say ("    {0,-24} -> {1}" -f $e.Alias, $e.Slug) }
}

Say ''
Head '用法'
Say  '  添加模组.bat <中文名>   将先查别名表, 命中后按对应 slug 录入'
Say  '  手工补录: 在 别名表.cfg 追加一行, 来源写 manual'
Say ''
Ok '别名表维护结束'
