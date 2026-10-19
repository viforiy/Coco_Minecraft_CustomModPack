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

.PARAMETER Check
    只做体检: 检查 side 偏差、前置缺失、文档与元数据不一致
    不做任何改动; 有异常时退出码 2
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
    [switch]$NoRemove,

    # 只做体检: 检查 side 偏差、前置缺失、文档与元数据不一致, 不做任何改动
    [switch]$Check
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

# 2.3) 体检模式: 只检查不修改, 结束后退出
if ($Check) {
    $issues = New-Object System.Collections.Generic.List[string]

    # 检查一: side 与 Modrinth 官方标注是否一致(批量查询, 不逐个请求)
    $mrIds = @($mods | Where-Object { $_.MrId } | ForEach-Object { $_.MrId })
    $projMap = Get-MrProjectsBatch -Ids $mrIds
    $sideBad = 0
    foreach ($m in $mods) {
        if (-not $m.MrId) { continue }
        $proj = $projMap[$m.MrId]
        if (-not $proj) { continue }
        $suggest = Get-SuggestedSide $proj
        if ($suggest -and $suggest -ne $m.Side) {
            $sideBad++
            # 只有"当前标为客户端、而官方标注服务端必需"才会真的让服务端缺模组
            if ($m.Side -eq 'client' -and $proj.server_side -eq 'required') {
                $issues.Add(("side 风险  {0}  当前=client, 但官方标注服务端必需" -f $m.Key))
            }
        }
    }
    Info ("side 检查   共 {0} 个, 与官方标注不同 {1} 个(多数为标注保守, 不计异常)" -f @($mods | Where-Object { $_.MrId }).Count, $sideBad)

    # 检查二: 文档与元数据是否一一对应
    $modKeysNow = @($mods | ForEach-Object { $_.Key })
    $docOnly = @($docKeys | Where-Object { $modKeysNow -notcontains $_ })
    $modOnly = @($modKeysNow | Where-Object { $docKeys -notcontains $_ })
    foreach ($k in $modOnly) { $issues.Add("文档缺少行  $k (元数据存在, 文档未记录)") }
    foreach ($k in $docOnly) { $issues.Add("文档多余行  $k (元数据缺失)") }
    Info ("文档对应   元数据 {0} 个, 文档 {1} 条, 差异 {2} 处" -f $modKeysNow.Count, $docKeys.Count, ($modOnly.Count + $docOnly.Count))

    # 检查三: 同一项目对应多个元数据文件
    $dupIds = @($mods | Where-Object { $_.MrId } | Group-Object MrId | Where-Object { $_.Count -gt 1 })
    foreach ($g in $dupIds) {
        $issues.Add(("重复项目   {0} 对应 {1} 个元数据: {2}" -f $g.Name, $g.Count, (($g.Group | ForEach-Object { $_.Key }) -join ', ')))
    }
    Info ("重复检查   同一项目多份元数据 {0} 组" -f $dupIds.Count)

    # 检查四: 前置列写到的名称能否对应到包内模组
    $nameIndex = @{}
    foreach ($m in $mods) {
        $nameIndex[$m.Key.ToLower()] = $m.Key
        if ($m.Name) { $nameIndex[$m.Name.ToLower()] = $m.Key }
    }
    $aliasTable = @(Read-AliasTable $PackDir)
    foreach ($a in $aliasTable) { if (-not $nameIndex.ContainsKey($a.Alias.ToLower())) { $nameIndex[$a.Alias.ToLower()] = $a.Slug } }

    $depBad = 0
    $nameKeys = @($nameIndex.Keys)
    foreach ($line in $docLines) {
        if ($line -notmatch '^\|') { continue }
        # 跳过表头与分隔行
        if ($line -match '^\|\s*(名称|slug|---)') { continue }
        $cells0 = ($line -split '\|')
        if ($cells0.Count -lt 6) { continue }
        $cells0 = $cells0[1..($cells0.Count - 2)] | ForEach-Object { $_.Trim() }
        if ($cells0.Count -lt 4) { continue }
        $depCell = $cells0[3]
        if (-not $depCell -or $depCell -eq '—') { continue }
        $slugCell = ''
        if ($cells0[1] -match '`([^`]+)`') { $slugCell = $Matches[1] }

        foreach ($token in ($depCell -split '[、,，/＋+]')) {
            $tk = ($token -replace '<[^>]*>', '').Trim()
            if (-not $tk -or $tk -eq '—' -or $tk -eq '---') { continue }
            # 内置/外部依赖不在 mods 目录, 视为已知例外
            if ($tk -match '内置|外部') { continue }
            # 已知内置库: 随宿主模组一起分发, 不会出现在 mods 目录
            if ($tk -match '(?i)^(ponder|biolith|mixinsquared|flywheel|xaerolib|whitenoise|apollib|worldmesher|lithium)$') { continue }
            # 去掉「前置库」「前置」「配置库」这类后缀再比对
            $tkNorm = ($tk -replace '(前置库|前置|配置格式库|配置库|核心库|内嵌浏览器框架|物品管理器)$', '').Trim()
            $hit = $nameIndex[$tk.ToLower()]
            if (-not $hit) { $hit = $nameIndex[$tkNorm.ToLower()] }
            if (-not $hit) {
                # 归一化: 去空格与下划线后再比一次
                $flat = ($tkNorm -replace '[\s_\-'']', '').ToLower()
                foreach ($k in $nameKeys) {
                    $kf = ($k -replace '[\s_\-'']', '')
                    if ($kf.Length -ge 4 -and $flat.Contains($kf)) { $hit = $nameIndex[$k]; break }
                }
            }
            if (-not $hit -and $tkNorm.Length -ge 2) {
                # 包含匹配: 前置项里含包内名称, 或包内名称含前置项
                $lower = $tkNorm.ToLower()
                foreach ($k in $nameKeys) {
                    if ($k.Length -ge 3 -and ($lower.Contains($k) -or $k.Contains($lower))) { $hit = $nameIndex[$k]; break }
                }
            }
            if (-not $hit) {
                $depBad++
                $issues.Add(("前置无法解析  {0} 的前置项「{1}」在包内找不到对应模组" -f $slugCell, $tk))
            }
        }
    }
    Info ("前置检查   无法解析的前置项 {0} 处" -f $depBad)

    Say ''
    if ($issues.Count -eq 0) {
        Ok '无异常'
        exit 0
    }
    Head ("发现 {0} 处异常" -f $issues.Count)
    $issues | ForEach-Object { Say "  - $_" }
    Say ''
    Warn '体检只报告, 不做修改; 修正后重新运行'
    exit 2
}

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
    Say  '         下面会询问是否删除这些模组的元数据'
} else {
    Info '用户删行 0 条'
}
if ($metaGone.Count -gt 0) {
    Warn "元数据被删 $($metaGone.Count) 条(依据: 基线有该 slug, 文档仍有行, 元数据已缺)"
    foreach ($k in $metaGone) { Say "  - $k" }
}
Info "文档残留 $($pureGhost.Count) 条(文档有行, 元数据从未存在)"

# 2.47) 执行删除: 用户删行的模组 -> 移除元数据(确认与备份见共用函数)
if ($userDeleted.Count -gt 0) {
    if ($NoRemove) {
        Info '已指定 -NoRemove, 跳过元数据删除'
    } else {
        Head '准备删除元数据'
        $targets = @()
        foreach ($k in $userDeleted) {
            $mm = ($mods | Where-Object { $_.Key -eq $k } | Select-Object -First 1)
            if ($mm) { $targets += $mm }
        }
        $rm = Invoke-MetadataRemove -PackDir $PackDir -Targets $targets -DocPath $DocPath -DryRun:$DryRun
        if ($rm.Removed -gt 0) {
            # 重新读取元数据与差异, 供后续步骤使用
            $mods = @(Get-ChildItem (Join-Path $PackDir 'mods') -Filter '*.pw.toml' -ErrorAction SilentlyContinue | ForEach-Object { Read-PwFile $_.FullName } | Sort-Object Key)
            $modKeysAll = @($mods | ForEach-Object { $_.Key })
            $newMods = @($mods | Where-Object { $docKeys -notcontains $_.Key -and $baseline.Slugs -notcontains $_.Key })
            $docLines = $rm.DocLines
            $sections = @(Read-DocSections $docLines)
        }
    }
}

# 2.5) 文档里存在、但元数据已没有的条目
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
    $cells = ($l -split '\|')
    if ($cells.Count -lt 4) { $newLines.Add($l); continue }
    $cells = $cells[1..($cells.Count - 2)] | ForEach-Object { $_.Trim() }
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
# 排除用户删行的那批: 它们等待删除元数据, 不应被补录回文档
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
