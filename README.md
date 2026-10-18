# Coco 整合包 · 部署与更新脚本

本分支存放整合包的部署与更新脚本，配合 `main` 分支的 packwiz 清单使用。

## 背景

整合包的模组清单以 packwiz 格式维护在 `main` 分支，包含 `pack.toml`、`index.toml` 与
`mods/*.pw.toml`。模组 jar 不纳入版本库，由 packwiz-installer 依据清单在本地获取。

客户端与服务端需要在启动前将本地 `mods` 与清单对齐，为此提供一组可挂载到启动流程的脚本。
脚本与包内容相互独立，集中存放于本分支。

## 内容

| 文件 | 作用 |
| --- | --- |
| `一键部署.bat` | 部署入口。释放对应脚本至游戏目录，生成 `mod更新源.cfg` 与启动前命令 |
| `[客户端]mod更新脚本.bat` | 同步客户端侧模组，由 PCL 启动前调用 |
| `[服务端]mod更新脚本.bat` | 同步服务端侧模组，由开服脚本调用 |

## 使用场景

- 初次安装整合包：部署脚本并挂载到 PCL 或开服脚本，此后每次启动自动对齐模组
- 服务端开服：开服前校验并补齐服务端侧模组，避免与客户端版本不一致
- 切换元数据仓：在部署时指定其他 packwiz 仓地址，无需修改脚本本体

## 环境要求

- Windows 10 1809 或更高版本，依赖系统自带的 `curl.exe` 与 `tar.exe`
- 无需预装 git、packwiz 与 Java，脚本自行准备并在缓存目录复用
- 默认以普通权限运行，仅在启用本地包服务时尝试添加防火墙规则

## 使用

### 获取

```bash
git clone -b tools https://github.com/viforiy/Coco_Minecraft_CustomModPack.git CocoModPack-tools
```

压缩包下载：<https://github.com/viforiy/Coco_Minecraft_CustomModPack/archive/refs/heads/tools.zip>

### 部署

双击 `一键部署.bat`，依次选择平台、填写游戏目录与元数据仓；元数据仓留空即使用本仓库 `main` 分支。

无人值守方式：

```bat
一键部署.bat 1 "D:\Minecraft\versions\Coco" ["仓库地址" "分支" /y /run]
一键部署.bat 2 "D:\mc_server"               ["仓库地址" "分支" /y /run]
```

`/y` 直接覆盖同名文件（覆盖前备份），`/run` 部署完成后立即执行一次更新。

### 挂载

| 平台 | 位置 | 命令 |
| --- | --- | --- |
| 客户端 | PCL → 版本设置 → 设置 → 高级选项 → 启动前执行指令 | `call "{verpath}\[客户端]mod更新脚本.bat" "$INST_JAVA"` |
| 服务端 | 开服脚本 `java` 行之前 | `call "[服务端]mod更新脚本.bat"`<br>`if errorlevel 1 exit /b 1` |

### 配置

部署生成的 `mod更新源.cfg` 位于游戏目录，用于覆盖脚本内置参数：

| 键 | 说明 |
| --- | --- |
| `PACK_GIT_URL` | 模组元数据仓地址 |
| `PACK_GIT_BRANCH` | 分支名，默认 `main` |
| `META_SOURCE` | 元数据同步方式：`auto` / `git` / `zip` |
| `PACK_SOURCE` | 包来源：`file`（默认）/ `serve` / `remote` |
| `PROXY_PORT` | 系统代理端口，默认 `7890` |

## 说明

- 更新脚本首次单独运行时请求一次确认并写入标记，此后不再提示；未经部署而直接运行前，请确认目标目录正确。
- `mods` 目录由脚本依据清单维护，手动放入的 jar 会在下次同步时被覆盖或清理。
- 维护整合包所需的工具（清单同步、PW-GUI 下载等）位于 `dev` 分支，玩家无需获取。
