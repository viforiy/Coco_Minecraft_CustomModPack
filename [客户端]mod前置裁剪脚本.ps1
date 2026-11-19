#requires -version 5
<#
  [客户端]mod前置裁剪脚本.ps1 —— packwiz 元数据前置裁剪(客户端模组分类 + 按人删减)

  位置与角色:
    和 [客户端]mod后处理修复脚本 配对使用.
      后处理修复 = 装完之后修 jar / 配置
      前置裁剪   = 装之前动元数据, 决定哪些模组根本不落地
    由 [客户端]mod更新脚本.bat 在 packwiz refresh 之后、安装器之前调用(-InPlace),
    所以永远作用在本次刚拉下来的那份元数据上, 不存在"用的还是上一版元数据"的问题.
    也可以单独双击运行: 用缓存里的元数据先剪一遍, 顺手把分类报告刷出来.

  它做什么:
    1) 扫 meta\mods\**.pw.toml, 读 side 字段, 把模组分成三类:
         仅客户端 side="client"   双端 side="both" 或无 side   仅服务端 side="server"
    2) 生成 / 维护一份人话清单 [客户端]模组裁剪清单.txt
         行首 #  注释掉 = 保留(默认全是这个状态)
         行首 -  裁剪, 本机不装
         行首 +  强制保留, 白名单模式下必须显式写 +
       清单只按 metafile 相对路径记, 元数据换版本也不会错位.
    3) 按清单把对应 .pw.toml 从元数据目录删掉, 并删掉 mods 里已经落地的 jar,
       再由 packwiz refresh 重建 index.toml 与 pack.toml 哈希, 安装器就不会再装回来.
    4) 出报告 [客户端]模组分类报告.txt 与 %CACHE_ROOT%\mod-classify.tsv(机器可读).

  模式:
    blacklist 默认. 只有写了 - 的行被裁掉, 其余全装.
    whitelist 白名单. 仅客户端模组默认全部裁掉, 只有写了 + 的保留;
              双端模组不吃这套(它们服务端也要, 一律保留, 想剪必须自己写 -).
    想给不同的人不同的裁剪结果, 就各人放各自的清单, 或者用 -Profile 名字区分清单文件.

  不做什么:
    不碰 config / resourcepacks / saves; 不动服务端包; 不改元数据仓远端.
    远端包模式(PACK_SOURCE=remote)下元数据不在本机, 本脚本只出报告不改文件.

  用法:
    双击 = 交互挑选(带编号的客户端模组列表, 输入编号即裁剪/恢复), 结束后按提示退出
    [客户端]mod前置裁剪脚本.bat -Quiet            静默按清单执行, 给 PCL 启动前指令链用
    [客户端]mod前置裁剪脚本.bat -List             只打印分类, 什么都不改
    [客户端]mod前置裁剪脚本.bat -Pick             交互挑选后再执行
    [客户端]mod前置裁剪脚本.bat -Profile 小霸王    换一份清单(清单文件名带后缀)
    [客户端]mod前置裁剪脚本.bat -Reset            备份旧清单后重新生成(全部保留)
    [客户端]mod前置裁剪脚本.bat -Plan             只出报告与清单, 不删任何文件
    [客户端]mod前置裁剪脚本.bat --help            看全部参数

  可写进 mod更新源.cfg 的键(优先级低于命令行参数):
    PRE_TRIM=1              0 = 更新脚本不再调用前置裁剪
    PRE_PROFILE=default     清单文件后缀, default = 不带后缀
    PRE_TRIM_MODE=blacklist blacklist / whitelist
    PRE_TOUCH_MODS=1        0 = 只删元数据, 不动 mods 里已有的 jar
    PRE_FAIL_HARD=0         1 = 裁剪失败就让更新脚本失败中止
    PRE_MAX_TRIM=0          一次最多裁多少个, 0 = 不限制(超过 90% 也会被拦)
#>
[CmdletBinding()]
param(
    [string]$GameDir,
    [string]$MetaDir,
    [string]$CacheRoot,
    [string]$Packwiz,
    [Alias('Profile')]
    [string]$ProfileName,
    [string]$ListFile,
    [ValidateSet('blacklist', 'whitelist')]
    [string]$Mode,
    [string]$CfgFile,
    [switch]$Fresh,
    [switch]$Reset,
    [switch]$Plan,
    [switch]$SkipMods,
    [switch]$SkipRefresh,
    [switch]$InPlace,
    [switch]$Pick,
    [Alias('List')]
    [switch]$ListOnly,
    [switch]$Hard,
    [switch]$Quiet,
    [switch]$Help
)

$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [Text.Encoding]::GetEncoding(936) } catch { }

$script:VER = '1.0.0'
$script:TS = Get-Date -Format 'yyyyMMdd-HHmmss'
$script:Now = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
$script:LogFile = $null
$script:Warns = New-Object System.Collections.ArrayList
$script:IsQuiet = [bool]$Quiet
$script:TrimCount = 0
$script:JarDeleted = 0
$script:JarBytes = 0
$script:Changed = 0
$script:RefreshState = '未执行'

$LIST_DEFAULT = '[客户端]模组裁剪清单.txt'
$REPORT_NAME = '[客户端]模组分类报告.txt'

# ===========================================================================
#  输出与日志
# ===========================================================================
function Say([string]$m) { if (-not $script:IsQuiet) { Write-Host $m } }
function Info([string]$m) { Write-Host "[信息] $m" }
function Ok([string]$m) { Write-Host "[完成] $m" }
function ErrMsg([string]$m) { Write-Host "[错误] $m" }
function Log([string]$m) {
    if (-not $script:LogFile) { return }
    try { [IO.File]::AppendAllText($script:LogFile, "$m`r`n", [Text.Encoding]::GetEncoding(936)) } catch { }
}
function Warn([string]$m) {
    [void]$script:Warns.Add($m)
    Write-Host "[警告] $m"
    Log "[warn] $m"
}

# ===========================================================================
#  文本读写: .pw.toml 是 UTF-8, 清单与报告跟整合包其它文件一样走 GBK(936)
# ===========================================================================
function Read-TextAuto([string]$path) {
    $bytes = [IO.File]::ReadAllBytes($path)
    if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
        return [Text.Encoding]::UTF8.GetString($bytes, 3, $bytes.Length - 3)
    }
    $strict = New-Object Text.UTF8Encoding($false, $true)
    try { return $strict.GetString($bytes) } catch { }
    return [Text.Encoding]::GetEncoding(936).GetString($bytes)
}
function Read-Lines([string]$path) {
    $list = New-Object System.Collections.ArrayList
    if (-not (Test-Path -LiteralPath $path)) { return $list }
    $text = Read-TextAuto $path
    foreach ($l in ($text -split "`r?`n")) { [void]$list.Add($l) }
    return $list
}
function Write-Text936([string]$path, [string]$text) {
    $dir = Split-Path -Parent $path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $enc = [Text.Encoding]::GetEncoding(936)
    [IO.File]::WriteAllText($path, $text, $enc)
}
function Write-TextUtf8Bom([string]$path, [string]$text) {
    $dir = Split-Path -Parent $path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $enc = New-Object Text.UTF8Encoding($true)
    [IO.File]::WriteAllText($path, $text, $enc)
}
function Get-FileSizeText([long]$bytes) {
    if ($bytes -ge 1048576) { return ('{0:N1} MB' -f ($bytes / 1048576)) }
    if ($bytes -ge 1024) { return ('{0:N0} KB' -f ($bytes / 1024)) }
    return "$bytes B"
}
function Get-Sha256Hex([string]$path) {
    $fs = [IO.File]::OpenRead($path)
    try {
        $sha = [Security.Cryptography.SHA256]::Create()
        try { return (($sha.ComputeHash($fs) | ForEach-Object { $_.ToString('x2') }) -join '') }
        finally { $sha.Dispose() }
    } finally { $fs.Dispose() }
}

# ===========================================================================
#  外部程序
# ===========================================================================
function Invoke-Native([string]$exe, [string[]]$argv, [string]$workDir) {
    $out = @()
    $code = 1
    $pushed = $false
    if ($workDir) { Push-Location -LiteralPath $workDir; $pushed = $true }
    try {
        $out = & $exe @argv 2>&1
        $code = $LASTEXITCODE
        if ($null -eq $code) { $code = 0 }
    } catch {
        $out = @("$($_.Exception.Message)")
        $code = 1
    } finally {
        if ($pushed) { try { Pop-Location } catch { } }
    }
    $text = @($out | ForEach-Object { "$_" })
    return New-Object psobject -Property @{ ExitCode = [int]$code; Output = $text }
}

function Find-Packwiz {
    $cands = New-Object System.Collections.ArrayList
    if ($Packwiz) { [void]$cands.Add($Packwiz) }
    if ($MetaDir) { [void]$cands.Add((Join-Path $MetaDir 'packwiz.exe')) }
    if ($script:CACHE) { [void]$cands.Add((Join-Path $script:CACHE 'tools\packwiz.exe')) }
    if ($script:CACHE) { [void]$cands.Add((Join-Path $script:CACHE 'meta\packwiz.exe')) }
    foreach ($c in $cands) {
        if ($c -and (Test-Path -LiteralPath $c)) { return (Resolve-Path -LiteralPath $c).Path }
    }
    $cmd = Get-Command 'packwiz.exe' -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    $cmd = Get-Command 'packwiz' -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    return $null
}

function Find-Git {
    $cmd = Get-Command 'git.exe' -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    foreach ($p in @("$env:ProgramFiles\Git\cmd\git.exe", "${env:ProgramFiles(x86)}\Git\cmd\git.exe", "$env:LocalAppData\Programs\Git\cmd\git.exe")) {
        if ($p -and (Test-Path -LiteralPath $p)) { return $p }
    }
    return $null
}

# ===========================================================================
#  路径与配置
# ===========================================================================
function Resolve-GameDir([string]$p) {
    if ($p -and (Test-Path -LiteralPath $p)) { return (Resolve-Path -LiteralPath $p).Path.TrimEnd('\') }
    foreach ($c in @($PSScriptRoot, (Split-Path -Parent $PSScriptRoot))) {
        if ($c -and (Test-Path -LiteralPath (Join-Path $c 'mods'))) { return $c.TrimEnd('\') }
    }
    if ($PSScriptRoot) { return $PSScriptRoot.TrimEnd('\') }
    return (Get-Location).Path.TrimEnd('\')
}

function Read-CfgFile([string]$path) {
    $h = @{}
    if (-not (Test-Path -LiteralPath $path)) { return $h }
    foreach ($line in (Read-Lines $path)) {
        $t = "$line".Trim()
        if (-not $t -or $t.StartsWith('#')) { continue }
        $i = $t.IndexOf('=')
        if ($i -lt 1) { continue }
        $k = $t.Substring(0, $i).Trim().ToUpperInvariant()
        $v = $t.Substring($i + 1).Trim()
        if ($k) { $h[$k] = $v }
    }
    return $h
}

function Get-CfgValue($cfg, [string]$key, [string]$def) {
    if ($cfg -and $cfg.ContainsKey($key)) {
        $v = "$($cfg[$key])"
        if ($v -ne '') { return $v }
    }
    return $def
}

# ===========================================================================
#  packwiz 元数据解析
# ===========================================================================
function Get-TomlString([string]$text, [string]$key) {
    $pat = '(?m)^[ \t]*' + [regex]::Escape($key) + '[ \t]*=[ \t]*"([^"\r\n]*)"'
    $m = [regex]::Match($text, $pat)
    if ($m.Success) { return $m.Groups[1].Value }
    $pat2 = "(?m)^[ \t]*" + [regex]::Escape($key) + "[ \t]*=[ \t]*'([^'\r\n]*)'"
    $m2 = [regex]::Match($text, $pat2)
    if ($m2.Success) { return $m2.Groups[1].Value }
    return ''
}

function Test-LibraryName([string]$name, [string]$file) {
    $s = "$name $file".ToLowerInvariant()
    foreach ($k in @(' api', 'api-', '-api', ' lib', 'lib-', '-lib', 'library', 'framework', 'core', 'config')) {
        if ($s -like "*$k*") { return $true }
    }
    return $false
}

function Get-ModEntries([string]$root) {
    $out = New-Object System.Collections.ArrayList
    $modsMeta = Join-Path $root 'mods'
    if (-not (Test-Path -LiteralPath $modsMeta)) { return $out }
    $files = @(Get-ChildItem -LiteralPath $modsMeta -Recurse -File -Filter '*.pw.toml' -ErrorAction SilentlyContinue)
    $modsDir = Join-Path $script:GAME 'mods'
    foreach ($f in $files) {
        $rel = $f.FullName.Substring($root.Length).TrimStart('\').Replace('\', '/')
        $text = ''
        try { $text = Read-TextAuto $f.FullName } catch { continue }
        $side = (Get-TomlString $text 'side').ToLowerInvariant()
        switch ($side) {
            '' { $side = 'both' }
            'client' { }
            'server' { }
            default { $side = 'both' }
        }
        $name = Get-TomlString $text 'name'
        if (-not $name) { $name = [IO.Path]::GetFileNameWithoutExtension($f.Name) -replace '\.pw$', '' }
        $fileName = Get-TomlString $text 'filename'
        $link = ''
        if ($text -match '(?m)^[ \t]*\[update\.modrinth\]') {
            $id = Get-TomlString $text 'mod-id'
            if ($id) { $link = "https://modrinth.com/mod/$id" }
        } elseif ($text -match '(?m)^[ \t]*\[update\.curseforge\]') {
            $id = Get-TomlString $text 'project-id'
            if ($id) { $link = "https://www.curseforge.com/projects/$id" }
        }
        $optional = $false
        if ($text -match '(?ms)^[ \t]*\[option\][^\[]*?optional[ \t]*=[ \t]*true') { $optional = $true }

        $installed = $false
        $size = 0
        $jarPath = ''
        if ($fileName) {
            $cand = Join-Path $modsDir $fileName
            if (Test-Path -LiteralPath $cand) {
                $installed = $true
                $jarPath = $cand
                $size = (Get-Item -LiteralPath $cand).Length
            }
        }
        $obj = New-Object psobject -Property @{
            Rel       = $rel
            Name      = $name
            FileName  = $fileName
            Side      = $side
            Link      = $link
            Optional  = $optional
            Installed = $installed
            Size      = [long]$size
            JarPath   = $jarPath
            IsLib     = (Test-LibraryName $name $fileName)
            Trim      = $false
            Reason    = ''
        }
        [void]$out.Add($obj)
    }
    return $out
}

function Get-SideText([string]$side) {
    switch ($side) {
        'client' { return '仅客户端' }
        'server' { return '仅服务端' }
        default { return '双端' }
    }
}

# ===========================================================================
#  裁剪清单: 解析 / 生成 / 合并 / 改写单行
# ===========================================================================
function Get-LineInfo([string]$line) {
    if (-not $line) { return $null }
    $body = $line
    $i = $body.IndexOf('|')
    if ($i -ge 0) { $body = $body.Substring(0, $i) }
    $body = $body.Trim()
    if (-not $body) { return $null }
    $marker = ''
    $c = $body.Substring(0, 1)
    if ($c -eq '#') {
        # "#- xxx" 是被注释掉的裁剪行, 仍然算"清单里提到过", 但不生效
        $body = $body.Substring(1).Trim()
        if ($body -and ($body.Substring(0, 1) -eq '-' -or $body.Substring(0, 1) -eq '+')) { $body = $body.Substring(1).Trim() }
        $marker = '#'
    } elseif ($c -eq '-' -or $c -eq '+') {
        $marker = $c
        $body = $body.Substring(1).Trim()
    }
    if (-not $body) { return $null }
    if (-not $body.ToLowerInvariant().EndsWith('.pw.toml')) { return $null }
    $norm = $body.Replace('\', '/').TrimStart('/')
    if (-not $norm.ToLowerInvariant().StartsWith('mods/')) { $norm = 'mods/' + $norm }
    return New-Object psobject -Property @{ Id = $norm; Marker = $marker }
}

function Read-TrimList([string]$path) {
    $res = New-Object psobject -Property @{
        Trim     = @{}
        Keep     = @{}
        Mention  = @{}
        Mode     = ''
        Lines    = (New-Object System.Collections.ArrayList)
        Exists   = $false
    }
    if (-not (Test-Path -LiteralPath $path)) { return $res }
    $res.Exists = $true
    foreach ($line in (Read-Lines $path)) {
        [void]$res.Lines.Add($line)
        $t = "$line".Trim()
        if ($t -match '^(?i)MODE[ \t]*=[ \t]*(blacklist|whitelist)') {
            $res.Mode = $Matches[1].ToLowerInvariant()
            continue
        }
        $info = Get-LineInfo $line
        if (-not $info) { continue }
        $res.Mention[$info.Id] = 1
        switch ($info.Marker) {
            '-' { $res.Trim[$info.Id] = 1 }
            '+' { $res.Keep[$info.Id] = 1 }
        }
    }
    return $res
}

function New-TrimListText($entries, [string]$modeName, [string]$metaRoot) {
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine('# ============================================================================')
    [void]$sb.AppendLine("# Coco's 整合包 · 客户端模组裁剪清单")
    [void]$sb.AppendLine('#')
    [void]$sb.AppendLine('# 用法: 想在本机不装的模组, 把对应行行首的 # 去掉, 变成 " - " 开头; 想装回来就重新加回 #')
    [void]$sb.AppendLine('#       行首 -  裁剪(本机不装)      行首 +  强制保留      行首 #  注释 / 保留')
    [void]$sb.AppendLine('#       改完保存, 下次启动游戏自动生效; 也可以直接跑 [客户端]mod前置裁剪脚本.bat -Pick 交互挑')
    [void]$sb.AppendLine('#')
    [void]$sb.AppendLine('# 模式 MODE   blacklist = 只裁 - 的行(默认)   whitelist = 仅客户端模组只留 + 的行')
    [void]$sb.AppendLine("#  当前模式    $modeName")
    [void]$sb.AppendLine("#  生成时间    $script:Now")
    [void]$sb.AppendLine("#  元数据目录  $metaRoot")
    [void]$sb.AppendLine('#')
    [void]$sb.AppendLine('# 注意: 名称里带 API / Lib / Core / Framework 的多半是前置库, 裁掉前先确认没有别的模组依赖它')
    [void]$sb.AppendLine('#       双端模组服务端也要用, 裁掉只影响本机; 仅服务端模组客户端本来就不会装')
    [void]$sb.AppendLine('# ============================================================================')
    [void]$sb.AppendLine("MODE=$modeName")
    [void]$sb.AppendLine('')

    $groups = @(
        @{ Side = 'client'; Title = '仅客户端模组 (可以放心裁)' },
        @{ Side = 'both'; Title = '双端模组 (服务端也用, 裁掉只影响本机)' },
        @{ Side = 'server'; Title = '仅服务端模组 (客户端安装器本来就跳过)' }
    )
    foreach ($g in $groups) {
        $items = @($entries | Where-Object { $_.Side -eq $g.Side } | Sort-Object Name)
        if ($items.Count -eq 0) { continue }
        [void]$sb.AppendLine("# ----- $($g.Title): $($items.Count) 个 -----")
        foreach ($e in $items) {
            $sizeTxt = '未安装'
            if ($e.Installed) { $sizeTxt = Get-FileSizeText $e.Size }
            $flag = ''
            if ($e.Optional) { $flag += ' [可选]' }
            if ($e.IsLib) { $flag += ' [疑似前置库]' }
            $line = '#- ' + $e.Rel + '  | ' + $e.Name + ' | ' + $e.FileName + ' | ' + $sizeTxt + $flag
            [void]$sb.AppendLine($line)
        }
        [void]$sb.AppendLine('')
    }
    return $sb.ToString()
}

function Add-MissingToTrimList([string]$path, $entries, [string]$modeName) {
    $state = Read-TrimList $path
    $missing = @($entries | Where-Object { -not $state.Mention.ContainsKey($_.Rel) } | Sort-Object Side, Name)
    if ($missing.Count -eq 0) { return 0 }
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine("# ----- 新增模组, 由脚本自动追加 $script:Now ($($missing.Count) 个) -----")
    foreach ($e in $missing) {
        $sizeTxt = '未安装'
        if ($e.Installed) { $sizeTxt = Get-FileSizeText $e.Size }
        $flag = ''
        if ($e.Optional) { $flag += ' [可选]' }
        if ($e.IsLib) { $flag += ' [疑似前置库]' }
        [void]$sb.AppendLine('#- ' + $e.Rel + '  | ' + $e.Name + ' | ' + $e.FileName + ' | ' + $sizeTxt + ' [' + (Get-SideText $e.Side) + ']' + $flag)
    }
    $old = ''
    if (Test-Path -LiteralPath $path) { $old = Read-TextAuto $path }
    if (-not $old.EndsWith("`n")) { $old += "`r`n" }
    Write-Text936 $path ($old + $sb.ToString())
    return $missing.Count
}

function Set-TrimMarker([string]$path, [string]$id, [bool]$trim) {
    $lines = Read-Lines $path
    $hit = -1
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $info = Get-LineInfo $lines[$i]
        if ($info -and $info.Id -ieq $id) { $hit = $i; break }
    }
    if ($trim) { $newLine = '- ' + $id } else { $newLine = '#- ' + $id }
    if ($hit -ge 0) { $lines[$hit] = $newLine } else { [void]$lines.Add($newLine) }
    Write-Text936 $path (($lines -join "`r`n") + "`r`n")
}

# ===========================================================================
#  索引刷新与哈希校验
# ===========================================================================
function Invoke-Refresh([string]$dir) {
    $pwz = Find-Packwiz
    if (-not $pwz) {
        $script:RefreshState = '跳过(没有 packwiz)'
        return $false
    }
    $r = Invoke-Native $pwz @('refresh') $dir
    Log "packwiz refresh rc=$($r.ExitCode)"
    foreach ($l in $r.Output) { Log "  $l" }
    if ($r.ExitCode -ne 0) {
        $script:RefreshState = "失败(rc=$($r.ExitCode))"
        return $false
    }
    $script:RefreshState = '已刷新'
    return $true
}

function Test-IndexHash([string]$dir) {
    $packFile = Join-Path $dir 'pack.toml'
    $idxFile = Join-Path $dir 'index.toml'
    if (-not (Test-Path -LiteralPath $packFile)) { return @{ Ok = $false; Msg = '缺少 pack.toml' } }
    if (-not (Test-Path -LiteralPath $idxFile)) { return @{ Ok = $false; Msg = '缺少 index.toml' } }
    $text = Read-TextAuto $packFile
    $declared = ''
    $m = [regex]::Match($text, '(?ms)^[ \t]*\[index\][^\[]*?hash[ \t]*=[ \t]*"([^"]*)"')
    if ($m.Success) { $declared = $m.Groups[1].Value }
    $actual = Get-Sha256Hex $idxFile
    if (-not $declared) { return @{ Ok = $false; Msg = 'pack.toml 里没有 index.hash' } }
    if ($declared.ToLowerInvariant() -eq $actual) { return @{ Ok = $true; Msg = 'ok' } }
    return @{ Ok = $false; Msg = "哈希不一致 declared=$declared actual=$actual" }
}

function Repair-IndexHash([string]$dir) {
    $packFile = Join-Path $dir 'pack.toml'
    $idxFile = Join-Path $dir 'index.toml'
    if (-not (Test-Path -LiteralPath $packFile) -or -not (Test-Path -LiteralPath $idxFile)) { return $false }
    $actual = Get-Sha256Hex $idxFile
    $text = Read-TextAuto $packFile
    $new = [regex]::Replace($text, '(?ms)(^[ \t]*\[index\][^\[]*?hash[ \t]*=[ \t]*")[^"]*(")', { param($m) $m.Groups[1].Value + $actual + $m.Groups[2].Value })
    if ($new -eq $text) { return $false }
    # pack.toml 必须是无 BOM 的 UTF-8, 带 BOM 会让 packwiz 的 TOML 解析器报错
    $enc = New-Object Text.UTF8Encoding($false)
    [IO.File]::WriteAllText($packFile, $new, $enc)
    Log "index.hash 手工改写为 $actual"
    return $true
}

# ===========================================================================
#  帮助
# ===========================================================================
function Show-Help {
    Write-Host ''
    Write-Host "  Coco's 整合包 - 客户端 Mod 前置裁剪脚本 v$script:VER"
    Write-Host ''
    Write-Host '  作用: 在 packwiz 安装器跑之前, 把元数据里的客户端模组按清单删减掉,'
    Write-Host '        并删掉 mods 里已经落地的 jar, 让不同机器只装自己想要的那部分.'
    Write-Host ''
    Write-Host '  常用'
    Write-Host '    双击 bat                      交互挑选(带编号列表), 选完直接生效'
    Write-Host '    bat -Quiet                    静默按清单执行, 给 PCL 启动前指令链用'
    Write-Host '    bat -List                     只打印分类, 不动元数据与 mods'
    Write-Host '    bat -Pick                     交互挑选后再执行'
    Write-Host '    bat -Plan                     只出清单与报告, 不删文件'
    Write-Host '    bat -Reset                    备份旧清单后重新生成(全部保留)'
    Write-Host '    bat -Profile 小霸王            用另一份清单: [客户端]模组裁剪清单.小霸王.txt'
    Write-Host '    bat --help                    看这份帮助'
    Write-Host ''
    Write-Host '  给更新脚本内部调用(一般不用手写)'
    Write-Host '    -InPlace -MetaDir <目录> -GameDir <目录> -CacheRoot <目录> -Packwiz <exe>'
    Write-Host '        直接对刚同步好的元数据目录动手, 索引刷新交给更新脚本自己做'
    Write-Host '    -SkipMods -SkipRefresh -Hard    细分开关'
    Write-Host ''
    Write-Host '  文件'
    Write-Host "    裁剪清单  $script:GAME\$script:LISTNAME"
    Write-Host "    分类报告  $script:GAME\$REPORT_NAME"
    Write-Host "    机器可读  $($script:CACHE)\mod-classify.tsv"
    Write-Host "    日志      $($script:CACHE)\logs\pre-trim-*.log"
    Write-Host ''
}

# ===========================================================================
#  主流程
# ===========================================================================
$script:GAME = Resolve-GameDir $GameDir

if ($Help) {
    $script:CACHE = if ($CacheRoot) { $CacheRoot } else { Join-Path $env:LocalAppData 'CocoPackwiz' }
    $script:LISTNAME = $LIST_DEFAULT
    Show-Help
    exit 0
}

# --- 元数据仓防呆: 在仓库目录里跑会把清单写进仓库 ---
if (Test-Path -LiteralPath (Join-Path $script:GAME 'pack.toml')) {
    ErrMsg "本目录里有 pack.toml, 看起来是模组元数据仓而不是整合包实例"
    Write-Host "       请把本脚本放进整合包实例目录(含 mods 与 PCL启动前命令.txt 的那一层)"
    Log 'abort: game dir looks like metadata repo'
    exit 1
}

# --- 缓存目录: 与更新脚本保持一致, 不可写时退回实例目录 ---
if (-not $CacheRoot) { $CacheRoot = $env:COCO_CACHE_ROOT }
if (-not $CacheRoot) { $CacheRoot = Join-Path $env:LocalAppData 'CocoPackwiz' }
try {
    if (-not (Test-Path -LiteralPath $CacheRoot)) { New-Item -ItemType Directory -Path $CacheRoot -Force | Out-Null }
    $probe = Join-Path $CacheRoot '.write-test'
    [IO.File]::WriteAllText($probe, 'x')
    Remove-Item -LiteralPath $probe -Force
} catch {
    $CacheRoot = Join-Path $script:GAME '.packwiz-cache'
    New-Item -ItemType Directory -Path $CacheRoot -Force | Out-Null
}
$script:CACHE = (Resolve-Path -LiteralPath $CacheRoot).Path.TrimEnd('\')

$logDir = Join-Path $script:CACHE 'logs'
if (-not (Test-Path -LiteralPath $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
$script:LogFile = Join-Path $logDir "pre-trim-$script:TS.log"
Log "=== Coco 前置裁剪 v$script:VER $script:TS ==="
Log "GAME=$($script:GAME)"
Log "CACHE=$($script:CACHE)"
Log "MODEARGS inPlace=$InPlace plan=$Plan list=$ListOnly pick=$Pick quiet=$Quiet"

# --- 配置文件 ---
if (-not $CfgFile) { $CfgFile = Join-Path $script:GAME 'mod更新源.cfg' }
$cfg = Read-CfgFile $CfgFile
Log "CFG=$CfgFile keys=$($cfg.Keys.Count)"

if (-not $ProfileName) { $ProfileName = Get-CfgValue $cfg 'PRE_PROFILE' 'default' }
$ProfileName = "$ProfileName".Trim()
$script:ProfileName = $ProfileName
if ($ProfileName -and $ProfileName -ne 'default') {
    $script:LISTNAME = '[客户端]模组裁剪清单.' + ($ProfileName -replace '[\\/:*?"<>|]', '_') + '.txt'
} else {
    $script:LISTNAME = $LIST_DEFAULT
}
if (-not $ListFile) { $ListFile = Join-Path $script:GAME $script:LISTNAME }
$script:LISTNAME = Split-Path -Leaf $ListFile

if (-not $Mode) { $Mode = (Get-CfgValue $cfg 'PRE_TRIM_MODE' 'blacklist').ToLowerInvariant() }
if ($Mode -ne 'whitelist') { $Mode = 'blacklist' }
# 清单里的 MODE= 行优先级高于 cfg, 但低于命令行 -Mode
if (-not $PSBoundParameters.ContainsKey('Mode') -and (Test-Path -LiteralPath $ListFile)) {
    $preMode = (Read-TrimList $ListFile).Mode
    if ($preMode) { $Mode = $preMode }
}

$touchMods = (Get-CfgValue $cfg 'PRE_TOUCH_MODS' '1') -ne '0'
if ($SkipMods) { $touchMods = $false }

# --- 元数据目录 ---
if (-not $MetaDir) { $MetaDir = Join-Path $script:CACHE 'meta' }
$metaRoot = $null
if (Test-Path -LiteralPath (Join-Path $MetaDir 'pack.toml')) {
    $metaRoot = (Resolve-Path -LiteralPath $MetaDir).Path.TrimEnd('\')
}
if (-not $metaRoot) {
    Info '本机还没有 packwiz 元数据缓存, 先跑一次 [客户端]mod更新脚本.bat 再来'
    Warn "没有元数据目录: $MetaDir"
    Log 'abort: meta missing'
    if ($Hard) { exit 1 }
    exit 0
}
$script:META = $metaRoot
$git = Find-Git

# --- -Fresh: 单独跑的时候先把缓存里的元数据拉到最新, 更新脚本内部调用时不用(它刚同步过) ---
if ($Fresh) {
    if (-not $InPlace -and $git -and (Test-Path -LiteralPath (Join-Path $metaRoot '.git'))) {
        Info '同步元数据仓 (-Fresh)'
        $rf = Invoke-Native $git @('-C', $metaRoot, '-c', 'core.autocrlf=false', 'fetch', '--depth', '1', 'origin')
        if ($rf.ExitCode -eq 0) {
            $rr = Invoke-Native $git @('-C', $metaRoot, 'reset', '--hard', 'FETCH_HEAD')
            if ($rr.ExitCode -eq 0) { Ok '元数据已更新到远端最新' } else { Warn "git reset 失败 rc=$($rr.ExitCode)" }
        } else {
            Warn "git fetch 失败 rc=$($rf.ExitCode), 继续用本机缓存"
        }
    } else {
        Info '更新脚本内部调用或没有 git, 跳过 -Fresh 同步'
    }
}

$gitHead = ''
if ($git -and (Test-Path -LiteralPath (Join-Path $metaRoot '.git'))) {
    $r = Invoke-Native $git @('-C', $metaRoot, 'rev-parse', '--short', 'HEAD')
    if ($r.ExitCode -eq 0 -and $r.Output.Count -gt 0) { $gitHead = "$($r.Output[0])".Trim() }
}

# --- 分类 ---
Say ''
Say "Coco's 整合包 - 客户端 Mod 前置裁剪"
Say '  ------------------------------------------------------------------'
Say "  整合包目录 : $($script:GAME)"
Say "  元数据目录 : $metaRoot$(if ($gitHead) { "  (git $gitHead)" })"
Say "  裁剪清单   : $ListFile"
Say "  裁剪模式   : $Mode"

$entries = Get-ModEntries $metaRoot
if ($entries.Count -eq 0) {
    Info '元数据里没有 mods/*.pw.toml, 没有可分类的模组'
    Log 'abort: no entries'
    if ($Hard) { exit 1 }
    exit 0
}
$clientList = @($entries | Where-Object { $_.Side -eq 'client' } | Sort-Object Name)
$bothList = @($entries | Where-Object { $_.Side -eq 'both' } | Sort-Object Name)
$serverList = @($entries | Where-Object { $_.Side -eq 'server' } | Sort-Object Name)
Log "classify total=$($entries.Count) client=$($clientList.Count) both=$($bothList.Count) server=$($serverList.Count)"

Info ("元数据 $($entries.Count) 个: 仅客户端 $($clientList.Count) / 双端 $($bothList.Count) / 仅服务端 $($serverList.Count)")

# --- 清单: 生成 / 合并 / 重置 ---
if ($Reset) {
    if (Test-Path -LiteralPath $ListFile) {
        $bak = "$ListFile.bak-$script:TS"
        Copy-Item -LiteralPath $ListFile -Destination $bak -Force
        Info "旧清单已备份: $bak"
    }
    Write-Text936 $ListFile (New-TrimListText $entries $Mode $metaRoot)
    Ok "裁剪清单已重建(全部保留): $ListFile"
    Log "list reset -> $ListFile"
} elseif (-not (Test-Path -LiteralPath $ListFile)) {
    Write-Text936 $ListFile (New-TrimListText $entries $Mode $metaRoot)
    Ok "裁剪清单已生成: $ListFile"
    Info '默认全部保留; 想裁哪个就去掉该行行首的 #'
    Log "list seeded -> $ListFile"
} else {
    $added = Add-MissingToTrimList $ListFile $entries $Mode
    if ($added -gt 0) { Info "清单里补上了新增的 $added 个模组(默认保留)" }
}

$state = Read-TrimList $ListFile
if ($state.Mode -and $state.Mode -ne $Mode -and -not $PSBoundParameters.ContainsKey('Mode')) {
    $Mode = $state.Mode
    Info "清单里指定了 MODE=$Mode, 按清单来"
}

# --- 计算裁剪集合 ---
$known = @{}
foreach ($e in $entries) { $known[$e.Rel] = $e }
foreach ($id in $state.Trim.Keys) {
    if (-not $known.ContainsKey($id)) { Warn "清单里的裁剪项在元数据里找不到, 已忽略: $id" }
}
foreach ($id in $state.Keep.Keys) {
    if (-not $known.ContainsKey($id)) { Warn "清单里的保留项在元数据里找不到, 已忽略: $id" }
}

$toTrim = New-Object System.Collections.ArrayList
foreach ($e in $entries) {
    $trim = $false
    $why = ''
    if ($state.Trim.ContainsKey($e.Rel)) {
        $trim = $true
        $why = '清单指定'
    } elseif ($Mode -eq 'whitelist' -and $e.Side -eq 'client' -and -not $state.Keep.ContainsKey($e.Rel)) {
        $trim = $true
        $why = '白名单未列出'
    }
    if ($trim -and $state.Keep.ContainsKey($e.Rel)) {
        $trim = $false
        $why = ''
    }
    if ($trim) { $e.Trim = $true; $e.Reason = $why; [void]$toTrim.Add($e) }
}

# --- 拦一道: 一次裁太多就只出报告, 不动文件 ---
function Test-TrimBlocked($list, $allEntries) {
    if ($list.Count -eq 0) { return $false }
    $maxTrim = 0
    $maxTxt = Get-CfgValue $cfg 'PRE_MAX_TRIM' '0'
    if ($maxTxt -match '^\d+$') { $maxTrim = [int]$maxTxt }
    if ($maxTrim -gt 0 -and $list.Count -gt $maxTrim) {
        Warn "本次要裁 $($list.Count) 个, 超过 PRE_MAX_TRIM=$maxTrim, 已拦下不改文件"
        return $true
    }
    if ($list.Count -gt 20 -and $list.Count -ge [math]::Floor($allEntries.Count * 0.9)) {
        Warn "本次要裁 $($list.Count) / $($allEntries.Count) 个模组, 比例太高, 已拦下不改文件"
        Warn '确实是这个打算的话, 在 mod更新源.cfg 里写 PRE_MAX_TRIM=条目数 再跑'
        return $true
    }
    return $false
}

# --- 交互挑选 ---
function Invoke-Picker {
    if (-not $Pick) { return }
    if ($script:IsQuiet) { return }
    if ([Console]::IsInputRedirected) {
        Say '  (检测到标准输入被重定向, 跳过交互挑选)'
        return
    }
    $pool = @($entries | Where-Object { $_.Side -eq 'client' } | Sort-Object Name)
    if ($pool.Count -eq 0) { return }
    $st = Read-TrimList $ListFile
    while ($true) {
        Write-Host ''
        Write-Host '  ============ 可裁剪的仅客户端模组 ============'
        for ($i = 0; $i -lt $pool.Count; $i++) {
            $e = $pool[$i]
            $mark = '  保留'
            if ($st.Trim.ContainsKey($e.Rel)) { $mark = '  裁剪' }
            $sizeTxt = '未安装'
            if ($e.Installed) { $sizeTxt = Get-FileSizeText $e.Size }
            $libTxt = ''
            if ($e.IsLib) { $libTxt = ' [前置库?]' }
            Write-Host ("  [{0,3}] {1}  {2,-34} {3,-10}{4}" -f ($i + 1), $mark, $e.Name, $sizeTxt, $libTxt)
        }
        $trimmedNow = @($pool | Where-Object { $st.Trim.ContainsKey($_.Rel) }).Count
        Write-Host ''
        Write-Host "  当前: 裁剪 $trimmedNow / 保留 $($pool.Count - $trimmedNow)"
        Write-Host '  输入编号(空格或逗号分隔)切换裁剪/保留, a=全裁 n=全留 l=重列 q=完成退出:'
        $ans = Read-Host '  > '
        if ($null -eq $ans) { break }
        $ans = "$ans".Trim()
        if ($ans -eq '' -or $ans -ieq 'q') { break }
        if ($ans -ieq 'l') { continue }
        if ($ans -ieq 'a') {
            foreach ($e in $pool) { Set-TrimMarker $ListFile $e.Rel $true }
            $st = Read-TrimList $ListFile
            continue
        }
        if ($ans -ieq 'n') {
            foreach ($e in $pool) { Set-TrimMarker $ListFile $e.Rel $false }
            $st = Read-TrimList $ListFile
            continue
        }
        $nums = [regex]::Matches($ans, '\d+')
        if ($nums.Count -eq 0) { Write-Host '  没看懂, 再试一次'; continue }
        foreach ($m in $nums) {
            $idx = [int]$m.Value
            if ($idx -lt 1 -or $idx -gt $pool.Count) { continue }
            $e = $pool[$idx - 1]
            $nowTrim = $st.Trim.ContainsKey($e.Rel)
            Set-TrimMarker $ListFile $e.Rel (-not $nowTrim)
        }
        $st = Read-TrimList $ListFile
    }
    if ($pool.Count -gt 0) {
        $st2 = Read-TrimList $ListFile
        $cnt = @($pool | Where-Object { $st2.Trim.ContainsKey($_.Rel) }).Count
        Ok "清单已保存, 仅客户端模组裁剪 $cnt / $($pool.Count)"
    }
}

Invoke-Picker

# 交互之后重新计算一遍, 保证与最终清单一致
$state = Read-TrimList $ListFile
$toTrim = New-Object System.Collections.ArrayList
foreach ($e in $entries) {
    $e.Trim = $false
    $e.Reason = ''
    $trim = $false
    if ($state.Trim.ContainsKey($e.Rel)) {
        $trim = $true
        $e.Reason = '清单指定'
    } elseif ($Mode -eq 'whitelist' -and $e.Side -eq 'client' -and -not $state.Keep.ContainsKey($e.Rel)) {
        $trim = $true
        $e.Reason = '白名单未列出'
    }
    if ($trim -and $state.Keep.ContainsKey($e.Rel)) { $trim = $false; $e.Reason = '' }
    if ($trim) { $e.Trim = $true; [void]$toTrim.Add($e) }
}
if (Test-TrimBlocked $toTrim $entries) {
    foreach ($e in $toTrim) { $e.Trim = $false; $e.Reason = '' }
    $toTrim.Clear()
}
$script:TrimCount = $toTrim.Count

foreach ($e in $toTrim) { Log "trim $($e.Rel) side=$($e.Side) name=$($e.Name) why=$($e.Reason)" }

# --- 执行: 删元数据 / 删 jar / 刷索引 ---
$applyFiles = (-not $ListOnly) -and (-not $Plan)
if ($ListOnly) { Info '只列分类(-List), 不改任何文件' }

if ($toTrim.Count -gt 0) {
    if ($applyFiles) {
        $removed = 0
        foreach ($e in $toTrim) {
            $p = Join-Path $metaRoot ($e.Rel.Replace('/', '\'))
            if (Test-Path -LiteralPath $p) {
                try { Remove-Item -LiteralPath $p -Force; $removed++; $script:Changed = 1 }
                catch { Warn "删不掉元数据文件: $p  $($_.Exception.Message)" }
            }
        }
        Ok "已从元数据删除 $removed 个 metafile"

        if ($touchMods) {
            $modsDir = Join-Path $script:GAME 'mods'
            foreach ($e in $toTrim) {
                if (-not $e.FileName) { continue }
                $jar = Join-Path $modsDir $e.FileName
                if (-not (Test-Path -LiteralPath $jar)) { continue }
                $sz = (Get-Item -LiteralPath $jar).Length
                try {
                    Remove-Item -LiteralPath $jar -Force
                    $script:JarDeleted++
                    $script:JarBytes += $sz
                    $script:Changed = 1
                    Log "jar removed $jar ($sz bytes)"
                } catch {
                    Warn "删不掉 jar(游戏可能正开着): $jar"
                }
            }
            if ($script:JarDeleted -gt 0) { Ok "已从 mods 删除 $($script:JarDeleted) 个 jar, 共 $(Get-FileSizeText $script:JarBytes)" }
        }

        if ($InPlace) {
            $script:RefreshState = '交给更新脚本刷新'
        } elseif ($SkipRefresh) {
            $script:RefreshState = '跳过(-SkipRefresh)'
        } else {
            if (Invoke-Refresh $metaRoot) {
                $chk = Test-IndexHash $metaRoot
                if (-not $chk.Ok) {
                    Warn "索引哈希校验不过: $($chk.Msg)"
                    if (Repair-IndexHash $metaRoot) {
                        $chk2 = Test-IndexHash $metaRoot
                        if ($chk2.Ok) { Ok '已手工改写 pack.toml 的 index.hash' } else { Warn "手工改写后仍不一致: $($chk2.Msg)" }
                    }
                }
            } else {
                Warn 'packwiz refresh 没成功, index.toml 可能还留着已删的 metafile, 安装器会报 404'
            }
        }
    } else {
        $script:RefreshState = 'plan 模式未刷新'
        Info "本次将裁剪 $($toTrim.Count) 个模组(plan 模式, 未动文件)"
    }
} else {
    $script:RefreshState = '无需刷新'
    Info '清单里没有要裁剪的模组, 全部保留'
}

# --- 报告 ---
$sb = New-Object System.Text.StringBuilder
[void]$sb.AppendLine('=' * 78)
[void]$sb.AppendLine("Coco's 整合包 · 客户端模组分类与裁剪报告")
[void]$sb.AppendLine('=' * 78)
[void]$sb.AppendLine("生成时间      : $script:Now")
[void]$sb.AppendLine("脚本版本      : v$script:VER")
[void]$sb.AppendLine("整合包目录    : $($script:GAME)")
[void]$sb.AppendLine("元数据目录    : $metaRoot")
if ($gitHead) { [void]$sb.AppendLine("元数据版本    : git $gitHead") }
[void]$sb.AppendLine("裁剪清单      : $ListFile")
[void]$sb.AppendLine("裁剪模式      : $Mode")
$pwz = Find-Packwiz
if ($pwz) { [void]$sb.AppendLine("packwiz       : $pwz") }
[void]$sb.AppendLine("索引刷新      : $($script:RefreshState)")
[void]$sb.AppendLine('')
[void]$sb.AppendLine('模组分类统计')
[void]$sb.AppendLine('-' * 78)
[void]$sb.AppendLine("总计 metafile       : $($entries.Count)")
[void]$sb.AppendLine("仅客户端 side=client: $($clientList.Count)")
[void]$sb.AppendLine("双端     side=both   : $($bothList.Count)")
[void]$sb.AppendLine("仅服务端 side=server: $($serverList.Count)")
[void]$sb.AppendLine("本次裁剪            : $($toTrim.Count)")
[void]$sb.AppendLine("已删 jar            : $($script:JarDeleted) 个, $(Get-FileSizeText $script:JarBytes)")
[void]$sb.AppendLine('')
if ($toTrim.Count -gt 0) {
    [void]$sb.AppendLine('本次裁剪的模组')
    [void]$sb.AppendLine('-' * 78)
    foreach ($e in ($toTrim | Sort-Object Side, Name)) {
        $sizeTxt = '未安装'
        if ($e.Installed) { $sizeTxt = Get-FileSizeText $e.Size }
        [void]$sb.AppendLine(("  [{0}] {1}" -f (Get-SideText $e.Side), $e.Name))
        [void]$sb.AppendLine("      metafile : $($e.Rel)")
        [void]$sb.AppendLine("      jar      : $($e.FileName)  ($sizeTxt, $($e.Reason))")
        if ($e.Link) { [void]$sb.AppendLine("      链接     : $($e.Link)") }
        if ($e.IsLib) { [void]$sb.AppendLine('      注意     : 名称像前置库, 确认没有别的模组依赖它') }
    }
    [void]$sb.AppendLine('')
}
function Write-EntrySection($builder, [string]$title, $items, [string]$note) {
    [void]$builder.AppendLine($title)
    [void]$builder.AppendLine('-' * 78)
    if ($note) { [void]$builder.AppendLine("  $note") }
    foreach ($e in $items) {
        $flag = '保留'
        if ($e.Trim) { $flag = '裁剪' }
        $sizeTxt = '未安装'
        if ($e.Installed) { $sizeTxt = Get-FileSizeText $e.Size }
        $extra = ''
        if ($e.IsLib) { $extra = '  [前置库?]' }
        if ($e.Optional) { $extra += '  [可选]' }
        [void]$builder.AppendLine(("[{0}] {1,-38} {2,-10} {3}{4}" -f $flag, $e.Name, $sizeTxt, $e.Rel, $extra))
    }
    [void]$builder.AppendLine('')
}
Write-EntrySection $sb "仅客户端模组 ($($clientList.Count))  —— 裁剪最安全的一档" $clientList '裁掉后本机没有这个功能, 服务端与其它人不受影响'
Write-EntrySection $sb "双端模组 ($($bothList.Count))  —— 服务端也装, 裁掉只影响本机" $bothList '清单里也给了这些行, 想裁必须自己写 - 开头'
Write-EntrySection $sb "仅服务端模组 ($($serverList.Count))  —— 客户端安装器本来就跳过" $serverList '平时不用管, 出现在这里只是为了分类完整'
[void]$sb.AppendLine('怎么改')
[void]$sb.AppendLine('-' * 78)
[void]$sb.AppendLine("  1) 打开 $ListFile")
[void]$sb.AppendLine('  2) 想不装的模组, 把该行行首的 # 去掉(变成 - 开头); 想装回来再加回 #')
[void]$sb.AppendLine('  3) 保存后下次启动游戏自动生效; 也可以双击 [客户端]mod前置裁剪脚本.bat -Pick 交互挑')
[void]$sb.AppendLine('  4) 裁剪只作用于本机 mods 与本次安装, 元数据仓和别人的整合包不受影响')
if ($script:Warns.Count -gt 0) {
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('本次警告')
    [void]$sb.AppendLine('-' * 78)
    foreach ($w in $script:Warns) { [void]$sb.AppendLine("  ! $w") }
}
$reportPath = Join-Path $script:GAME $REPORT_NAME
Write-Text936 $reportPath $sb.ToString()
Ok "分类报告: $reportPath"

# --- 机器可读清单 ---
$tsv = New-Object System.Text.StringBuilder
[void]$tsv.AppendLine("metafile`tside`tname`tfilename`tstatus`tinstalled`tbytes`tlink`tlibrary")
foreach ($e in ($entries | Sort-Object Side, Name)) {
    $st = 'keep'
    if ($e.Trim) { $st = 'trim' }
    $inst = '0'
    if ($e.Installed) { $inst = '1' }
    $lib = '0'
    if ($e.IsLib) { $lib = '1' }
    [void]$tsv.AppendLine(("{0}`t{1}`t{2}`t{3}`t{4}`t{5}`t{6}`t{7}`t{8}" -f $e.Rel, $e.Side, $e.Name, $e.FileName, $st, $inst, $e.Size, $e.Link, $lib))
}
$tsvPath = Join-Path $script:CACHE 'mod-classify.tsv'
Write-TextUtf8Bom $tsvPath $tsv.ToString()
Log "report=$reportPath tsv=$tsvPath"

# --- 状态文件, 给更新脚本看 ---
$statePath = Join-Path $script:CACHE 'pre-trim-state.cfg'
$stateText = New-Object System.Text.StringBuilder
[void]$stateText.AppendLine("TS=$script:TS")
[void]$stateText.AppendLine("MODE=$Mode")
[void]$stateText.AppendLine("PROFILE=$ProfileName")
[void]$stateText.AppendLine("TOTAL=$($entries.Count)")
[void]$stateText.AppendLine("CLIENT=$($clientList.Count)")
[void]$stateText.AppendLine("TRIMMED=$($toTrim.Count)")
[void]$stateText.AppendLine("JARS=$($script:JarDeleted)")
[void]$stateText.AppendLine("CHANGED=$($script:Changed)")
[void]$stateText.AppendLine("REFRESH=$($script:RefreshState)")
Write-Text936 $statePath $stateText.ToString()

# --- 控制台摘要 ---
Say ''
if ($toTrim.Count -gt 0) {
    Info "本次裁剪 $($toTrim.Count) 个模组:"
    foreach ($e in ($toTrim | Sort-Object Side, Name)) {
        Say ("  - [{0}] {1}  ({2})" -f (Get-SideText $e.Side), $e.Name, $e.Rel)
    }
}
Say "  清单: $ListFile"
Say "  报告: $reportPath"
Say "  日志: $script:LogFile"
Say ''
Log "done trimmed=$($toTrim.Count) jars=$($script:JarDeleted) changed=$($script:Changed) refresh=$($script:RefreshState)"

if ($Hard -and $script:Warns.Count -gt 0) { exit 1 }
exit 0
