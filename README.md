# Coco 整合包 · 维护者工具

本分支存放维护整合包用的工具脚本，仅面向维护者。玩家侧工具在 `tools` 分支。

## 背景

整合包的模组清单以 packwiz 格式维护在 `main` 分支。维护者增删模组后，需要同步两处：

- `mods/*.pw.toml` 的 `side` 字段，packwiz 生成时未必正确
- `模组列表介绍.md` 的表格，必须与 `mods/` 目录保持一一对应

本分支集中处理这类同步与编辑工作。

## 内容

| 文件 | 作用 |
| --- | --- |
| `维护模组清单.bat` / `.ps1` | 同步 `mods/` 与清单文档：清理失效条目、刷新 jar 与安装端、补录新条目 |
| `推送元数据.bat` / `.ps1` | 提交并推送 `main` 分支的元数据，直连失败时自动尝试代理 |
| `获取PW-GUI.bat` | 下载 packwiz 图形化编辑器，用于编辑元数据 |
| `开发流程.md` | 日常操作步骤与提交信息约定 |

## 环境要求

- Windows 10 1809 或更高版本，使用系统内置 PowerShell 5.1
- `维护模组清单` 需访问 `api.modrinth.com`，直连失败时自动尝试本机 `7890` 代理
- `packwiz.exe` 需位于 `%LOCALAPPDATA%\CocoPackwiz\meta` 或 PATH，用于刷新索引
- `PW-GUI` 运行需 Java 17 及以上

## 在其他仓库上使用

本分支工具不绑定特定仓库，可配合任意符合 packwiz 规范的元数据仓使用，分支名与远端名不必是 `main` 与 `origin`。

目标目录需同时含 `pack.toml` 与 `mods/`；推送环节另需是 git 仓库且配置了远端。

### 包目录的确定顺序

1. 命令行 `-PackDir "路径"`
2. 环境变量 `COCO_PACK_DIR`
3. 本目录的 `工具配置.cfg`（首次运行后自动生成）
4. 自动探测：工具所在目录、其上级目录、同级目录中带 `pack.toml` 的目录
5. 以上都没有时提示输入

命中多个候选时列出选择；自动解析的结果写入 `工具配置.cfg`，下次无需再指定。用 `-PackDir` 显式指定的只对本次生效，不覆盖已记住的默认值。

### 分支与远端的确定

- 分支取仓库当前分支
- 远端优先取该分支的上游，其次 `工具配置.cfg` 的 `REMOTE`，再其次 `origin`，最后第一个远端
- 远端默认分支由 `refs/remotes/<远端>/HEAD` 判定；当前分支与它不一致时会提示"玩家从默认分支获取不到本次改动"

### 示例：换到自己的仓库

```bat
:: 首次运行，指定包目录，之后会被记住
推送元数据.bat -PackDir "D:\my-pack"

:: 或者用环境变量
set "COCO_PACK_DIR=D:\my-pack"
维护模组清单.bat
```

## 使用
### 获取

```bash
git clone -b dev https://github.com/viforiy/Coco_Minecraft_CustomModPack.git CocoModPack-dev
```

压缩包下载：<https://github.com/viforiy/Coco_Minecraft_CustomModPack/archive/refs/heads/dev.zip>

### 维护模组清单

```bat
维护模组清单.bat                      :: 交互式，处理清理、同步与补录
维护模组清单.bat -DryRun              :: 只显示差异，不写文件
维护模组清单.bat -NoSide              :: 跳过 side 校正
维护模组清单.bat -NoPrune             :: 不删除失效条目
维护模组清单.bat -All                 :: 不逐个确认
维护模组清单.bat -PackDir "D:\包目录"  :: 指定其他 packwiz 包
```

目标仓库没有清单文档时，会按 `mods/` 现有条目生成空白骨架：每条含名称、slug、jar 文件名与安装端，前置与功能留空，分类统一为「未分类」，之后可自行拆分重排。生成后再次运行不会重复写入。

处理顺序：

1. 清理：清单中存在但 `mods/` 已删除的条目，确认后移除并重算计数
2. 同步：已有条目的 jar 文件名与安装端按元数据刷新
3. 补录：列出未收录的模组，按 Modrinth 的 `client_side` / `server_side` 校正 `side`，
   自动填入 required 依赖，交互录入中文名、分类与功能后插入表格
4. 若改动了 `.pw.toml`，自动执行 `packwiz refresh`

### 推送元数据

`维护模组清单.bat` 结束时会询问是否立即推送；也可以单独运行：

```bat
推送元数据.bat                       :: 交互式，确认提交信息后推送
推送元数据.bat -NoPrompt             :: 不询问，直接提交并推送
推送元数据.bat -DryRun               :: 只预览将要提交的内容
推送元数据.bat -Message "标题"       :: 指定提交标题
```

行为：

1. 检查目录与分支，`main` 之外的会先确认
2. 汇总新增 / 删除 / 更新的模组与其它改动文件
3. 按变更内容生成提交信息，`git add -A` 后提交
4. 依次尝试「当前 git 配置」「经 7890 代理」「直连无代理」推送
5. 推送失败时保留本地提交，并给出手动推送命令

### 获取 PW-GUI

```bat
获取PW-GUI.bat                     :: 下载到本目录
获取PW-GUI.bat "D:\某个整合包"      :: 下载到指定 packwiz 包目录
```

二进制文件不纳入版本库，由 `.gitignore` 的 `*.exe` 规则忽略。

## 相关分支

| 分支 | 用途 |
| --- | --- |
| `main` | packwiz 清单，packwiz 与 packwiz-installer 的数据源 |
| `tools` | 玩家侧部署与更新脚本 |
| `dev` | 本分支，维护者工具 |
