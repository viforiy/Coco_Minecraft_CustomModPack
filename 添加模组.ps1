#Requires -Version 5.1
<#
.SYNOPSIS
    添加模组: 从 Modrinth 链接或 slug 录入, 写入 mods/<slug>.pw.toml

.DESCRIPTION
    1. 解析输入: 支持项目链接、slug、项目 ID
    2. 校验项目存在, 并检查是否已在包内
    3. 按 pack.toml 的加载器与游戏版本筛选可用版本, 无匹配时列出已有版本
    4. 调用 packwiz 写入元数据并刷新索引
    5. 输出结果与后续动作提示

    packwiz 采用 --project-id 与 --version-id 显式指定, 不使用其搜索模式,
    避免 -y 盲选到不相关项目。

.PARAMETER Target
    项目链接、slug 或项目 ID; 省略时交互输入

.PARAMETER PackDir
    packwiz 包目录, 解析顺序与其它工具一致

.PARAMETER DryRun
    只解析与检查, 打印将要执行的 packwiz 命令, 不写任何文件

.PARAMETER Proxy
    HTTP 代理, 例如 http://127.0.0.1:7890; 省略时先直连再试本机 7890
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string]$Target,

    [string]$PackDir,
    [string]$Proxy,
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::GetEncoding(936)
$ToolHome = $PSScriptRoot
. (Join-Path $ToolHome '工具配置.ps1')
. (Join-Path $ToolHome '工具函数.ps1')

Say ''
Say '=========================================================='
Say '  Coco 整合包 · 添加模组'
Say '=========================================================='
Say '  输入 Modrinth 链接、slug 或项目 ID, 按包设定写入元数据'
Say ''

# 1) 包目录与 pack.toml
try {
    $PackDir = Resolve-PackDir -ToolRoot $ToolHome -CliValue $PackDir -NonInteractive:([bool]$DryRun)
} catch {
    Fail $_.Exception.Message
    exit 1
}
$meta = Read-PackMeta -PackDir $PackDir
Info "包目录     $PackDir"
Info "包设定     MC $($meta.Minecraft) / $($meta.Loaders -join ',')"

if (-not $meta.Minecraft -or $meta.Loaders.Count -eq 0) {
    Fail 'pack.toml 缺少 [versions] 配置, 无法确定加载器与游戏版本'
    Say  '  请检查 pack.toml 的 [versions] 段, 至少包含 minecraft 与一个加载器'
    exit 1
}

# 2) 输入
$raw = $Target
if (-not $raw) {
    $raw = Read-Host '  请输入 Modrinth 链接 / slug / 项目 ID'
}
if (-not $raw) { Fail '未提供输入, 已中止'; exit 1 }

$key = ConvertTo-MrSlug -InputText $raw
Info "解析结果   $key"

# 3) 校验项目
$proj = Get-MrProject -IdOrSlug $key
if (-not $proj) {
    Fail "无法解析项目: $key"
    Say  '  可能原因: slug 拼写错误, 该模组不在 Modrinth, 或网络不可用'
    Say  '  CurseForge 项目将在后续版本支持'
    exit 1
}
Info "项目       $($proj.title)  (slug: $($proj.slug), id: $($proj.id))"
Info "官方标注   client=$($proj.client_side) server=$($proj.server_side)"

# 4) 是否已在包内
$modsDir = Join-Path $PackDir 'mods'
$existing = @()
foreach ($f in Get-ChildItem -LiteralPath $modsDir -Filter '*.pw.toml' -ErrorAction SilentlyContinue) {
    $m = Read-PwFile $f.FullName
    if ($m.MrId -eq $proj.id -or $m.Key -eq $proj.slug) { $existing += $m }
}
if ($existing.Count -gt 0) {
    $hit = $existing[0]
    Warn "已在包内: $($hit.Key)  ($($hit.Filename))"
    Say  '  若要更新版本, 请使用 packwiz update; 若要改 side, 运行 维护模组清单.bat'
    exit 2
}

# 5) 版本筛选
$versions = Get-MrProjectVersions -Id $proj.id -Loaders $meta.Loaders -GameVersions @($meta.Minecraft)
if (-not $versions -or $versions.Count -eq 0) {
    Fail "没有适配 MC $($meta.Minecraft) / $($meta.Loaders -join ',') 的版本"
    $all = Get-MrProjectVersions -Id $proj.id
    if ($all -and $all.Count -gt 0) {
        $gv = @($all | ForEach-Object { $_.game_versions } | Sort-Object -Unique)
        $ld = @($all | ForEach-Object { $_.loaders } | Sort-Object -Unique)
        Say  ("  该项目已有版本支持: MC {0}" -f (($gv | Select-Object -Last 6) -join ', '))
        Say  ("  加载器: {0}" -f ($ld -join ', '))
        Say  '  可选做法: 换用其它模组, 或调整 pack.toml 的版本设定(需评估整体兼容)'
    }
    exit 1
}

$pick = Select-PreferredVersion -Versions $versions
Info ("匹配版本   {0} 个, 选用 {1} ({2}, {3})" -f $versions.Count, $pick.version_number, $pick.version_type, $pick.date_published)

# 6) packwiz
$packwiz = Resolve-Packwiz
if (-not $packwiz) {
    Fail '找不到 packwiz.exe'
    Say  '  请先运行一次客户端更新脚本以下载缓存, 或把 packwiz 放进 PATH'
    exit 1
}
$cmdArgs = @('modrinth','add','--project-id',$proj.id,'--version-id',$pick.id,'-y')

Say ''
Info '将执行    packwiz modrinth add --project-id <id> --version-id <vid> -y'
if ($DryRun) {
    Say ''
    Warn 'DryRun 结束, 未写入任何文件'
    exit 0
}

# 7) 执行
Push-Location $PackDir
$prevProxyHttps = $env:HTTPS_PROXY
$prevProxyHttp  = $env:HTTP_PROXY
try {
    $out = & $packwiz @cmdArgs 2>&1
    $code = $LASTEXITCODE
    if ($code -ne 0) {
        # 网络类失败时挂代理重试一次
        $text = ($out | ForEach-Object { "$_" }) -join "`n"
        if ($text -match 'proxy|connect|timeout|dial|network') {
            Warn '直连失败, 尝试经本机代理重试'
            $env:HTTPS_PROXY = 'http://127.0.0.1:7890'
            $env:HTTP_PROXY  = 'http://127.0.0.1:7890'
            $out = & $packwiz @cmdArgs 2>&1
            $code = $LASTEXITCODE
        }
    }
} finally {
    $env:HTTPS_PROXY = $prevProxyHttps
    $env:HTTP_PROXY  = $prevProxyHttp
    Pop-Location
}

if ($code -ne 0) {
    Fail "packwiz 执行失败 (退出码 $code)"
    $out | ForEach-Object { Say "  $_" }
    exit 1
}

# 8) 结果
$target = Join-Path $modsDir "$($proj.slug).pw.toml"
if (-not (Test-Path $target)) {
    $found = Get-ChildItem -LiteralPath $modsDir -Filter '*.pw.toml' |
        Where-Object { (Read-PwFile $_.FullName).MrId -eq $proj.id } | Select-Object -First 1
    if ($found) { $target = $found.FullName }
}

if (Test-Path $target) {
    $newMod = Read-PwFile $target
    Ok "已写入 $($newMod.Key).pw.toml"
    Say  "  文件名 $($newMod.Filename)"
    Say  "  安装端 $($newMod.Side)"
    $sideText = switch ($newMod.Side) { 'client' { '客户端' } 'server' { '服务端' } default { '双端' } }
    if ($sideText -ne '') { Say  "  提示   packwiz 生成的 side 未必准确, 同步清单时会按官方标注校正" }
} else {
    Warn '未找到新生成的 .pw.toml, 请检查 mods 目录'
    exit 1
}

Say ''
Head '下一步'
Say  '  1. 运行 维护模组清单.bat 补录到清单文档(会询问中文名、分类与功能)'
Say  '  2. 运行 推送元数据.bat 提交推送'
Say ''
Ok '添加流程结束'
