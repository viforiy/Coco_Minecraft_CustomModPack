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

.PARAMETER NoPrune
    不删除清单中的失效条目(文档有行、元数据缺失)

.PARAMETER NoRemove
    不删除「用户删行」对应的元数据, 只报告
#>
[CmdletBinding()]
param(
    [string]$PackDir,
    [string]$DocPath,
    [string]$Proxy,
    [switch]$DryRun,
    [switch]$NoSide,
    [switch]$All,

    [switch]$NoPrune,

    # 跳过删除元数据(只报告用户删行)
    [switch]$NoRemove
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

# 2.4) 顺手刷新别名表: 覆盖手工改过文档但未运行别名工具的情形
#      后续若有补录写入, 保存后会再刷新一次
if (-not $DryRun) {
    $aliasStats = Update-AliasTableFromDoc -PackDir $PackDir -DocPath $DocPath
    Info "别名表已刷新: $($aliasStats.Total) 条"
}

# 2.45) 三方判定: 元数据 / 文档 / HEAD 基线
#       目的是把「用户删了文档行」和「新装尚未补录」分开, 两者在二元对比下无法区分
$baseline = Get-BaselineDocSlugs -PackDir $PackDir -DocPath $DocPath
$modKeysAll = @($mods | ForEach-Object { $_.Key })
$normalKeys = @($modKeysAll | Where-Object { $docKeys -contains $_ })
$userDeleted = @($modKeysAll | Where-Object { $docKeys -notcontains $_ -and $baseline.Slugs -contains $_ })
$newUndoc    = @($modKeysAll | Where-Object { $docKeys -notcontains $_ -and $baseline.Slugs -notcontains $_ })
$docOnlyKeys = @($docKeys | Where-Object { $modKeysAll -notcontains $_ })
$metaGone    = @($docOnlyKeys | Where-Object { $baseline.Slugs -contains $_ })
$pureGhost   = @($docOnlyKeys | Where-Object { $baseline.Slugs -notcontains $_ })

Head '三方判定'
if ($baseline.Ok) {
    Info "基线     HEAD 版清单文档, $($baseline.Slugs.Count) 条"
} else {
    Warn "基线     不可用($($baseline.Reason))"
    Say  '         无基线时不会判定删除, 缺失行一律视为新装未补录'
}
Info "正常     $($normalKeys.Count) 条"
Info "新装未补录 $($newUndoc.Count) 条"
if ($userDeleted.Count -gt 0) {
    Warn "用户删行  $($userDeleted.Count) 条(依据: 基线有该 slug, 文档已无)"
    foreach ($k in $userDeleted) {
        $nm = ($mods | Where-Object { $_.Key -eq $k } | Select-Object -First 1)
        $label = if ($nm -and $nm.Name) { $nm.Name } else { '(无名称)' }
        Say  ("  - {0}  ({1})" -f $k, $label)
    }
    Say  '         这些模组的元数据仍存在; 删除动作在 F8 实现, 本次仅报告, 不执行'
} else {
    Info '用户删行 0 条'
}
if ($metaGone.Count -gt 0) {
    Warn "元数据被删 $($metaGone.Count) 条(依据: 基线有该 slug, 文档仍有行, 元数据已缺)"
    foreach ($k in $metaGone) { Say "  - $k" }
}
Info "文档残留 $($pureGhost.Count) 条(文档有行, 元数据从未存在)"

# 2.47) 执行删除: 用户删行的模组 -> 移除元数据(含备份与确认)
if ($userDeleted.Count -gt 0) {
    if ($DryRun) {
        Warn 'DryRun: 不执行删除, 仅报告'
    } elseif ($NoRemove) {
        Info '已指定 -NoRemove, 跳过元数据删除'
    } else {
        Head '准备删除元数据'
        $targets = @()
        foreach ($k in $userDeleted) {
            $mm = ($mods | Where-Object { $_.Key -eq $k } | Select-Object -First 1)
            if ($mm) { $targets += $mm }
        }

        Say ''
        Say '  将删除以下模组的元数据:'
        foreach ($mm in $targets) { Say ("    - {0}  ({1})  -> mods/{2}" -f $mm.Key, $mm.Name, (Split-Path $mm.Path -Leaf)) }
        Say  '  删除前会自动备份到缓存目录'
        $ans = Read-Host '  确认删除吗 [y/N]'
        if (-not $ans -or $ans -notmatch '^[Yy]') {
            Info '未确认, 未做任何改动'
        } else {
            # 确认后才备份: 选 N 时不留下任何痕迹
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
            foreach ($mm in $targets) {
                Copy-Item -LiteralPath $mm.Path -Destination (Join-Path $backupDir (Split-Path $mm.Path -Leaf)) -Force
                $manifest += ("{0}`t{1}`t{2}" -f $mm.Key, $mm.Name, $mm.Filename)
            }
            [IO.File]::WriteAllText((Join-Path $backupDir '清单.txt'), ($manifest -join "`r`n"), $Utf8NoBom)
            Info "备份目录 $backupDir ($($targets.Count) 个文件)"
            $packwiz = Resolve-Packwiz
            $removed = 0
            $failed = 0
            foreach ($mm in $targets) {
                $okDel = $false
                if ($packwiz) {
                    Push-Location $PackDir
                    $rmOut = & $packwiz remove $mm.Key 2>&1
                    if ($LASTEXITCODE -eq 0) { $okDel = $true }
                    Pop-Location
                }
                if (-not $okDel) {
                    # 缺少 packwiz 或 remove 失败时退化为直接删文件
                    Remove-Item -LiteralPath $mm.Path -Force -ErrorAction SilentlyContinue
                    $okDel = -not (Test-Path $mm.Path)
                }
                if ($okDel) { $removed++; Ok "已删除 $($mm.Key)" } else { $failed++; Warn "删除失败 $($mm.Key)" }
            }

            if ($removed -gt 0 -and -not $packwiz) {
                $pwz2 = Resolve-Packwiz
                if ($pwz2) { Push-Location $PackDir; [void](& $pwz2 refresh 2>&1); Pop-Location }
            }

            # 文档计数可能因手工删行而失真, 这里重算并写回
            $docNow = [IO.File]::ReadAllText($DocPath, [Text.Encoding]::UTF8) -split "`r?`n"
            $fixedDoc = Repair-DocCounts $docNow @(Read-DocSections $docNow)
            [IO.File]::WriteAllText($DocPath, ($fixedDoc -join "`r`n"), $Utf8NoBom)
            Ok "已删除 $removed 个模组的元数据; 文档计数已重算"

            # 重新读取元数据与差异, 供后续步骤使用
            $mods = @(Get-ChildItem (Join-Path $PackDir 'mods') -Filter '*.pw.toml' -ErrorAction SilentlyContinue | ForEach-Object { Read-PwFile $_.FullName } | Sort-Object Key)
            $modKeysAll = @($mods | ForEach-Object { $_.Key })
            $newMods = @($mods | Where-Object { $docKeys -notcontains $_.Key -and $baseline.Slugs -notcontains $_.Key })
            $docLines = $fixedDoc
            $sections = @(Read-DocSections $docLines)
        }
    }
}

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
# 排除用户删行的那批: 它们等待 F8 删除元数据, 不应被补录回文档
$newMods = @($mods | Where-Object { $docKeys -notcontains $_.Key -and $baseline.Slugs -notcontains $_.Key })
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
if ($DryRun) {
    Warn 'DryRun, 文档未写入'
} else {
    Ok "文档已更新 $DocPath"
    # 顺带刷新别名表, 保证中文名对照跟随文档
    $aliasStats = Update-AliasTableFromDoc -PackDir $PackDir -DocPath $DocPath
    Info "别名表已刷新: $($aliasStats.Total) 条"
}
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
