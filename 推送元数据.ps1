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
#>
[CmdletBinding()]
param(
    [string]$PackDir,
    [string]$Message,
    [switch]$NoPrompt,
    [switch]$DryRun
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
if ($lines.Count -eq 0) {
    Ok '工作区干净, 没有需要提交的改动'
    $ahead = (Invoke-Git @('rev-list','--count','@{u}..HEAD') -AllowFail)
    if ($ahead.Code -eq 0 -and [int]$ahead.Out.Trim() -gt 0) {
        Warn "但本地领先远端 $($ahead.Out.Trim()) 个提交, 需要推送"
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
$title = $Message
if (-not $title) {
    $parts = @()
    if ($addedMods.Count)   { $parts += "新增 $($addedMods.Count)" }
    if ($deletedMods.Count) { $parts += "删除 $($deletedMods.Count)" }
    if ($modChanged.Count)  { $parts += "更新 $($modChanged.Count)" }
    if ($parts.Count -eq 0) { $parts += '同步文件' }
    $title = '同步模组元数据: ' + ($parts -join ' / ')
}
Say ''
Say "  提交信息标题: $title"
if (-not $NoPrompt) {
    $custom = Read-Host '  回车沿用上面的标题, 或输入自定义标题'
    if ($custom) { $title = $custom }
}

$body = New-Object System.Collections.Generic.List[string]
$body.Add($title)
$body.Add('')
if ($addedMods.Count)   { $body.Add('新增: ' + ($addedMods -join ', ')) }
if ($deletedMods.Count) { $body.Add('删除: ' + ($deletedMods -join ', ')) }
if ($modChanged.Count)  { $body.Add('更新: ' + ($modChanged -join ', ')) }
if ($otherFiles.Count)  { $body.Add('其它: ' + ($otherFiles -join ', ')) }
$body.Add('')
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

# 6) 推送
Head '推送'
$proxy = 'http://127.0.0.1:7890'
$remoteName = $repo.Remote
if (-not $remoteName) {
    Fail '仓库没有配置任何远端, 只能保留本地提交'
    Say "  先添加远端再重试:  git -C ""$PackDir"" remote add origin <仓库地址>"
    exit 1
}
$pushRef = "HEAD:$branch"
Say "  目标 $remoteName / $branch"
$attempts = @(
    @{ Name = '按当前 git 配置'; Args = @('push',$remoteName,$pushRef) },
    @{ Name = "经代理 $proxy";    Args = @('-c',"http.proxy=$proxy",'-c',"https.proxy=$proxy",'push',$remoteName,$pushRef) },
    @{ Name = '直连无代理';       Args = @('-c','http.proxy=','-c','https.proxy=','push',$remoteName,$pushRef) }
)
$pushed = $false
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
    Warn "失败: $($why.Trim())"
}

if (-not $pushed) {
    Fail '三次尝试均未推送成功'
    Say '  常见原因: 代理未启动, 或网络无法访问 github.com'
    Say '  提交已保存在本地, 网络恢复后执行:'
    Say "    git -C ""$PackDir"" push $remoteName $pushRef"
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
