# WorkBuddy for Linux

[![Update version index](https://github.com/ziyue67/workbuddy-linux/actions/workflows/update-index.yml/badge.svg)](https://github.com/ziyue67/workbuddy-linux/actions/workflows/update-index.yml)
[![Self check](https://github.com/ziyue67/workbuddy-linux/actions/workflows/self-check.yml/badge.svg)](https://github.com/ziyue67/workbuddy-linux/actions/workflows/self-check.yml)
[![Lint](https://github.com/ziyue67/workbuddy-linux/actions/workflows/lint.yml/badge.svg)](https://github.com/ziyue67/workbuddy-linux/actions/workflows/lint.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![最新版本](https://img.shields.io/badge/dynamic/json?url=https%3A%2F%2Fraw.githubusercontent.com%2Fziyue67%2Fworkbuddy-linux%2Fmain%2Findex.json&query=%24.channels%5B%27workbuddy-linux-x64-deb%27%5D.version&label=WorkBuddy&color=blue)](index.json)

[WorkBuddy](https://www.workbuddy.cn/) 官网的下载页只列了 macOS / Windows / iOS / Android / 鸿蒙，Linux 一栏写着「统信 UOS/银河麒麟：请到系统应用商店下载」——Ubuntu、Debian、Fedora 用户没有入口。

但这个软件其实**有官方构建的 deb 和 rpm**，只是没挂在下载页上：腾讯的更新接口会直接返回最新 Linux 构建的下载地址。

本仓库提供的就是围绕这个接口的一键安装脚本和版本索引：

```bash
./install.sh          # 查最新版 → 下载 → 校验 → 交给 apt/dnf 安装
```

## 这不是什么

- **不是 WorkBuddy 的官方项目**，与腾讯无关。
- **不托管、不打包、不修改 WorkBuddy 的二进制**。安装包始终从腾讯官方 CDN（`download.codebuddy.cn`）实时下载，本仓库里只有脚本、文档和一份元数据索引。
- **MIT 许可证只覆盖本仓库的脚本与索引**，不覆盖 WorkBuddy 本体（专有软件，版权归腾讯）。

## 快速开始

最简单的方式是先把脚本下载下来看一眼再运行：

```bash
curl -fsSL https://raw.githubusercontent.com/ziyue67/workbuddy-linux/main/install.sh -o install.sh
less install.sh          # 建议看一眼
bash install.sh
```

或者克隆仓库（国内网络可以走代理）：

```bash
git clone https://github.com/ziyue67/workbuddy-linux.git
cd workbuddy-linux && ./install.sh
```

国内直连 `raw.githubusercontent.com` 不通时，在地址前拼一个代理前缀即可（任选其一）：

```bash
curl -fsSL https://ghproxy.net/https://raw.githubusercontent.com/ziyue67/workbuddy-linux/main/install.sh | bash
```

## 用法

```
./install.sh [选项]

  -c, --channel deb|rpm    指定包类型（默认按系统自动判断）
  -a, --arch x64|arm64     指定架构（默认按 uname -m 自动判断）
  -d, --dir DIR            下载目录（默认 ~/Downloads）
  -n, --check              只查询最新版本信息，不下载不安装
  -u, --url-only           只打印最新版的下载地址
  -t, --table              列出四个通道各自的最新版本
      --json               配合 --check 输出 JSON
  -r, --redownload         本地已有同样大小的文件也重新下载
      --dry-run            只下载并校验，不安装
      --rm                 安装成功后删除安装包
      --recommends         一并安装 deb 的推荐依赖（imagemagick、托盘库等）
      --expect-sha256 H    强制校验 SHA256，不匹配则中止
      --mirror URL         替换下载域名，用于自建/第三方镜像
  -f, --force              已是最新版本也重新安装
  -h, --help               帮助
```

常用组合：

```bash
./install.sh --check                 # 最新版是哪个？我装的是哪个？
./install.sh --table                 # 四个通道一览
./install.sh --url-only              # 只要下载地址，自己 curl
./install.sh --dry-run --rm          # 只下载校验，先不装
./install.sh --rm                    # 装完不留下 400MB 安装包
```

脚本会在本机已是最新版本时直接退出，所以可以放进定时任务或更新脚本里重复执行。

## 支持矩阵

更新接口认这四个通道，本仓库的 `index.json` 会每天自动刷新：

| platform | 包类型 | 适用 |
| --- | --- | --- |
| `workbuddy-linux-x64-deb` | x86_64 deb | Ubuntu / Debian / 深度 / openKylin |
| `workbuddy-linux-x64-rpm` | x86_64 rpm | Fedora / RHEL / openSUSE |
| `workbuddy-linux-arm64-deb` | arm64 deb | ARM 上的 Debian 系 |
| `workbuddy-linux-arm64-rpm` | arm64 rpm | ARM 上的 Fedora 系 |

官方包依赖的都是发行版标准库（deb 侧：`libgtk-3-0 libnotify4 libnss3 libxss1 libxtst6 xdg-utils libatspi2.0-0 libuuid1 libsecret-1-0`；rpm 侧：`gtk3 nss alsa-lib at-spi2-core libXScrnSaver libnotify mesa-libgbm` 等），不依赖任何麒麟/UOS 专有组件。`postinst` 里连 Ubuntu 24+ 的 AppArmor 分支都写好了。

**龙架构（LoongArch）没有官方版**：Electron 与部分 node 模块不支持该架构，deepin 龙芯商店里的是社区移植包。

## 版本索引

`index.json` 由 GitHub Action 每天自动刷新，结构如下：

```json
{
  "channels": {
    "workbuddy-linux-x64-deb": {
      "version": "5.5.6.38337834",
      "url": "https://download.codebuddy.cn/workbuddy/saas/linux-x64-deb/...",
      "api_sha256": "03d756b2...",
      "released": "2026-09-10T17:23:54Z",
      "size": 429329908
    }
  }
}
```

`size` 字段是实测的远端文件体积。它有个实际用处：腾讯会在**版本号和构建号都不变**的情况下往同一个地址重传新构建，这时 `version` 看不出任何变化，但 `size` 的 diff 会直接暴露出来（见下）。

只想拿版本号的话：

```bash
curl -fsSL https://raw.githubusercontent.com/ziyue67/workbuddy-linux/main/index.json | jq -r '.channels["workbuddy-linux-x64-deb"].version'
```

## 同版本号 ≠ 同文件

这是个实际踩到的坑，值得单独说：**腾讯会在版本号、构建号、CDN 文件名全都不变的情况下，往同一个 URL 上传重新构建的包。**

实测记录（同一个 `WorkBuddy-linux-x64-deb-5.5.6.38337834-5f969292.deb`）：

| 观测日期 | 体积 | SHA256 |
| --- | --- | --- |
| 2026-09-26 | 429,302,312 | `2ef1bca2…` |
| 2026-10-02 | 429,329,908 | `2b86814a…` |

包内控制段的构建时间戳是 **2026-09-21 10:26**，比接口返回的 09-10 晚 11 天——即上游 9 月 21 日重新构建后覆盖了旧文件，但一个字都没改版本号。

带来的后果：

- **光看版本号判断"要不要更新"是不准的**。你以为已是最新，实际装的可能是旧构建。
- 之前的实测哈希会失效：`checksums.json` 里 9/26 记录的那条已经被这次重传推翻了。
- 这也解释了为什么接口的 `api_sha256` 一直对不上真实文件——那个字段大概对应某个内部构建产物，而不是 CDN 上当前这份。

现在的应对：

- `checksums.json` 记录了每个通道的实测体积与哈希，`entries` 是当前有效值，`rebuild_log` 是历次重传的时间线。
- `self-check` 工作流每天比对实测体积与 `checksums.json` 记录，一旦对不上就发 `::warning::` 并写进 run summary，不会静默过去。
- `install.sh --check` 会打印远端大小，`--check --json` 输出里带 `size` 字段，方便自己写脚本盯着。
- 想装到确定的那一份，用 `--expect-sha256` 固定哈希；但记住哈希本身也会随上游重传而变化。

换句话说：这个仓库能可靠地告诉你**上游当前在发什么**，但它没法给你一个跨时间稳定的二进制标识——上游没提供这种东西。

## 发布页与校验值

[Releases](https://github.com/ziyue67/workbuddy-linux/releases) 里每个上游版本一条记录，内容是四个通道的官方 CDN 直链和校验值——**不附带安装包文件**，二进制始终留在腾讯自己的 CDN 上，仓库只做索引和直链（原因见 [NOTICE.md](NOTICE.md)）。上游出新版本时由 Action 自动建 release，不需要手动维护。

`checksums.json` 收录实际下载后算出来的 SHA256 与体积（接口自带的 `api_sha256` 不可信，见上），欢迎 PR 补充其它通道和版本。

## 自动化

整个仓库不需要人工干预，三个工作流各管一段：

| 工作流 | 触发 | 做什么 |
| --- | --- | --- |
| [`update-index.yml`](.github/workflows/update-index.yml) | 每天 03:17 UTC + 手动 | 刷新 `index.json` 并提交；发现上游新版本就自动建 Release（只放直链）；任一通道查询失败则整步失败，不会提交残缺索引 |
| [`self-check.yml`](.github/workflows/self-check.yml) | 每天 06:23 UTC + 手动 + 脚本变更 | 体检：四个通道接口是否可用、直链是否 200 且文件大小正常、**实测体积与 `checksums.json` 记录的体积是否一致**（对不上说明上游原地重传了包，会发出 warning）、`index.json` 是否还在刷新（超过 48 小时未更新就报错） |
| [`lint.yml`](.github/workflows/lint.yml) | push / PR | `shellcheck -S style` + `bash -n` |

上游哪天改了接口、换了 CDN 路径，或者原地重传了包，`self-check` 会先亮起来，而不是等用户装不上才发现。所有脚本本地都能直接跑：

```bash
./scripts/update-index.sh      # 重新生成 index.json
./scripts/release-notes.sh     # 预览下一个 Release 的说明
./scripts/publish-release.sh --dry-run   # 演练发 Release（新版本才真的建）
```

## 常见问题

**接口给的 `sha256hash` 和实际文件对不上？**
这是官方接口的已知问题，不是下载损坏：`api_sha256` 字段与真实文件的内容哈希一直不一致，疑似对应内部构建产物。脚本默认只警告不拦截；要强校验就自己算一遍，用 `--expect-sha256` 固定——但要留意上游原地重传会让这个哈希失效（见[同版本号 ≠ 同文件](#同版本号--同文件)）。

**装完之后应用内更新不了？**
接口返回 `supportsFastUpdate: false`，应用里点更新会提示「前往官网下载」，而官网没有 Linux 入口，等于死循环。更新方式就是重新跑一遍 `./install.sh`。

**下载速度慢 / 想用自建镜像？**
`./install.sh --mirror https://your.mirror` 会把下载域名从 `download.codebuddy.cn` 换成你的地址，路径部分保持不变。这对内网缓存、离线分发很有用——镜像由你自己搭建和承担相应责任，本仓库不分发二进制。

**Arch 系怎么办？**
官方没有 Arch 包，脚本会在检测到 `pacman` 时直接报错退出，请走 AUR 或自行转换官方 deb。

## 贡献

欢迎 PR：改进脚本兼容性、补充发行版适配、修正文档，或者提交你实测的校验值。自动化索引在 `.github/workflows/update-index.yml`，本地可用 `./scripts/update-index.sh` 重新生成。

## 许可与出处

- 本仓库的脚本、文档与索引数据：MIT，见 [LICENSE](LICENSE)；覆盖范围的详细说明见 [NOTICE.md](NOTICE.md)。
- WorkBuddy 本体：腾讯科技（深圳）有限公司的专有软件，版权归腾讯所有，不在本许可证覆盖范围内，本仓库也不分发其安装包。
- 本项目与腾讯无隶属关系，不是官方项目。

发现这个安装方法的原始文章：[《WorkBuddy 没给 Ubuntu/Fedora 留下载入口？官方的 deb 和 rpm 都找到了》](https://xingwangzhe.fun/posts/workbuddy-linux-deb-rpm/)（作者 xingwangzhe，CC-BY-NC-SA-4.0）。本仓库的脚本是在该思路基础上实现的，接口地址与拆包结论均来自该文。
