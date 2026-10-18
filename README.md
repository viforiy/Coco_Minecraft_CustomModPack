# Coco 整合包 - 工具分支 (tools)

这个分支**只放脚本和工具**, 不放整合包内容。整合包本身在 `main` 分支。

| 分支 | 内容 | 谁在用 |
|---|---|---|
| `main` | `pack.toml`、`index.toml`、`mods/*.pw.toml` 等 packwiz 包内容 | packwiz、packwiz-installer、更新脚本拉取 |
| `tools` | 一键部署脚本、客户端/服务端更新脚本、PW-GUI 下载器、本说明 | 玩家与服主 |
| `master` | 历史遗留分支, 已不再维护 | 无 |

## 玩家怎么拿到脚本

任选一种:

```bash
# 只拉工具分支
git clone -b tools https://github.com/viforiy/Coco_Minecraft_CustomModPack.git CocoModPack-tools
```

或者用浏览器下载压缩包:

```
https://github.com/viforiy/Coco_Minecraft_CustomModPack/archive/refs/heads/tools.zip
```

不想装 git 也完全没问题, 上面那个 zip 链接直接点就能下。

## 装好之后

1. 解压后双击 `一键部署.bat`
2. 选 `1 客户端` 或 `2 服务端`
3. 填游戏目录 (PCL 版本文件夹 / 开服目录), 可以直接把文件夹拖进窗口
4. 元数据仓直接回车, 默认就是本仓库的 `main` 分支
5. 按它打印的提示, 把 `call` 那一行挂到 PCL 或开服脚本里

之后每次启动/开服都会自动对齐模组。详细说明在 `一键部署.bat` 的开场屏幕里。

## 三个脚本的关系

```
一键部署.bat                       只跑一次, 放脚本 + 写 mod更新源.cfg
   |
   +--> [客户端]mod更新脚本.bat      PCL 启动游戏前调用
   +--> [服务端]mod更新脚本.bat      开服脚本 java 之前调用
            |
            +--> 拉元数据 -> packwiz refresh -> packwiz-installer -> 对齐 mods
```

单独双击这两个更新脚本会先弹一次知情确认, 确认后本机记住, 不再打扰。

## PW-GUI 怎么处理

[PW-GUI](https://github.com/AmberIsFrozen/PW-GUI) 是第三方做的 packwiz 图形化编辑器,
用来打开一个包目录、增删模组、改版本号。它是**开发期工具**, 不是玩家需要的东西, 所以:

- **不进 git 仓库**。仓库 `.gitignore` 里有 `*.exe`, 已经自动忽略; 6 MB 以上的二进制
  进了版本库只会把仓库撑大, 以后每次升级都要多存一份历史副本。
- **需要时用 `获取PW-GUI.bat` 下载**:

```bat
获取PW-GUI.bat                    :: 下到脚本所在目录
获取PW-GUI.bat "D:\某个整合包"     :: 直接下到那个 packwiz 包目录里
```

脚本带三重兜底: 直连 -> 本机 7890 代理 -> GitHub 加速镜像, 下完会校验体积并打印 SHA256。

- **放哪最顺手**: 放在要编辑的那个包目录旁边, 也就是 `pack.toml` 所在的那一层。
  PW-GUI 打开时直接选这个目录就行。因为被 `.gitignore` 忽略, 放哪儿都不会误提交。

- **它只改元数据**, 不下载 jar。改完记得回命令行跑一次:

```bash
packwiz refresh
```

然后 `git status` 确认只动了该动的 `.pw.toml` / `index.toml`, 再提交推送。

## 备注

- `main` 分支里已经不再存放脚本, 保持"纯 packwiz 包"的结构:
  `packwiz`、`packwiz serve`、`packwiz-installer` 都要求 `pack.toml` 在仓库根目录。
- `.packwizignore` 里另外排除了 `*.bat` `*.md` `*.exe`, 就算谁把工具放进了 `main`,
  packwiz 也不会把它们算进包索引。
