#Requires -Version 5.1
<#
================================================================================
  NeoForgeSwitch.ps1  —  PCL2 版本隔离环境下的 NeoForge 版本一键升降级
================================================================================

  ▍一. 这个脚本解决什么问题

  PCL2 没有"把整合包换一个 NeoForge 版本"的入口。它只有两条路:
      新建版本   -> 得到一个空的 versions\neoforge-<v>\，mods/存档全丢
      重装/更新  -> 按 Setup.ini 里记录的 loader 版本原样再来一遍

  而一个 NeoForge 版本在磁盘上其实只是"四样东西":
      1) versions\<V>\<V>.json      里的 --fml.* 参数、47 个 loader 库、mainClass
      2) libraries\net\neoforged\... 下对应的 47 个 jar
      3) libraries\...\neoforge-<v>-universal.jar      (maven 直供)
      4) libraries\...\neoforge-<v>-client.jar         (maven 没有, 得本地用
         binarypatcher 把 installer 里的 data/client.lzma 打上去)

  版本隔离让 mods/config/saves 都躺在 versions\<V>\ 里，而 loader 全在共享的
  libraries\ 里 —— 所以换 loader 根本不需要碰 mods 和存档。
  这就是本脚本的全部立足点。

  ▍二. 一次切换的流程(共 12 步)

    [1] 定位        找到 .minecraft 和要操作的版本目录
    [2] 读现状      从版本 JSON 取出 NeoForge/FML/MC/NeoForm 四元组
    [3] 取目标      下载 neoforge-<目标>-installer.jar, 掏出 version.json
                    和 data/client.lzma
    [4] 硬校验      目标的 --fml.mcVersion、--fml.neoFormVersion 必须与当前
                    一致(否则要重跑 NeoForm 重映射链, 不是本脚本能力范围)
    [5] mods 预检   扫 mods\*.jar 的 loaderVersion 声明(软校验, 只提示)
    [6] 备份        <V>.json + PCL\Setup.ini + PCL\config.json 三件, 带 meta
    [7] 备依赖      按 maven 坐标补齐缺失的 loader 库(带 SHA1, 按 rules 过滤)
    [8] 备产物      universal.jar 缺失则下载; client.jar 缺失则调 binarypatcher
                    用 client.lzma 打在 client-<mc>-<neoform>-srg.jar 上生成
    [9] 组装 JSON   基线 = 原版 JSON(或差集/特征剥离) + 目标 loader 段落
                    libraries/arguments/mainClass 三段替换, 其余字段不动
    [10] 写三处     <V>.json / Setup.ini(VersionNeoForge+Info) /
                    config.json(MinecraftInstallManifest)
    [11] 自检       三处是否一致 + classpath 每个文件是否存在 +
                    JVM 参数(-p/-DignoreList/-DmergeModules)引用的模块是否都在
    [12] 收尾       成功 -> 报告并强制提示"重启 PCL2 才生效";
                    失败 -> 从备份还原三处 -> 重新抛错

  为什么第 12 步一定要提示重启 PCL:
    PCL 启动游戏时用的是它内存里缓存的版本信息。三个文件改完而 PCL 还开着,
    它会照旧数据拼 --fml.* 参数。本机日志里出现过: 磁盘上 <V>.json 已经是
    21.1.259, 那次启动传到 ModLauncher 的却是 21.1.266。

  幂等性: 往返切换(例 259 -> 266 -> 259)必须得到与原文件 SHA1 完全一致的结果，
  这是本脚本的验收门槛, 也是"只改 loader 段落"这个设计能成立的前提。

  ▍三. 术语: PCL 实例 vs 整合包(版本)

  这两个层级最容易混, 脚本里刻意用两个词:

    PCL 实例   一个 .minecraft(PCL 的工作目录), 含 versions\ + libraries\ + assets\
               例: D:\...\[Client]MultiIntergationPack\.minecraft
    整合包     该实例下 versions\<版本名>\ 的一个具体版本, 含 mods/config/saves
    (版本)     例: …\versions\Coco's 整合包

  一个 PCL 实例里可以并存十几个整合包(本机 18 个版本, 其中 3 个是 NeoForge)。
  所以"改哪个 NeoForge 版本"必须同时说清: 哪个实例 + 哪个版本。
  菜单顶部、-Status 开头、切换抬头都会把这两级一起打出来。

  ▍四. 命令行用法

    .\NeoForgeSwitch.ps1 -Status                    看当前状态+三处是否一致
    .\NeoForgeSwitch.ps1 -List                      列出该 MC 版本所有 NeoForge 版本
    .\NeoForgeSwitch.ps1 -Latest                    升到该系列最新正式版
    .\NeoForgeSwitch.ps1 -Target 21.1.266           升降级到指定版本(可给多个)
    .\NeoForgeSwitch.ps1 -Target 21.1.266 -DryRun   只演练, 不写任何文件
    .\NeoForgeSwitch.ps1 -Rollback                  回滚到上一次切换前
    .\NeoForgeSwitch.ps1 -Rollback -BackupId 2026   回滚到指定备份
    .\NeoForgeSwitch.ps1 -Menu                      交互菜单(双击 bat 走这条)
    .\NeoForgeSwitch.ps1 -PickMcDir                 列出本机所有 PCL 实例, 挑一个
    .\NeoForgeSwitch.ps1 -PickVersion               列出该实例下所有整合包, 挑一个

    两级目标怎么指定(优先级从高到低):
      PCL 实例: -McDir <路径>  >  -PickMcDir    >  配置.cfg  >  自动探测
      整合包  : -VersionDir <路径>  >  -VersionName <名字>  >  -PickVersion
                >  PCL.ini 里最近启动的  >  只有一个就它  >  交互选

    通用参数:
      -McDir <路径>      PCL 实例(.minecraft)。可以只给其中的任一层
                         (…\versions\Coco's 整合包 也行, 会自动上溯到根)
      -PickMcDir         交互式挑 PCL 实例(菜单 [8])
      -ScanRoot <路径>   扫描实例时额外加进来的根目录(可给多个)
      -VersionDir <路径> 整合包(版本)文件夹完整路径, 最明确
      -VersionName <名>  只给版本目录名
      -PickVersion       交互式挑整合包(菜单 [9])
      -Force             跳过确认
      -NoModCheck        不做 mods loaderVersion 预检
      -StrictModCheck    mods 预检不通过就中止(默认只提示)
      -Offline           只用本地缓存, 不联网
      -Proxy auto|on|off 代理策略(默认 auto, 见"六. 全局变量")
      -ProxyHost/-ProxyPort  代理地址(默认 127.0.0.1:7890)
      -TimeoutSec <秒>   单次网络超时(默认 40)

  ▍五. 文件与目录约定

    脚本只碰下面这些位置, 不会写别的地方:

      <McDir>\
        versions\<V>\<V>.json              ← [10] 改写
        versions\<V>\PCL\Setup.ini         ← [10] 改写
        versions\<V>\PCL\config.json       ← [10] 改写
        libraries\                         ← [7][8] 补齐/生成(只增不删)
        NeoForgeSwitch\                    ← 本脚本的私有目录, 全部可删
          .lock                            并发锁
          switch.log                       操作日志
          mods-index.json                  mods 预检缓存
          version-list.txt                 maven 版本清单缓存
          cahe\                            (见 CacheRoot)
          backups\<时间戳>_<from>-to-<to>\  三件备份 + meta.json

    脚本同目录:
      配置.cfg          记住上次用的 .minecraft
      一键切换NeoForge.bat  双击入口(纯 ASCII, 只负责把本脚本拉起来)

  ▍六. 全局变量

    $script:Utf8NoBom       UTF-8 无 BOM 编码器。PCL 的所有配置都是这个编码,
                            用带 BOM 写会让 PCL 读到 \ufeff 前缀。
    $script:MavenRoot       NeoForge maven 仓库根。版本清单、installer、
                            universal.jar、loader 依赖都从这里取。
    $script:UserAgent       下载时用的 UA, 避免部分 CDN 拒绝空 UA。
    $script:TimeoutSec      单次网络超时秒数(由 -TimeoutSec 覆盖)。
    $script:ProxyMode       auto|on|off, 由 -Proxy 覆盖。
    $script:ProxyUrl        最终选定的代理 URL; $null 表示直连。
                            由 Initialize-Proxy 在启动时一次性决定。
    $script:ProxySource     代理是怎么来的(probe/system/param/none), 只用于日志。
    $script:Ctx             运行上下文对象, 一次运行内不变:
                              Root       .minecraft 绝对路径
                              SaveRoot   <Root>\NeoForgeSwitch
                              BackupRoot <Root>\NeoForgeSwitch\backups
                              CacheRoot  <Root>\NeoForgeSwitch\cache
                              LogPath    <Root>\NeoForgeSwitch\switch.log
                              LockPath   <Root>\NeoForgeSwitch\.lock
                            (取代早期版本里散落的 $script:SaveRoot)
    $script:LockHeld        $true 表示当前进程持锁, 退出时要释放。
    $script:VersionName     实际要操作的版本目录名。通常来自 -VersionName;
                            当 -McDir 指到一个版本目录时, 由 Find-McDir 自动填入。
                            (-PickMcDir 换整合包后会清空, 让它重新按 PCL.ini 推断)

  ▍七. 函数索引(按层)

    一 输出           Say Head Ok Info Warn Fail Show-RestartNotice
    二 基础工具       Read-TextFile Write-TextFile ConvertTo-JsonString
                      Write-JsonValue ConvertTo-JsonText Get-Sha1 New-Directory
                      Copy-VersionJson Set-JsonProperty Format-Display
                      Get-TargetSummary Get-VersionFolderShort
    三 网络           Test-TcpPort Initialize-Proxy New-WebRequest
                      Write-DownloadProgress Invoke-Download Get-MavenVersions
    四 上下文与锁     New-Context Enter-ContextLock Exit-ContextLock
                      Write-SwitchLog
    五 环境定位       Test-IsMcDir Resolve-McDirFromPath Get-SettingsPath
                      Get-SavedMcDir Save-McDir
                      Get-AllMcDirs            扫本机所有 PCL 实例
                      Select-McDirInteractively 挑 PCL 实例(菜单 [8])
                      Find-McDir
                      Get-LoaderVersionsOfDir Get-NeoForgeVersionDirs
                      Select-VersionDir        定整合包(版本)
                      Select-VersionInteractively 挑整合包(菜单 [9])
                      Test-LoaderVersionFormat
    六 版本解析       Read-VersionJson Get-ArgText Get-GameArgValue Get-FmlArg
                      Get-LoaderInfo Get-LibraryPath Get-LibraryUrl
                      Get-LibrarySha1 Test-LibraryAllowed
    七 loader 元数据  Get-LoaderMeta Read-VanillaBaseline
    八 库与产物       Get-MissingLibraries Install-LoaderLibraries
                      Resolve-NeoForgeJars Get-BinaryPatcher Get-JavaExe
    九 JSON 组装      Get-LoaderSignature Test-IsLoaderLib Repair-LibraryEntry
                      Test-IsLoaderJvmArg Remove-LoaderJvmArgs
                      Remove-LoaderGameArgs Build-VersionJson Merge-VersionJson
    十 落点读写       Update-SetupIni Update-PclConfig
    十一 校验         Test-JvmArgReferences Test-VersionState
                      Get-ModsIndex Test-ModsCompatibility Test-VersionInRange
                      ConvertTo-ComparableVersion
    十二 备份与回滚   New-Backup Get-Backups Restore-Backup Invoke-Rollback
    十三 业务动作     Invoke-Switch Invoke-StatusAction Invoke-ListAction
                      Invoke-Action
    十四 交互菜单     Show-TargetBlock Invoke-Menu
    十五 入口         (顶层 try/catch, 见文件末尾)

  ▍八. 已知边界(会被明确拒绝, 不会猜)

    · 目标 NeoForge 的 --fml.mcVersion 与当前不同  -> 跨 MC 版本, 拒绝
    · 目标 NeoForge 的 --fml.neoFormVersion 与当前不同 -> 需重建 srg/extra, 拒绝
    · 缺少 client-<mc>-<neoform>-srg.jar -> 同上, 拒绝
    正确做法: 用 PCL 装一个对应 MC 版本的新实例, 再把 mods/config 搬过去。

    另外: 切换完成后不要在 PCL 里对本版本点"重装/更新" —— PCL 会按
    Setup.ini / MinecraftInstallManifest 里记录的 loader 版本重装一遍。
    本脚本已经把这两处一起改了, 所以正常情况没问题; 但如果你用旧备份
    只还原了 JSON 却没还原 ini, 就会出现"界面显示的版本"和"实际跑的版本"
    对不上 —— 用 -Status 可以一眼看出来。
================================================================================
#>

[CmdletBinding()]
param(
    # ── 目标与动作 ─────────────────────────────────────────────────────────
    [string]$McDir,
    [string]$VersionName,
    [string[]]$Target,
    [switch]$List,
    [switch]$Status,
    [switch]$Rollback,
    [string]$BackupId,
    [switch]$Latest,
    [switch]$Menu,

    # ── 目标整合包 ─────────────────────────────────────────────────────────
    #   两级目标, 别混:
    #     -McDir        PCL 实例(PCL 工作目录), 也就是那个 .minecraft
    #     -VersionDir   该实例下的版本文件夹(整合包), 例如 …\versions\Coco's 整合包
    #     -VersionName  只给版本名(等价于 -VersionDir 的最后一段)
    [switch]$PickMcDir,
    [string[]]$ScanRoot,
    [string]$VersionDir,
    [switch]$PickVersion,

    # ── 行为开关 ───────────────────────────────────────────────────────────
    [switch]$DryRun,
    [switch]$Force,
    [switch]$NoModCheck,
    [switch]$StrictModCheck,
    [switch]$Offline,

    # ── 网络 ───────────────────────────────────────────────────────────────
    [ValidateSet('auto', 'on', 'off')]
    [string]$Proxy = 'auto',
    [string]$ProxyHost = '127.0.0.1',
    [int]$ProxyPort = 7890,
    [int]$TimeoutSec = 40
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

# ============================================================================
#  全局变量(含义见文件头"五. 全局变量")
# ============================================================================
$script:Utf8NoBom  = New-Object System.Text.UTF8Encoding($false)
$script:MavenRoot  = 'https://maven.neoforged.net/releases'
$script:UserAgent  = 'NeoForgeSwitch/2.0'
$script:TimeoutSec = $TimeoutSec
$script:ProxyMode  = $Proxy
$script:ProxyUrl   = $null
$script:ProxySource = 'none'
$script:Ctx        = $null
$script:LockHeld   = $false

# ============================================================================
#  一. 输出
#     统一走 Write-Host, 避免被管道吞掉; 颜色语义固定:
#     青色=标题 绿色=完成 灰色=信息 黄色=注意 红色=错误
# ============================================================================
function Say  { param([string]$m) Write-Host $m }
function Head { param([string]$m) Write-Host ''; Write-Host "== $m ==" -ForegroundColor Cyan }
function Ok   { param([string]$m) Write-Host "[完成] $m" -ForegroundColor Green }
function Info { param([string]$m) Write-Host "[信息] $m" -ForegroundColor Gray }
function Warn { param([string]$m) Write-Host "[注意] $m" -ForegroundColor Yellow }
function Fail { param([string]$m) Write-Host "[错误] $m" -ForegroundColor Red }

function Show-RestartNotice {
    <#
        切换/回滚成功后的强制提醒: 必须重启 PCL2

        为什么非要重启 —— 这不是保险起见, 是实测踩过的坑:
        PCL 启动游戏时用的是它在内存里缓存的版本信息。改完三个文件如果 PCL 还开着,
        它会按旧数据拼 --fml.* 参数。本机日志里明确出现过这种事:
        磁盘上的 <V>.json 早就改回 21.1.259 了, 8:19 那次启动的参数却仍是 21.1.266。

        所以这条提示要足够显眼(黄框 + 三步操作 + 验证命令), 不能只是一行灰字。
    #>
    param([string]$Action = '切换')

    $bar = '  ' + ('=' * 66)
    Write-Host ''
    Write-Host $bar -ForegroundColor Yellow
    Write-Host ("  !  {0}成功 —— 需要重启 PCL2 才会生效" -f $Action) -ForegroundColor Yellow
    Write-Host $bar -ForegroundColor Yellow
    Write-Host '  PCL 启动时会缓存版本信息。改完文件如果 PCL 还开着, 它会按内存里的旧数据' -ForegroundColor Gray
    Write-Host '  拼 --fml.* 参数 —— 结果就是"文件明明改了, 游戏还是老版本"。' -ForegroundColor Gray
    Write-Host ''
    Write-Host '  请依次做:' -ForegroundColor White
    Write-Host '    1) 完全退出 PCL2 (含托盘图标; 任务管理器里不该再有 Plain Craft Launcher 2.exe)' -ForegroundColor White
    Write-Host '    2) 重新打开 PCL2' -ForegroundColor White
    Write-Host '    3) 再点启动' -ForegroundColor White
    Write-Host ''
    Write-Host '  想确认是否真的生效, 启动后看启动日志第一行:' -ForegroundColor DarkGray
    Write-Host '    Get-Content "<.minecraft>\versions\<版本名>\logs\latest.log" -TotalCount 1' -ForegroundColor DarkGray
    Write-Host '    --fml.neoForgeVersion 后面跟的数字, 就是实际加载的版本' -ForegroundColor DarkGray
    Write-Host $bar -ForegroundColor Yellow
    Write-Host ''
}

# ============================================================================
#  二. 基础工具
# ============================================================================

function Read-TextFile {
    <#
        读 UTF-8 无 BOM 文本; 文件不存在返回 $null(而不是抛错)
        PCL 自己的 ini/json 都是这个编码, 用别的编码读会得到乱码
    #>
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    return [System.IO.File]::ReadAllText($Path, $script:Utf8NoBom)
}

function Write-TextFile {
    <#
        先写 .tmp 再覆盖目标, 避免写到一半把版本文件弄坏

        刻意不用 [System.IO.File]::Replace: 目标路径里出现 [ ] (本机就是
        "D:\...\[Client]MultiIntergationPack\...") 时它会抛"路径的形式不合法",
        换成 PowerShell 的 -LiteralPath 系列 cmdlet 就没这个问题。
    #>
    param([string]$Path, [string]$Content)
    $tmp = "$Path.neoswitch.tmp"
    [System.IO.File]::WriteAllText($tmp, $Content, $script:Utf8NoBom)
    if (Test-Path -LiteralPath $Path) {
        Copy-Item -LiteralPath $tmp -Destination $Path -Force
        Remove-Item -LiteralPath $tmp -Force
    } else {
        Move-Item -LiteralPath $tmp -Destination $Path
    }
}

function ConvertTo-JsonString {
    <#
        把字符串转成 JSON 字面量(带引号)
        中文原样输出 —— Newtonsoft 默认也不转义非 ASCII, 这样 diff 才可读
    #>
    param([string]$s)
    $sb = New-Object System.Text.StringBuilder
    foreach ($ch in $s.ToCharArray()) {
        switch ($ch) {
            '"'  { [void]$sb.Append('\"'); continue }
            '\'  { [void]$sb.Append('\\'); continue }
            "`b" { [void]$sb.Append('\b'); continue }
            "`f" { [void]$sb.Append('\f'); continue }
            "`n" { [void]$sb.Append('\n'); continue }
            "`r" { [void]$sb.Append('\r'); continue }
            "`t" { [void]$sb.Append('\t'); continue }
            default {
                if ([int]$ch -lt 32) { [void]$sb.Append(('\u{0:x4}' -f [int]$ch)) }
                else { [void]$sb.Append($ch) }
            }
        }
    }
    return '"' + $sb.ToString() + '"'
}

function Write-JsonValue {
    <#
        递归输出一个 JSON 值(对象/数组/标量)
        排版规则 = Newtonsoft.Json 的 Formatting.Indented: 2 空格缩进、
        "key": value 冒号后单空格、数组每项一行
    #>
    param($Sb, $Value, [int]$Level)
    $pad = ' ' * ($Level * 2)
    $padIn = ' ' * (($Level + 1) * 2)

    if ($null -eq $Value) { [void]$Sb.Append('null'); return }
    if ($Value -is [bool]) { [void]$Sb.Append($(if ($Value) { 'true' } else { 'false' })); return }
    if ($Value -is [string]) { [void]$Sb.Append((ConvertTo-JsonString $Value)); return }

    # 整数类原样输出; 浮点类如果其实是整数(JSON 里的 size 等)也输出成整数
    if ($Value -is [int] -or $Value -is [long] -or $Value -is [int16] -or $Value -is [byte]) {
        [void]$Sb.Append($Value.ToString([System.Globalization.CultureInfo]::InvariantCulture)); return
    }
    if ($Value -is [double] -or $Value -is [single] -or $Value -is [decimal]) {
        $d = [double]$Value
        if ($d -eq [math]::Floor($d) -and [math]::Abs($d) -lt 1e15) {
            [void]$Sb.Append(([long]$d).ToString([System.Globalization.CultureInfo]::InvariantCulture))
        } else {
            [void]$Sb.Append($d.ToString('R', [System.Globalization.CultureInfo]::InvariantCulture))
        }
        return
    }

    # 数组(注意 string 也是 IEnumerable, 前面已拦掉)
    $isList = ($Value -is [System.Collections.IList]) -and -not ($Value -is [string])
    if ($isList) {
        $items = @($Value)
        if ($items.Count -eq 0) { [void]$Sb.Append('[]'); return }
        [void]$Sb.Append("[`r`n")
        for ($i = 0; $i -lt $items.Count; $i++) {
            [void]$Sb.Append($padIn)
            Write-JsonValue -Sb $Sb -Value $items[$i] -Level ($Level + 1)
            if ($i -lt $items.Count - 1) { [void]$Sb.Append(',') }
            [void]$Sb.Append("`r`n")
        }
        [void]$Sb.Append($pad + ']')
        return
    }

    # 对象
    $props = @($Value.PSObject.Properties | Where-Object { $_.MemberType -in @('NoteProperty', 'Property') })
    if ($props.Count -eq 0) { [void]$Sb.Append('{}'); return }
    [void]$Sb.Append("{`r`n")
    for ($i = 0; $i -lt $props.Count; $i++) {
        [void]$Sb.Append($padIn)
        [void]$Sb.Append((ConvertTo-JsonString $props[$i].Name))
        [void]$Sb.Append(': ')
        Write-JsonValue -Sb $Sb -Value $props[$i].Value -Level ($Level + 1)
        if ($i -lt $props.Count - 1) { [void]$Sb.Append(',') }
        [void]$Sb.Append("`r`n")
    }
    [void]$Sb.Append($pad + '}')
}

function ConvertTo-JsonText {
    <#
        JSON 序列化入口

        自己实现而不是用 ConvertTo-Json, 原因有两个:
          1) PS 5.1 的 ConvertTo-Json 会把中文写成 \uXXXX, 并用"值对齐"的怪排版
          2) 排版一致才能让"切换前后 diff"只剩真正的语义变化 —— 259->266 那次
             整个 73 KB 文件只有 1 行差异, 靠的就是这里
        输出与 PCL(Newtonsoft) 逐字节一致, 已用原文件往返验证过。
    #>
    param($Object)
    $sb = New-Object System.Text.StringBuilder
    Write-JsonValue -Sb $sb -Value $Object -Level 0
    return $sb.ToString()
}

function Get-Sha1 {
    param([string]$Path)
    $sha = [System.Security.Cryptography.SHA1]::Create()
    try {
        return [System.BitConverter]::ToString($sha.ComputeHash([System.IO.File]::ReadAllBytes($Path))).Replace('-', '').ToLower()
    } finally { $sha.Dispose() }
}

function New-Directory {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -ItemType Directory -Force -Path $Path | Out-Null
    }
}

function Copy-VersionJson {
    <#
        浅拷贝一个版本 JSON 对象(保持字段顺序)

        早期版本用 "ConvertTo-Json | ConvertFrom-Json" 做深拷贝, 有两个毛病:
          - 数字类型会被悄悄改写(int -> long/double)
          - 对 73 KB 的对象有明显开销
        这里只复制顶层属性的引用, 随后调用方会把 libraries/arguments/mainClass
        换成新数组, 所以浅拷贝足够。
    #>
    param($Source)
    $out = [pscustomobject]@{}
    foreach ($p in $Source.PSObject.Properties) {
        $out | Add-Member -NotePropertyName $p.Name -NotePropertyValue $p.Value -Force
    }
    return $out
}

function Set-JsonProperty {
    <#
        给对象设置一个属性, 且不改变它在 JSON 里的位置

        为什么需要它: Add-Member -Force 对"已存在的属性"是"删掉再追加",
        字段会被挪到对象末尾。PCL 的配置文件字段顺序虽然不影响解析, 但会让
        diff 变得不可读, 也破坏"往返不改原文件"这条验收标准。
        所以: 存在就赋值, 不存在才 Add-Member。
    #>
    param($Object, [string]$Name, $Value)
    if ($Object.PSObject.Properties.Name -contains $Name) {
        $Object.$Name = $Value
    } else {
        $Object | Add-Member -NotePropertyName $Name -NotePropertyValue $Value -Force
    }
}

function Format-Display {
    <#
        按"显示宽度"把字符串补到指定列数, 用于菜单/表格对齐
        中文和全角符号占 2 列, 半角占 1 列。控制台字体即使不是等宽, 只要按显示
        宽度算, 列也能对齐 —— 直接用 PadRight 会因为 strlen 与显示宽度不一致而错位。
    #>
    param([string]$Text, [int]$Width)
    if ($null -eq $Text) { $Text = '' }
    $w = 0
    foreach ($ch in $Text.ToCharArray()) {
        $code = [int]$ch
        $wide = ($code -ge 0x1100 -and (
            $code -le 0x115F -or $code -eq 0x2329 -or $code -eq 0x232A -or
            ($code -ge 0x2E80 -and $code -le 0xA4CF) -or
            ($code -ge 0xAC00 -and $code -le 0xD7A3) -or
            ($code -ge 0xF900 -and $code -le 0xFAFF) -or
            ($code -ge 0xFE30 -and $code -le 0xFE6F) -or
            ($code -ge 0xFF00 -and $code -le 0xFF60) -or
            ($code -ge 0xFFE0 -and $code -le 0xFFE6)
        ))
        if ($wide) { $w += 2 } else { $w += 1 }
    }
    if ($w -ge $Width) { return $Text }
    return $Text + (' ' * ($Width - $w))
}

function Get-TargetSummary {
    <#
        把"这次到底要改哪个"整理成两级结构, 供菜单/状态/切换抬头统一使用

        这两级很容易混, 但它们是不同的东西:
          Instance   PCL 实例(PCL 工作目录)。一个 .minecraft, 底下有 versions\ 与 libraries\
          Version    版本(整合包)。PCL 实例下 versions\<版本名>\, 里面是 mods/config/saves

        同一个 PCL 实例里可以并存十几个整合包(本机就是 18 个), 所以只说"整合包路径"
        是不够的 —— 必须同时说清是哪个实例下的哪个版本。
    #>
    param([string]$Root, $Version)

    $s = [pscustomobject]@{
        Instance     = $Root
        InstanceName = Split-Path $Root -Leaf
        VersionName  = ''
        VersionDir   = ''
        Mc           = ''
        NeoForge     = ''
        Fml          = ''
        LibCount     = 0
        Consistent   = $true
        Error        = ''
    }
    # 实例名: 目录就叫 .minecraft 时, 用它的父目录名更有辨识度
    # (本机 "…\[Client]MultiIntergationPack\.minecraft" -> "[Client]MultiIntergationPack")
    $leafName = Split-Path $Root -Leaf
    if ($leafName -eq '.minecraft' -or $leafName -eq 'minecraft') {
        $parentLeaf = Split-Path (Split-Path $Root -Parent) -Leaf
        if ($parentLeaf) { $s.InstanceName = $parentLeaf }
    }
    if (-not $Version) {
        try { $Version = Select-VersionDir -Root $Root } catch { $s.Error = $_.Exception.Message; return $s }
    }
    try {
        $s.VersionName = $Version.Name
        $s.VersionDir = $Version.Dir
        $js = Read-VersionJson $Version.Json
        $li = Get-LoaderInfo $js
        $s.Mc = $li.McVersion
        $s.NeoForge = $li.NeoForge
        $s.Fml = $li.Fml
        $s.LibCount = @($js.libraries).Count
        $iniVer = Get-LoaderVersionsOfDir $Version.Dir
        if ($iniVer -and $li.NeoForge -and $iniVer -ne $li.NeoForge) { $s.Consistent = $false }
    } catch {
        $s.Error = $_.Exception.Message
    }
    return $s
}

function Get-VersionFolderShort {
    <#
        把版本目录缩成 versions\<版本名> 这种便于阅读的形态
        完整路径在菜单里太长, 会撑破一行; 但完全省掉又让人不知道改的是哪
    #>
    param([string]$Root, [string]$VersionDir)
    if (-not $VersionDir) { return '' }
    $prefix = (Join-Path $Root 'versions') + '\'
    if ($VersionDir.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) {
        return 'versions\' + $VersionDir.Substring($prefix.Length)
    }
    return $VersionDir
}

# ============================================================================
#  三. 网络
#     所有出网请求都经过 Initialize-Proxy 决定好的 $script:ProxyUrl:
#       auto(默认) 先探测 127.0.0.1:7890, 通则用; 不通回落到系统代理; 再不行直连
#       on         强制走 -ProxyHost:-ProxyPort
#       off        强制直连
#     调用 java 时另外加 -Djava.net.useSystemProxies=true, 让它也吃系统代理。
# ============================================================================

function Test-TcpPort {
    <#
        快速探测某端口是否可连(默认 500ms 超时)
        用来判断"本机有没有在 7890 上跑代理", 比 Test-NetConnection 快得多
    #>
    param([string]$HostName, [int]$Port, [int]$TimeoutMs = 500)
    $client = $null
    try {
        $client = New-Object System.Net.Sockets.TcpClient
        $task = $client.ConnectAsync($HostName, $Port)
        if ($task.Wait($TimeoutMs) -and $client.Connected) { return $true }
        return $false
    } catch {
        return $false
    } finally {
        if ($client) { try { $client.Close() } catch { } }
    }
}

function Initialize-Proxy {
    <#
        决定这次运行用哪个代理, 结果写进 $script:ProxyUrl / $script:ProxySource
        只在启动时调用一次
    #>
    param([string]$Mode, [string]$HostName, [int]$Port)

    $script:ProxyUrl = $null
    $script:ProxySource = 'none'

    if ($Mode -eq 'off') {
        $script:ProxySource = '直连(参数指定)'
        Info "网络: 直连(已用 -Proxy off 关闭代理)"
        return
    }

    $candidate = "http://${HostName}:$Port"

    if ($Mode -eq 'on') {
        $script:ProxyUrl = $candidate
        $script:ProxySource = '参数指定'
        Info "网络: 使用代理 $candidate"
        return
    }

    # auto: 先探测本机常见代理端口, 通则用
    if (Test-TcpPort -HostName $HostName -Port $Port) {
        $script:ProxyUrl = $candidate
        $script:ProxySource = '探测到本机代理'
        Info "网络: 探测到 $HostName`:$Port 可用, 走代理"
        return
    }

    # 再看系统(IE)代理设置
    try {
        $sysProxy = [System.Net.WebRequest]::GetSystemWebProxy()
        $probe = $sysProxy.GetProxy([uri]'https://maven.neoforged.net')
        if ($probe -and $probe.Host -and $probe.Host -ne 'maven.neoforged.net') {
            $script:ProxyUrl = "$($probe.Scheme)://$($probe.Host):$($probe.Port)"
            $script:ProxySource = '系统代理'
            Info "网络: 使用系统代理 $script:ProxyUrl"
            return
        }
    } catch { }

    $script:ProxySource = '直连'
    Info "网络: 没找到代理($HostName`:$Port 不通, 系统代理也没配), 直连"
}

function New-WebRequest {
    <#
        统一创建带代理/超时/UA 的 HttpWebRequest
        所有出网的地方都必须走这里, 否则代理策略会漏
    #>
    param([string]$Url)
    $req = [System.Net.HttpWebRequest]::Create($Url)
    $req.Timeout = $script:TimeoutSec * 1000
    $req.ReadWriteTimeout = $script:TimeoutSec * 1000
    $req.UserAgent = $script:UserAgent
    if ($script:ProxyUrl) {
        $req.Proxy = New-Object System.Net.WebProxy($script:ProxyUrl, $true)
    } elseif ($script:ProxyMode -eq 'off') {
        $req.Proxy = $null
    }
    return $req
}

function Write-DownloadProgress {
    <#
        单行刷新的下载进度条
        输出被重定向(比如被 bat 记录到文件)时不画进度, 免得日志里全是回首符
    #>
    param([string]$Label, [long]$Read, [long]$Total)
    if ([Console]::IsOutputRedirected) { return }
    if ($Total -le 0) {
        Write-Host ("`r    $Label  " + [math]::Round($Read / 1MB, 2) + " MB") -NoNewline
        return
    }
    $pct = [int](100 * $Read / $Total)
    $barLen = 24
    $filled = [int]($barLen * $pct / 100)
    $bar = ('#' * $filled) + ('.' * ($barLen - $filled))
    Write-Host ("`r    $Label  [$bar] $pct%  " + [math]::Round($Read / 1MB, 2) + '/' + [math]::Round($Total / 1MB, 2) + " MB") -NoNewline
}

function Invoke-Download {
    <#
        下载一个文件到指定位置

        行为:
          - 目标已存在: 有 sha1 就校验, 没有就当缓存命中(直接返回 cached)
          - 下载写 .part, 完成后才改名, 失败最多重试 3 次(带退避)
          - 每个请求都走 New-WebRequest, 因此自动带上代理
          - -Validate 可以传一个 scriptblock(参数是文件路径), 下载后做额外校验
            (用来救"半截 installer 被当成好文件"这种缓存投毒)

        返回: 'cached' | 'downloaded'
    #>
    param(
        [string]$Url,
        [string]$Dest,
        [string]$ExpectSha1,
        [scriptblock]$Validate
    )

    if (Test-Path -LiteralPath $Dest) {
        $ok = $true
        if ($ExpectSha1) {
            $ok = ((Get-Sha1 -Path $Dest) -eq $ExpectSha1)
            if (-not $ok) { Warn "校验不符, 重新下载: $(Split-Path $Dest -Leaf)" }
        }
        if ($ok -and $Validate) {
            try { $ok = [bool](& $Validate $Dest) } catch { $ok = $false }
            if (-not $ok) { Warn "缓存文件不可用, 重新下载: $(Split-Path $Dest -Leaf)" }
        }
        if ($ok) { return 'cached' }
        Remove-Item -LiteralPath $Dest -Force -ErrorAction SilentlyContinue
    }

    if ($Offline) { throw "离线模式下缺少文件: $Dest ($Url)" }

    New-Directory (Split-Path $Dest -Parent)
    $tmp = "$Dest.part"
    $label = Split-Path $Dest -Leaf
    $lastError = $null

    for ($attempt = 1; $attempt -le 3; $attempt++) {
        try {
            if ($attempt -gt 1) { Info "第 $attempt 次尝试: $label" }
            $req = New-WebRequest -Url $Url
            $resp = $req.GetResponse()
            $total = 0
            try { $total = [long]$resp.ContentLength } catch { $total = 0 }
            $in = $resp.GetResponseStream()
            $out = [System.IO.File]::Create($tmp)
            try {
                $buffer = New-Object byte[] 81920
                $read = 0L
                while (($n = $in.Read($buffer, 0, $buffer.Length)) -gt 0) {
                    $out.Write($buffer, 0, $n)
                    $read += $n
                    Write-DownloadProgress -Label $label -Read $read -Total $total
                }
            } finally {
                $out.Dispose(); $in.Dispose(); $resp.Dispose()
            }
            if (-not [Console]::IsOutputRedirected) { Write-Host '' }

            if ((Get-Item -LiteralPath $tmp).Length -le 0) { throw '下载到的文件是空的' }

            if ($ExpectSha1) {
                $actual = Get-Sha1 -Path $tmp
                if ($actual -ne $ExpectSha1) {
                    throw "SHA1 校验失败`n  期望 $ExpectSha1`n  实际 $actual"
                }
            }
            if ($Validate) {
                if (-not (& $Validate $tmp)) { throw '下载后的文件未通过校验(可能是错误页或半截内容)' }
            }

            if (Test-Path -LiteralPath $Dest) { Remove-Item -LiteralPath $Dest -Force }
            [System.IO.File]::Move($tmp, $Dest)
            return 'downloaded'
        } catch {
            $lastError = $_
            if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
            if (-not [Console]::IsOutputRedirected) { Write-Host '' }
            if ($attempt -lt 3) { Start-Sleep -Milliseconds (500 * $attempt) }
        }
    }
    throw "下载失败(已重试 3 次): $Url`n  $($lastError.Exception.Message)"
}

function Get-MavenVersions {
    <#
        取 NeoForge 的版本清单(带本地缓存与内置兜底)

        返回: 按版本号升序排列的、以 $Prefix 开头且不含 alpha/beta 的版本号数组
        失败时: 用上次缓存; 缓存也没有则抛错(提示用 -Target 显式指定)
    #>
    param([string]$Prefix)
    $url = "$script:MavenRoot/net/neoforged/neoforge/maven-metadata.xml"
    $xml = $null
    if (-not $Offline) {
        try {
            $req = New-WebRequest -Url $url
            $resp = $req.GetResponse()
            $sr = New-Object System.IO.StreamReader($resp.GetResponseStream())
            $text = $sr.ReadToEnd(); $sr.Close(); $resp.Dispose()
            $xml = [xml]$text
        } catch {
            Warn "版本清单拉取失败, 改用本地缓存: $($_.Exception.Message)"
        }
    }
    $cacheFile = Join-Path $script:Ctx.CacheRoot 'version-list.txt'
    if ($xml) {
        $all = @($xml.metadata.versioning.versions.version)
        New-Directory $script:Ctx.CacheRoot
        Set-Content -LiteralPath $cacheFile -Value $all -Encoding UTF8
    } elseif (Test-Path -LiteralPath $cacheFile) {
        $all = @(Get-Content -LiteralPath $cacheFile -Encoding UTF8)
    } else {
        throw '没有版本清单可读, 请检查网络, 或用 -Target 显式指定版本'
    }
    $filtered = @($all | Where-Object { $_ -like "$Prefix*" -and $_ -notmatch 'alpha|beta' })
    return @($filtered | Sort-Object { try { [version]($_ -replace '[^0-9.].*$', '') } catch { [version]'0.0' } })
}

# ============================================================================
#  四. 上下文与并发锁
# ============================================================================

function New-Context {
    <#
        建立运行上下文(见文件头"五. 全局变量")
        所有路径相关的副作用都限定在这个目录里, 方便备份、清理和排查
    #>
    param([string]$Root)
    $saveRoot = Join-Path $Root 'NeoForgeSwitch'
    New-Directory $saveRoot
    $script:Ctx = [pscustomobject]@{
        Root       = $Root
        SaveRoot   = (Resolve-Path -LiteralPath $saveRoot).Path
        BackupRoot = Join-Path (Resolve-Path -LiteralPath $saveRoot).Path 'backups'
        CacheRoot  = Join-Path (Resolve-Path -LiteralPath $saveRoot).Path 'cache'
        LogPath    = Join-Path (Resolve-Path -LiteralPath $saveRoot).Path 'switch.log'
        LockPath   = Join-Path (Resolve-Path -LiteralPath $saveRoot).Path '.lock'
    }
    New-Directory $script:Ctx.BackupRoot
    New-Directory $script:Ctx.CacheRoot
    return $script:Ctx
}

function Write-SwitchLog {
    <#
        追加一行操作日志(时间 + 内容)
        日志本身不参与任何判断, 纯粹给"我昨天到底切了什么"这类问题留证据
    #>
    param([string]$Message)
    if (-not $script:Ctx) { return }
    try {
        $line = "{0}  {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
        Add-Content -LiteralPath $script:Ctx.LogPath -Value $line -Encoding UTF8
    } catch { }
}

function Enter-ContextLock {
    <#
        抢并发锁, 防止两个实例同时改同一批文件

        实现: 在 SaveRoot 下建 .lock, 内容 "<PID>|<时间戳>"。
          - 锁存在且 PID 活着、时间戳未过期 -> 认为有人在跑, 等一会儿再试
          - 锁存在但 PID 已消失(上次异常退出) -> 当作陈旧锁, 直接接管
          - 锁存在、PID 活着但时间戳超过 StaleMinutes -> 也当陈旧锁
            (防 PID 被系统复用后, 一条早已不存在的实例把锁"钉死")
          - 超过 WaitSec 秒仍抢不到 -> 抛错, 让用户自己决定
    #>
    param([int]$WaitSec = 8, [int]$StaleMinutes = 30)
    $lockPath = $script:Ctx.LockPath
    $deadline = (Get-Date).AddSeconds($WaitSec)
    $announced = $false

    while ($true) {
        if (-not (Test-Path -LiteralPath $lockPath)) { break }

        $otherPid = 0
        $stamp = $null
        try {
            $text = (Read-TextFile $lockPath).Trim()
            $parts = $text -split '\|', 2
            $otherPid = [int]$parts[0]
            if ($parts.Count -gt 1) { $stamp = [datetime]::Parse($parts[1]) }
        } catch { $otherPid = 0 }

        $alive = $false
        if ($otherPid -gt 0) {
            $alive = @(Get-Process -Id $otherPid -ErrorAction SilentlyContinue).Count -gt 0
        }
        $expired = $false
        if ($alive -and $stamp) {
            if (((Get-Date) - $stamp).TotalMinutes -gt $StaleMinutes) { $expired = $true }
        }

        if (-not $alive) {
            Info "接管上次残留的锁(进程 $otherPid 已不在)"
            Remove-Item -LiteralPath $lockPath -Force -ErrorAction SilentlyContinue
            break
        }
        if ($expired) {
            Warn "接管过期的锁(进程 $otherPid 的锁已存在超过 $StaleMinutes 分钟)"
            Remove-Item -LiteralPath $lockPath -Force -ErrorAction SilentlyContinue
            break
        }
        if ((Get-Date) -gt $deadline) {
            throw "另一个实例正在操作这个整合包(进程 $otherPid)。如果确认没有在跑, 删除 $lockPath 后重试。"
        }
        if (-not $announced) {
            Warn "检测到另一个实例(进程 $otherPid)正在操作, 等待中..."
            $announced = $true
        }
        Start-Sleep -Milliseconds 300
    }

    [System.IO.File]::WriteAllText($lockPath, "$PID|$((Get-Date).ToString('s'))", $script:Utf8NoBom)
    $script:LockHeld = $true
}

function Exit-ContextLock {
    <# 释放锁; 只在确实持锁时动手, 避免误删别人的锁 #>
    if (-not $script:LockHeld -or -not $script:Ctx) { return }
    try { Remove-Item -LiteralPath $script:Ctx.LockPath -Force -ErrorAction SilentlyContinue } catch { }
    $script:LockHeld = $false
}

# ============================================================================
#  五. 环境定位
# ============================================================================

function Test-IsMcDir {
    <#
        判断一个路径是不是 .minecraft 根
        判据: 它下面直接有 versions\ 目录(这是 .minecraft 的定义性特征)
              加 -Strict 时还要求有 libraries\ —— 用来判定"这是个能正常启动的整合包",
              而不是某个半成品或只是个同名文件夹

        注意: 版本目录 versions\<V>\ 自己不会有 versions\ 子目录, 所以不会被误判
    #>
    param([string]$Path, [switch]$Strict)
    if (-not $Path) { return $false }
    if (-not (Test-Path -LiteralPath $Path)) { return $false }
    if (-not (Test-Path -LiteralPath (Join-Path $Path 'versions'))) { return $false }
    if ($Strict -and -not (Test-Path -LiteralPath (Join-Path $Path 'libraries'))) { return $false }
    return $true
}

function Resolve-McDirFromPath {
    <#
        从"任意一个子路径"上溯找到 .minecraft 根

        为什么需要它: 用户很自然会给出这些路径, 而不是干净的 .minecraft 根:
            ...\.minecraft\versions\Coco's 整合包     <- 版本目录(PCL 里显示的就是这个)
            ...\.minecraft\versions                   <- 版本列表目录
            ...\.minecraft\mods                       <- 版本隔离时这些目录在版本里, 但偶尔也会被指向
            ...\.minecraft                            <- 正确形态

        版本隔离有个容易搞混的点: mods/config/saves 被隔离到 versions\<V>\, 但
        libraries\ 和 assets\ 始终在 .minecraft 根下共享。所以只要上溯到 .minecraft,
        libraries 自然就找到了 —— "向上找 libraries"这个动作就体现在这里。

        返回: { Root=<.minecraft 或 $null>; VersionName=<若原路径是版本目录, 记下名字>; Levels=<上溯层数> }
    #>
    param([string]$Path)
    $result = [pscustomobject]@{ Root = $null; VersionName = $null; Levels = 0; Original = $Path }

    if (-not $Path) { return $result }
    $full = $Path
    try {
        if (Test-Path -LiteralPath $Path) { $full = (Resolve-Path -LiteralPath $Path).Path }
    } catch { }

    # 原路径是否是 versions\<版本名> 形态(上溯两级能到 .minecraft 的那种)
    $isVersionDir = $false
    $p1 = Split-Path $full -Parent
    if ($p1 -and (Split-Path $p1 -Leaf) -eq 'versions') { $isVersionDir = $true }

    $cur = $full
    for ($i = 0; $i -lt 5 -and $cur; $i++) {
        if (Test-IsMcDir $cur) {
            $result.Root = $cur
            $result.Levels = $i
            if ($isVersionDir -and $i -ge 1) { $result.VersionName = Split-Path $full -Leaf }
            break
        }
        $cur = Split-Path $cur -Parent
    }
    return $result
}

function Get-SettingsPath { return (Join-Path $PSScriptRoot '配置.cfg') }

function Get-SavedMcDir {
    <# 读"上次用的 .minecraft", 存在脚本同目录的 配置.cfg #>
    $path = Get-SettingsPath
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    $text = Read-TextFile $path
    if (-not $text) { return $null }
    $m = [regex]::Match($text, '(?m)^McDir=(.*)$')
    if ($m.Success) { return $m.Groups[1].Value.Trim() }
    return $null
}

function Save-McDir {
    param([string]$Path)
    if ((Get-SavedMcDir) -eq $Path) { return }
    try {
        Set-Content -LiteralPath (Get-SettingsPath) -Value @(
            '# 本文件由 NeoForgeSwitch.ps1 自动维护, 记录上次使用的 .minecraft',
            "McDir=$Path"
        ) -Encoding UTF8
    } catch { }
}

function Get-AllMcDirs {
    <#
        找出这台机器上"看起来是整合包"的 .minecraft 目录

        用来支持"这台机器上有多个整合包, 我要换一个操作"的场景。
        做法: 从若干已知根和所有盘符根出发, 只看一层子目录, 不递归(桌面那种目录
              文件极多, 递归会明显变慢), 再对每个候选做上溯归一。

        返回: [{ Path; VersionCount; Valid }] 按"版本多的在前"排序
    #>
    param([string[]]$ExtraRoots)

    $raw = New-Object System.Collections.Generic.List[string]

    # 1) 已配置的那个永远在候选里(哪怕它在很偏的位置)
    $saved = Get-SavedMcDir
    if ($saved) { $raw.Add($saved) }

    # 2) 常见整合包根 + 调用方额外指定的根
    $roots = @(
        'D:\Program Files\Minecraft',
        'C:\Program Files\Minecraft',
        'D:\Minecraft',
        'C:\Minecraft',
        (Join-Path $env:USERPROFILE 'Desktop'),
        (Join-Path $env:USERPROFILE 'Documents'),
        (Join-Path $env:USERPROFILE 'Downloads')
    )
    if ($ExtraRoots) { $roots += $ExtraRoots }

    # 3) 每个盘符的根(只加盘符本身, 后面统一看一层子目录)
    foreach ($drv in (Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue)) {
        if ($drv.Root -match '^[A-Za-z]:\\$') { $roots += $drv.Root }
    }

    foreach ($r in ($roots | Where-Object { $_ } | Select-Object -Unique)) {
        if (-not (Test-Path -LiteralPath $r)) { continue }
        $raw.Add($r)
        $raw.Add((Join-Path $r '.minecraft'))
        $subs = @(Get-ChildItem -LiteralPath $r -Directory -ErrorAction SilentlyContinue | Select-Object -First 200)
        foreach ($s in $subs) {
            $raw.Add((Join-Path $s.FullName '.minecraft'))
        }
    }

    # 归一 + 去重 + 统计
    $seen = New-Object System.Collections.Generic.HashSet[string]
    $result = @()
    foreach ($c in $raw) {
        $rr = Resolve-McDirFromPath -Path $c
        if (-not $rr.Root) { continue }
        $key = $rr.Root.ToLower()
        if (-not $seen.Add($key)) { continue }

        $vdir = Join-Path $rr.Root 'versions'
        $vCount = 0
        try { $vCount = @(Get-ChildItem -LiteralPath $vdir -Directory -ErrorAction SilentlyContinue).Count } catch { }

        $result += [pscustomobject]@{
            Path         = $rr.Root
            VersionCount = $vCount
            Valid        = (Test-IsMcDir -Path $rr.Root -Strict)
        }
    }

    # 合法的排前面, 版本多的排前面
    return @($result | Sort-Object @{ Expression = 'Valid'; Descending = $true }, @{ Expression = 'VersionCount'; Descending = $true })
}

function Select-McDirInteractively {
    <#
        列出所有候选整合包让用户挑一个

        这是"换一个 PCL 实例"的唯一入口: 选中后会写进 配置.cfg,
        之后不加 -McDir 也会默认用它。

        注意它选的是 PCL 实例(.minecraft), 不是整合包 —— 整合包(版本)由
        Select-VersionInteractively 在选定实例之后再选。
    #>
    param([string]$Current, [string[]]$ExtraRoots)

    Say ''
    Say '扫描本机的 PCL 实例(.minecraft)...'
    $list = @(Get-AllMcDirs -ExtraRoots $ExtraRoots)
    if ($list.Count -eq 0) { throw '没有找到任何 .minecraft 目录, 请用 -McDir 直接指定' }

    Say ''
    Say '找到以下 PCL 实例:'
    Say ''
    for ($i = 0; $i -lt $list.Count; $i++) {
        $item = $list[$i]
        $mark = ''
        if ($Current -and $item.Path -eq $Current) { $mark = '  <- 当前' }
        $tag = if ($item.Valid) { '' } else { '  [缺 libraries, 可能不完整]' }
        $color = if ($mark) { 'Cyan' } elseif ($item.Valid) { 'White' } else { 'DarkGray' }
        Write-Host ("  [{0,2}] {1}" -f ($i + 1), $item.Path) -ForegroundColor $color
        Write-Host ("       {0} 个版本{1}{2}" -f $item.VersionCount, $tag, $mark) -ForegroundColor DarkGray
    }
    Say ''

    $pick = Read-Host '序号(回车取消)'
    if ($pick -notmatch '^\d+$') { return $null }
    $idx = [int]$pick - 1
    if ($idx -lt 0 -or $idx -ge $list.Count) { return $null }

    $chosen = $list[$idx].Path
    Save-McDir $chosen
    Ok "已切换 PCL 实例: $chosen"
    return $chosen
}

function Find-McDir {
    <#
        定位 .minecraft

        顺序: -McDir -> 配置.cfg -> 脚本目录向上 6 层 -> 用户目录/常见盘符
              -> 在这些根下找一层 .minecraft -> 多候选时让用户选

        两种"宽松"处理:
          · 给的路径不是 .minecraft 根也没关系: 只要它在 .minecraft 里面
            (版本目录 / versions / mods 之类), 都会自动上溯到根
          · 如果上溯到的是一个版本目录, 顺手把 -VersionName 也锁定了

        注意: 刻意只向下找一层, 不递归。桌面这种目录文件极多, 递归会明显变慢,
              而且扫到无关目录还可能误判。
    #>
    if ($McDir) {
        $r = Resolve-McDirFromPath -Path $McDir
        if (-not $r.Root) {
            throw ("指定的路径不在任何有效的 .minecraft 里: $McDir`n" +
                "  说明: 要指到含 versions\ 与 libraries\ 的 .minecraft 根目录。`n" +
                "        版本隔离后 mods/config/saves 在 versions\<版本名>\ 里, `n" +
                "        但 libraries\ 和 assets\ 一直在 .minecraft 根下共享, 所以只有根目录才是操作目标。")
        }
        if ($r.Levels -gt 0) {
            Info "从 '$McDir' 上溯 $($r.Levels) 层找到 .minecraft: $($r.Root)"
        }
        if ($r.VersionName) {
            if (-not $VersionName) {
                $script:VersionName = $r.VersionName
                Info "路径是个版本目录, 已自动锁定版本: $($r.VersionName)"
            } elseif ($VersionName -ne $r.VersionName) {
                Warn "给了 -VersionName '$VersionName', 但路径指向版本 '$($r.VersionName)', 以 -VersionName 为准"
            }
        }
        Save-McDir $r.Root
        return $r.Root
    }

    # 明确要求"换一个整合包": 列出候选让用户挑, 选中即写配置
    if ($PickMcDir) {
        $chosen = Select-McDirInteractively -Current (Get-SavedMcDir) -ExtraRoots $ScanRoot
        if (-not $chosen) { throw '已取消选择整合包' }
        return $chosen
    }

    $saved = Get-SavedMcDir
    if ($saved) {
        $r = Resolve-McDirFromPath -Path $saved
        if ($r.Root) { return $r.Root }
    }

    # 1) 脚本自身周围
    $probe = @()
    $cur = $PSScriptRoot
    for ($i = 0; $i -lt 6 -and $cur; $i++) {
        $probe += $cur
        $probe += (Join-Path $cur '.minecraft')
        $probe += (Join-Path $cur 'minecraft')
        $cur = Split-Path $cur -Parent
    }
    $probe += @(
        (Join-Path $env:USERPROFILE '.minecraft'),
        (Join-Path $env:APPDATA '.minecraft')
    )
    foreach ($p in $probe) {
        $r = Resolve-McDirFromPath -Path $p
        if ($r.Root) {
            Save-McDir $r.Root
            Info "已记住 .minecraft: $($r.Root)"
            return $r.Root
        }
    }

    # 2) 常见"整合包根目录"下找一层 .minecraft
    $roots = @(
        'D:\Program Files\Minecraft',
        'C:\Program Files\Minecraft',
        'D:\Minecraft',
        'C:\Minecraft',
        (Join-Path $env:USERPROFILE 'Desktop')
    )
    $found = @()
    foreach ($r in $roots) {
        if (-not (Test-Path -LiteralPath $r)) { continue }
        $candidates = @()
        $candidates += @(Get-ChildItem -LiteralPath $r -Directory -ErrorAction SilentlyContinue |
            ForEach-Object { Join-Path $_.FullName '.minecraft' })
        $candidates += @(Join-Path $r '.minecraft')
        foreach ($c in $candidates) {
            if (Test-IsMcDir $c) { $found += (Resolve-Path -LiteralPath $c).Path }
        }
    }
    $found = @($found | Select-Object -Unique | Sort-Object)

    if ($found.Count -eq 1) { Save-McDir $found[0]; return $found[0] }
    if ($found.Count -gt 1) {
        Say ''
        Say '找到多个 .minecraft, 请选择要操作的整合包:'
        for ($i = 0; $i -lt $found.Count; $i++) { Say ("  [{0}] {1}" -f ($i + 1), $found[$i]) }
        $pick = Read-Host '序号(回车取消)'
        if ($pick -match '^\d+$' -and [int]$pick -ge 1 -and [int]$pick -le $found.Count) {
            $chosen = $found[[int]$pick - 1]
            Save-McDir $chosen
            return $chosen
        }
    }
    throw '没能定位 .minecraft, 请用 -McDir 指定'
}

function Get-LoaderVersionsOfDir {
    <# 读 Setup.ini 里记录的 NeoForge 版本(可能为空: 老 PCL 或不完整安装) #>
    param([string]$VersionDir)
    $ini = Read-TextFile (Join-Path $VersionDir 'PCL\Setup.ini')
    if (-not $ini) { return $null }
    $m = [regex]::Match($ini, '(?m)^VersionNeoForge:([^\r\n]*)')
    if ($m.Success) { return $m.Groups[1].Value.Trim() }
    return $null
}

function Get-NeoForgeVersionDirs {
    <#
        列出 .minecraft 下所有 NeoForge 版本目录
        判据: Setup.ini 有 VersionNeoForge, 或版本 JSON 里出现 --fml.neoForgeVersion
    #>
    param([string]$Root)
    $result = @()
    $versionsDir = Join-Path $Root 'versions'
    foreach ($d in (Get-ChildItem -LiteralPath $versionsDir -Directory -ErrorAction SilentlyContinue)) {
        $jsonPath = Join-Path $d.FullName ($d.Name + '.json')
        if (-not (Test-Path -LiteralPath $jsonPath)) { continue }
        $nf = Get-LoaderVersionsOfDir $d.FullName
        $looksNeoForge = [bool]$nf
        if (-not $looksNeoForge) {
            $raw = Read-TextFile $jsonPath
            if ($raw -and $raw -match '--fml\.neoForgeVersion') { $looksNeoForge = $true }
        }
        if ($looksNeoForge) {
            $result += [pscustomobject]@{ Name = $d.Name; Dir = $d.FullName; Json = $jsonPath; NeoForge = $nf }
        }
    }
    return @($result)
}

function Select-VersionDir {
    <#
        选一个版本目录(整合包)

        优先级: -VersionDir(完整路径) -> -VersionName(名字) -> -PickVersion(交互)
                -> PCL.ini 里最近启动的 -> 只有一个就它 -> 让用户选

        这里的"版本目录"= 整合包, 位于 <PCL实例>\versions\<版本名>\,
        不要和 -McDir(PCL 实例本身) 混淆。
    #>
    param([string]$Root)
    $cands = @(Get-NeoForgeVersionDirs $Root)

    # 1) 明确给了版本文件夹
    if ($VersionDir) {
        $full = $VersionDir
        try { if (Test-Path -LiteralPath $VersionDir) { $full = (Resolve-Path -LiteralPath $VersionDir).Path } } catch { }
        $leaf = Split-Path $full -Leaf
        $hit = $cands | Where-Object {
            $_.Dir -eq $full -or ($_.Name -eq $leaf -and $_.Dir -like '*\versions\*')
        } | Select-Object -First 1
        if (-not $hit) {
            throw ("指定的版本目录不在这个 PCL 实例下: $VersionDir`n" +
                "  PCL 实例: $Root`n" +
                "  该实例下可选的版本: " + (($cands | ForEach-Object { $_.Name }) -join ', '))
        }
        return $hit
    }

    # 2) 只给了版本名
    if ($VersionName) {
        $hit = $cands | Where-Object { $_.Name -eq $VersionName } | Select-Object -First 1
        if (-not $hit) { throw "找不到版本目录: $VersionName (当前有: $(($cands | ForEach-Object { $_.Name }) -join ', '))" }
        return $hit
    }

    if ($cands.Count -eq 0) { throw '这个 PCL 实例下没有 NeoForge 版本目录' }

    # 3) 明确要求交互选
    if ($PickVersion) {
        $picked = Select-VersionInteractively -Root $Root -Current ''
        if (-not $picked) { throw '已取消选择整合包' }
        return $picked
    }

    if ($cands.Count -eq 1) { return $cands[0] }

    $pclIni = Read-TextFile (Join-Path $Root 'PCL.ini')
    if ($pclIni) {
        $m = [regex]::Match($pclIni, '(?m)^Version:([^\r\n]*)')
        if ($m.Success) {
            $last = $m.Groups[1].Value.Trim()
            $hit = $cands | Where-Object { $_.Name -eq $last } | Select-Object -First 1
            if ($hit) { return $hit }
        }
    }

    $picked = Select-VersionInteractively -Root $Root -Current ''
    if (-not $picked) { throw '已取消选择整合包' }
    return $picked
}

function Select-VersionInteractively {
    <#
        列出某个 PCL 实例下所有 NeoForge 版本(整合包)让用户挑

        和 Select-McDirInteractively 的区别:
          Select-McDirInteractively   选 PCL 实例(.minecraft)
          Select-VersionInteractively 选该实例下的某个整合包版本
        两个是不同层级, 菜单里分别对应 [8] 和 [9]。
    #>
    param([string]$Root, [string]$Current)

    $cands = @(Get-NeoForgeVersionDirs $Root)
    if ($cands.Count -eq 0) { throw "PCL 实例 $Root 下没有 NeoForge 版本" }

    Say ''
    Say ("  PCL 实例: {0}" -f $Root)
    Say ''

    # 表头(按显示宽度补齐, 中文占两列)
    Write-Host ('  ' + (Format-Display '序号' 6) + (Format-Display '整合包(版本目录)' 30) +
        (Format-Display 'Minecraft' 12) + (Format-Display 'NeoForge' 12) + '库') -ForegroundColor DarkCyan

    for ($i = 0; $i -lt $cands.Count; $i++) {
        $c = $cands[$i]
        $mc = '?'; $nf = $c.NeoForge; $libs = '?'
        try {
            $js = Read-VersionJson $c.Json
            $li = Get-LoaderInfo $js
            $mc = $li.McVersion
            if ($li.NeoForge) { $nf = $li.NeoForge }
            $libs = @($js.libraries).Count
        } catch { }
        if (-not $nf) { $nf = '?' }

        $mark = ''
        if ($Current -and $c.Name -eq $Current) { $mark = '  <- 当前' }
        $color = if ($mark) { 'Cyan' } else { 'White' }
        Write-Host ('  ' + (Format-Display ("[{0}]" -f ($i + 1)) 6) + (Format-Display $c.Name 30) +
            (Format-Display $mc 12) + (Format-Display $nf 12) + $libs + $mark) -ForegroundColor $color
    }
    Say ''

    $pick = Read-Host '  序号(回车取消)'
    if ($pick -notmatch '^\d+$') { return $null }
    $idx = [int]$pick - 1
    if ($idx -lt 0 -or $idx -ge $cands.Count) { return $null }

    $chosen = $cands[$idx]
    $script:VersionName = $chosen.Name
    Ok "已锁定整合包: $($chosen.Name)"
    return $chosen
}

function Test-LoaderVersionFormat {
    <#
        校验版本号形态, 例如 21.1.266
        不校验就直接拼 URL 的话, 用户打错一个字要等 3 次重试才看到 404
    #>
    param([string]$Value)
    if ($Value -notmatch '^\d+(\.\d+)+$') {
        throw "版本号格式不对: '$Value' (应形如 21.1.266, 可用 -List 查看)"
    }
}

# ============================================================================
#  六. 版本解析(纯函数区: 只读文件/只做字符串处理, 不产生副作用)
# ============================================================================

function Read-VersionJson {
    param([string]$Path)
    $raw = Read-TextFile $Path
    if (-not $raw) { throw "读不到版本文件: $Path" }
    try { return ($raw | ConvertFrom-Json) } catch { throw "版本文件不是合法 JSON: $Path`n$($_.Exception.Message)" }
}

function Get-ArgText {
    <# 把 arguments 里的一项转成字符串; 对象型规则(带 rules)取其 value 拼接 #>
    param($Item)
    if ($null -eq $Item) { return '' }
    if ($Item -is [string]) { return $Item }
    if ($Item.PSObject.Properties.Name -contains 'value') {
        $v = $Item.value
        if ($v -is [array]) { return ($v -join ' ') }
        return [string]$v
    }
    return ''
}

function Get-GameArgValue {
    <# 从 arguments.game 里取某个开关后面的值(按"字符串对"匹配) #>
    param($Json, [string]$Flag)
    $game = @($Json.arguments.game)
    for ($i = 0; $i -lt $game.Count - 1; $i++) {
        if ((Get-ArgText $game[$i]) -eq $Flag) { return (Get-ArgText $game[$i + 1]) }
    }
    return ''
}

function Get-FmlArg {
    <# 取 --fml.xxx 的值 #>
    param($Json, [string]$Key)
    return (Get-GameArgValue -Json $Json -Flag "--fml.$Key")
}

function Get-LoaderInfo {
    <#
        一次取全 loader 四元组 + 主类
        这四个值就是"这个版本到底是什么"的唯一描述
    #>
    param($Json)
    return [pscustomobject]@{
        NeoForge     = Get-FmlArg $Json 'neoForgeVersion'
        Fml          = Get-FmlArg $Json 'fmlVersion'
        McVersion    = Get-FmlArg $Json 'mcVersion'
        NeoForm      = Get-FmlArg $Json 'neoFormVersion'
        LaunchTarget = (Get-GameArgValue -Json $Json -Flag '--launchTarget')
        MainClass    = $Json.mainClass
    }
}

function Get-LibraryPath {
    <#
        Maven 坐标 -> libraries 下的相对路径

        支持:
            group:artifact:version
            group:artifact:version:classifier
            group:artifact:version@ext        (老版本 21.1.1 这种写法)
            group:artifact:version:classifier@ext
    #>
    param([string]$Name)
    $ext = 'jar'
    $coords = $Name
    if ($coords -match '@') {
        $parts = $coords -split '@', 2
        $coords = $parts[0]; $ext = $parts[1]
    }
    $seg = $coords -split ':'
    if ($seg.Count -lt 3) { throw "无法解析的库坐标: $Name" }
    $group = $seg[0]; $artifact = $seg[1]; $version = $seg[2]
    $classifier = if ($seg.Count -ge 4) { $seg[3] } else { '' }
    $file = $artifact + '-' + $version
    if ($classifier) { $file += '-' + $classifier }
    $file += '.' + $ext
    $rel = ($group -replace '\.', '/') + '/' + $artifact + '/' + $version + '/' + $file
    return [pscustomobject]@{
        Rel = $rel; File = $file; Group = $group; Artifact = $artifact
        Version = $version; Classifier = $classifier; Ext = $ext
    }
}

function Get-LibraryUrl {
    <# 取下载地址: 优先 downloads.artifact.url -> 库自带 url 字段 -> 按 maven 规则拼 #>
    param($Lib, $LibPath)
    if ($Lib.downloads -and $Lib.downloads.artifact -and $Lib.downloads.artifact.url) {
        return $Lib.downloads.artifact.url
    }
    if ($Lib.PSObject.Properties.Name -contains 'url' -and $Lib.url) {
        return ($Lib.url.TrimEnd('/') + '/' + $LibPath.Rel)
    }
    return ("$script:MavenRoot/" + $LibPath.Rel)
}

function Get-LibrarySha1 {
    param($Lib)
    if ($Lib.downloads -and $Lib.downloads.artifact -and $Lib.downloads.artifact.sha1) {
        return $Lib.downloads.artifact.sha1
    }
    return $null
}

function Test-LibraryAllowed {
    <#
        按 libraries 条目的 rules 判断本机是否需要这个文件

        natives、objc-bridge、netty-epoll 这类跨平台包都带
        rules=[{action:allow, os:{name:linux|osx}}], 不判断会把 27 个
        用不上的库全算成"缺失", 也会白下载几十 MB。

        语义同官方启动器: 有 allow 命中才允许, disallow 命中则否决。
        本机按 windows / x64 处理。
    #>
    param($Lib)
    if (-not ($Lib.PSObject.Properties.Name -contains 'rules')) { return $true }
    $rules = @($Lib.rules)
    if ($rules.Count -eq 0) { return $true }
    $allowed = $false
    foreach ($r in $rules) {
        $match = $true
        if ($r.PSObject.Properties.Name -contains 'os' -and $r.os) {
            if ($r.os.PSObject.Properties.Name -contains 'name' -and $r.os.name) {
                if ($r.os.name -ne 'windows') { $match = $false }
            }
            if ($r.PSObject.Properties.Name -contains 'arch' -and $r.os.arch) {
                if ($r.os.arch -in @('x86', 'arm64')) { $match = $false }
            }
        }
        if ($match) {
            if ($r.action -eq 'allow') { $allowed = $true }
            elseif ($r.action -eq 'disallow') { $allowed = $false }
        }
    }
    return $allowed
}

# ============================================================================
#  七. loader 元数据(从 installer jar 里掏 version.json 与 client.lzma)
# ============================================================================

function Get-LoaderMeta {
    <#
        取某个 NeoForge 版本的安装元数据

        数据来源: maven 上的 neoforge-<v>-installer.jar(约 7 MB), 里面有两个
        我们需要的东西:
            version.json      该版本完整的 loader 定义(库 + 参数 + mainClass)
            data/client.lzma  打补丁用的 binpatch(生成 client.jar 时要用)

        缓存: <CacheRoot>\loader-<v>\{installer.jar, version.json, client.lzma}
              由于 installer 没有官方 sha1, 半截下载会被"文件存在即命中"误判,
              所以这里对 zip 解析失败做了自愈: 删掉重下一次。
    #>
    param([string]$NeoForgeVersion)

    $cacheDir = Join-Path $script:Ctx.CacheRoot "loader-$NeoForgeVersion"
    New-Directory $cacheDir
    $vj = Join-Path $cacheDir 'version.json'
    $lz = Join-Path $cacheDir 'client.lzma'
    $ins = Join-Path $cacheDir 'installer.jar'

    if (-not (Test-Path -LiteralPath $vj)) {
        $url = "$script:MavenRoot/net/neoforged/neoforge/$NeoForgeVersion/neoforge-$NeoForgeVersion-installer.jar"
        Info "取 $NeoForgeVersion 的安装元数据"

        # 校验器: 能被当成 zip 打开才算可用, 挡住"半截下载被当缓存"的情况
        $isZip = {
            param($path)
            try {
                Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue
                $z = [System.IO.Compression.ZipFile]::OpenRead($path)
                $n = $z.Entries.Count
                $z.Dispose()
                return ($n -gt 10)
            } catch { return $false }
        }

        try {
            Invoke-Download -Url $url -Dest $ins -Validate $isZip | Out-Null
        } catch {
            throw "取不到 NeoForge $NeoForgeVersion 的安装包, 版本号可能写错了(用 -List 看可用版本)。`n  $($_.Exception.Message)"
        }

        try {
            Add-Type -AssemblyName System.IO.Compression.FileSystem
            $zip = [System.IO.Compression.ZipFile]::OpenRead($ins)
            try {
                $e = $zip.Entries | Where-Object { $_.FullName -eq 'version.json' } | Select-Object -First 1
                if (-not $e) { throw "installer 里没有 version.json: $NeoForgeVersion" }
                [System.IO.Compression.ZipFileExtensions]::ExtractToFile($e, $vj, $true)
                $e2 = $zip.Entries | Where-Object { $_.FullName -eq 'data/client.lzma' } | Select-Object -First 1
                if ($e2) { [System.IO.Compression.ZipFileExtensions]::ExtractToFile($e2, $lz, $true) }
            } finally { $zip.Dispose() }
        } catch {
            # 自愈: 缓存坏了就清掉, 下次(或立刻重试一次)重新下载
            Warn "缓存里的安装包不可用, 清理后重试: $($_.Exception.Message)"
            Remove-Item -LiteralPath $ins -Force -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath $vj -Force -ErrorAction SilentlyContinue
            Invoke-Download -Url $url -Dest $ins -Validate $isZip | Out-Null
            $zip = [System.IO.Compression.ZipFile]::OpenRead($ins)
            try {
                $e = $zip.Entries | Where-Object { $_.FullName -eq 'version.json' } | Select-Object -First 1
                [System.IO.Compression.ZipFileExtensions]::ExtractToFile($e, $vj, $true)
                $e2 = $zip.Entries | Where-Object { $_.FullName -eq 'data/client.lzma' } | Select-Object -First 1
                if ($e2) { [System.IO.Compression.ZipFileExtensions]::ExtractToFile($e2, $lz, $true) }
            } finally { $zip.Dispose() }
        }
    }

    if (-not (Test-Path -LiteralPath $lz)) {
        # 有 version.json 但没有 lzma(老缓存) -> 补齐
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        if (Test-Path -LiteralPath $ins) {
            $zip = [System.IO.Compression.ZipFile]::OpenRead($ins)
            try {
                $e2 = $zip.Entries | Where-Object { $_.FullName -eq 'data/client.lzma' } | Select-Object -First 1
                if ($e2) { [System.IO.Compression.ZipFileExtensions]::ExtractToFile($e2, $lz, $true) }
            } finally { $zip.Dispose() }
        }
    }

    $json = Read-VersionJson $vj
    return [pscustomobject]@{ Json = $json; Lzma = $lz; InstallerJar = $ins; Info = (Get-LoaderInfo $json) }
}

function Read-VanillaBaseline {
    <#
        读原版版本定义, 作为"替换 loader 段落"的基线

        为什么要校验 id / mainClass:
          基线是整份 JSON 的地基, 如果 versions\<mc>\<mc>.json 被人改过、
          或者名字对不上内容, 会静默污染结果(而且很难查)。
          这里宁可返回 $null 让上层降级到"差集"模式, 也不用可疑的基线。
    #>
    param([string]$Root, [string]$McVersion)
    $path = Join-Path $Root ("versions\$McVersion\$McVersion.json")
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    try {
        $vj = Read-VersionJson $path
        if ($vj.id -ne $McVersion) {
            Warn "原版 JSON 的 id 是 '$($vj.id)', 与目录名 '$McVersion' 不符, 不拿它当基线"
            return $null
        }
        if ($vj.mainClass -ne 'net.minecraft.client.main.Main') {
            Warn "原版 JSON 的主类不是 net.minecraft.client.main.Main, 不拿它当基线"
            return $null
        }
        return $vj
    } catch {
        Warn "原版 JSON 解析失败, 不拿它当基线: $($_.Exception.Message)"
        return $null
    }
}

# ============================================================================
#  八. 库与产物准备
# ============================================================================

function Get-MissingLibraries {
    <#
        算出"这个 loader 需要、但本地还没有"的库(已按 rules 过滤平台包)
        DryRun 的预估和真正下载都走这一个函数, 避免两处逻辑走偏
    #>
    param($LoaderJson, [string]$Root)
    $libRoot = Join-Path $Root 'libraries'
    $missing = @()
    foreach ($lib in @($LoaderJson.libraries)) {
        if (-not (Test-LibraryAllowed $lib)) { continue }
        $lp = Get-LibraryPath $lib.name
        $dest = Join-Path $libRoot ($lp.Rel -replace '/', '\')
        if (-not (Test-Path -LiteralPath $dest)) { $missing += $lib }
    }
    return @($missing)
}

function Install-LoaderLibraries {
    <#
        按目标 loader 的 libraries 列表补齐 libraries 目录
        只增不删: 旧版本的库留着, 切回去就不用重新下载
    #>
    param($LoaderJson, [string]$Root)
    $libRoot = Join-Path $Root 'libraries'
    $missing = @(Get-MissingLibraries -LoaderJson $LoaderJson -Root $Root)
    $total = @($LoaderJson.libraries).Count

    Info "检查 loader 依赖 $total 项, 缺 $($missing.Count) 项"
    if ($missing.Count -eq 0) { return 0 }

    $failed = @()
    foreach ($lib in $missing) {
        $lp = Get-LibraryPath $lib.name
        $dest = Join-Path $libRoot ($lp.Rel -replace '/', '\')
        $sha = Get-LibrarySha1 $lib
        $url = Get-LibraryUrl $lib $lp
        try {
            Invoke-Download -Url $url -Dest $dest -ExpectSha1 $sha | Out-Null
        } catch {
            $failed += "$($lib.name)  <-  $url"
            Warn "缺库: $($lib.name)"
        }
    }
    Ok "依赖补齐完成(新下 $($missing.Count - $failed.Count) 项)"
    if ($failed.Count -gt 0) {
        throw ("以下依赖下载失败, 联网后重试:`n  " + ($failed -join "`n  "))
    }
    return $missing.Count
}

function Resolve-NeoForgeJars {
    <#
        备齐目标版本需要的三个 jar

          neoforge-<v>-universal.jar   maven 直供, 直接下
          client-<mc>-<neoform>-srg.jar  同 MC 版本内共用, 缺了就得重跑重映射链
          neoforge-<v>-client.jar       maven 上没有, 用 binarypatcher 把
                                        installer 里的 client.lzma 打在 srg 上生成

        生成命令(与 installer 的 processor #10 等价):
            java -jar binarypatcher.jar --clean <srg> --output <out> --apply <lzma>
        这个输出已与 PCL 自己的产物做过字节级比对(SHA1 相同)。
    #>
    param([string]$Root, [string]$VersionDir, [string]$NeoForgeVersion, [string]$McVersion, [string]$NeoForm, [string]$ClientLzma)

    $libRoot = Join-Path $Root 'libraries'
    $nfDir = Join-Path $libRoot "net\neoforged\neoforge\$NeoForgeVersion"
    New-Directory $nfDir
    $universal = Join-Path $nfDir "neoforge-$NeoForgeVersion-universal.jar"
    $clientJar = Join-Path $nfDir "neoforge-$NeoForgeVersion-client.jar"

    Invoke-Download -Url "$script:MavenRoot/net/neoforged/neoforge/$NeoForgeVersion/neoforge-$NeoForgeVersion-universal.jar" -Dest $universal | Out-Null

    $clientDir = Join-Path $libRoot "net\minecraft\client\$McVersion-$NeoForm"
    $srg = Join-Path $clientDir "client-$McVersion-$NeoForm-srg.jar"
    $extra = Join-Path $clientDir "client-$McVersion-$NeoForm-extra.jar"

    if (-not (Test-Path -LiteralPath $srg)) {
        throw "缺少 $McVersion-$NeoForm 的 srg 产物: $srg`n这说明需要跑完整的 NeoForm 重映射链(jarsplitter/AutoRenamingTool/binarypatcher), 属于跨 MC 版本安装, 本脚本只做同 MC 版本内的 loader 切换。"
    }
    if (-not (Test-Path -LiteralPath $extra)) {
        Warn "缺少 extra 产物(通常不影响启动, 但建议用 PCL 的重装补齐): $extra"
    }

    if (-not (Test-Path -LiteralPath $clientJar)) {
        $patcher = Get-BinaryPatcher $Root
        if (-not $patcher) { throw '找不到 binarypatcher, 无法生成 patched client jar' }
        if (-not (Test-Path -LiteralPath $ClientLzma)) { throw "缺少 binpatch: $ClientLzma" }
        $java = Get-JavaExe -VersionDir $VersionDir
        if (-not $java) { throw '找不到可用的 java(需要 21+)' }

        Info "生成 neoforge-$NeoForgeVersion-client.jar (binarypatcher)"
        $tmp = "$clientJar.build"
        $old = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try {
            # -Djava.net.useSystemProxies=true: 让 java 侧也跟随系统代理
            # (binarypatcher 本身不联网, 但保持与其他 java 调用一致, 便于以后接别的工具)
            $out = & $java '-Djava.net.useSystemProxies=true' -jar $patcher --clean $srg --output $tmp --apply $ClientLzma 2>&1
            $code = $LASTEXITCODE
        } finally { $ErrorActionPreference = $old }
        if ($code -ne 0 -or -not (Test-Path -LiteralPath $tmp)) {
            throw ("binarypatcher 失败(exit $code):`n" + ($out -join "`n"))
        }
        [System.IO.File]::Move($tmp, $clientJar)
        Ok ("client.jar 已生成 " + [math]::Round((Get-Item -LiteralPath $clientJar).Length / 1MB, 2) + " MB")
    } else {
        Info 'client.jar 已存在, 复用'
    }

    return [pscustomobject]@{ Universal = $universal; Client = $clientJar; Srg = $srg; Extra = $extra }
}

function Get-BinaryPatcher {
    <# 找本地的 binarypatcher; 没有就从 maven 补一个 #>
    param([string]$Root)
    $base = Join-Path $Root 'libraries\net\neoforged\installertools\binarypatcher'
    $hit = Get-ChildItem -LiteralPath $base -Recurse -Filter 'binarypatcher-*-fatjar.jar' -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($hit) { return $hit.FullName }
    if ($Offline) { return $null }
    Info '本地缺 binarypatcher, 从 maven 补一个'
    $dest = Join-Path $base '2.1.2\binarypatcher-2.1.2-fatjar.jar'
    try {
        Invoke-Download -Url "$script:MavenRoot/net/neoforged/installertools/binarypatcher/2.1.2/binarypatcher-2.1.2-fatjar.jar" -Dest $dest | Out-Null
        return $dest
    } catch { return $null }
}

function Get-JavaExe {
    <#
        找可用的 Java, 要求 21+ (NeoForge 1.20.5+ 必需)

        优先级: PCL 版本里记录的强制 Java -> JAVA_HOME -> 常见路径 -> PATH
        注意: java -version 的输出走 stderr, 直接 2>&1 在 Stop 策略下会被当成
        终止错误抛出来, 所以这里临时放宽策略并 try 住。
    #>
    param([string]$VersionDir)
    $candidates = @()

    if ($VersionDir) {
        $cfgPath = Join-Path $VersionDir 'PCL\config.json'
        if (Test-Path -LiteralPath $cfgPath) {
            try {
                $cfg = Read-VersionJson $cfgPath
                if ($cfg.InstanceForcedJava -and $cfg.InstanceForcedJava.Folder) {
                    $candidates += (Join-Path $cfg.InstanceForcedJava.Folder 'java.exe')
                }
            } catch { }
        }
    }
    if ($env:JAVA_HOME) { $candidates += (Join-Path $env:JAVA_HOME 'bin\java.exe') }
    $candidates += @(
        'D:\Program Files\jdk21\bin\java.exe',
        'C:\Program Files\Java\jdk-21\bin\java.exe'
    )
    $cmd = Get-Command java -ErrorAction SilentlyContinue
    if ($cmd) { $candidates += $cmd.Source }

    foreach ($c in $candidates) {
        if (-not $c -or -not (Test-Path -LiteralPath $c)) { continue }
        $major = 0
        $old = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try {
            $ver = (& $c -version 2>&1 | Out-String)
            if ($ver -match 'version "(?<v>\d+)') { $major = [int]$Matches['v'] }
        } catch {
        } finally { $ErrorActionPreference = $old }
        if ($major -ge 21) { return $c }
    }
    return $null
}

# ============================================================================
#  九. JSON 组装
# ============================================================================

function Get-LoaderSignature {
    <# 旧 loader 的库坐标集合, 用于"当前 JSON 减去旧 loader"的精确差集 #>
    param($LoaderJson)
    $names = New-Object System.Collections.Generic.HashSet[string]
    foreach ($l in @($LoaderJson.libraries)) { [void]$names.Add($l.name) }
    return $names
}

function Test-IsLoaderLib {
    <#
        兜底: 拿不到旧版 loader 定义时, 按坐标特征判断某个库是否属于 loader
        只在最后一级降级路径里用
    #>
    param([string]$Name)
    $g = ($Name -split ':')[0]
    $patterns = @(
        '^net\.neoforged', '^cpw\.mods', '^net\.minecraftforge', '^net\.fabricmc$',
        '^com\.electronwill\.night-config', '^net\.minecrell', '^org\.apache\.maven$',
        '^net\.jodah', '^com\.machinezoo', '^org\.openjdk\.nashorn', '^org\.jline$',
        '^org\.ow2\.asm', '^org\.antlr$', '^org\.codehaus\.plexus', '^net\.sf\.jopt-simple'
    )
    foreach ($p in $patterns) { if ($g -match $p) { return $true } }
    return $false
}

function Repair-LibraryEntry {
    <#
        老版本(如 21.1.1)的坐标把扩展名写在里面: net.jodah:typetools:0.6.3@jar
        新版不写。语义一样(Maven 默认扩展名就是 jar), 但为了与 PCL 装新版时的
        风格统一, 统一去掉; 非 jar 扩展保持原样。
    #>
    param($Lib)
    $name = [string]$Lib.name
    if ($name -match '@jar$') {
        $copy = $Lib | ConvertTo-Json -Depth 20 | ConvertFrom-Json
        $copy.name = $name -replace '@jar$', ''
        return [pscustomobject]@{ Lib = $copy; Renamed = $true }
    }
    return [pscustomobject]@{ Lib = $Lib; Renamed = $false }
}

function Test-IsLoaderJvmArg {
    <#
        判断某条 JVM 参数是否属于 loader 段落
        这些参数在换版本时必须整段替换, 不能与 vanilla 参数混在一起
    #>
    param([string]$Text)
    if (-not $Text) { return $false }
    if ($Text -match '^-Djava\.net\.preferIPv6Addresses') { return $true }
    if ($Text -match '^-DignoreList=') { return $true }
    if ($Text -match '^-DlibraryDirectory=') { return $true }
    if ($Text -match '^-DmergeModules=') { return $true }                 # 21.1.1 这类早期版本
    if ($Text -match '^-Dfml\.(pluginLayerLibraries|gameLayerLibraries)=') { return $true }
    if ($Text -eq '-p' -or $Text -eq '--add-modules' -or $Text -eq '--add-opens' -or $Text -eq '--add-exports') { return $true }
    return $false
}

function Remove-LoaderJvmArgs {
    <#
        从 JVM 参数里剔除 loader 段落

        必须成对剔除: -p / --add-modules / --add-opens / --add-exports 后面
        都跟着一个值(那个值本身没有任何 loader 特征), 只按单条过滤会把值留在
        原地, 生成一个语法错误的参数列表。
    #>
    param($JvmArgs)
    $out = New-Object System.Collections.ArrayList
    $arr = @($JvmArgs)
    $paired = @('-p', '--add-modules', '--add-opens', '--add-exports')
    $i = 0
    while ($i -lt $arr.Count) {
        $t = Get-ArgText $arr[$i]
        if (Test-IsLoaderJvmArg $t) {
            if ($paired -contains $t -and $i + 1 -lt $arr.Count) { $i += 2 } else { $i += 1 }
            continue
        }
        [void]$out.Add($arr[$i])
        $i++
    }
    return @($out)
}

function Remove-LoaderGameArgs {
    <# 从 game 参数里剔除 --fml.* 与 --launchTarget 及其值 #>
    param($GameArgs)
    $out = New-Object System.Collections.ArrayList
    $arr = @($GameArgs)
    $i = 0
    while ($i -lt $arr.Count) {
        $t = Get-ArgText $arr[$i]
        if ($t -match '^--fml\.' -or $t -eq '--launchTarget') {
            if ($arr[$i] -is [string] -and $i + 1 -lt $arr.Count -and $arr[$i + 1] -is [string]) { $i += 2 } else { $i += 1 }
            continue
        }
        [void]$out.Add($arr[$i])
        $i++
    }
    return @($out)
}

function Build-VersionJson {
    <#
        组装新版本 JSON 的三个"可变段落"

        规则 = 原 JSON 的非 loader 部分 + 目标 loader 的 (libraries/arguments/mainClass)

        非 loader 部分(基线)的来源优先级:
          1) 原版 JSON   versions\<mc>\<mc>.json   —— 最干净, 就是原始数据
          2) 差集        当前 JSON 减去旧 loader 的库坐标集合
          3) 特征剥离    按 groupId 特征判断(兜底)

        拼接规则与 PCL 自己装 NeoForge 时完全一致: 原版库整段在前, loader 库
        整段在后, 不按坐标去重(去重会得到比原文件更短的数组, 平白放大差异)。
    #>
    param($CurrentJson, $CurrentLoaderJson, $TargetLoaderJson, [string]$BaselineMode, [string]$Root, [string]$McVersion)

    $currentLibs = @($CurrentJson.libraries)
    $vanillaLibs = @()
    $vanillaJvm = @()
    $vanillaGame = @()
    $modeUsed = ''

    $currentLoaderNames = $null
    if ($CurrentLoaderJson) { $currentLoaderNames = Get-LoaderSignature $CurrentLoaderJson }

    # 1) 原版 JSON 基线
    $vanillaJson = $null
    if ($BaselineMode -in @('auto', 'vanilla')) {
        $vanillaJson = Read-VanillaBaseline -Root $Root -McVersion $McVersion
    }

    if ($vanillaJson) {
        $vanillaLibs = @($vanillaJson.libraries)
        $vanillaJvm = @($vanillaJson.arguments.jvm)
        $vanillaGame = @($vanillaJson.arguments.game)
        $modeUsed = "原版 JSON ($McVersion)"
    } elseif ($BaselineMode -in @('auto', 'diff') -and $currentLoaderNames) {
        # 2) 差集
        foreach ($l in $currentLibs) { if (-not $currentLoaderNames.Contains($l.name)) { $vanillaLibs += $l } }
        $vanillaJvm = @(Remove-LoaderJvmArgs -JvmArgs @($CurrentJson.arguments.jvm))
        $vanillaGame = @(Remove-LoaderGameArgs @($CurrentJson.arguments.game))
        $modeUsed = '当前 JSON 差集'
    } else {
        # 3) 特征剥离
        foreach ($l in $currentLibs) { if (-not (Test-IsLoaderLib $l.name)) { $vanillaLibs += $l } }
        $vanillaJvm = @(Remove-LoaderJvmArgs -JvmArgs @($CurrentJson.arguments.jvm))
        $vanillaGame = @(Remove-LoaderGameArgs @($CurrentJson.arguments.game))
        $modeUsed = '坐标特征剥离'
    }

    $loaderLibs = @($TargetLoaderJson.libraries)
    $merged = New-Object System.Collections.ArrayList
    foreach ($l in $vanillaLibs) { [void]$merged.Add($l) }
    $renamed = 0
    foreach ($l in $loaderLibs) {
        $fixed = Repair-LibraryEntry -Lib $l
        if ($fixed.Renamed) { $renamed++ }
        [void]$merged.Add($fixed.Lib)
    }
    if ($renamed -gt 0) {
        Info "已把 $renamed 个带 @jar 后缀的库坐标归一化(老版本写法, 去掉后缀语义不变)"
    }

    $newJvm = New-Object System.Collections.ArrayList
    foreach ($a in $vanillaJvm) { [void]$newJvm.Add($a) }
    foreach ($a in @($TargetLoaderJson.arguments.jvm)) { [void]$newJvm.Add($a) }

    $newGame = New-Object System.Collections.ArrayList
    foreach ($a in $vanillaGame) { [void]$newGame.Add($a) }
    foreach ($a in @($TargetLoaderJson.arguments.game)) { [void]$newGame.Add($a) }

    Info "基线来源: $modeUsed  (原版库 $(@($vanillaLibs).Count) + loader 库 $(@($loaderLibs).Count) = $(@($merged).Count))"

    return [pscustomobject]@{
        Json = [pscustomobject]@{
            arguments = [pscustomobject]@{ game = @($newGame); jvm = @($newJvm) }
            libraries = @($merged)
            mainClass = $TargetLoaderJson.mainClass
        }
        VanillaLibs = @($vanillaLibs)
        LoaderLibs  = @($loaderLibs)
        Baseline    = $modeUsed
    }
}

function Merge-VersionJson {
    <#
        把组装好的三个段落写回原 JSON 的骨架里

        只替换 libraries / arguments / mainClass 三项, 其余字段
        (assets, downloads, assetIndex, javaVersion, logging, complianceLevel,
         minimumLauncherVersion, clientVersion, id, type, time...) 原样保留 ——
        这些是 Minecraft 侧的常量, 与 loader 版本无关。

        注意: 必须用"直接赋值"而不是 Add-Member -Force。
        Add-Member -Force 对已存在的属性是"删掉再追加", 会把这三个字段挪到末尾,
        整个文件的字段顺序就变了 —— JSON 语义虽不变, 但 diff 变得不可读, 也破坏了
        "往返切换 SHA1 一致"这条验收标准。直接赋值则保持原位。
    #>
    param($CurrentJson, $Built)
    $out = Copy-VersionJson -Source $CurrentJson
    $out.libraries = @($Built.Json.libraries)
    $out.mainClass = $Built.Json.mainClass
    $out.arguments = [pscustomobject]@{
        game = @($Built.Json.arguments.game)
        jvm  = @($Built.Json.arguments.jvm)
    }
    return $out
}

# ============================================================================
#  十. 落点读写(三个文件: 版本 JSON / Setup.ini / config.json)
# ============================================================================

function Update-SetupIni {
    <#
        改 PCL 的版本设置:
            VersionNeoForge:21.1.266     PCL 界面显示 + "重装/更新"的依据
            Info:正式版 1.21.1, NeoForge 21.1.266

        Info 只替换 "NeoForge <版本>" 这一段, 保留前面原有的类型词(正式版/快照版),
        免得把非正式版写成"正式版"。
    #>
    param([string]$VersionDir, [string]$NewNeoForge, [string]$McVersion)

    $path = Join-Path $VersionDir 'PCL\Setup.ini'
    if (-not (Test-Path -LiteralPath $path)) { Warn "没有 Setup.ini, 跳过: $path"; return $false }

    $text = Read-TextFile $path
    $original = $text

    # VersionNeoForge
    if ($text -match '(?m)^VersionNeoForge:') {
        $text = [regex]::Replace($text, '(?m)^VersionNeoForge:[^\r\n]*', "VersionNeoForge:$NewNeoForge")
    } else {
        $text = $text.TrimEnd("`r", "`n") + "`r`nVersionNeoForge:$NewNeoForge`r`n"
    }

    # Info: 保留原有类型词, 只换 NeoForge 版本
    if ($text -match '(?m)^Info:([^\r\n]*)') {
        $oldInfo = $Matches[1]
        $m = [regex]::Match($oldInfo, '^(?<head>[^,]*?)\s*,\s*NeoForge\s+\S+\s*$')
        if ($m.Success) {
            $newInfo = ($m.Groups['head'].Value.Trim()) + ", NeoForge $NewNeoForge"
        } else {
            # 老格式不认识就直接按标准格式写, 但尽量沿用原来的类型词
            $typeWord = '正式版'
            if ($oldInfo -match '(快照版|预览版|正式版)') { $typeWord = $Matches[1] }
            $newInfo = "$typeWord $McVersion, NeoForge $NewNeoForge"
        }
        $text = [regex]::Replace($text, '(?m)^Info:[^\r\n]*', "Info:$newInfo")
    } else {
        $text = $text.TrimEnd("`r", "`n") + "`r`nInfo:正式版 $McVersion, NeoForge $NewNeoForge`r`n"
    }

    if ($text -ne $original) {
        Write-TextFile -Path $path -Content $text
        return $true
    }
    return $false
}

function Update-PclConfig {
    <#
        改 PCL 的安装清单:
            MinecraftInstallManifest.Components.ModLoaderVersions.NeoForge

        这是新版 PCL 判断"这个版本装了什么"的元数据, 与 Setup.ini 是两套
        (旧 PCL 只写 ini, 新 PCL 两个都写)。存在的层才改, 不硬造结构。
    #>
    param([string]$VersionDir, [string]$NewNeoForge)

    $path = Join-Path $VersionDir 'PCL\config.json'
    if (-not (Test-Path -LiteralPath $path)) {
        Info "没有 PCL/config.json, 跳过(老版本 PCL 不写这个文件)"
        return $false
    }

    $obj = Read-VersionJson $path
    $changed = $false

    if ($obj.PSObject.Properties.Name -contains 'MinecraftInstallManifest' -and $obj.MinecraftInstallManifest) {
        $m = $obj.MinecraftInstallManifest
        if (-not ($m.PSObject.Properties.Name -contains 'Components') -or -not $m.Components) {
            Set-JsonProperty -Object $m -Name 'Components' -Value ([pscustomobject]@{})
        }
        if (-not ($m.Components.PSObject.Properties.Name -contains 'ModLoaderVersions') -or -not $m.Components.ModLoaderVersions) {
            Set-JsonProperty -Object $m.Components -Name 'ModLoaderVersions' -Value ([pscustomobject]@{})
        }
        $old = $null
        if ($m.Components.ModLoaderVersions.PSObject.Properties.Name -contains 'NeoForge') {
            $old = $m.Components.ModLoaderVersions.NeoForge
        }
        if ($old -ne $NewNeoForge) {
            Set-JsonProperty -Object $m.Components.ModLoaderVersions -Name 'NeoForge' -Value $NewNeoForge
            $changed = $true
        }
        Set-JsonProperty -Object $m -Name 'LastModifiedUtc' -Value ((Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffffffZ'))
        $changed = $true
    }

    if ($changed) {
        Write-TextFile -Path $path -Content (ConvertTo-JsonText $obj)
    }
    return $changed
}

# ============================================================================
#  十一. 校验
# ============================================================================

function Test-JvmArgReferences {
    <#
        JVM 参数里除了 --fml.*, 还有三类东西是"按文件名点名"的:

          -p <module path>      写死了 asm / bootstraplauncher 的版本路径
          -DignoreList=...      列举要跳过的 jar 文件名
          -DmergeModules=...    列举要合并的 jar 文件名(21.1.1 要求 jna-5.10.0.jar)

        这里把它们逐项对照 classpath 实际内容, 分两级输出:
          Fatal  -p 指向的模块缺失 -> 100% 起不来
          Warn   ignoreList / mergeModules 点名的文件缺席 -> 通常是 FML 会跳过的
                 历史遗留(如 21.1.1 要 jna 5.10.0 而 vanilla 给的是 5.14.0)
    #>
    param($Json, [string]$Root)
    $fatal = @()
    $warn = @()
    $jvm = @($Json.arguments.jvm)
    $libRoot = Join-Path $Root 'libraries'

    $basenames = New-Object System.Collections.Generic.HashSet[string]
    foreach ($lib in @($Json.libraries)) {
        try {
            if (-not (Test-LibraryAllowed $lib)) { continue }
            $lp = Get-LibraryPath $lib.name
            [void]$basenames.Add($lp.File)
        } catch { }
    }

    $sep = [regex]::Escape('${classpath_separator}')
    for ($i = 0; $i -lt $jvm.Count; $i++) {
        $t = Get-ArgText $jvm[$i]

        if ($t -eq '-p' -and $i + 1 -lt $jvm.Count) {
            $value = Get-ArgText $jvm[$i + 1]
            foreach ($seg in ($value -split $sep)) {
                if (-not $seg) { continue }
                $rel = ($seg -replace [regex]::Escape('${library_directory}'), '').TrimStart('/', '\')
                if (-not $rel) { continue }
                $full = Join-Path $libRoot ($rel -replace '/', '\')
                if (-not (Test-Path -LiteralPath $full)) {
                    $fatal += "JVM 参数 -p 指向的模块不存在: $rel (目标版本要求的库没备齐)"
                }
            }
        }

        if ($t -match '^-DignoreList=(.*)$') {
            foreach ($n in ($Matches[1] -split ',')) {
                $n = $n.Trim()
                if (-not $n) { continue }
                if ($n -match '^\$\{') { continue }
                if ($n -eq 'client-extra' -or $n -like 'neoforge-*') { continue }
                if (-not $basenames.Contains($n)) {
                    $warn += "JVM 参数 -DignoreList 提到 $n, classpath 上没有这个文件(一般无影响)"
                }
            }
        }

        if ($t -match '^-DmergeModules=(.*)$') {
            foreach ($n in ($Matches[1] -split ',')) {
                $n = $n.Trim()
                if (-not $n) { continue }
                if (-not $basenames.Contains($n)) {
                    $warn += "该版本要求合并 $n, 而 classpath 上是 vanilla 自带的另一个版本(NeoForge 早期版本的历史遗留, 通常只影响日志)"
                }
            }
        }
    }
    return [pscustomobject]@{ Fatal = @($fatal); Warn = @($warn) }
}

function Test-VersionState {
    <#
        自检: 这个版本"看起来"是否自洽

        检查四类:
          1) 三处落点(JSON / Setup.ini / config.json)的 loader 版本是否一致
          2) 关键产物 universal/client/srg 是否存在
          3) classpath 上每个库文件是否存在(按 rules 过滤平台包)
          4) JVM 参数里点名引用的模块是否存在

        -Parsed 可以传入已经解析好的 @{Json; Info}, 避免同一次操作里重复解析
    #>
    param(
        [string]$Root,
        [string]$VersionDir,
        [string]$JsonPath,
        [switch]$Quiet,
        $Parsed
    )

    $problems = @()
    $warnings = @()

    $json = if ($Parsed -and $Parsed.Json) { $Parsed.Json } else { Read-VersionJson $JsonPath }
    $li = if ($Parsed -and $Parsed.Info) { $Parsed.Info } else { Get-LoaderInfo $json }

    if (-not $li.NeoForge) { $problems += '版本 JSON 里没有 --fml.neoForgeVersion' }
    if (-not $li.McVersion) { $problems += '版本 JSON 里没有 --fml.mcVersion' }
    if (-not $li.Fml) { $problems += '版本 JSON 里没有 --fml.fmlVersion' }

    # 1) 三处一致性
    $iniVer = Get-LoaderVersionsOfDir $VersionDir
    if ($iniVer -and $li.NeoForge -and ($iniVer -ne $li.NeoForge)) {
        $problems += "Setup.ini 记录 $iniVer, 版本 JSON 实际 $($li.NeoForge)  -> PCL 会显示错版本, 且'重装'会打回 $iniVer"
    }
    $cfgPath = Join-Path $VersionDir 'PCL\config.json'
    if (Test-Path -LiteralPath $cfgPath) {
        try {
            $cfg = Read-VersionJson $cfgPath
            if ($cfg.MinecraftInstallManifest -and $cfg.MinecraftInstallManifest.Components -and $cfg.MinecraftInstallManifest.Components.ModLoaderVersions) {
                $cv = $cfg.MinecraftInstallManifest.Components.ModLoaderVersions.NeoForge
                if ($cv -and $li.NeoForge -and ($cv -ne $li.NeoForge)) {
                    $problems += "PCL/config.json 安装清单记录 $cv, 版本 JSON 实际 $($li.NeoForge)"
                }
            }
        } catch { Warn "PCL/config.json 解析失败: $($_.Exception.Message)" }
    }

    # 2) 关键产物
    if ($li.NeoForge -and $li.McVersion -and $li.NeoForm) {
        $nfDir = Join-Path $Root "libraries\net\neoforged\neoforge\$($li.NeoForge)"
        foreach ($f in @("neoforge-$($li.NeoForge)-universal.jar", "neoforge-$($li.NeoForge)-client.jar")) {
            if (-not (Test-Path -LiteralPath (Join-Path $nfDir $f))) { $problems += "缺文件: $f" }
        }
        $clientDir = Join-Path $Root "libraries\net\minecraft\client\$($li.McVersion)-$($li.NeoForm)"
        if (-not (Test-Path -LiteralPath (Join-Path $clientDir "client-$($li.McVersion)-$($li.NeoForm)-srg.jar"))) {
            $problems += "缺文件: client-$($li.McVersion)-$($li.NeoForm)-srg.jar"
        }
    }

    # 3) classpath 完整性
    $libRoot = Join-Path $Root 'libraries'
    $miss = 0; $missList = @()
    foreach ($lib in @($json.libraries)) {
        try {
            if (-not (Test-LibraryAllowed $lib)) { continue }
            $lp = Get-LibraryPath $lib.name
            $dest = Join-Path $libRoot ($lp.Rel -replace '/', '\')
            if (-not (Test-Path -LiteralPath $dest)) { $miss++; if ($missList.Count -lt 8) { $missList += $lib.name } }
        } catch { }
    }
    if ($miss -gt 0) { $problems += "classpath 上有 $miss 个库文件缺失, 例如: $($missList -join '; ')" }

    # 4) JVM 参数引用
    $argRef = Test-JvmArgReferences -Json $json -Root $Root
    foreach ($p in @($argRef.Fatal)) { $problems += $p }
    $warnings = @($argRef.Warn)

    if (-not $Quiet) {
        $stateText = if ($problems.Count -eq 0) { '一致' } else { "有 $($problems.Count) 个问题" }
        Say ''
        Say "版本      : $(Split-Path $VersionDir -Leaf)"
        Say "Minecraft : $($li.McVersion)"
        Say "NeoForge  : $($li.NeoForge)   (FML $($li.Fml), NeoForm $($li.NeoForm))"
        Say "启动目标  : $($li.LaunchTarget)    主类: $($li.MainClass)"
        Say "库条目    : $(@($json.libraries).Count)"
        Say "状态      : $stateText"
        if ($problems.Count -gt 0) { foreach ($p in $problems) { Warn $p } }
        if ($warnings.Count -gt 0) { foreach ($w in $warnings) { Info "提示: $w" } }
    }

    return [pscustomobject]@{ Problems = @($problems); Warnings = @($warnings); Info = $li }
}

function Get-ModsIndex {
    <#
        扫描 mods 目录, 得到每个 jar 的 loaderVersion 声明

        代价: 211 个 jar 每个都要开 zip 读一个 entry, 约 3-5 秒。
        所以按 (文件名 + 大小 + 修改时间) 做缓存, 只有变化的 jar 才重扫。
        缓存文件: <CacheRoot>\mods-index.json
    #>
    param([string]$VersionDir)

    $modsDir = Join-Path $VersionDir 'mods'
    if (-not (Test-Path -LiteralPath $modsDir)) { return @() }

    $jars = @(Get-ChildItem -LiteralPath $modsDir -Filter *.jar -File -ErrorAction SilentlyContinue)
    if ($jars.Count -eq 0) { return @() }

    # 读旧缓存
    $cacheFile = Join-Path $script:Ctx.CacheRoot 'mods-index.json'
    $cache = @{}
    if (Test-Path -LiteralPath $cacheFile) {
        try {
            $raw = Read-TextFile $cacheFile
            $obj = $raw | ConvertFrom-Json
            foreach ($p in $obj.PSObject.Properties) { $cache[$p.Name] = $p.Value }
        } catch { $cache = @{} }
    }

    $result = @()
    $hits = 0; $scans = 0
    Add-Type -AssemblyName System.IO.Compression.FileSystem

    foreach ($j in $jars) {
        $key = "$($j.Name)|$($j.Length)|$($j.LastWriteTimeUtc.Ticks)"
        if ($cache.ContainsKey($key)) {
            $result += [pscustomobject]@{ Jar = $j.Name; LoaderVersion = $cache[$key] }
            $hits++
            continue
        }
        $lv = $null
        try {
            $zip = [System.IO.Compression.ZipFile]::OpenRead($j.FullName)
            try {
                $e = $zip.Entries | Where-Object { $_.FullName -eq 'META-INF/neoforge.mods.toml' } | Select-Object -First 1
                if ($e) {
                    $sr = New-Object System.IO.StreamReader($e.Open())
                    $txt = $sr.ReadToEnd(); $sr.Close()
                    $m = [regex]::Match($txt, '(?m)^\s*loaderVersion\s*=\s*"([^"]*)"')
                    if ($m.Success) { $lv = $m.Groups[1].Value.Trim() }
                }
            } finally { $zip.Dispose() }
        } catch { }
        $cache[$key] = $lv
        $result += [pscustomobject]@{ Jar = $j.Name; LoaderVersion = $lv }
        $scans++
    }

    if ($scans -gt 0) {
        try {
            $saveObj = [pscustomobject]@{}
            foreach ($k in $cache.Keys) { $saveObj | Add-Member -NotePropertyName $k -NotePropertyValue $cache[$k] -Force }
            New-Directory $script:Ctx.CacheRoot
            Write-TextFile -Path $cacheFile -Content (ConvertTo-JsonText $saveObj)
        } catch { }
        Info "mods 预检: 复用 $hits 条缓存, 新扫描 $scans 个 jar"
    }

    return @($result)
}

function Test-ModsCompatibility {
    <#
        预检: 目标 FML 版本是否满足各 mod 声明的 loaderVersion 区间

        注意: 不少 mod 把 loaderVersion 写成了别的分支(1.21.1 的包写成 [5.7,)),
        FML 对它只做软校验, 实际照常加载。所以这里返回清单让上层"提示",
        是否阻断由 -StrictModCheck 决定。
    #>
    param([string]$VersionDir, [string]$TargetFml)

    $index = @(Get-ModsIndex -VersionDir $VersionDir)
    if ($index.Count -eq 0) { return @() }

    $bad = @()
    foreach ($item in $index) {
        if (-not $item.LoaderVersion) { continue }
        if ($item.LoaderVersion -eq '*' -or $item.LoaderVersion -eq '') { continue }
        if (-not (Test-VersionInRange $TargetFml $item.LoaderVersion)) {
            $bad += "$($item.Jar)  要求 loaderVersion=$($item.LoaderVersion), 目标 FML=$TargetFml"
        }
    }
    return @($bad)
}

function Test-VersionInRange {
    <#
        判断版本是否落在 Maven 区间里
        支持: '*' / '4.0.45'(前缀匹配) / '[4,)' / '(4,5)' / '[1,)' 这类写法
    #>
    param([string]$Version, [string]$Range)
    $Range = $Range.Trim()
    if ($Range -eq '*' -or $Range -eq '') { return $true }
    if ($Range -notmatch '^[\[\(]') {
        return ($Version -like "$Range*")
    }
    $m = [regex]::Match($Range, '^([\[\(])([^,\]\)]*),?([^\]\)]*)([\]\)])$')
    if (-not $m.Success) { return $true }
    $lo = $m.Groups[2].Value.Trim()
    $hi = $m.Groups[3].Value.Trim()
    $incLo = $m.Groups[1].Value -eq '['
    $incHi = $m.Groups[4].Value -eq ']'
    $v = ConvertTo-ComparableVersion $Version
    if ($lo) {
        $l = ConvertTo-ComparableVersion $lo
        if ($incLo) { if ($v -lt $l) { return $false } } else { if ($v -le $l) { return $false } }
    }
    if ($hi) {
        $h = ConvertTo-ComparableVersion $hi
        if ($incHi) { if ($v -gt $h) { return $false } } else { if ($v -ge $h) { return $false } }
    }
    return $true
}

function ConvertTo-ComparableVersion {
    <#
        '4.0.45' -> [version]4.0.45.0
        补足四段是为了能直接比较, 缺段按 0 处理
    #>
    param([string]$V)
    $parts = @(($V -split '[.\-+]') | ForEach-Object { if ($_ -match '^\d+$') { [int]$_ } else { 0 } })
    while ($parts.Count -lt 4) { $parts += 0 }
    return [version]::new($parts[0], $parts[1], $parts[2], $parts[3])
}

# ============================================================================
#  十二. 备份与回滚
# ============================================================================

function New-Backup {
    <#
        把三个落点文件复制到一份带时间戳的备份里

        目录名带毫秒和冲突后缀: 同一秒里连做两次(from-to 相同)也不会互相覆盖
        备份内容只有三件纯文本(约 80 KB), 不含库 —— 库是可重建的, 不必备份
    #>
    param([string]$Root, [string]$VersionDir, [string]$JsonPath, [string]$From, [string]$To)

    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss-fff'
    $dir = Join-Path $script:Ctx.BackupRoot "${stamp}_$From-to-$To"
    $n = 1
    while (Test-Path -LiteralPath $dir) {
        $dir = Join-Path $script:Ctx.BackupRoot "${stamp}_$($n)_$From-to-$To"
        $n++
    }
    New-Directory $dir

    $vname = Split-Path $VersionDir -Leaf
    Copy-Item -LiteralPath $JsonPath -Destination (Join-Path $dir ($vname + '.json')) -Force
    foreach ($f in @('PCL\Setup.ini', 'PCL\config.json')) {
        $src = Join-Path $VersionDir $f
        if (Test-Path -LiteralPath $src) {
            Copy-Item -LiteralPath $src -Destination (Join-Path $dir ($f -replace '\\', '_')) -Force
        }
    }

    $meta = [pscustomobject]@{
        Time        = (Get-Date).ToString('s')
        VersionName = $vname
        VersionDir  = $VersionDir
        JsonPath    = $JsonPath
        From        = $From
        To          = $To
        Root        = $Root
    }
    Write-TextFile -Path (Join-Path $dir 'meta.json') -Content (ConvertTo-JsonText $meta)
    return $dir
}

function Get-Backups {
    param()
    if (-not (Test-Path -LiteralPath $script:Ctx.BackupRoot)) { return @() }
    $items = @()
    foreach ($d in (Get-ChildItem -LiteralPath $script:Ctx.BackupRoot -Directory | Sort-Object Name -Descending)) {
        $metaFile = Join-Path $d.FullName 'meta.json'
        if (-not (Test-Path -LiteralPath $metaFile)) { continue }
        try {
            $meta = Read-VersionJson $metaFile
            $items += [pscustomobject]@{ Dir = $d.FullName; Name = $d.Name; Meta = $meta }
        } catch { }
    }
    return @($items)
}

function Restore-Backup {
    <#
        把一份备份里的三个文件还原回版本目录
        切换失败时的自动回滚和 -Rollback 都走这里, 保证两条路径行为一致
    #>
    param([string]$BackupDir, [string]$VersionDir)

    $vname = Split-Path $VersionDir -Leaf
    $srcJson = Join-Path $BackupDir ($vname + '.json')
    if (-not (Test-Path -LiteralPath $srcJson)) { throw "备份里没有版本 JSON: $srcJson" }

    Copy-Item -LiteralPath $srcJson -Destination (Join-Path $VersionDir ($vname + '.json')) -Force
    foreach ($f in @('PCL\Setup.ini', 'PCL\config.json')) {
        $src = Join-Path $BackupDir ($f -replace '\\', '_')
        if (Test-Path -LiteralPath $src) {
            Copy-Item -LiteralPath $src -Destination (Join-Path $VersionDir $f) -Force
        }
    }
}

function Invoke-Rollback {
    <#
        回滚到某次备份(默认最新一次)
        回滚后立刻自检, 把"还原完是否真的自洽"也一并报出来
    #>
    param([string]$Root, [string]$Which)

    $backups = @(Get-Backups)
    if ($backups.Count -eq 0) { throw '没有可回滚的备份' }

    $pick = $null
    if ($Which) {
        $pick = $backups | Where-Object { $_.Name -like "*$Which*" } | Select-Object -First 1
        if (-not $pick) { throw "找不到备份: $Which`n现有备份:`n  " + (($backups | ForEach-Object { $_.Name }) -join "`n  ") }
    } else {
        $pick = $backups[0]
    }

    $meta = $pick.Meta
    $vname = $meta.VersionName
    $vdir = Join-Path $Root "versions\$vname"
    if (-not (Test-Path -LiteralPath $vdir)) { throw "备份对应的版本目录不存在: $vdir" }

    Head "回滚到 $($meta.From)"
    Info "备份: $($pick.Name)"
    Restore-Backup -BackupDir $pick.Dir -VersionDir $vdir
    Ok "已还原到 NeoForge $($meta.From)"
    Write-SwitchLog "回滚 $vname -> $($meta.From) (备份 $($pick.Name))"

    Test-VersionState -Root $Root -VersionDir $vdir -JsonPath (Join-Path $vdir ($vname + '.json'))

    # 回滚同样改了那三个文件, 同样需要 PCL 重新读一遍
    Show-RestartNotice -Action '回滚'
}

# ============================================================================
#  十三. 业务动作
# ============================================================================

function Invoke-Switch {
    <#
        把一个版本从当前 loader 换到目标 loader(核心流程)

        参数:
          Root/Version  由调用方定位好的上下文
          TargetVersion 目标 NeoForge 版本号(已通过格式校验)

        流程见文件头"二. 一次切换的流程"。
        事务边界: 从第 6 步(备份)开始, 之后任一步失败都会还原三个文件。
        库与产物不回滚 —— 它们只增不删, 留着下次还能用。
    #>
    param(
        [string]$Root,
        $Version,
        [string]$TargetVersion,
        [switch]$DryRun,
        [switch]$NoModCheck,
        [switch]$StrictModCheck,
        [switch]$Force
    )

    $vdir = $Version.Dir
    $jsonPath = $Version.Json
    $currentJson = Read-VersionJson $jsonPath
    $cur = Get-LoaderInfo $currentJson
    if (-not $cur.NeoForge) { $cur.NeoForge = Get-LoaderVersionsOfDir $vdir }
    if (-not $cur.NeoForge) { throw '当前版本 JSON 里读不到 NeoForge 版本' }
    if (-not $cur.McVersion) { throw '当前版本 JSON 里读不到 --fml.mcVersion' }

    # 抬头把"改哪个实例下的哪个整合包"写清楚, 避免把 PCL 实例当成整合包
    Head "换版本: $($cur.NeoForge) -> $TargetVersion"
    Say ("  PCL 实例  " + $Root)
    Say ("  整合包    " + $Version.Name)
    Say ("  版本目录  " + $vdir)
    Say ("  Minecraft " + $cur.McVersion)

    if ($cur.NeoForge -eq $TargetVersion) {
        Ok '目标版本与当前版本相同, 不需要切换'
        Test-VersionState -Root $Root -VersionDir $vdir -JsonPath $jsonPath -Parsed ([pscustomobject]@{ Json = $currentJson; Info = $cur })
        return
    }

    $series = ($cur.McVersion -replace '^1\.', '') + '.'
    if (-not $TargetVersion.StartsWith($series)) {
        Warn "目标 $TargetVersion 不在当前 Minecraft $($cur.McVersion) 的 NeoForge 系列 $series* 内, 下面会用目标元数据再校验一次"
    }

    # ── 1) 取目标元数据 ────────────────────────────────────────────────────
    $targetMeta = Get-LoaderMeta $TargetVersion
    $tgt = $targetMeta.Info
    if ($tgt.McVersion -ne $cur.McVersion) {
        throw "目标 NeoForge $TargetVersion 对应 Minecraft $($tgt.McVersion), 当前是 $($cur.McVersion)。跨 MC 版本要重新生成 NeoForm 产物(srg/extra/patch), 请用 PCL 装新版本再迁移数据。"
    }
    if ($tgt.NeoForm -ne $cur.NeoForm) {
        throw "目标 NeoForge $TargetVersion 的 neoFormVersion 是 $($tgt.NeoForm), 当前 $($cur.NeoForm)。srg/extra 产物需要重建, 不在本脚本能力内。"
    }
    Ok "元数据校验通过 (FML $($tgt.Fml), NeoForm $($tgt.NeoForm))"

    # ── 2) mods 预检(软校验) ───────────────────────────────────────────────
    if (-not $NoModCheck) {
        $bad = @(Test-ModsCompatibility -VersionDir $vdir -TargetFml $tgt.Fml)
        if ($bad.Count -gt 0) {
            Warn "有 $($bad.Count) 个 mod 声明的 loaderVersion 与目标 FML $($tgt.Fml) 不匹配(多数是作者笔误, 一般不影响加载):"
            $bad | Select-Object -First 10 | ForEach-Object { Say "    $_" }
            if ($StrictModCheck -and -not $Force) {
                $ans = Read-Host '严格模式: 仍然继续? (y/N)'
                if ($ans -notmatch '^[Yy]') { throw '已取消' }
            }
        } else {
            Ok 'mods 的 loaderVersion 约束全部满足'
        }
    }

    # ── 3) 取当前 loader 元数据(仅在没有原版 JSON 可作基线时才需要) ────────
    $currentLoaderJson = $null
    $vanillaProbe = Join-Path $Root ("versions\$($cur.McVersion)\$($cur.McVersion).json")
    if (-not (Test-Path -LiteralPath $vanillaProbe)) {
        try {
            Info "没有原版 JSON 可作基线, 取当前版本 $($cur.NeoForge) 的元数据做差集"
            $currentLoaderJson = (Get-LoaderMeta $cur.NeoForge).Json
        } catch { Warn "取当前版本元数据失败, 改用坐标特征剥离: $($_.Exception.Message)" }
    }

    # ── 4) 组装新 JSON ────────────────────────────────────────────────────
    $built = Build-VersionJson -CurrentJson $currentJson -CurrentLoaderJson $currentLoaderJson `
        -TargetLoaderJson $targetMeta.Json -BaselineMode 'auto' -Root $Root -McVersion $cur.McVersion
    $newJson = Merge-VersionJson -CurrentJson $currentJson -Built $built

    # ── 4.5) 演练: 只报计划, 不落盘 ───────────────────────────────────────
    if ($DryRun) {
        Head '演练结果'
        Say "  主类: $($newJson.mainClass)"
        Say "  库条目: $(@($newJson.libraries).Count)  (原 $(@($currentJson.libraries).Count))"
        Say "  FML 参数: --fml.neoForgeVersion $TargetVersion / --fml.fmlVersion $($tgt.Fml)"
        $missing = @(Get-MissingLibraries -LoaderJson $targetMeta.Json -Root $Root)
        Say "  待下载依赖: $($missing.Count) 项"
        $missing | Select-Object -First 12 | ForEach-Object { Say "    $($_.name)" }
        $clientJarProbe = Join-Path $Root "libraries\net\neoforged\neoforge\$TargetVersion\neoforge-$TargetVersion-client.jar"
        $universalProbe = Join-Path $Root "libraries\net\neoforged\neoforge\$TargetVersion\neoforge-$TargetVersion-universal.jar"
        if (Test-Path -LiteralPath $universalProbe) { Say "  universal.jar: 已存在" } else { Say "  universal.jar: 待下载" }
        if (Test-Path -LiteralPath $clientJarProbe) { Say "  client.jar: 已存在, 复用" } else { Say "  client.jar: 待用 binarypatcher 生成" }
        Say ''
        Info '演练结束, 没有写入任何文件'
        return
    }

    # ── 5) 备份 ───────────────────────────────────────────────────────────
    $backupDir = New-Backup -Root $Root -VersionDir $vdir -JsonPath $jsonPath -From $cur.NeoForge -To $TargetVersion
    Ok "已备份: $(Split-Path $backupDir -Leaf)"
    Write-SwitchLog "开始切换 $($Version.Name): $($cur.NeoForge) -> $TargetVersion (备份 $(Split-Path $backupDir -Leaf))"

    # ── 6~11) 事务体 ──────────────────────────────────────────────────────
    try {
        Install-LoaderLibraries -LoaderJson $targetMeta.Json -Root $Root | Out-Null
        $jars = Resolve-NeoForgeJars -Root $Root -VersionDir $vdir -NeoForgeVersion $TargetVersion `
            -McVersion $cur.McVersion -NeoForm $tgt.NeoForm -ClientLzma $targetMeta.Lzma
        Ok ("产物就绪: universal " + [math]::Round((Get-Item -LiteralPath $jars.Universal).Length / 1MB, 2) +
            " MB, client " + [math]::Round((Get-Item -LiteralPath $jars.Client).Length / 1MB, 2) + " MB")

        Write-TextFile -Path $jsonPath -Content (ConvertTo-JsonText $newJson)
        [void](Update-SetupIni -VersionDir $vdir -NewNeoForge $TargetVersion -McVersion $cur.McVersion)
        [void](Update-PclConfig -VersionDir $vdir -NewNeoForge $TargetVersion)
        Ok '三个落点已更新'

        $check = Test-VersionState -Root $Root -VersionDir $vdir -JsonPath $jsonPath
        if ($check.Problems.Count -gt 0) {
            throw ("切换后自检不通过:`n  " + ($check.Problems -join "`n  "))
        }
    } catch {
        Fail $_.Exception.Message
        Warn '正在回滚三处文件'
        try {
            Restore-Backup -BackupDir $backupDir -VersionDir $vdir
            Ok "已回滚到 $($cur.NeoForge)"
            Write-SwitchLog "切换失败并回滚: $($_.Exception.Message)"
        } catch {
            Fail "回滚也失败了, 请手动用备份还原: $backupDir"
            Write-SwitchLog "切换失败且回滚失败: $($_.Exception.Message) / $backupDir"
        }
        throw
    }

    Say ''
    Ok "现在这个版本是 NeoForge $TargetVersion"
    Info '顺手提醒: 不要对这个版本点 PCL 的"重装/更新", 那会按安装清单把 loader 重装一遍'
    Info "回滚命令: .\NeoForgeSwitch.ps1 -Rollback"
    Write-SwitchLog "切换完成 $($Version.Name): $($cur.NeoForge) -> $TargetVersion"

    # 必须重启 PCL(它会缓存版本信息), 这条提示放在最后, 保证一定看得到
    Show-RestartNotice -Action '切换'
}

function Invoke-StatusAction {
    param([string]$Root)
    $version = Select-VersionDir -Root $Root
    $t = Get-TargetSummary -Root $Root -Version $version

    Head '当前状态'
    # 先讲清"这是哪个实例下的哪个整合包", 再看它内部是否自洽
    # 列宽 34: 本机实例名 "[Client]MultiIntergationPack" 显示宽度 28, 要留出间隔
    Say ("  PCL 实例  " + (Format-Display $t.InstanceName 34) + $t.Instance)
    Say ("  整合包    " + (Format-Display $t.VersionName 34) + $t.VersionDir)
    Say ''

    $r = Test-VersionState -Root $Root -VersionDir $version.Dir -JsonPath $version.Json
    if ($r.Info.McVersion) {
        $prefix = ($r.Info.McVersion -replace '^1\.', '') + '.'
        Info "该 MC 版本对应的 NeoForge 系列前缀: $prefix"
    }
    return $r
}

function Invoke-ListAction {
    <#
        列出该 MC 版本可选的 NeoForge 版本, 标出当前用的那个
    #>
    param([string]$Root)
    $version = Select-VersionDir -Root $Root
    $js = Read-VersionJson $version.Json
    $li = Get-LoaderInfo $js
    if (-not $li.McVersion) { throw '版本 JSON 里没有 --fml.mcVersion, 无法确定目标版本系列' }

    $prefix = ($li.McVersion -replace '^1\.', '') + '.'
    $all = @(Get-MavenVersions -Prefix $prefix)
    $current = if ($li.NeoForge) { $li.NeoForge } else { Get-LoaderVersionsOfDir $version.Dir }

    Head "Minecraft $($li.McVersion) 可用的 NeoForge 版本"
    foreach ($v in $all) {
        if ($v -eq $current) { Write-Host "  $v  <- 当前" -ForegroundColor Cyan }
        else { Write-Host "  $v" -ForegroundColor Gray }
    }
    Say ''
    Info "共 $($all.Count) 个正式版, 最新 $($all[-1])"
    Info "切换示例: .\NeoForgeSwitch.ps1 -Target $($all[-1])"
    return $all
}

function Invoke-Action {
    <#
        动作分发(菜单和命令行共用的唯一入口)

        Action:
          Status    看状态
          List      列版本
          Latest    升到最新
          Switch    切到 -Target 指定的版本(可多个)
          Rollback  回滚
    #>
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('Status', 'List', 'Latest', 'Switch', 'Rollback')]
        [string]$Action,
        [string]$Root,
        [string[]]$Targets,
        [string]$BackupIdArg,
        [switch]$DryRun,
        [switch]$NoModCheck,
        [switch]$StrictModCheck,
        [switch]$Force
    )

    switch ($Action) {
        'Status' { Invoke-StatusAction -Root $Root | Out-Null }
        'List' { Invoke-ListAction -Root $Root | Out-Null }
        'Rollback' { Invoke-Rollback -Root $Root -Which $BackupIdArg }
        'Latest' {
            $version = Select-VersionDir -Root $Root
            $js = Read-VersionJson $version.Json
            $li = Get-LoaderInfo $js
            if (-not $li.McVersion) { throw '版本 JSON 里没有 --fml.mcVersion' }
            $prefix = ($li.McVersion -replace '^1\.', '') + '.'
            $all = @(Get-MavenVersions -Prefix $prefix)
            if ($all.Count -eq 0) { throw "没有找到 $prefix 系列版本" }
            Invoke-Switch -Root $Root -Version $version -TargetVersion $all[-1] `
                -DryRun:$DryRun -NoModCheck:$NoModCheck -StrictModCheck:$StrictModCheck -Force:$Force
        }
        'Switch' {
            $list = @($Targets | Where-Object { $_ })
            if ($list.Count -eq 0) { throw '没有指定 -Target' }
            foreach ($t in $list) {
                Test-LoaderVersionFormat $t
                $version = Select-VersionDir -Root $Root
                Invoke-Switch -Root $Root -Version $version -TargetVersion $t `
                    -DryRun:$DryRun -NoModCheck:$NoModCheck -StrictModCheck:$StrictModCheck -Force:$Force
            }
        }
    }
}

# ============================================================================
#  十四. 交互菜单
#     中文提示全部由 PowerShell 输出(bat 只负责把本脚本拉起来)
#     菜单与命令行共用 Invoke-Action, 不再起子进程
# ============================================================================

function Show-TargetBlock {
    <#
        画菜单顶部的"目标区块"

        刻意把两级分开写: PCL 实例那一行是 .minecraft 根, 整合包那一行是
        versions\<名字>。早先版本把两者都叫"整合包", 于是显示成
        "整合包: D:\...\.minecraft" —— 那个其实是 PCL 实例, 不是整合包。
    #>
    param([string]$Root)

    $line = '  ' + ('-' * 72)
    Write-Host $line -ForegroundColor DarkCyan

    if (-not ($Root -and (Test-IsMcDir $Root))) {
        Write-Host '  PCL 实例  (还没定位, 运行任意一项会自动搜索)' -ForegroundColor DarkGray
        Write-Host $line -ForegroundColor DarkCyan
        return
    }

    # 实例这一级: 路径单独一行, 数目另起一行 —— 路径动辄 60+ 字符, 硬凑对齐会被撑破
    $allVers = @(Get-NeoForgeVersionDirs $Root)
    Write-Host ('  PCL 实例  ' + $Root) -ForegroundColor Gray
    Write-Host ('            该实例下有 {0} 个版本可选' -f $allVers.Count) -ForegroundColor DarkGray

    # 版本这一级: 名字 / 相对路径 / loader 信息, 三行分明
    $t = Get-TargetSummary -Root $Root
    if ($t.Error) {
        Write-Host ('  整合包    (读不到: ' + $t.Error + ')') -ForegroundColor Yellow
        Write-Host $line -ForegroundColor DarkCyan
        return
    }

    $badge = ''
    if (-not $t.Consistent) { $badge = '  [三处不一致]' }
    Write-Host ('  整合包    ' + $t.VersionName + $badge) `
        -ForegroundColor $(if ($t.Consistent) { 'White' } else { 'Yellow' })
    Write-Host ('            路径  ' + (Get-VersionFolderShort -Root $Root -VersionDir $t.VersionDir)) -ForegroundColor DarkGray
    Write-Host ('            内容  MC {0}  ·  NeoForge {1}  ·  FML {2}  ·  {3} 个库' -f $t.Mc, $t.NeoForge, $t.Fml, $t.LibCount) -ForegroundColor DarkGray
    Write-Host $line -ForegroundColor DarkCyan
}

function Invoke-Menu {
    param([string]$Root)

    while ($true) {
        Clear-Host
        Write-Host ''
        Write-Host '  ========================================================================' -ForegroundColor DarkCyan
        Write-Host '    NeoForge 版本切换        PCL2 版本隔离 · 原位升降级' -ForegroundColor Cyan
        Write-Host '  ========================================================================' -ForegroundColor DarkCyan
        Write-Host ''

        Show-TargetBlock -Root $Root
        Write-Host ''

        # 菜单项按"显示宽度"排版, 中文占两列, 所以用 Format-Display 而不是空格硬凑
        $items = @(
            @{ K = '[1]'; T = '查看当前状态'; D = '三处元数据是否一致、库是否齐全' },
            @{ K = '[2]'; T = '列出可切换的版本'; D = '该 MC 版本的全部 NeoForge 正式版' },
            @{ K = '[3]'; T = '升级到最新正式版'; D = '' },
            @{ K = '[4]'; T = '切到指定版本'; D = '升降级都走这里' },
            @{ K = '[5]'; T = '回滚到上一次切换前'; D = '' },
            @{ K = '[6]'; T = '打开备份目录'; D = '' },
            @{ K = '[7]'; T = '只演练不写入'; D = '看看会改什么、要不要下载' }
        )
        foreach ($it in $items) {
            $row = '     ' + (Format-Display $it.K 6) + (Format-Display $it.T 26) + $it.D
            Write-Host $row.TrimEnd() -ForegroundColor White
        }
        Write-Host ''
        Write-Host '     ---- 换目标 ----' -ForegroundColor DarkCyan
        Write-Host ('     ' + (Format-Display '[8]' 6) + (Format-Display '换 PCL 实例' 26) + '换一个 .minecraft(游戏目录)') -ForegroundColor White
        Write-Host ('     ' + (Format-Display '[9]' 6) + (Format-Display '换整合包' 26) + '换当前实例下的某个版本') -ForegroundColor White
        Write-Host ('     ' + (Format-Display '[0]' 6) + '退出') -ForegroundColor White
        Write-Host ''

        $ch = Read-Host '  请选择'
        if (-not $ch) { return }

        try {
            switch ($ch.Trim()) {
                '1' { Invoke-Action -Action Status -Root $Root | Out-Null }
                '2' { Invoke-Action -Action List -Root $Root | Out-Null }
                '3' { Invoke-Action -Action Latest -Root $Root }
                '4' {
                    $v = Read-Host '  目标 NeoForge 版本(例如 21.1.266)'
                    if ($v) { Invoke-Action -Action Switch -Root $Root -Targets @($v.Trim()) }
                }
                '5' { Invoke-Action -Action Rollback -Root $Root }
                '6' {
                    if ($Root -and (Test-Path -LiteralPath $script:Ctx.BackupRoot)) {
                        Start-Process explorer.exe -ArgumentList $script:Ctx.BackupRoot
                        Start-Sleep -Milliseconds 600
                    } else { Warn '还没有备份目录' }
                }
                '7' {
                    $v = Read-Host '  演练的目标 NeoForge 版本(例如 21.1.266)'
                    if ($v) {
                        # 菜单里的"演练"就是一个带 -DryRun 的切换, 复用同一条代码路径
                        Invoke-Action -Action Switch -Root $Root -Targets @($v.Trim()) -DryRun
                    }
                }
                '8' {
                    # 换 PCL 实例(.minecraft): 选完重建上下文(备份/缓存目录跟着走),
                    # 并清空版本锁定, 让下面的 [9] / 自动推断重新开始
                    $chosen = Select-McDirInteractively -Current $Root -ExtraRoots $ScanRoot
                    if ($chosen) {
                        $Root = $chosen
                        $null = New-Context -Root $Root
                        $script:VersionName = $null
                    }
                    continue
                }
                '9' {
                    # 换整合包(版本): 只在当前 PCL 实例下选
                    $cur = $null
                    try { $cur = (Select-VersionDir -Root $Root).Name } catch { }
                    $chosen = Select-VersionInteractively -Root $Root -Current $cur
                    if ($chosen) {
                        $script:VersionName = $chosen.Name
                        $script:VersionDir = $chosen.Dir
                    }
                    continue
                }
                '0' { return }
                default { continue }
            }
        } catch {
            Fail $_.Exception.Message
        }

        Write-Host ''
        Read-Host '  按回车返回菜单' | Out-Null
    }
}

# ============================================================================
#  十五. 入口
#     所有分支都收敛到 Invoke-Action; 这里只做"参数 -> 动作"的翻译
# ============================================================================

$exitCode = 0
try {
    $root = Find-McDir
    $null = New-Context -Root $root

    # 代理只在真正要联网的动作前决定, -Status 之类不需要
    if (-not ($Status -or $Rollback)) {
        Initialize-Proxy -Mode $Proxy -HostName $ProxyHost -Port $ProxyPort
    }

    if ($Menu) {
        Invoke-Menu -Root $root
    } else {
        # 需要写文件/跑产物的动作才抢锁; 只读动作(Status/List)不抢
        $needLock = $false
        if ($Rollback) { $needLock = $true }
        elseif ($Latest -or ($Target -and $Target.Count -gt 0)) { $needLock = $true }

        if ($needLock) { Enter-ContextLock }

        try {
            # 参数 -> 动作 的翻译表
            $action = $null
            $actionTargets = @()
            $actionBackupId = $null

            if ($Rollback) {
                $action = 'Rollback'; $actionBackupId = $BackupId
            } elseif ($Status) {
                $action = 'Status'
            } elseif ($List) {
                $action = 'List'
            } elseif ($Latest) {
                $action = 'Latest'
            } elseif ($Target -and $Target.Count -gt 0) {
                $action = 'Switch'; $actionTargets = $Target
            } else {
                # 没有指定动作: 打印用法与当前版本
                # 注意 "当前版本" 这一段要容错 —— 刚用 -PickMcDir 换到一个
                # 没有任何 NeoForge 版本的整合包时, 这里不该把整个流程炸掉
                Say ''
                try {
                    $v0 = Select-VersionDir -Root $root
                    $li0 = Get-LoaderInfo (Read-VersionJson $v0.Json)
                    Say "当前整合包: $root"
                    Say "当前版本  : $($v0.Name)"
                    Say "Minecraft $($li0.McVersion), NeoForge $($li0.NeoForge)"
                } catch {
                    Say "当前整合包: $root"
                    Say '  (这个整合包里没有可操作的 NeoForge 版本)'
                }
                Say ''
                Say '用法:'
                Say '  -Status                 看当前状态'
                Say '  -List                   列出可切换的版本'
                Say '  -Latest                 升到最新正式版'
                Say '  -Target 21.1.266        切到指定版本(加 -DryRun 只演练)'
                Say '  -Rollback               回滚到上一次切换前'
                Say '  -PickMcDir              换一个整合包(列出本机所有 .minecraft)'
                Say '  -Menu                   交互菜单'
                Say ''
                Say '示例: .\NeoForgeSwitch.ps1 -Target 21.1.266'
            }

            if ($action) {
                Invoke-Action -Action $action -Root $root -Targets $actionTargets -BackupIdArg $actionBackupId `
                    -DryRun:$DryRun -NoModCheck:$NoModCheck -StrictModCheck:$StrictModCheck -Force:$Force
            }
        } finally {
            Exit-ContextLock
        }
    }
} catch {
    Fail $_.Exception.Message
    if ($_.ScriptStackTrace) { Write-Host $_.ScriptStackTrace -ForegroundColor DarkGray }
    $exitCode = 1
} finally {
    Exit-ContextLock
}

exit $exitCode
