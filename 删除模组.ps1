#Requires -Version 5.1
<#
.SYNOPSIS
    删除模组: 从清单文档移除对应行, 并移除其元数据

.DESCRIPTION
    以清单文档为权威, 本工具只是把「删行」这一步自动化:

      1. 解析输入(中文名 / slug / 项目链接)
      2. 在清单文档中定位该模组的表格行
      3. 删除该行并重算所属分类的计数
      4. 调用共用函数移除元数据: 确认 -> 备份 -> packwiz remove -> 刷新索引

    确认环节仍在共用函数内, 默认 N, 因此不存在误操作即删除的可能。

.PARAMETER Target
    中文名、slug 或 Modrinth 链接; 省略时交互输入

.PARAMETER PackDir
    packwiz 包目录, 解析顺序与其它工具一致

.PARAMETER DryRun
    只显示将删除的行与元数据, 不做任何改动
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string]$Target,

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
Say '  Coco 整合包 · 删除模组'
Say '=========================================================='
Say '  从清单文档移除该模组的行, 并移除其元数据'
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
    exit 1
}

# 输入解析: 中文名走别名表, 链接取 slug
$raw = $Target
if (-not $raw) { $raw = Read-Host '  请输入要删除的模组(中文名 / slug / 链接)' }
if (-not $raw) { Fail '未提供输入, 已中止'; exit 1 }

$key = ConvertTo-MrSlug -InputText $raw
if ($raw -match '[\u4e00-\u9fa5]') {
    $hit = Resolve-Alias -PackDir $PackDir -Text $raw
    if ($hit) {
        Info "别名命中   $raw -> $hit"
        $key = $hit
    } else {
        Fail "别名表里没有「$raw」"
        Say  '  可改用 slug, 或在 别名表.cfg 追加一行后重试'
        exit 1
    }
}
Info "目标模组   $key"

# 定位文档行
$docLines = [IO.File]::ReadAllText($docPath, [Text.Encoding]::UTF8) -split "`r?`n"
$hitIndex = -1
for ($i = 0; $i -lt $docLines.Count; $i++) {
    if ($docLines[$i] -notmatch '^\|') { continue }
    if ($docLines[$i] -match ('`' + [regex]::Escape($key) + '`')) { $hitIndex = $i; break }
}
if ($hitIndex -lt 0) {
    Warn "清单文档里没有 $key 这一行, 无需删除"
    Say  '  若只想移除元数据, 直接运行 packwiz remove; 若要清理失效行, 运行 维护模组清单.bat'
    exit 2
}

# 元数据是否存在
$pwPath = Join-Path (Join-Path $PackDir 'mods') "$key.pw.toml"
$mod = $null
if (Test-Path $pwPath) { $mod = Read-PwFile $pwPath }
if (-not $mod) {
    Warn "mods/ 下没有 $key.pw.toml, 只会删除文档行"
}

$rowText = $docLines[$hitIndex]
Info "文档行     $rowText"

if ($DryRun) {
    Say ''
    Warn 'DryRun: 只显示计划, 不做改动'
    if ($mod) {
        Say ("  将删除文档行与元数据: {0}  ({1})" -f $mod.Key, $mod.Name)
    } else {
        Say '  将只删除文档行(元数据已不存在)'
    }
    exit 0
}

# 删除文档行并重算计数
# 逐行重建而非切片: 切片在删最后一行时会因 6..5 倒序而把该行又带回来
$rest = New-Object System.Collections.Generic.List[string]
for ($i = 0; $i -lt $docLines.Count; $i++) {
    if ($i -ne $hitIndex) { $rest.Add($docLines[$i]) }
}
$rest = $rest.ToArray()
$rest = Repair-DocCounts $rest @(Read-DocSections $rest)
[IO.File]::WriteAllText($docPath, ($rest -join "`r`n"), (New-Object Text.UTF8Encoding($false)))
Ok "已从清单文档移除该行, 分类计数已重算"

# 移除元数据
if ($mod) {
    Say ''
    Head '移除元数据'
    $rm = Invoke-MetadataRemove -PackDir $PackDir -Targets @($mod) -DocPath $docPath
    if ($rm.Removed -gt 0) {
        Ok '删除完成'
    } else {
        Warn '元数据未删除, 文档行已移除'
        Say  '  可稍后运行 维护模组清单.bat 再处理; 或直接 packwiz remove ' + $key
    }
} else {
    Info '无需删除元数据'
}

Say ''
Head '下一步'
Say  '  运行 推送元数据.bat 提交推送'
Say ''
Ok '删除流程结束'
