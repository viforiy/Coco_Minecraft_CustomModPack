# Coco 整合包 · 模组清单

本分支存放整合包的 packwiz 元数据，是模组清单的唯一来源。

## 目录结构

| 路径 | 说明 |
| --- | --- |
| `pack.toml` | 整合包信息：名称、版本、Minecraft 与加载器版本 |
| `index.toml` | 文件索引与哈希，由 `packwiz refresh` 生成 |
| `mods/*.pw.toml` | 模组元数据，每个文件描述一个模组及其下载来源 |
| `modlist.md`、`模组列表介绍.md` | 清单的文字说明 |

模组 jar 不存放在本分支。客户端与服务端依据清单，由 packwiz-installer 从 Modrinth
与 CurseForge 获取对应文件。

## 分支职责

| 分支 | 内容 |
| --- | --- |
| `main` | packwiz 模组清单，即本分支 |
| `tools` | 部署与更新脚本，仓库默认分支 |

使用者不需要手动处理本分支内容，请先到 `tools` 分支获取脚本：
<https://github.com/viforiy/Coco_Minecraft_CustomModPack/tree/tools>

## 使用方

- 客户端与服务端的更新脚本：以本分支为元数据源，启动前对齐本地 `mods`
- packwiz 命令行：`refresh`、`serve`、`add`、`update` 等操作均在本分支目录下执行
- packwiz-installer：按 `pack.toml` 与 `index.toml` 声明的清单拉取文件

## 修改流程

1. 使用 packwiz CLI 或 PW-GUI 增删模组、调整版本
2. 执行 `packwiz refresh` 刷新 `index.toml` 与 `pack.toml` 中的索引哈希
3. 核对 `git status`，确认改动仅涉及本次调整的元数据
4. 提交并推送，客户端与服务端在下次启动时自动同步

索引哈希与文件内容必须保持一致，否则 packwiz-installer 会以
`index file hash is invalid` 中断安装。

## 环境要求

- 维护清单：需要 packwiz，或 PW-GUI（需 Java 17 及以上）
- 获取模组文件：需要可访问 Modrinth 与 CurseForge
- 仓库根目录须保持 `pack.toml` 位于第一层，packwiz 与 packwiz-installer 均依赖该结构
