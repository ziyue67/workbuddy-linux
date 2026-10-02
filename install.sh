#!/usr/bin/env bash
#
# WorkBuddy for Linux —— 获取并安装腾讯官方构建的 deb / rpm
#
# 官网 https://www.workbuddy.cn 的下载页只列了 macOS / Windows / 移动端，没有 Linux 入口。
# 但官方更新接口
#     https://copilot.tencent.com/v2/update?platform=workbuddy-linux-<arch>-<type>
# 会返回最新 Linux 构建的真实下载地址。本脚本只做三件事：
#     1) 查询该接口拿到最新版地址
#     2) 下载并做基本校验
#     3) 交给系统包管理器安装
#
# 版权说明：WorkBuddy 本体是腾讯的专有软件。本仓库不打包、不修改、不再分发它的二进制，
# 只提供脚本与版本索引。本脚本以 MIT 许可证发布（见 LICENSE），该许可证不覆盖 WorkBuddy。
#
set -euo pipefail

readonly API_BASE="${WORKBUDDY_API_BASE:-https://copilot.tencent.com/v2/update}"
readonly DEFAULT_MIRROR="${WORKBUDDY_MIRROR:-https://download.codebuddy.cn}"

CHANNEL=""
ARCH=""
MODE="install"           # install | check | url-only | table
DOWNLOAD_DIR="${WORKBUDDY_DIR:-$HOME/Downloads}"
KEEP=1
DRY_RUN=0
WITH_RECOMMENDS=0
REDOWNLOAD=0
FORCE=0
JSON=0
MIRROR="$DEFAULT_MIRROR"
EXPECT_SHA=""
SUDO=()

if [ -t 2 ]; then
  c_blue=$'\033[1;34m'; c_yellow=$'\033[1;33m'; c_red=$'\033[1;31m'; c_off=$'\033[0m'
else
  c_blue=""; c_yellow=""; c_red=""; c_off=""
fi

log()  { printf '%s==>%s %s\n' "$c_blue" "$c_off" "$*" >&2; }
warn() { printf '%s警告:%s %s\n' "$c_yellow" "$c_off" "$*" >&2; }
die()  { printf '%s错误:%s %s\n' "$c_red" "$c_off" "$*" >&2; exit 1; }

usage() {
  cat <<'EOF'
用法: install.sh [选项]

默认行为: 自动识别架构 (amd64/arm64) 与包类型 (deb/rpm)，查询官方接口的最新版本，
下载到 ~/Downloads，然后交给 apt / dnf / yum / zypper 安装。

选项:
  -c, --channel deb|rpm    指定包类型（默认按系统自动判断）
  -a, --arch x64|arm64     指定架构（默认按 uname -m 自动判断）
  -d, --dir DIR            下载目录（默认 ~/Downloads）
  -n, --check              只查询最新版本信息，不下载不安装
  -u, --url-only           只打印最新版的下载地址
  -t, --table              列出四个通道（x64/arm64 × deb/rpm）各自的最新版本
      --json               配合 --check 使用，输出 JSON（便于脚本 / GitHub Action 调用）
  -r, --redownload         即使本地已有同样大小的文件也重新下载
      --dry-run            只下载并校验，不安装
      --rm                 安装成功后删除下载的安装包
      --recommends         一并安装 deb 的推荐依赖（imagemagick、托盘库等）
      --expect-sha256 H    强制校验下载文件的 SHA256，不匹配则中止
      --mirror URL         替换下载域名（自建或第三方镜像），默认 download.codebuddy.cn
  -f, --force              即使本地已是最新版本，也重新下载安装
  -h, --help               显示本帮助

环境变量:
  WORKBUDDY_API_BASE   覆盖更新接口地址
  WORKBUDDY_MIRROR     等同于 --mirror
  WORKBUDDY_DIR        等同于 --dir

示例:
  ./install.sh                  一键安装最新版
  ./install.sh --check          看看最新版是哪个
  ./install.sh --table          四个通道一览
  ./install.sh --url-only       只要下载地址
  ./install.sh --dry-run --rm   只下载校验，不安装
EOF
}

# ---------- 参数解析 ----------

while [ $# -gt 0 ]; do
  case "$1" in
    -c|--channel)  [ $# -ge 2 ] || die "--channel 需要一个参数"; CHANNEL=$2; shift 2 ;;
    -a|--arch)     [ $# -ge 2 ] || die "--arch 需要一个参数"; ARCH=$2; shift 2 ;;
    -d|--dir)      [ $# -ge 2 ] || die "--dir 需要一个参数"; DOWNLOAD_DIR=$2; shift 2 ;;
    --mirror)      [ $# -ge 2 ] || die "--mirror 需要一个参数"; MIRROR=$2; shift 2 ;;
    --expect-sha256) [ $# -ge 2 ] || die "--expect-sha256 需要一个参数"; EXPECT_SHA=$2; shift 2 ;;
    -n|--check)    MODE="check"; shift ;;
    -u|--url-only) MODE="url-only"; shift ;;
    -t|--table)    MODE="table"; shift ;;
    --json)        JSON=1; shift ;;
    -r|--redownload) REDOWNLOAD=1; shift ;;
    --dry-run)     DRY_RUN=1; shift ;;
    --rm)          KEEP=0; shift ;;
    --recommends)  WITH_RECOMMENDS=1; shift ;;
    -f|--force)    FORCE=1; shift ;;
    -h|--help)     usage; exit 0 ;;
    *) die "未知参数: $1（用 --help 查看用法）" ;;
  esac
done

[ -z "$CHANNEL" ] || case "$CHANNEL" in deb|rpm) ;; *) die "--channel 只能是 deb 或 rpm" ;; esac
[ -z "$ARCH" ] || case "$ARCH" in x64|arm64) ;; *) die "--arch 只能是 x64 或 arm64" ;; esac
[ "$JSON" -eq 0 ] || [ "$MODE" = check ] || die "--json 需要配合 --check 使用"

# ---------- 环境探测 ----------

detect_arch() {
  case "$(uname -m)" in
    x86_64|amd64)   printf 'x64' ;;
    aarch64|arm64)  printf 'arm64' ;;
    *) die "不支持的架构 $(uname -m)：官方只构建了 x64 与 arm64" ;;
  esac
}

detect_channel() {
  if command -v apt-get >/dev/null 2>&1; then printf 'deb'
  elif command -v dnf >/dev/null 2>&1 || command -v yum >/dev/null 2>&1 || command -v zypper >/dev/null 2>&1; then printf 'rpm'
  elif command -v pacman >/dev/null 2>&1; then die "Arch 系系统请用 AUR 或自行转换官方 deb，本脚本不适用"
  else die "无法判断包管理器，请用 --channel deb 或 --channel rpm 指定"
  fi
}

setup_sudo() {
  if [ "$(id -u)" -eq 0 ]; then
    SUDO=()
  elif command -v sudo >/dev/null 2>&1; then
    SUDO=(sudo)
  else
    die "需要 root 权限：请用 root 运行，或先安装 sudo"
  fi
}

# ---------- 接口与 JSON ----------

fetch_meta() {
  local platform=$1 out
  out=$(curl -fsSL --connect-timeout 20 --max-time 60 "$API_BASE?platform=$platform" 2>/dev/null) \
    || die "查询更新接口失败：$API_BASE?platform=$platform（检查网络或代理）"
  printf '%s' "$out"
}

json_get() { # json_get <json> <key>
  local json=$1 key=$2
  if command -v jq >/dev/null 2>&1; then
    printf '%s' "$json" | jq -r --arg k "$key" '.[$k] // empty'
  elif command -v python3 >/dev/null 2>&1; then
    printf '%s' "$json" | python3 -c 'import json,sys; v=json.load(sys.stdin).get(sys.argv[1], ""); print(v if v is not None else "")' "$key"
  else
    printf '%s' "$json" | tr ',' '\n' \
      | grep -o "\"$key\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" | head -n1 \
      | sed 's/.*:[[:space:]]*"//; s/"$//'
  fi
}

json_escape() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }

fmt_time() { # 接口 timestamp 是 Unix 秒
  [ -n "${1:-}" ] || return 0
  date -u -d "@$1" '+%Y-%m-%d %H:%M UTC' 2>/dev/null || printf '%s' "$1"
}

iso_time() {
  [ -n "${1:-}" ] || return 0
  date -u -d "@$1" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || printf '%s' "$1"
}

installed_version() {
  local v=""
  if command -v dpkg-query >/dev/null 2>&1; then
    v=$(dpkg-query -W -f='${Version}' workbuddy 2>/dev/null || true)
  elif command -v rpm >/dev/null 2>&1; then
    v=$(rpm -q --qf '%{VERSION}' workbuddy 2>/dev/null || true)
  fi
  case "$v" in *"not installed"*|*"未安装"*) v="" ;; esac
  printf '%s' "$v"
}

is_up_to_date() { # is_up_to_date <已安装> <最新>
  [ -n "$1" ] || return 1
  [ "$1" = "$2" ] && return 0
  case "$2" in "$1".*) return 0 ;; esac
  return 1
}

# ---------- 下载与校验 ----------

remote_size() {
  curl -sIL --connect-timeout 20 "$1" 2>/dev/null | tr -d '\r' \
    | awk 'tolower($1) == "content-length:" { v = $2 } END { print v + 0 }'
}

local_size() {
  if command -v stat >/dev/null 2>&1; then
    stat -c %s "$1" 2>/dev/null || stat -f %z "$1" 2>/dev/null || printf '0'
  else
    printf '0'
  fi
}

check_magic() { # 防止把 HTML 错误页当成安装包
  local f=$1 t=$2
  case "$t" in
    deb) [ "$(head -c 4 "$f")" = "!<ar" ] || die "下载到的不是有效的 deb 包（可能是错误页面），文件保留在 $f" ;;
    rpm) [ "$(head -c 4 "$f" | od -An -tx1 | tr -d ' \n')" = "edabeedb" ] || die "下载到的不是有效的 rpm 包，文件保留在 $f" ;;
  esac
}

file_sha256() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | awk '{print $1}'
  else die "系统里没有 sha256sum / shasum，无法校验"
  fi
}

download() { # download <url> <目标文件>
  local url=$1 dest=$2 part="${2}.part"
  trap 'rm -f "$part"' EXIT INT TERM
  log "开始下载 $(basename "$dest")"
  if [ -t 2 ]; then
    curl -fL --retry 3 --retry-delay 2 --connect-timeout 20 --progress-bar -o "$part" "$url"
  else
    curl -fsL --retry 3 --retry-delay 2 --connect-timeout 20 -o "$part" "$url"
  fi
  mv -f "$part" "$dest"
  trap - EXIT INT TERM
  log "下载完成：$dest（$(local_size "$dest") 字节）"
}

# ---------- 安装 ----------

do_install() { # do_install <文件> <类型>
  local file=$1 t=$2
  case "$t" in
    deb)
      command -v apt-get >/dev/null 2>&1 || die "系统里没有 apt-get，可手动安装：sudo dpkg -i '$file'"
      local args=(-y)
      [ "$WITH_RECOMMENDS" -eq 1 ] || args+=(--no-install-recommends)
      [ "$FORCE" -eq 1 ] && args+=(--reinstall)
      log "apt-get install ${file##*/}"
      "${SUDO[@]}" apt-get install "${args[@]}" "$file"
      ;;
    rpm)
      if command -v dnf >/dev/null 2>&1; then
        if [ "$FORCE" -eq 1 ]; then
          log "dnf reinstall ${file##*/}"
          "${SUDO[@]}" dnf reinstall -y "$file"
        else
          log "dnf install ${file##*/}"
          "${SUDO[@]}" dnf install -y "$file"
        fi
      elif command -v yum >/dev/null 2>&1; then
        log "yum install ${file##*/}"
        "${SUDO[@]}" yum install -y "$file"
      elif command -v zypper >/dev/null 2>&1; then
        if [ "$FORCE" -eq 1 ]; then
          log "zypper install --force ${file##*/}"
          "${SUDO[@]}" zypper --non-interactive install --force --allow-unsigned-rpm "$file"
        else
          log "zypper install ${file##*/}"
          "${SUDO[@]}" zypper --non-interactive install --allow-unsigned-rpm "$file"
        fi
      elif command -v rpm >/dev/null 2>&1; then
        warn "只找到 rpm，依赖需要自己解决"
        "${SUDO[@]}" rpm -Uvh --replacepkgs "$file"
      else
        die "找不到 dnf / yum / zypper / rpm，无法安装"
      fi
      ;;
  esac
}

# ---------- 通道表 ----------

print_table() {
  printf '%-32s %-22s %s\n' "通道 (platform)" "最新版本" "发布时间"
  printf '%-32s %-22s %s\n' "--------------------------------" "----------------------" "--------------------"
  local a t p meta ver ts
  for a in x64 arm64; do
    for t in deb rpm; do
      p="workbuddy-linux-$a-$t"
      meta=$(curl -fsSL --connect-timeout 20 --max-time 60 "$API_BASE?platform=$p" 2>/dev/null || true)
      ver=$(json_get "$meta" version); ts=$(json_get "$meta" timestamp)
      [ -n "$ver" ] || ver="(查询失败)"
      printf '%-32s %-22s %s\n' "$p" "$ver" "$(fmt_time "$ts")"
    done
  done
}

# ---------- 主流程 ----------

[ "$MODE" = table ] && { print_table; exit 0; }

[ -n "$CHANNEL" ] || CHANNEL=$(detect_channel)
[ -n "$ARCH" ] || ARCH=$(detect_arch)
PLATFORM="workbuddy-linux-$ARCH-$CHANNEL"

META=$(fetch_meta "$PLATFORM")
VERSION=$(json_get "$META" version)
URL=$(json_get "$META" url)
API_SHA=$(json_get "$META" sha256hash)
TS=$(json_get "$META" timestamp)

[ -n "$VERSION" ] || die "接口没有返回版本号，原始响应：$META"
[ -n "$URL" ] || die "接口没有返回下载地址，原始响应：$META"

if [ "$MIRROR" != "$DEFAULT_MIRROR" ]; then
  URL="${MIRROR}${URL#"$DEFAULT_MIRROR"}"
fi

INSTALLED=$(installed_version)
UP_TO_DATE=0
is_up_to_date "$INSTALLED" "$VERSION" && UP_TO_DATE=1

if [ "$MODE" = check ]; then
  # 顺带 HEAD 一下拿远端体积：同版本号被原地重传时，这个值和摘要里的记录会对不上
  CHECK_SIZE=$(remote_size "$URL")
  [ "$CHECK_SIZE" -gt 0 ] 2>/dev/null || CHECK_SIZE=0
  if [ "$JSON" -eq 1 ]; then
    printf '{"platform":"%s","type":"%s","arch":"%s","version":"%s","url":"%s","api_sha256":"%s","timestamp":%s,"released":"%s","size":%s,"installed":"%s","up_to_date":%s}\n' \
      "$PLATFORM" "$CHANNEL" "$ARCH" \
      "$(json_escape "$VERSION")" "$(json_escape "$URL")" "$(json_escape "$API_SHA")" \
      "${TS:-0}" "$(iso_time "$TS")" "$CHECK_SIZE" "$(json_escape "$INSTALLED")" \
      "$([ "$UP_TO_DATE" -eq 1 ] && printf 'true' || printf 'false')"
  else
    printf '通道      : %s\n' "$PLATFORM"
    printf '最新版本  : %s\n' "$VERSION"
    printf '发布时间  : %s\n' "$(fmt_time "$TS")"
    printf '下载地址  : %s\n' "$URL"
    if [ "$CHECK_SIZE" -gt 0 ]; then
      printf '远端大小  : %s 字节\n' "$CHECK_SIZE"
    else
      printf '远端大小  : (HEAD 失败，未知)\n'
    fi
    printf '接口声明  : sha256 %s\n' "${API_SHA:-(无)}"
    if [ -n "$INSTALLED" ]; then
      if [ "$UP_TO_DATE" -eq 1 ]; then
        printf '本地版本  : %s（已是最新）\n' "$INSTALLED"
      else
        printf '本地版本  : %s（可升级）\n' "$INSTALLED"
      fi
    else
      printf '本地版本  : 未安装\n'
    fi
  fi
  exit 0
fi

if [ "$MODE" = url-only ]; then
  printf '%s\n' "$URL"
  exit 0
fi

if [ "$UP_TO_DATE" -eq 1 ] && [ "$FORCE" -eq 0 ]; then
  log "本机已安装 $INSTALLED，就是最新版（用 --force 可强制重装）"
  exit 0
fi

if [ -n "$INSTALLED" ]; then
  log "本机版本 $INSTALLED → 目标版本 $VERSION"
else
  log "本机未安装 WorkBuddy，目标版本 $VERSION"
fi

mkdir -p "$DOWNLOAD_DIR" || die "无法创建下载目录 $DOWNLOAD_DIR"
FILE="$DOWNLOAD_DIR/$(basename "$URL")"

R_SIZE=$(remote_size "$URL")
if [ "$REDOWNLOAD" -eq 0 ] && [ -f "$FILE" ] && [ "$R_SIZE" -gt 0 ] && [ "$(local_size "$FILE")" = "$R_SIZE" ]; then
  log "本地已存在同样大小的安装包，跳过下载（用 --redownload 可强制重下）"
else
  download "$URL" "$FILE"
fi

check_magic "$FILE" "$CHANNEL"

ACTUAL_SHA=$(file_sha256 "$FILE")
printf '文件 SHA256: %s\n' "$ACTUAL_SHA" >&2
if [ -n "$EXPECT_SHA" ]; then
  if [ "$ACTUAL_SHA" = "$EXPECT_SHA" ]; then
    log "SHA256 校验通过"
  else
    die "SHA256 不匹配：期望 $EXPECT_SHA，实际 $ACTUAL_SHA"
  fi
elif [ -n "$API_SHA" ] && [ "$ACTUAL_SHA" != "$API_SHA" ]; then
  warn "接口声明的 sha256 ($API_SHA) 与实际文件不一致。这是官方接口的已知现象，多次下载结果稳定；如需强校验请自备 --expect-sha256。"
fi

if [ "$DRY_RUN" -eq 1 ]; then
  log "--dry-run：已下载并校验，未执行安装。文件：$FILE"
  exit 0
fi

setup_sudo
do_install "$FILE" "$CHANNEL"

NEW=$(installed_version)
if [ -n "$NEW" ]; then
  log "安装完成，当前版本：$NEW"
else
  warn "安装命令已执行，但没能读到已安装版本，请手动确认：dpkg -l workbuddy / rpm -q workbuddy"
fi

if [ "$KEEP" -eq 0 ]; then
  rm -f "$FILE" && log "已删除安装包 $FILE"
else
  log "安装包保留在：$FILE"
fi

log "从应用菜单启动 WorkBuddy，或在终端运行 workbuddy"
