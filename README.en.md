# dev-kit

[简体中文](README.md) · English

One command to set up a development machine. Pick what you want; `dev-kit` installs it under
your home directory, wires up your shell, and on the next run updates everything and removes the
versions it replaced.

Supports **macOS**, **Linux**, and **Windows**. Language toolchains never need `sudo`/admin.

## Quick start

**macOS / Linux**

```sh
# interactive menu (arrow keys, space to tick)
curl -fsSL https://raw.githubusercontent.com/zzhtl/dev-kit/main/install.sh | bash

# non-interactive
curl -fsSL https://raw.githubusercontent.com/zzhtl/dev-kit/main/install.sh | bash -s -- --all --yes
curl -fsSL https://raw.githubusercontent.com/zzhtl/dev-kit/main/install.sh | bash -s -- --with go,rust,node --yes
```

**Windows (PowerShell)**

```powershell
# interactive menu
irm https://raw.githubusercontent.com/zzhtl/dev-kit/main/install.ps1 | iex

# non-interactive (parameters need the scriptblock form)
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/zzhtl/dev-kit/main/install.ps1))) -All -Yes
```

When done, **open a new shell** (or `. ~/.config/dev-kit/env.sh` / `. $PROFILE`) so the new tools are on `PATH`.

## Interactive menu

Run it with no arguments and everything is a checkbox — no flags to memorise:

```
  dev-kit 0.1.0  select components to install / update

  ▸ [x] git       Git
    [x] jdk       JDK (Temurin, via SDKMAN)
    [ ] maven     Apache Maven
    [ ] gradle    Gradle
    [x] go        Go

  up/down move   space toggle   enter confirm
  a all   n none   i invert   q quit
```

The flow is **pick the action (install / uninstall) → tick components → review the options → run**.

| Key | What it does |
|-----|--------------|
| `↑` `↓` / `k` `j` | move |
| `space` | toggle the current row |
| `1`–`9` | toggle the Nth row directly |
| `a` / `n` / `i` | all / none / invert |
| `enter` | confirm, go to the next step |
| `q` / `Esc` | back one step; quits on the first screen |

After the components comes the options screen. Every row opens with enter; pick
"▶ start install" when it looks right:

```
  dev-kit 0.1.0  install options

  about to install / update: jdk go node

      JDK majors: 25
      Go version: latest
      Node version: latest LTS
      mirrors: auto
      write shell rc files: yes
  ▸   ▶ start install
      ← back
```

- The menu language follows `$LANG` (Windows: the UI culture) and switches between English and
  Chinese. Override it with `--lang zh|en` (`-Lang` on PowerShell) or `DEVKIT_LANG`.
- If the terminal cannot do it (no TTY, `TERM=dumb`, narrower than 44 columns) it falls back to a
  plain numbered menu. Force that with `--no-tui` / `-NoTui` or `DEVKIT_NO_TUI=1`.
- In CI and other headless runs, pass `--all` or `--with a,b,c` — nothing will prompt.

## Components

| Component | How it is installed | Version manager |
|-----------|---------------------|-----------------|
| `git`     | system package manager (mac: Xcode CLT; Windows: winget or portable MinGit) | — |
| `jdk`     | Temurin (Eclipse Adoptium), majors **≥ 21** | mac/linux: SDKMAN; Windows: `Use-Jdk <major>` |
| `maven`   | Apache Maven 3.x | SDKMAN (mac/linux) |
| `gradle`  | Gradle latest | SDKMAN (mac/linux) |
| `go`      | official archive from go.dev | single version (`--go-version` to pin) |
| `rust`    | rustup, `stable` by default | rustup channels/toolchains |
| `node`    | via **fnm**, latest LTS by default | fnm |
| `pnpm`    | standalone binary (`@pnpm/exe`) | single version |
| `bun`     | official release archive | single version |

## Options

Same flags on both scripts (`--flag value` on Bash, `-Flag value` on PowerShell):

```
--all                     install every component
--with a,b,c              install these components
--yes                     no prompts; with no selection, update what is already installed
--jdk-version 21[,25]     JDK major(s); default: newest LTS (>= 21)
--go-version 1.27.1       pin Go
--rust-version 1.90.0     pin Rust (or stable / beta / nightly)
--node-version lts|24     Node line to install
--mirror auto|cn|off      package mirrors (default: auto)
--no-shell-init           do not modify shell rc / PowerShell profile
--lang zh|en              menu language (default: from the system locale)
--no-tui                  plain numbered menu instead of the arrow-key one
--help
```

- Selecting `maven` or `gradle` without `jdk` (and with no JDK already present) adds `jdk` automatically.
- With no selection and a terminal attached, you get the interactive menu.
- In CI / piped with no TTY, pass `--all` or `--with ...`.

## Updating and cleanup

Re-run the same command to update. The policy per tool:

- **JDK / Node** (multi-version): each installed *major* is bumped to its latest patch, that patch
  becomes the default, and the superseded patch of that major is removed. **Other majors are kept** —
  running with a new `--jdk-version` *adds* a major, it never drops one.
- **Rust**: `rustup update` refreshes every channel. A pinned `--rust-version X.Y.Z` is tracked;
  moving the pin removes the old pinned toolchain but never touches `stable`/`beta`/`nightly`.
- **Go / bun / pnpm / Maven / Gradle** (single version): replaced in place with the latest release.
- **git**: upgraded via the system package manager (or `winget upgrade` / MinGit re-download).

## China mirrors

`--mirror auto` (default) probes `github.com` and `go.dev`; if they are slow or unreachable it
switches to domestic mirrors. Force it with `--mirror cn` or `--mirror off`.

| Tool | Mirror used in `cn` mode |
|------|--------------------------|
| JDK (Temurin) | Tsinghua TUNA Adoptium mirror (falls back to Adoptium + GitHub) |
| Go | `golang.google.cn` + `GOPROXY=https://goproxy.cn,direct` |
| Rust | `rsproxy.cn` (dist server + sparse crates index in `cargo/config.toml`) |
| Node (fnm) | `FNM_NODE_DIST_MIRROR=https://npmmirror.com/mirrors/node` |
| pnpm / npm | `registry.npmmirror.com` (written to `~/.npmrc` only if you have no `registry=`) |
| bun | `registry.npmmirror.com/-/binary/bun` |
| Maven / Gradle | TUNA / Tencent Cloud mirrors |

Switching back to `--mirror off` removes the mirror settings dev-kit added (its `cargo`/`.npmrc`
blocks and `GOPROXY`), leaving anything you configured yourself untouched.

## Where things go

Nothing is installed system-wide. `sudo` is used **only** for system packages
(git, curl, unzip, a compiler for Rust).

**macOS / Linux**

```
~/.config/dev-kit/env.sh      generated env; sourced from ~/.bashrc, ~/.zshrc, ...
~/.local/share/dev-kit/       go/, jdk/, maven/, gradle/, bin/fnm
~/.sdkman/                    SDKMAN (JDK / Maven / Gradle)
~/.cargo, ~/.rustup           Rust
~/.bun, ~/.local/share/pnpm   bun, pnpm
```

**Windows**

```
%LOCALAPPDATA%\dev-kit\       env.ps1, jdk\, go\, maven\, gradle\, bin\fnm.exe, git\
%USERPROFILE%\.cargo          Rust
%USERPROFILE%\.bun            bun
%LOCALAPPDATA%\pnpm           pnpm
```

User-scope `PATH` and environment variables only — the machine `PATH` is never modified.

## Switching JDK versions

**macOS / Linux** (SDKMAN):

```sh
sdk list java          # what is installed / available
sdk use java 21.0.12+1.1-tem     # this shell
sdk default java 25.0.4-tem      # new shells
```

**Windows**:

```powershell
Get-DevKitJdk                 # list installed majors
Use-Jdk 21                    # this session
Use-Jdk 25 -Persist           # set the default for new sessions too
```

## Notes

- Bash script targets the bash that ships on a stock machine (including macOS `bash 3.2`).
- Installing `jdk` / `maven` / `gradle` on macOS needs bash >= 4 (SDKMAN 5.23 requires it, macOS
  ships 3.2). With Homebrew present dev-kit runs `brew install bash` and uses that bash for
  SDKMAN only — your login shell is left alone.
- Windows script runs on Windows PowerShell **5.1** and PowerShell 7. If a profile does not load,
  it prints the `Set-ExecutionPolicy -Scope CurrentUser RemoteSigned` hint.
- Rust on Windows needs the MSVC C++ Build Tools for linking; the installer detects them and, with
  `winget`, offers to install them.
- Alpine / musl is supported on a best-effort basis (Node comes from the unofficial musl builds).

## Uninstall

Same UX as install — choose "uninstall components" in the main menu, or jump straight to the
uninstall checklist with `--uninstall`; flags work too:

```sh
# macOS / Linux
curl -fsSL .../install.sh | bash                              # choose uninstall in the menu
curl -fsSL .../install.sh | bash -s -- --uninstall            # straight to the uninstall checklist
curl -fsSL .../install.sh | bash -s -- --uninstall --with bun,go --yes
curl -fsSL .../install.sh | bash -s -- --uninstall --all --yes
```

```powershell
# Windows
& ([scriptblock]::Create((irm .../install.ps1))) -Uninstall -All -Yes
```

Uninstall is thorough: it removes the toolchain, its **caches** (module/build caches, package
stores, download caches), and dev-kit's own config (`env.sh` / `env.ps1`, the rc / profile marker
block, the cargo and npm mirror blocks it added, `GOPROXY` if dev-kit set it, and the User-scope
`PATH`/env entries on Windows). When the last component is removed, the whole `dev-kit` directory goes too.

- `--keep-cache` keeps download/build caches (removes only the toolchains + config).
- `--yes` skips the confirmation prompt (required for non-interactive uninstall together with `--all`/`--with`).
- **User-authored files are never deleted** — `~/.gitconfig`, `~/.m2/settings.xml`,
  `~/.gradle/gradle.properties`, and your own `~/.npmrc` lines are kept and listed at the end so
  you can remove them yourself if you want to.
- `git` is a system package (or your Xcode CLT); dev-kit does not remove it, it prints the command to do so.

## License

Apache-2.0.
