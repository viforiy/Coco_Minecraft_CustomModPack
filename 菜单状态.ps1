#Requires -Version 5.1
<#
    菜单状态行

    供 开发工具.bat 在进入菜单前调用, 只输出三行摘要:
        包目录 / 分支与上游 / 工作区是否有未提交改动

    只读, 不修改任何文件; 找不到包目录时给出提示而不报错, 便于首次使用。
#>
[CmdletBinding()]
param([string]$PackDir)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::GetEncoding(936)
$ToolHome = $PSScriptRoot
. (Join-Path $ToolHome '工具配置.ps1')

function Say  { param($m) Write-Host $m }
function Info { param($m) Write-Host "[信息] $m" -ForegroundColor Gray }
function Warn { param($m) Write-Host "[注意] $m" -ForegroundColor Yellow }

try {
    $resolved = Resolve-PackDir -ToolRoot $ToolHome -CliValue $PackDir -NonInteractive
} catch {
    Warn '包目录 未设置, 首次运行时会询问'
    exit 0
}

Info "包目录 $resolved"

try {
    $repo = Get-RepoInfo -PackDir $resolved
    $up = if ($repo.Upstream) { $repo.Upstream } else { '未设置上游' }
    Info "分支   $($repo.Branch)  ->  $up"
} catch {
    Warn '该目录不是 git 仓库, 推送环节不可用'
    exit 0
}

$prev = $ErrorActionPreference
$prevOut = [Console]::OutputEncoding
$ErrorActionPreference = 'Continue'
try {
    [Console]::OutputEncoding = [Text.Encoding]::UTF8
    $status = (& git -C $resolved -c core.quotepath=false status --porcelain 2>&1 | ForEach-Object { "$_" })
} finally {
    [Console]::OutputEncoding = $prevOut
    $ErrorActionPreference = $prev
}
$changed = @($status | Where-Object { $_.Trim() -ne '' }).Count
if ($changed -gt 0) {
    Warn "工作区 有 $changed 个未提交改动"
} else {
    Info '工作区 干净'
}
