#Requires -Version 5.1
<#
    开发工具共用的定位与配置逻辑

    供 维护模组清单.ps1 与 推送元数据.ps1 点引用:

        . (Join-Path $PSScriptRoot '工具配置.ps1')

    对外提供:
        Resolve-PackDir   解析 packwiz 包目录, 结果写入 工具配置.cfg
        Get-RepoInfo      读取当前分支 / 上游 / 远端列表
        Get-ConfigPath    配置文件路径
#>

function Get-ConfigPath {
    [CmdletBinding()]
    param([string]$ToolRoot)
    return (Join-Path $ToolRoot '工具配置.cfg')
}

function Read-ToolConfig {
    [CmdletBinding()]
    param([string]$ToolRoot)
    $map = @{}
    $path = Get-ConfigPath $ToolRoot
    if (-not (Test-Path $path)) { return $map }
    foreach ($line in [IO.File]::ReadAllLines($path, [Text.Encoding]::UTF8)) {
        if ($line -match '^\s*#') { continue }
        $i = $line.IndexOf('=')
        if ($i -le 0) { continue }
        $k = $line.Substring(0, $i).Trim()
        $v = $line.Substring($i + 1).Trim()
        if ($k) { $map[$k] = $v }
    }
    return $map
}

function Save-ToolConfig {
    [CmdletBinding()]
    param([string]$ToolRoot, [hashtable]$Config)
    $path = Get-ConfigPath $ToolRoot
    $lines = @(
        '# Coco 整合包开发工具配置',
        '# 首次运行时自动生成, 可手工修改后保存',
        '# PACK_DIR  packwiz 包目录, 需含 pack.toml 与 .git',
        '# REMOTE    推送使用的远端名, 留空则自动探测',
        ''
    )
    foreach ($k in @('PACK_DIR','REMOTE')) {
        if ($Config.ContainsKey($k) -and $Config[$k]) { $lines += "$k=$($Config[$k])" }
    }
    [IO.File]::WriteAllText($path, ($lines -join "`r`n"), (New-Object Text.UTF8Encoding($false)))
    return $path
}

function Test-PackDir {
    [CmdletBinding()]
    param([string]$Path)
    if (-not $Path) { return $false }
    return ((Test-Path (Join-Path $Path 'pack.toml')) -and (Test-Path (Join-Path $Path 'mods')))
}

# 依次尝试: 传入值 -> 环境变量 -> 配置 -> 自身与同级目录
function Find-PackCandidates {
    [CmdletBinding()]
    param([string]$ToolRoot, [string]$CliValue, [string]$Configured)
    $list = New-Object System.Collections.Generic.List[string]
    foreach ($p in @($CliValue, $env:COCO_PACK_DIR, $Configured)) {
        if ($p) { $list.Add($p.Trim().Trim('"').TrimEnd('\')) }
    }
    foreach ($p in @($ToolRoot, (Split-Path -Parent $ToolRoot))) {
        if ($p) { $list.Add($p) }
    }
    $parent = Split-Path -Parent $ToolRoot
    if ($parent -and (Test-Path $parent)) {
        foreach ($d in (Get-ChildItem -LiteralPath $parent -Directory -ErrorAction SilentlyContinue)) {
            if ($d.Name.StartsWith('.')) { continue }
            if (Test-Path (Join-Path $d.FullName 'pack.toml')) { $list.Add($d.FullName) }
        }
    }
    $out = New-Object System.Collections.Generic.List[string]
    foreach ($p in $list) {
        if (-not $p) { continue }
        if (-not (Test-PackDir $p)) { continue }
        if (-not $out.Contains($p)) { $out.Add($p) }
    }
    return $out.ToArray()
}

# 解析包目录, 命中多个候选时提示选择, 成功后写回配置
function Resolve-PackDir {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$ToolRoot,
        [string]$CliValue,
        [switch]$NonInteractive
    )

    $cfg = Read-ToolConfig $ToolRoot
    $candidates = @(Find-PackCandidates -ToolRoot $ToolRoot -CliValue $CliValue -Configured $cfg['PACK_DIR'])

    if ($candidates.Count -eq 1) {
        $chosen = $candidates[0]
        if ($cfg['PACK_DIR'] -ne $chosen) {
            $cfg['PACK_DIR'] = $chosen
            [void](Save-ToolConfig -ToolRoot $ToolRoot -Config $cfg)
            Write-Host "[信息] 已记住包目录: $chosen" -ForegroundColor Gray
        }
        return (Resolve-Path $chosen).Path
    }

    if ($candidates.Count -gt 1) {
        Write-Host ''
        Write-Host '== 发现多个 packwiz 包目录 ==' -ForegroundColor Cyan
        for ($i = 0; $i -lt $candidates.Count; $i++) {
            Write-Host ("  {0,2}. {1}" -f ($i + 1), $candidates[$i])
        }
        if ($NonInteractive) {
            Write-Host "[信息] 非交互模式, 使用第 1 项" -ForegroundColor Gray
            $chosen = $candidates[0]
        } else {
            $pick = Read-Host '  选择序号'
            if (-not $pick -or $pick -notmatch '^\d+$' -or [int]$pick -lt 1 -or [int]$pick -gt $candidates.Count) { $pick = '1' }
            $chosen = $candidates[[int]$pick - 1]
        }
        $cfg['PACK_DIR'] = $chosen
        [void](Save-ToolConfig -ToolRoot $ToolRoot -Config $cfg)
        Write-Host "[信息] 已记住包目录: $chosen" -ForegroundColor Gray
        return (Resolve-Path $chosen).Path
    }

    if ($NonInteractive) { throw "找不到 packwiz 包目录, 请用 -PackDir 指定, 或设置环境变量 COCO_PACK_DIR" }

    Write-Host '[注意] 未自动找到 packwiz 包目录' -ForegroundColor Yellow
    Write-Host '       需要同时含 pack.toml 与 mods 目录, 且通常是 git 仓库' -ForegroundColor DarkGray
    while ($true) {
        $raw = Read-Host '  packwiz 包目录'
        if (-not $raw) { continue }
        $raw = $raw.Trim('"').TrimEnd('\')
        if (Test-PackDir $raw) {
            $cfg['PACK_DIR'] = $raw
            [void](Save-ToolConfig -ToolRoot $ToolRoot -Config $cfg)
            Write-Host "[信息] 已记住包目录: $raw" -ForegroundColor Gray
            return (Resolve-Path $raw).Path
        }
        Write-Host '  这个目录里没有 pack.toml 或 mods, 请重新输入' -ForegroundColor Yellow
    }
}

# 读取仓库信息: 当前分支, 上游, 远端列表, 远端默认分支
function Get-RepoInfo {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$PackDir,
        [string]$PreferredRemote
    )

    $run = {
        param([string[]]$a)
        $prev = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try {
            $o = & git -C $PackDir @a 2>&1
            $c = $LASTEXITCODE
        } finally { $ErrorActionPreference = $prev }
        return [pscustomobject]@{ Code = $c; Out = ((($o | ForEach-Object { "$_" }) -join "`n")) }
    }

    $r = & $run @('rev-parse','--abbrev-ref','HEAD')
    if ($r.Code -ne 0) { throw "不是 git 仓库或没有提交: $PackDir" }
    $branch = $r.Out.Trim()

    $up = & $run @('rev-parse','--abbrev-ref','--symbolic-full-name','@{u}')
    $upstream = if ($up.Code -eq 0) { $up.Out.Trim() } else { '' }

    $rm = & $run @('remote')
    $remotes = @($rm.Out -split "`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ })

    $remote = ''
    if ($upstream -and $upstream -match '^([^/]+)/(.+)$') { $remote = $Matches[1] }
    if (-not $remote -and $PreferredRemote -and $remotes -contains $PreferredRemote) { $remote = $PreferredRemote }
    if (-not $remote -and $remotes -contains 'origin') { $remote = 'origin' }
    if (-not $remote -and $remotes.Count -gt 0) { $remote = $remotes[0] }

    $defaultBranch = ''
    if ($remote) {
        $h = & $run @('symbolic-ref','--short',"refs/remotes/$remote/HEAD")
        if ($h.Code -eq 0) { $defaultBranch = ($h.Out.Trim() -replace "^$([regex]::Escape($remote))/", '') }
    }

    return [pscustomobject]@{
        Branch        = $branch
        Upstream      = $upstream
        Remote        = $remote
        Remotes       = @($remotes)
        DefaultBranch = $defaultBranch
    }
}
