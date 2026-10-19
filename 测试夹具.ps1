#Requires -Version 5.1
<#
    构造五态测试夹具

    生成一个带 git 基线的沙箱仓库, 覆盖三方判定的五种状态:

      normal      正常          钠 Sodium            元数据与文档都有
      deletedRow  用户删行      锂 Lithium           元数据在, 文档行已被删除
      metaGone    元数据被手删  鸢尾花 Iris          文档行在, 元数据已被删除
      newUndoc    新装未补录    苹果皮 AppleSkin     元数据在, 文档从未记录, 基线也没有
      ghost       文档残留      幽灵模组 ghost-mod   文档行在, 元数据从未存在

    用法
      测试夹具.ps1                   在真实包同级建 夹具-<时间戳>
      测试夹具.ps1 -Path "D:\夹具"   指定路径
#>
[CmdletBinding()]
param([string]$Path)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::GetEncoding(936)
$ToolHome = $PSScriptRoot
. (Join-Path $ToolHome '工具配置.ps1')
. (Join-Path $ToolHome '工具函数.ps1')

$real = Resolve-PackDir -ToolRoot $ToolHome -NonInteractive
if (-not $Path) { $Path = Join-Path (Split-Path -Parent $real) ("夹具-" + (Get-Date -Format 'MMdd-HHmmss')) }
if (Test-Path $Path) { throw "目标已存在: $Path" }

New-Item -ItemType Directory -Force -Path (Join-Path $Path 'mods') | Out-Null
Copy-Item -LiteralPath (Join-Path $real 'pack.toml') -Destination $Path
Copy-Item -LiteralPath (Join-Path $real 'index.toml') -Destination $Path

function Invoke-FixtureGit {
    param([string[]]$GitArgs)
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { $out = & git -C $Path @GitArgs 2>&1; $code = $LASTEXITCODE }
    finally { $ErrorActionPreference = $prev }
    return [pscustomobject]@{ Code = $code; Out = (($out | ForEach-Object { "$_" }) -join "`n") }
}

function New-Row {
    param([string]$Slug, [string]$Label)
    return "| **$Label** | ``$Slug`` | $Slug.jar | — | 夹具 | 双端 |"
}

$header = @(
    '# 夹具包 · 模组清单说明',
    '',
    '### 夹具（0）',
    '',
    '| 名称 | slug | jar 文件名 | 前置 | 功能 | 端 |',
    '| --- | --- | --- | --- | --- | --- |'
)

# 第一阶段: 三个模组写入文档并提交, 形成基线
$baseMods = @('sodium', 'lithium', 'iris')
foreach ($m in $baseMods) {
    $src = Join-Path (Join-Path $real 'mods') "$m.pw.toml"
    if (-not (Test-Path $src)) { throw "真实包里缺少素材: $m.pw.toml" }
    Copy-Item -LiteralPath $src -Destination (Join-Path $Path 'mods')
}
$stage1 = New-Object System.Collections.Generic.List[string]
$stage1.AddRange([string[]]$header)
$stage1.Add((New-Row 'sodium' '钠 Sodium'))
$stage1.Add((New-Row 'lithium' '锂 Lithium'))
$stage1.Add((New-Row 'iris' '鸢尾花 Iris'))
[IO.File]::WriteAllText((Join-Path $Path '模组列表介绍.md'), ($stage1 -join "`r`n"), (New-Object Text.UTF8Encoding($false)))

[void](Invoke-FixtureGit @('init','-b','main','-q'))
[void](Invoke-FixtureGit @('-c','user.email=f@f','-c','user.name=fixture','add','-A'))
$ci = Invoke-FixtureGit @('-c','user.email=f@f','-c','user.name=fixture','commit','-qm','夹具基线')
if ($ci.Code -ne 0) { throw "基线提交失败: $($ci.Out)" }

# 第二阶段: 制造五种状态
Remove-Item -LiteralPath (Join-Path (Join-Path $Path 'mods') 'iris.pw.toml') -Force
$apple = Join-Path (Join-Path $real 'mods') 'appleskin.pw.toml'
if (Test-Path $apple) { Copy-Item -LiteralPath $apple -Destination (Join-Path $Path 'mods') }

$stage2 = New-Object System.Collections.Generic.List[string]
$stage2.AddRange([string[]]$header)
$stage2.Add((New-Row 'sodium' '钠 Sodium'))
$stage2.Add((New-Row 'iris' '鸢尾花 Iris'))
$stage2.Add((New-Row 'ghost-mod' '幽灵模组'))
[IO.File]::WriteAllText((Join-Path $Path '模组列表介绍.md'), ($stage2 -join "`r`n"), (New-Object Text.UTF8Encoding($false)))

Write-Host ''
Write-Host "夹具已生成: $Path" -ForegroundColor Green
Write-Host '  正常         sodium     元数据 + 文档 + 基线'
Write-Host '  用户删行     lithium    元数据 + 基线, 文档行已删'
Write-Host '  元数据被手删 iris       文档 + 基线, 元数据已删'
Write-Host '  新装未补录   appleskin  仅元数据, 基线无'
Write-Host '  文档残留     ghost-mod  仅文档, 基线无'
Write-Host ''
Write-Host '  验证:'
Write-Host ('    powershell -NoProfile -File "' + (Join-Path $ToolHome '维护模组清单.ps1') + '" -PackDir "' + $Path + '" -DryRun')
