#!/usr/bin/env bash
#
# 根据 index.json（可选 checksums.json）生成 Release 说明。
# 说明里放的是腾讯官方 CDN 上的安装包直链与校验值，不附带任何二进制文件。
#
# 用法: ./scripts/release-notes.sh > notes.md
#
set -euo pipefail

cd "$(dirname "$0")/.."

command -v jq >/dev/null 2>&1 || { echo "需要 jq" >&2; exit 1; }
[ -f index.json ] || { echo "缺少 index.json，先跑 ./scripts/update-index.sh" >&2; exit 1; }

VERSION=$(jq -r '.channels["workbuddy-linux-x64-deb"].version // empty' index.json)
[ -n "$VERSION" ] || { echo "index.json 里没有版本号" >&2; exit 1; }
RELEASED=$(jq -r '.channels["workbuddy-linux-x64-deb"].released // ""' index.json)

cat <<EOF
> **本 Release 不附带安装包文件。** 下面的直链指向腾讯官方 CDN 上的原始安装包，
> 本仓库不打包、不修改、不再分发这些二进制；点击链接即从腾讯服务器直接下载。
> 需要完全离线的镜像请自行下载后用 \`install.sh --mirror\` 指向你的地址。

上游最新版本：\`$VERSION\`（$RELEASED）

## 安装包直链

| 平台 | 用途 | 安装包 | 接口声明 sha256 |
| --- | --- | --- | --- |
EOF

jq -r '
  .channels
  | to_entries
  | sort_by(.key)
  | .[]
  | .value as $c
  | ($c.type) as $t
  | ($c.arch) as $a
  | (if $t == "deb" then "deb" else "rpm" end) as $kind
  | (if $a == "x64" then "x86_64" else "ARM64" end) as $cpu
  | (if $t == "deb" then "Ubuntu / Debian / UOS / openKylin" else "Fedora / RHEL / openSUSE" end) as $use
  | "| \($cpu) \($kind) | \($use) | [\($c.url | split("/") | last)](\($c.url)) | `\($c.api_sha256)` |"
' index.json

if [ -f checksums.json ] && [ "$(jq '[.entries[] | select(.version == "'"$VERSION"'")] | length' checksums.json)" -gt 0 ]; then
  cat <<'EOF'

## 社区实测校验值

接口字段 `api_sha256` 与真实文件的内容哈希并不一致（官方接口的已知问题），下表是实际下载后测出来的值：

| 通道 | 文件大小 | 实测 SHA256 |
| --- | --- | --- |
EOF
  jq -r --arg v "$VERSION" '
    .entries[]
    | select(.version == $v)
    | "| `\(.platform)` | \(.size) 字节 | " + (if .sha256 then "`\(.sha256)`" else "未校验（仅 HEAD 取体积）" end) + " |"
  ' checksums.json
  echo

  if jq -e '[.rebuild_log[]? | select(.version == "'"$VERSION"'")] | length > 0' checksums.json >/dev/null 2>&1; then
    cat <<'EOF'
> **注意：上游会原地重传。** 同一个版本号、同一个构建号、同一个文件名的包，
> 内容可能已经被换过（实测过体积和哈希都变的情况）。所以上表的哈希只代表测得那一刻的内容，
> 判断"有没有变"要看体积，别只看版本号。历次观测见仓库的 `checksums.json`。
EOF
    echo
  fi
  echo "校验方式：\`sha256sum 下载的文件\`，或用 \`install.sh --expect-sha256 <上面的值>\` 强制校验。欢迎 PR 补充其它通道的实测值（见 \`checksums.json\`）。"
fi

cat <<'EOF'

## 一键安装

```bash
curl -fsSL https://raw.githubusercontent.com/ziyue67/workbuddy-linux/main/install.sh -o install.sh
bash install.sh
```

脚本会自动识别架构（x64/arm64）和包类型（deb/rpm），查官方接口拿最新版地址、下载校验后交给
apt / dnf / yum / zypper 安装。更多选项见 [README](https://github.com/ziyue67/workbuddy-linux#用法)。

手动下载的话，直接用上表的直链即可，例如：

```bash
sudo apt install ./WorkBuddy-linux-x64-deb-*.deb     # Debian 系
sudo dnf install ./WorkBuddy-linux-x64-rpm-*.rpm     # Fedora 系
```

## 为什么这里没有安装包文件

WorkBuddy 是腾讯科技（深圳）有限公司的专有软件，二进制包不受本仓库的 MIT 许可证约束。
把安装包再分发到第三方仓库需要腾讯的授权，所以本仓库只提供脚本、版本索引和直链。
相关说明见 [NOTICE.md](https://github.com/ziyue67/workbuddy-linux/blob/main/NOTICE.md)。

---

安装方法出自 [xingwangzhe 的这篇文章](https://xingwangzhe.fun/posts/workbuddy-linux-deb-rpm/)，版本数据来自腾讯官方更新接口。
EOF
