#Requires -Version 5.1
<#
.SYNOPSIS
    提交并推送当前分支的模组元数据

.DESCRIPTION
    1. 检查目标目录是否为 git 仓库, 分支是否为 main
    2. 汇总变更: 新增/删除的模组与其它改动文件
    3. 生成或接收提交信息, git add -A 后提交
    4. 推送, 直连失败时依次尝试本机代理与无代理
    5. 输出推送结果与后续提示

.PARAMETER PackDir
    packwiz 包目录, 默认取脚本同级的 ..\Coco_Minecraft_CustomModPack

.PARAMETER Message
    提交信息标题, 省略时按变更内容自动生成

.PARAMETER NoPrompt
    不询问, 直接提交并推送, 适合脚本串联

.PARAMETER DryRun
    只显示将要提交的内容, 不执行 add/commit/push

.PARAMETER Force
    使用 --force-with-lease 覆盖远端分支, 仅在本地重置过历史时使用
    默认不强制; 未加 -NoPrompt 时会再次确认
#>
[CmdletBinding()]
param(
    [string]$PackDir,
    [string]$Message,
    [switch]$NoPrompt,
    [switch]$DryRun,

    # 使用 --force-with-lease 覆盖远端; 需显式指定, 默认不强制
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::GetEncoding(936)
$ToolHome = $PSScriptRoot
. (Join-Path $ToolHome '工具配置.ps1')
. (Join-Path $ToolHome '工具函数.ps1')


$Git = 'git'

function Invoke-Git {
    param([string[]]$GitArgs, [switch]$AllowFail)
    # 原生命令写到 stderr 时, ErrorActionPreference=Stop 会把它变成终止错误,
    # 这里临时降级, 由调用方按退出码判断成败
    $prev = $ErrorActionPreference
    # git 输出为 UTF-8, 若按控制台代码页(936)解码, 中文文件名会乱码
    $prevOut = [Console]::OutputEncoding
    $ErrorActionPreference = 'Continue'
    try {
        [Console]::OutputEncoding = [Text.Encoding]::UTF8
        $raw = & $Git -C $PackDir @GitArgs 2>&1
        $code = $LASTEXITCODE
    } finally {
        [Console]::OutputEncoding = $prevOut
        $ErrorActionPreference = $prev
    }
    $text = (($raw | ForEach-Object { "$_" }) -join "`n")
    if ($code -ne 0 -and -not $AllowFail) {
        throw ("git " + ($GitArgs -join ' ') + " 失败:`n" + $text)
    }
    return [pscustomobject]@{ Code = $code; Out = $text }
}

Say ''
Say '=========================================================='
Say '  Coco 整合包 · 元数据推送'
Say '=========================================================='
Say '  提交并推送当前分支, 玩家与服务端下次启动即同步'
Say ''

# 1) 定位仓库
try {
    $PackDir = Resolve-PackDir -ToolRoot $ToolHome -CliValue $PackDir -NonInteractive:([bool]$NoPrompt)
} catch {
    Fail $_.Exception.Message
    exit 1
}
if (-not (Test-Path (Join-Path $PackDir '.git'))) { Fail "目录不是 git 仓库: $PackDir"; exit 1 }
$cfg = Read-ToolConfig $ToolHome
$repo = Get-RepoInfo -PackDir $PackDir -PreferredRemote $cfg['REMOTE']
Info "仓库     $PackDir"
Info "当前分支 $($repo.Branch)$(if ($repo.Upstream) { "  ->  $($repo.Upstream)" } else { '  (尚未设置上游)' })"
if ($repo.Remotes.Count -gt 0) { Info "远端     $($repo.Remotes -join ', ')" } else { Warn '该仓库没有配置远端, 只能本地提交' }

# 2) 分支与上游
$branch = $repo.Branch
$expected = if ($repo.DefaultBranch) { $repo.DefaultBranch } else { $branch }
if ($branch -ne $expected) {
    Warn "当前分支 $branch 与远端默认分支 $expected 不同, 玩家从默认分支获取不到本次改动"
    if (-not $NoPrompt -and -not $DryRun) {
        $ans = Read-Host '  仍要继续吗 [y/N]'
        if (-not $ans -or $ans -notmatch '^[Yy]') { Info '已取消'; exit 1 }
    }
}

# 2.5) 一致性校验: 元数据与清单文档必须对齐, 否则先同步再推送
$docPath = Join-Path $PackDir '模组列表介绍.md'
if (Test-Path $docPath) {
    $modKeys = @(Get-ChildItem (Join-Path $PackDir 'mods') -Filter '*.pw.toml' -ErrorAction SilentlyContinue | ForEach-Object { $_.Name -replace '\.pw\.toml$','' })
    $docKeys = @(Get-DocSlugs -DocPath $docPath)
    $onlyMods = @($modKeys | Where-Object { $docKeys -notcontains $_ })
    $onlyDoc  = @($docKeys | Where-Object { $modKeys -notcontains $_ })
    if ($onlyMods.Count -gt 0 -or $onlyDoc.Count -gt 0) {
        Head '一致性校验未通过'
        if ($onlyMods.Count -gt 0) { Say ("  元数据有、文档未记录 {0} 个: {1}" -f $onlyMods.Count, ($onlyMods -join ', ')) }
        if ($onlyDoc.Count -gt 0)  { Say ("  文档有行、元数据缺失 {0} 个: {1}" -f $onlyDoc.Count, ($onlyDoc -join ', ')) }
        Warn '推送会把不一致状态写进基线, 之后的同步将无法判断删除意图'
        Say  '  顺序应为: 1 添加 -> 2 同步清单 -> 3 推送元数据'
        Say  '  请先运行 维护模组清单.bat 完成同步, 再推送'
        exit 2
    }
    Info "一致性校验通过: 元数据 $($modKeys.Count) 个, 文档 $($docKeys.Count) 条"
} else {
    Info '无清单文档, 跳过一致性校验'
}

# 3) 变更汇总
$status = (Invoke-Git @('-c','core.quotepath=false','status','--porcelain')).Out
$lines = @($status -split "`n" | Where-Object { $_.Trim() -ne '' })
$skipCommit = $false
if ($lines.Count -eq 0) {
    Ok '工作区干净, 没有需要提交的改动'
    $ahead = (Invoke-Git @('rev-list','--count','@{u}..HEAD') -AllowFail)
    if ($ahead.Code -eq 0 -and [int]$ahead.Out.Trim() -gt 0) {
        Warn "但本地领先远端 $($ahead.Out.Trim()) 个提交, 直接进入推送环节"
        $skipCommit = $true
    } else {
        exit 0
    }
}

$addedMods   = @()
$deletedMods = @()
$modChanged  = @()
$otherFiles  = @()
foreach ($l in $lines) {
    $code = $l.Substring(0,2)
    $path = $l.Substring(3).Trim('"')
    if ($path -like 'mods/*.pw.toml') {
        $slug = [IO.Path]::GetFileName($path) -replace '\.pw\.toml$',''
        if ($code -match '\?\?|A') { $addedMods += $slug }
        elseif ($code -match 'D')  { $deletedMods += $slug }
        else { $modChanged += $slug }
    } else {
        $otherFiles += $path
    }
}

$classified = $addedMods.Count + $deletedMods.Count + $modChanged.Count + $otherFiles.Count
if ($classified -eq 0) {
    # 常见于 git 只输出了警告行, 例如换行符转换提示
    Warn '未能识别的改动, 原始输出如下:'
    foreach ($l in $lines) { Say "  $l" }
}

Head '变更汇总'
if ($addedMods.Count)   { Say ("  新增模组 {0}: {1}" -f $addedMods.Count,   ($addedMods   -join ', ')) }
if ($deletedMods.Count) { Say ("  删除模组 {0}: {1}" -f $deletedMods.Count, ($deletedMods -join ', ')) }
if ($modChanged.Count)  { Say ("  更新模组 {0}: {1}" -f $modChanged.Count,  (($modChanged | Select-Object -First 10) -join ', ')) }
if ($otherFiles.Count)  { Say ("  其它改动 {0}: {1}" -f $otherFiles.Count,  ($otherFiles -join ', ')) }
Say ("  共 {0} 个文件" -f $lines.Count)

# 4) 提交信息
# 标题带模组名, 便于 git log --grep 检索; 超出长度上限时截断并标注总数
function Format-NameList {
    param([string[]]$Names, [int]$Max = 3)
    if (-not $Names -or $Names.Count -eq 0) { return '' }
    if ($Names.Count -le $Max) { return ($Names -join ' ') }
    return (($Names | Select-Object -First $Max) -join ' ') + " 等 $($Names.Count) 个"
}

function New-CommitTitle {
    param([string[]]$Added, [string[]]$Deleted, [string[]]$Changed, [int]$Max = 3)
    $parts = @()
    if ($Added.Count)   { $parts += '新增 ' + (Format-NameList $Added $Max) }
    if ($Deleted.Count) { $parts += '删除 ' + (Format-NameList $Deleted $Max) }
    if ($Changed.Count) { $parts += '更新 ' + (Format-NameList $Changed $Max) }
    if ($parts.Count -eq 0) { $parts += '同步文件' }
    return '同步模组元数据: ' + ($parts -join ', ')
}

$title = $Message
if (-not $title) {
    $title = New-CommitTitle $addedMods $deletedMods $modChanged 3
    # 标题控制在 72 字符内, 超长时减少列举个数
    foreach ($cap in @(2, 1)) {
        if ($title.Length -le 72) { break }
        $title = New-CommitTitle $addedMods $deletedMods $modChanged $cap
    }
}
Say ''
Say "  提交信息标题: $title"
Say  ("                ({0} 字符)" -f $title.Length)
if (-not $NoPrompt) {
    $custom = Read-Host '  回车沿用上面的标题, 或输入自定义标题'
    if ($custom) { $title = $custom }
}

# 正文分节列举, 便于 git log 阅读与逐项检索
$body = New-Object System.Collections.Generic.List[string]
$body.Add($title)
$body.Add('')
if ($addedMods.Count) {
    $body.Add("新增模组 $($addedMods.Count) 个")
    foreach ($s in $addedMods) { $body.Add("- $s") }
    $body.Add('')
}
if ($deletedMods.Count) {
    $body.Add("删除模组 $($deletedMods.Count) 个")
    foreach ($s in $deletedMods) { $body.Add("- $s") }
    $body.Add('')
}
if ($modChanged.Count) {
    $body.Add("更新模组 $($modChanged.Count) 个")
    foreach ($s in $modChanged) { $body.Add("- $s") }
    $body.Add('')
}
if ($otherFiles.Count) {
    $body.Add("其它文件 $($otherFiles.Count) 个")
    foreach ($s in $otherFiles) { $body.Add("- $s") }
    $body.Add('')
}
$body.Add('由 推送元数据.bat 生成')

if ($DryRun) {
    Head 'DryRun: 提交信息预览'
    $body | ForEach-Object { Say "  $_" }
    Warn 'DryRun 结束, 未执行 add / commit / push'
    exit 0
} else {
    if (-not $NoPrompt) {
        $ans = Read-Host '  确认提交并推送吗 [Y/n]'
        if ($ans -and $ans -notmatch '^[Yy]') { Info '已取消'; exit 1 }
    }
}

# 5) 提交
if ($skipCommit) {
    Info '无待提交改动, 跳过提交, 只执行推送'
} else {
    $msgFile = Join-Path $env:TEMP ("coco-commit-" + [guid]::NewGuid().ToString('N') + ".txt")
    [IO.File]::WriteAllText($msgFile, ($body -join "`n"), (New-Object System.Text.UTF8Encoding($false)))
    try {
        Invoke-Git @('add','-A') | Out-Null
        $r = Invoke-Git @('-c','i18n.commitEncoding=UTF-8','commit','-F',$msgFile) -AllowFail
        if ($r.Code -ne 0) { Fail "提交失败:`n$($r.Out)"; exit 1 }
        $hash = (Invoke-Git @('rev-parse','--short','HEAD')).Out.Trim()
        Ok "已提交 $hash"
    } finally {
        Remove-Item $msgFile -ErrorAction SilentlyContinue
    }
}

# 6) 推送
$proxy = 'http://127.0.0.1:7890'
$remoteName = $repo.Remote
if (-not $remoteName) {
    Fail '仓库没有配置任何远端, 只能保留本地提交'
    Say "  先添加远端再重试:  git -C ""$PackDir"" remote add origin <仓库地址>"
    exit 1
}

# 6.1) 推送前同步: 先 fetch, 落后则自动 rebase
$fetchTry = Invoke-Git @('fetch',$remoteName,'--quiet') -AllowFail
if ($fetchTry.Code -ne 0) {
    Warn '拉取远端状态失败, 跳过同步步骤'
} else {
    $behindRes = Invoke-Git @('rev-list','--count',"HEAD..$remoteName/$branch") -AllowFail
    $aheadRes  = Invoke-Git @('rev-list','--count',"$remoteName/$branch..HEAD") -AllowFail
    $behind = if ($behindRes.Code -eq 0) { [int]$behindRes.Out.Trim() } else { 0 }
    $ahead  = if ($aheadRes.Code -eq 0)  { [int]$aheadRes.Out.Trim() }  else { 0 }

    if ($behind -gt 0 -and -not $Force) {
        Warn "本地落后 $remoteName/$branch $behind 个提交, 领先 $ahead 个, 先同步"
        $dirty = @((Invoke-Git @('status','--porcelain') -AllowFail).Out -split "`n" | Where-Object { $_.Trim() -ne '' }).Count
        if ($dirty -gt 0) {
            Warn "工作区还有 $dirty 个未提交改动, 跳过自动 rebase"
            Say  "  手工处理:  git -C ""$PackDir"" stash && git -C ""$PackDir"" pull --rebase $remoteName $branch"
        } else {
            Info "rebase 到 $remoteName/$branch"
            $rb = Invoke-Git @('rebase',"$remoteName/$branch") -AllowFail
            if ($rb.Code -ne 0) {
                [void](Invoke-Git @('rebase','--abort') -AllowFail)
                Fail 'rebase 出现冲突, 已回滚到 rebase 前状态'
                Say  "  手工处理:  git -C ""$PackDir"" pull --rebase $remoteName $branch"
                exit 1
            }
            Ok '已 rebase 到远端最新'
            $ahead = [int]((Invoke-Git @('rev-list','--count',"$remoteName/$branch..HEAD") -AllowFail).Out.Trim())
            if ($ahead -eq 0) {
                Warn 'rebase 后本地没有独立提交了, 没有需要推送的内容'
                Say  '  若提交与远端内容相同、只想改提交信息, rebase 会把它视为已应用而丢弃'
                Say  "  这种情况改用:  推送元数据.bat -Force"
                exit 0
            }
            Info "本地领先 $remoteName/$branch $ahead 个提交, 可快进推送"
        }
    } elseif ($behind -gt 0) {
        Warn "本地落后 $remoteName/$branch $behind 个提交; 已指定 -Force, 跳过 rebase"
    } else {
        Info "本地领先 $remoteName/$branch $ahead 个提交, 可快进推送"
    }
}

Head '推送'
$pushRef = "HEAD:$branch"
$pushExtra = @()
if ($Force) {
    # --force-with-lease: 只有远端仍停在我上次看到的位置时才覆盖, 比 --force 安全
    $pushExtra = @('--force-with-lease')
    Warn '已启用强制推送(--force-with-lease)'
    if (-not $NoPrompt -and -not $DryRun) {
        $ans = Read-Host '  强制推送会重写远端历史, 确认继续吗 [y/N]'
        if (-not $ans -or $ans -notmatch '^[Yy]') { Info '已取消'; exit 1 }
    }
}
Say "  目标 $remoteName / $branch$(if ($Force) { '  (强制)' } else { '' })"
$attempts = @(
    @{ Name = '按当前 git 配置'; Args = (@('push') + $pushExtra + @($remoteName,$pushRef)) },
    @{ Name = "经代理 $proxy";    Args = (@('-c',"http.proxy=$proxy",'-c',"https.proxy=$proxy",'push') + $pushExtra + @($remoteName,$pushRef)) },
    @{ Name = '直连无代理';       Args = (@('-c','http.proxy=','-c','https.proxy=','push') + $pushExtra + @($remoteName,$pushRef)) }
)
$pushed = $false
$lastOut = ''  # 最后一次失败输出, 用于区分非快进与网络问题
foreach ($a in $attempts) {
    Info "尝试 $($a.Name)"
    $r = Invoke-Git $a.Args -AllowFail
    if ($r.Code -eq 0) {
        Ok "推送成功 ($($a.Name))"
        if ($r.Out.Trim()) { Say "  $($r.Out.Trim())" }
        $pushed = $true
        break
    }
    $why = ($r.Out -split "`n" | Where-Object { $_ -match 'fatal|error:|denied|rejected' } | Select-Object -First 1)
    if (-not $why) { $why = ($r.Out -split "`n" | Where-Object { $_.Trim() } | Select-Object -Last 1) }
    $lastOut = $r.Out
    Warn "失败: $($why.Trim())"
}

if (-not $pushed) {
    Fail '三次尝试均未推送成功'
    if ($lastOut -match 'non-fast-forward|fetch first|\[rejected\]|failed to push') {
        Head '远端拒绝: 本地与远端历史不一致(非快进)'
        Say "  本地 $branch -> $((Invoke-Git @('rev-parse','--short','HEAD') -AllowFail).Out.Trim())"
        Say "  远端 $remoteName/$branch -> $((Invoke-Git @('rev-parse','--short',"$remoteName/$branch") -AllowFail).Out.Trim())"
        Say ''
        Say '  情形一 远端有本地没有的提交(常见于换了机器提交):'
        Say "    git -C ""$PackDir"" pull --rebase $remoteName $branch"
        Say '    然后再运行推送'
        Say ''
        Say '  情形二 本地重置过历史, 想用本地覆盖远端:'
        Say '    推送元数据.bat -Force'
        Say '    使用 --force-with-lease, 远端若已被他人推进则不会覆盖'
        Say ''
        Warn '本次未强制推送, 以免覆盖他人提交'
    } else {
        Say '  常见原因: 代理未启动, 或网络无法访问远端'
        Say '  提交已保存在本地, 网络恢复后执行:'
        Say "    git -C ""$PackDir"" push $remoteName $pushRef"
    }
    exit 1
}

Head '结果'
Say "  分支 $branch  ->  $remoteName/$branch"
if ($repo.DefaultBranch -and $repo.DefaultBranch -ne $branch) {
    Warn "远端默认分支是 $($repo.DefaultBranch), 玩家默认拉取不到 $branch"
}
Say '  玩家客户端与服务端将在下次启动时按差异同步 mods'
Say '  注意 元数据仓改动后无需重新打包, 也无需通知玩家手动操作'
Say ''
Ok '推送流程结束'
