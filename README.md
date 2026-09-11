# dev-kit

简体中文 · [English](README.en.md)

一条命令装好一台开发机。想装什么自己勾，`dev-kit` 把它们装进你的家目录、配好 shell，
下次再跑一遍就升级到最新版并清掉被替换的旧版本。

支持 **macOS**、**Linux**、**Windows**。语言工具链全程不需要 `sudo` / 管理员权限。

## 快速开始

**macOS / Linux**

```sh
# 交互式菜单（方向键勾选）
curl -fsSL https://raw.githubusercontent.com/zzhtl/dev-kit/main/install.sh | bash

# 全部用命令行参数
curl -fsSL https://raw.githubusercontent.com/zzhtl/dev-kit/main/install.sh | bash -s -- --all --yes
curl -fsSL https://raw.githubusercontent.com/zzhtl/dev-kit/main/install.sh | bash -s -- --with go,rust,node --yes
```

**Windows（PowerShell）**

```powershell
# 交互式菜单
irm https://raw.githubusercontent.com/zzhtl/dev-kit/main/install.ps1 | iex

# 带参数时要用 scriptblock 形式
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/zzhtl/dev-kit/main/install.ps1))) -All -Yes
```

装完之后**开一个新终端**（或者 `. ~/.config/dev-kit/env.sh` / `. $PROFILE`），新工具才会进 `PATH`。

## 交互式菜单

不带任何参数直接跑，就是一路勾选，不用背参数：

```
  dev-kit 0.1.0  勾选要安装 / 更新的组件

  ▸ [x] git       Git
    [x] jdk       JDK（Temurin，经 SDKMAN）
    [ ] maven     Apache Maven
    [ ] gradle    Gradle
    [x] go        Go

  ↑/↓ 移动   空格 勾选   回车 确认
  a 全选   n 全不选   i 反选   q 退出
```

流程是：**选操作（安装 / 卸载）→ 勾组件 → 逐项确认选项 → 执行**。

| 按键 | 作用 |
|------|------|
| `↑` `↓` / `k` `j` | 上下移动 |
| `空格` | 勾选 / 取消当前项 |
| `1`–`9` | 直接勾选第 N 项 |
| `a` / `n` / `i` | 全选 / 全不选 / 反选 |
| `回车` | 确认，进入下一步 |
| `q` / `Esc` | 退回上一步；在第一屏则退出 |

勾完组件后是选项页，每一行都能回车进去改，改完选「▶ 开始安装」：

```
  dev-kit 0.1.0  安装选项

  即将安装 / 更新：jdk go node

      JDK 主版本: 25
      Go 版本: 最新版
      Node 版本: 最新 LTS
      镜像源: auto
      写入 shell 启动文件: 是
  ▸   ▶ 开始安装
      ← 返回上一步
```

- 界面语言跟随 `$LANG` / Windows 的 UI 区域设置自动切换中英文，也可以用 `--lang zh|en`
  （PowerShell 是 `-Lang`）或环境变量 `DEVKIT_LANG` 指定。
- 终端不支持（没有 TTY、`TERM=dumb`、宽度小于 44 列）时自动退回到编号菜单。
  也可以用 `--no-tui` / `-NoTui` 或 `DEVKIT_NO_TUI=1` 强制。
- CI 之类没有终端的场景，用 `--all` 或 `--with a,b,c`，不会有任何交互。

## 组件

| 组件 | 安装方式 | 版本管理 |
|-----------|---------------------|-----------------|
| `git`     | 系统包管理器（mac：Xcode CLT；Windows：winget 或绿色版 MinGit） | — |
| `jdk`     | Temurin（Eclipse Adoptium），主版本 **≥ 21** | mac/linux：SDKMAN；Windows：`Use-Jdk <major>` |
| `maven`   | Apache Maven 3.x | SDKMAN（mac/linux） |
| `gradle`  | Gradle 最新版 | SDKMAN（mac/linux） |
| `go`      | go.dev 官方压缩包 | 单版本（`--go-version` 可锁定） |
| `rust`    | rustup，默认 `stable` | rustup channel / toolchain |
| `node`    | 通过 **fnm**，默认最新 LTS | fnm |
| `pnpm`    | 独立二进制（`@pnpm/exe`） | 单版本 |
| `bun`     | 官方 release 压缩包 | 单版本 |

## 命令行参数

两个脚本参数一致（Bash 用 `--flag value`，PowerShell 用 `-Flag value`）：

```
--all                     安装全部组件
--with a,b,c              安装指定组件
--yes                     不询问；没有指定组件时，更新已经装了的
--jdk-version 21[,25]     JDK 主版本，默认最新 LTS（>= 21）
--go-version 1.27.1       锁定 Go 版本
--rust-version 1.90.0     锁定 Rust（也可以写 stable / beta / nightly）
--node-version lts|24     Node 版本线
--mirror auto|cn|off      镜像源，默认 auto
--no-shell-init           不改 shell rc / PowerShell profile
--lang zh|en              菜单语言，默认跟随系统
--no-tui                  用编号菜单代替方向键菜单
--help
```

- 只选了 `maven` 或 `gradle`、又没有任何 JDK 时，会自动带上 `jdk`。
- 有终端且没指定组件时，进交互式菜单。
- CI / 管道里没有 TTY 时，必须传 `--all` 或 `--with ...`。

## 更新与清理

重新跑同一条命令就是更新。各工具的策略：

- **JDK / Node**（多版本）：每个已装的**主版本**升到最新补丁版并设为默认，删掉被它取代的那个补丁版。
  **其他主版本保留** —— 带上新的 `--jdk-version` 是*新增*一个主版本，不会删掉原来的。
- **Rust**：`rustup update` 刷新所有 channel。`--rust-version X.Y.Z` 锁定的版本会被记下来，
  改锁定版本时删掉旧的那个，但不动 `stable`/`beta`/`nightly`。
- **Go / bun / pnpm / Maven / Gradle**（单版本）：原地替换成最新版。
- **git**：走系统包管理器升级（或 `winget upgrade` / 重新下载 MinGit）。

## 国内镜像

`--mirror auto`（默认）会探测 `github.com` 和 `go.dev`，慢或者不通就切到国内镜像。
也可以直接 `--mirror cn` 或 `--mirror off`。

| 工具 | `cn` 模式下用的镜像 |
|------|--------------------------|
| JDK（Temurin） | 清华 TUNA 的 Adoptium 镜像（失败回落 Adoptium + GitHub） |
| Go | `golang.google.cn` + `GOPROXY=https://goproxy.cn,direct` |
| Rust | `rsproxy.cn`（dist server + `cargo/config.toml` 里的 sparse 索引） |
| Node（fnm） | `FNM_NODE_DIST_MIRROR=https://npmmirror.com/mirrors/node` |
| pnpm / npm | `registry.npmmirror.com`（只在你自己没配 `registry=` 时写进 `~/.npmrc`） |
| bun | `registry.npmmirror.com/-/binary/bun` |
| Maven / Gradle | TUNA / 腾讯云镜像 |

切回 `--mirror off` 时，dev-kit 只删自己加的那部分镜像配置（`cargo`/`.npmrc` 里的标记块、
它设置的 `GOPROXY`），你自己写的配置一律不动。

## 装在哪里

不往系统目录装任何东西。`sudo` **只**用来装系统包（git、curl、unzip、Rust 需要的编译器）。

**macOS / Linux**

```
~/.config/dev-kit/env.sh      生成的环境变量，被 ~/.bashrc、~/.zshrc 等 source
~/.local/share/dev-kit/       go/、jdk/、maven/、gradle/、bin/fnm
~/.sdkman/                    SDKMAN（JDK / Maven / Gradle）
~/.cargo、~/.rustup           Rust
~/.bun、~/.local/share/pnpm   bun、pnpm
```

**Windows**

```
%LOCALAPPDATA%\dev-kit\       env.ps1、jdk\、go\、maven\、gradle\、bin\fnm.exe、git\
%USERPROFILE%\.cargo          Rust
%USERPROFILE%\.bun            bun
%LOCALAPPDATA%\pnpm           pnpm
```

只改用户级 `PATH` 和环境变量，机器级 `PATH` 一个字都不碰。

## 切换 JDK 版本

**macOS / Linux**（SDKMAN）：

```sh
sdk list java          # 看已装 / 可装的版本
sdk use java 21.0.12+1.1-tem     # 只对当前 shell 生效
sdk default java 25.0.4-tem      # 对新开的 shell 生效
```

**Windows**：

```powershell
Get-DevKitJdk                 # 列出已装的主版本
Use-Jdk 21                    # 当前会话
Use-Jdk 25 -Persist           # 顺便设成新会话的默认值
```

## 说明

- Bash 脚本按机器自带的 bash 写（包括 macOS 的 `bash 3.2`）。
- Windows 脚本支持 Windows PowerShell **5.1** 和 PowerShell 7。profile 加载不了时，
  它会提示 `Set-ExecutionPolicy -Scope CurrentUser RemoteSigned`。
- Windows 上的 Rust 链接需要 MSVC C++ 生成工具，脚本会检测；有 `winget` 时会问你要不要装。
- Alpine / musl 尽力支持（Node 用的是非官方构建）。

## 卸载

和安装一样的交互：在主菜单选「卸载组件」，或者直接 `--uninstall` 进卸载勾选页，
也可以全用参数：

```sh
# macOS / Linux
curl -fsSL .../install.sh | bash                              # 主菜单里选卸载
curl -fsSL .../install.sh | bash -s -- --uninstall            # 直接进卸载勾选页
curl -fsSL .../install.sh | bash -s -- --uninstall --with bun,go --yes
curl -fsSL .../install.sh | bash -s -- --uninstall --all --yes
```

```powershell
# Windows
& ([scriptblock]::Create((irm .../install.ps1))) -Uninstall -All -Yes
```

卸载是彻底的：删掉工具链、它的**缓存**（模块/构建缓存、包存储、下载缓存），以及 dev-kit 自己的配置
（`env.sh` / `env.ps1`、rc / profile 里的标记块、它加的 cargo 和 npm 镜像块、它设的 `GOPROXY`，
Windows 上还有用户级 `PATH`/环境变量）。删到最后一个组件时，整个 `dev-kit` 目录也一起删掉。

- `--keep-cache` 保留下载/构建缓存（只删工具链和配置）。
- `--yes` 跳过确认（非交互式卸载必须和 `--all`/`--with` 一起用）。
- **你自己写的文件永远不删** —— `~/.gitconfig`、`~/.m2/settings.xml`、`~/.gradle/gradle.properties`、
  你自己加的 `~/.npmrc` 行都会保留，并在最后列出来，要删你自己删。
- `git` 属于系统包（或 Xcode CLT），dev-kit 不删它，只打印删除命令给你。

## License

Apache-2.0.
