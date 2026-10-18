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
| `获取PW-GUI.bat` | 下载 packwiz 图形化编辑器，用于编辑元数据 |
| `开发流程.md` | 日常操作步骤与提交信息约定 |

## 环境要求

- Windows 10 1809 或更高版本，使用系统内置 PowerShell 5.1
- `维护模组清单` 需访问 `api.modrinth.com`，直连失败时自动尝试本机 `7890` 代理
- `packwiz.exe` 需位于 `%LOCALAPPDATA%\CocoPackwiz\meta` 或 PATH，用于刷新索引
- `PW-GUI` 运行需 Java 17 及以上

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

处理顺序：

1. 清理：清单中存在但 `mods/` 已删除的条目，确认后移除并重算计数
2. 同步：已有条目的 jar 文件名与安装端按元数据刷新
3. 补录：列出未收录的模组，按 Modrinth 的 `client_side` / `server_side` 校正 `side`，
   自动填入 required 依赖，交互录入中文名、分类与功能后插入表格
4. 若改动了 `.pw.toml`，自动执行 `packwiz refresh`

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
