#requires -version 5
<#
  Coco's 整合包 · MCEF 依赖下载通道封闭
  ---------------------------------------------------------------------------
  作用 : MCEF(Chromium) 在 org.cef.SystemBootstrap 的静态初始化里起后台线程, 无条件执行
           MCEFDownloader.downloadJavaCefChecksum()
         它会 HTTP GET <mirror>/java-cef-builds/<commit>/<平台>.tar.gz.sha256, 再和本地
         mods/mcef-libraries/<平台>.tar.gz.sha256 逐字节比对, 不一致就重下 124MB 的 .tar.gz.
         配置里的 skip-download=true 只挡住"下压缩包"那一步, 挡不住每次启动的 checksum 请求.
  处理 : 1) 把 downloadJavaCefChecksum() 的方法体改成 `return true;`(纯本地判断, 声明本地已是最新),
            其余方法/字段/常量池原样保留, 只替换这一个 Code 属性 -> 那个线程不再发请求;
         2) config\mcef\mcef.properties 里写 skip-download=true 双保险.
  幂等 : 已经是 return true 的 jar 直接跳过; 改前备份 *.bak-mcefdownload
  回滚 : 把 <jar>.bak-mcefdownload 改名回原 jar, 再删掉 config\mcef\mcef.properties 里的 skip-download
  备注 : MCEF 升级后方法签名变了的话, 脚本报"未找到目标方法"并原样退出, 不会破坏 jar
  用法 : mcef-block-download.ps1 [-GameDir <实例目录>] [-Jar <jar路径>] [-NoConfig] [-Quiet] [-Help]
#>
param(
    [string]$GameDir,
    [string]$Jar,
    [switch]$NoConfig,
    [switch]$Quiet,
    [switch]$Help
)

$ErrorActionPreference = 'Stop'

# ===== 统一路径: 从脚本位置往上最多 3 层, 找含 mods 的实例目录 =====
# 脚本住在 <实例目录>\Coco's Script\ 里(当前布局); 直接放根目录(老布局)也兼容
function Resolve-InstanceDir([string]$p) {
    if ($p -and (Test-Path -LiteralPath (Join-Path $p 'mods'))) { return (Resolve-Path -LiteralPath $p).Path.TrimEnd('\') }
    if ($env:COCO_GAME_DIR -and (Test-Path -LiteralPath (Join-Path $env:COCO_GAME_DIR 'mods'))) {
        return (Resolve-Path -LiteralPath $env:COCO_GAME_DIR).Path.TrimEnd('\')
    }
    $cur = $PSScriptRoot
    for ($i = 0; $i -lt 4 -and $cur; $i++) {
        if (Test-Path -LiteralPath (Join-Path $cur 'mods')) { return $cur.TrimEnd('\') }
        $parent = Split-Path -Parent $cur
        if (-not $parent -or $parent -eq $cur) { break }
        $cur = $parent
    }
    return ''
}

# ===== 统一输出 =====
function Say([string]$m) { if (-not $Quiet) { Write-Host $m } }
function Info([string]$m) { Write-Host "[信息] $m" }
function Done([string]$m) { Write-Host "[完成] $m" }
function Warn([string]$m) { Write-Host "[警告] $m" }
function Skip([string]$m) { Write-Host "[跳过] $m"; exit 0 }
function Fail([string]$m) {
    Write-Host "[错误] $m"
    if (-not $Quiet) { Read-Host '按回车退出' | Out-Null }
    exit 1
}

$CLASS = 'com/cinemamod/mcef/MCEFDownloader.class'
$METHOD = 'downloadJavaCefChecksum'
$DESC = '()Z'

if ($Help) {
    Write-Host ''
    Write-Host "  Coco's 整合包 · MCEF 依赖下载通道封闭"
    Write-Host ''
    Write-Host '  用法  mcef-block-download.ps1 [-GameDir <实例目录>] [-Jar <jar路径>] [-NoConfig] [-Quiet] [-Help]'
    Write-Host ''
    Write-Host '    -GameDir   实例目录(含 mods), 默认从脚本位置往上自动找'
    Write-Host '    -Jar       直接指定 mcef 的 jar'
    Write-Host '    -NoConfig  只改 jar, 不碰 config\mcef\mcef.properties'
    Write-Host '    -Quiet     静默, 不打印细节也不等待回车'
    Write-Host ''
    Write-Host '  返回码 0 = 已封闭 / 本来就已封闭 / 没装 mcef    1 = 出错'
    Write-Host ''
    exit 0
}

Add-Type -AssemblyName System.IO.Compression.FileSystem

# ---------- 1. 定位 ----------
$GameDir = Resolve-InstanceDir $GameDir
if (-not $GameDir) { Fail '找不到实例目录(需含 mods); 用 -GameDir 指定' }
if ([string]::IsNullOrWhiteSpace($Jar)) {
    $j = @(Get-ChildItem -LiteralPath (Join-Path $GameDir 'mods') -Filter 'mcef*.jar' -ErrorAction SilentlyContinue |
           Where-Object { $_.Extension -eq '.jar' } | Select-Object -First 1)
    if ($j.Count -eq 0) { Skip 'mods 里没有 mcef*.jar, 本机没有这个 mod' }
    $Jar = $j[0].FullName
}
if (-not (Test-Path -LiteralPath $Jar)) { Fail "找不到 MCEF jar: $Jar" }
Info "实例目录: $GameDir"
Info "MCEF jar: $Jar"

# ---------- 2. 字节读取工具 ----------
function U1($b, $o) { return [int]$b[$o] }
function U2($b, $o) { return (([int]$b[$o]) -shl 8) -bor ([int]$b[$o + 1]) }
function U4($b, $o) { return ((([int]$b[$o]) -shl 24) -bor (([int]$b[$o + 1]) -shl 16) -bor (([int]$b[$o + 2]) -shl 8) -bor ([int]$b[$o + 3])) }

function Get-CodeTarget($b) {
    # 返回 @{ AttrStart; ContentStart; Length } 或 $null
    if ((U4 $b 0) -ne 0xCAFEBABE) { throw '不是 class 文件' }
    $o = 8
    $cpCount = U2 $b $o; $o += 2
    $utf8 = @{}
    $i = 1
    while ($i -lt $cpCount) {
        $tag = U1 $b $o; $o += 1
        switch ($tag) {
            1 { $len = U2 $b $o; $o += 2; $utf8[$i] = [Text.Encoding]::UTF8.GetString($b, $o, $len); $o += $len }
            3 { $o += 4 }
            4 { $o += 4 }
            5 { $o += 8; $i++ }
            6 { $o += 8; $i++ }
            7 { $o += 2 }
            8 { $o += 2 }
            9 { $o += 4 }
            10 { $o += 4 }
            11 { $o += 4 }
            12 { $o += 4 }
            15 { $o += 3 }
            16 { $o += 2 }
            17 { $o += 4 }
            18 { $o += 4 }
            19 { $o += 2 }
            20 { $o += 2 }
            default { throw "未知常量池 tag=$tag" }
        }
        $i++
    }
    $o += 6                                        # access_flags / this / super
    $ifc = U2 $b $o; $o += 2 + 2 * $ifc
    $fc = U2 $b $o; $o += 2
    for ($k = 0; $k -lt $fc; $k++) {
        $o += 6
        $ac = U2 $b $o; $o += 2
        for ($a = 0; $a -lt $ac; $a++) { $o += 2; $len = U4 $b $o; $o += 4 + $len }
    }
    $mc = U2 $b $o; $o += 2
    $target = $null
    for ($k = 0; $k -lt $mc; $k++) {
        $nameIdx = U2 $b ($o + 2)
        $descIdx = U2 $b ($o + 4)
        $o += 6
        $ac = U2 $b $o; $o += 2
        $name = $utf8[$nameIdx]
        $desc = $utf8[$descIdx]
        for ($a = 0; $a -lt $ac; $a++) {
            $attrNameIdx = U2 $b $o
            $len = U4 $b ($o + 2)
            $contentStart = $o + 6
            if (-not $target -and $name -eq $METHOD -and $desc -eq $DESC -and $utf8[$attrNameIdx] -eq 'Code') {
                $target = @{ AttrStart = $o; ContentStart = $contentStart; Length = $len }
            }
            $o += 6 + $len
        }
    }
    return $target
}

# ---------- 3. 读 jar 里的 class ----------
$src = [System.IO.Compression.ZipFile]::OpenRead($Jar)
try {
    $entry = @($src.Entries | Where-Object { ($_.FullName -replace '\\', '/') -eq $CLASS })[0]
    if (-not $entry) { Fail "jar 里没有 $CLASS" }
    $ms = New-Object System.IO.MemoryStream
    $entry.Open().CopyTo($ms)
    $classBytes = $ms.ToArray()
} finally { $src.Dispose() }

$t = Get-CodeTarget $classBytes
if (-not $t) { Fail "没找到方法 $METHOD$DESC (MCEF 版本可能变了), 未做任何修改" }

$maxStack = U2 $classBytes $t.ContentStart
$codeLen = U4 $classBytes ($t.ContentStart + 4)
$code = @()
if ($codeLen -gt 0) { $code = $classBytes[($t.ContentStart + 8)..($t.ContentStart + 7 + $codeLen)] }

$alreadyPatched = ($codeLen -eq 2 -and $code[0] -eq 0x04 -and $code[1] -eq 0xAC)
if ($alreadyPatched) {
    Done "jar 已经是补丁状态 (downloadJavaCefChecksum = return true), 跳过 jar 改写"
} else {
    Say ("[信息] 原方法体: {0} 字节, max_stack={1} -> 改成 2 字节 (iconst_1; ireturn)" -f $codeLen, $maxStack)

    # 新 Code 属性内容: max_stack=1, max_locals=1, code_length=2, iconst_1; ireturn, 0 异常表, 0 属性
    $newContent = [byte[]]@(0, 1, 0, 1, 0, 0, 0, 2, 0x04, 0xAC, 0, 0, 0, 0)
    $newLen = [byte[]]@(0, 0, 0, [byte]$newContent.Length)

    $outList = New-Object System.Collections.Generic.List[byte]
    for ($i = 0; $i -le $t.AttrStart + 1; $i++) { $outList.Add($classBytes[$i]) }     # attr_name_index
    $outList.AddRange($newLen)                                                         # attribute_length
    $outList.AddRange($newContent)                                                     # 新内容
    $tailStart = $t.ContentStart + $t.Length
    for ($i = $tailStart; $i -lt $classBytes.Length; $i++) { $outList.Add($classBytes[$i]) }
    $newClass = $outList.ToArray()

    # 复核补丁后的 class 结构
    $t2 = Get-CodeTarget $newClass
    if (-not $t2) { Fail '补丁后解析失败, 未写入 jar' }
    $cl2 = U4 $newClass ($t2.ContentStart + 4)
    if ($cl2 -ne 2 -or $newClass[$t2.ContentStart + 8] -ne 0x04 -or $newClass[$t2.ContentStart + 9] -ne 0xAC) {
        Fail '补丁后方法体不是 return true, 未写入 jar'
    }

    # 备份 + 重写 jar
    $bak = "$Jar.bak-mcefdownload"
    if (-not (Test-Path -LiteralPath $bak)) { Copy-Item -LiteralPath $Jar -Destination $bak -Force }
    $tmp = "$Jar.tmp"
    if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force }
    $src = [System.IO.Compression.ZipFile]::OpenRead($Jar)
    $dst = [System.IO.Compression.ZipFile]::Open($tmp, 'Create')
    try {
        foreach ($e in $src.Entries) {
            $name = $e.FullName -replace '\\', '/'
            $zi = $dst.CreateEntry($name, [System.IO.Compression.CompressionLevel]::Optimal)
            $o = $zi.Open()
            if ($name -eq $CLASS) { $o.Write($newClass, 0, $newClass.Length) }
            else { $i = $e.Open(); $i.CopyTo($o); $i.Dispose() }
            $o.Dispose()
        }
    } finally { $src.Dispose(); $dst.Dispose() }
    Move-Item -LiteralPath $tmp -Destination $Jar -Force
    Done "jar 已改写: $Jar"
    Say "[信息] 备份: $bak"
}

# ---------- 4. 配置双保险 ----------
if (-not $NoConfig) {
    $cfgDir = Join-Path $GameDir 'config\mcef'
    $cfg = Join-Path $cfgDir 'mcef.properties'
    if (-not (Test-Path -LiteralPath $cfgDir)) { New-Item -ItemType Directory -Path $cfgDir | Out-Null }
    if (-not (Test-Path -LiteralPath $cfg)) {
        $default = @(
            '#MCEF settings (written by mcef-block-download.ps1)',
            'download-mirror=https\://mcef-download.cinemamod.com',
            'skip-download=true',
            'use-cache=true',
            'user-agent=null'
        ) -join "`r`n"
        [System.IO.File]::WriteAllText($cfg, $default + "`r`n", (New-Object System.Text.UTF8Encoding($false)))
        Done "新建 $cfg (skip-download=true)"
    } else {
        $text = [System.IO.File]::ReadAllText($cfg)
        if ($text -match '(?m)^\s*skip-download\s*=\s*true\s*$') {
            Done 'config: skip-download 已为 true'
        } else {
            Copy-Item -LiteralPath $cfg -Destination ($cfg + '.bak') -Force
            if ($text -match '(?m)^\s*skip-download\s*=') {
                $text = [regex]::Replace($text, '(?m)^\s*skip-download\s*=.*$', 'skip-download=true')
            } else {
                $text = $text.TrimEnd() + "`r`nskip-download=true`r`n"
            }
            [System.IO.File]::WriteAllText($cfg, $text, (New-Object System.Text.UTF8Encoding($false)))
            Done "config: skip-download 已改为 true (备份 $($cfg).bak)"
        }
    }
}

# ---------- 5. 本地库自检 ----------
$libRoot = Join-Path $GameDir 'mods\mcef-libraries'
if (Test-Path -LiteralPath $libRoot) {
    $platDirs = @(Get-ChildItem -LiteralPath $libRoot -Directory -ErrorAction SilentlyContinue)
    $tar = @(Get-ChildItem -LiteralPath $libRoot -Filter '*.tar.gz' -ErrorAction SilentlyContinue)
    Info ("本地库: {0} 个平台目录, {1} 个 tar.gz" -f $platDirs.Count, $tar.Count)
    if ($platDirs.Count -eq 0) { Warn '没有任何已解压的平台目录, MCEF 启动时会加载失败(但不会再联网下载)' }
} else {
    Warn '没找到 mods\mcef-libraries: 本机还没下过 Chromium, 补丁后也不会自动下, 需要手动放好库'
}

Say ''
Done 'MCEF 依赖下载通道已封闭: 启动时不会再请求 mcef-download.cinemamod.com'
Say '    (只保留 CEF 自身的网页访问能力, 与依赖下载无关)'
if (-not $Quiet) { Read-Host '按回车完成' | Out-Null }