#!/usr/bin/env bash
#
# WorkBuddy for Linux —— 一键修复登录超时 / 聊天一直转圈（TLS 1.3）
#
# 背景见 https://github.com/ziyue67/workbuddy-linux/issues/1
#   5.6.2 的 Electron 内置 Node 默认用 TLS 1.2 发 ClientHello，www.workbuddy.cn
#   所在的边缘节点对这种握手静默丢弃（不回 alert），表现为：
#     - 点登录没反应，或报网络不通
#     - 登录成功后发消息一直转圈，模型服务端看不到任何请求
#   同一台机器上用 curl（OpenSSL）访问同一 IP 完全正常，所以很容易误判成网络问题。
#
# 修复原理（issue 里实测得出的结论）：
#   在加载业务代码前把 Node 的最低 TLS 版本提到 1.3：
#     require("tls").DEFAULT_MIN_VERSION = "TLSv1.3";
#   打包后的 Electron 会忽略 NODE_OPTIONS（启动日志里有
#   "Most NODE_OPTIONs are not supported in packaged apps"），所以只能改包内代码。
#
#   三个入口都要改，少一个就会出现"登录能过、聊天一直转圈"：
#     1) app.asar!main/index.js                     主进程（登录 / 认证）
#     2) app.asar!main/daemon-app-server-entry.js   app-server 守护进程
#     3) app.asar.unpacked/cli/bin/{codebuddy,cbc-prewarm,codebuddy-lowmem}
#        CLI 宿主——聊天请求实际由它发出
#
# app.asar 是 header + 顺序拼接的文件，本脚本用「等长字节替换锚点注释」的方式注入，
# 不执行 asar extract / pack，文件大小和 header 都不变，unpacked 文件的标记也不会被破坏。
# 原始字节记录在 --state-dir 下，--revert 可原样恢复。
#
# 本脚本以 MIT 发布；WorkBuddy 本体是腾讯的专有软件，版权归腾讯。
#
set -euo pipefail

readonly DEFAULT_ROOT="/opt/WorkBuddy"
readonly DEFAULT_SHIM="/opt/wbtls.js"
readonly DEFAULT_STATE_DIR="/var/lib/workbuddy-tls-fix"
readonly SELF_URL="${WORKBUDDY_FIX_TLS_URL:-https://raw.githubusercontent.com/ziyue67/workbuddy-linux/main/scripts/fix-tls.sh}"
readonly SELF_DEST="/usr/local/sbin/workbuddy-fix-tls"

# 两个 asar 内锚点：打包产物里的 //#region 注释，去掉不影响运行
readonly MARKERS=(
  '//#region src/main/window/early-open-url-capture.ts'
  '//#region src/main/system/runtime/enable-daemon-compile-cache.ts'
)
readonly CLI_ENTRIES=(codebuddy cbc-prewarm codebuddy-lowmem)

ORIG_ARGS=("$@")
MODE="apply"          # apply | check | revert
APP_ROOT=""
SHIM=""
STATE_DIR=""
DRY_RUN=0
FORCE=0
NO_ELEVATE=0
INSTALL_SELF=0
QUIET=0
PATCHED=0
ALREADY=0
MISSING=0

if [ -t 2 ]; then
  c_blue=$'\033[1;34m'; c_yellow=$'\033[1;33m'; c_red=$'\033[1;31m'; c_off=$'\033[0m'
else
  c_blue=""; c_yellow=""; c_red=""; c_off=""
fi

log()  { [ "$QUIET" -eq 1 ] || printf '%s==>%s %s\n' "$c_blue" "$c_off" "$*" >&2; }
warn() { printf '%s警告:%s %s\n' "$c_yellow" "$c_off" "$*" >&2; }
die()  { printf '%s错误:%s %s\n' "$c_red" "$c_off" "$*" >&2; exit 1; }

usage() {
  cat <<'EOF'
用法: fix-tls.sh [选项]

修复 WorkBuddy for Linux 的登录超时 / 聊天转圈：把 Electron 内置 Node 的最低
TLS 版本提到 1.3（详见 https://github.com/ziyue67/workbuddy-linux/issues/1）。

默认行为: 自动探测 /opt/WorkBuddy，写入 /opt/wbtls.js，给 app.asar 的两个主进程
入口和 app.asar.unpacked/cli/bin 下的三个 CLI 宿主打补丁，并记录回滚数据。

选项:
      --check              只检查补丁状态，不修改任何文件
      --revert             撤销补丁，按记录恢复原始字节 / 原文件
      --dry-run            只打印将要做什么，不写入
      --root DIR           WorkBuddy 安装目录（默认自动探测 /opt/WorkBuddy）
      --shim PATH          外部 TLS 模块路径（默认 /opt/wbtls.js）
      --state-dir DIR      回滚记录目录（默认 /var/lib/workbuddy-tls-fix）
      --install-self       把本脚本安装到 /usr/local/sbin/workbuddy-fix-tls（供启动器自愈调用）
  -f, --force              已打过补丁也重新应用（默认幂等跳过）
  -q, --quiet              只输出错误
      --no-elevate         不是 root 时直接报错，不尝试 sudo
  -h, --help               显示本帮助

环境变量:
  WORKBUDDY_FIX_TLS_URL    --install-self 时下载脚本的地址（默认仓库 raw 地址）

示例:
  sudo ./scripts/fix-tls.sh                 一键修复
  sudo ./scripts/fix-tls.sh --check         看看当前打没打
  sudo ./scripts/fix-tls.sh --revert        恢复原样
  sudo ./scripts/fix-tls.sh --install-self  装到 /usr/local/sbin，供启动器自愈
EOF
}

# ---------- 参数解析 ----------

while [ $# -gt 0 ]; do
  case "$1" in
    --check)        MODE="check"; shift ;;
    --revert)       MODE="revert"; shift ;;
    --dry-run)      DRY_RUN=1; shift ;;
    --root)         [ $# -ge 2 ] || die "--root 需要一个参数"; APP_ROOT=$2; shift 2 ;;
    --shim)         [ $# -ge 2 ] || die "--shim 需要一个参数"; SHIM=$2; shift 2 ;;
    --state-dir)    [ $# -ge 2 ] || die "--state-dir 需要一个参数"; STATE_DIR=$2; shift 2 ;;
    --install-self) INSTALL_SELF=1; shift ;;
    -f|--force)     FORCE=1; shift ;;
    -q|--quiet)     QUIET=1; shift ;;
    --no-elevate)   NO_ELEVATE=1; shift ;;
    -h|--help)      usage; exit 0 ;;
    *) die "未知参数: $1（用 --help 查看用法）" ;;
  esac
done

[ -n "$SHIM" ] || SHIM="$DEFAULT_SHIM"
[ -n "$STATE_DIR" ] || STATE_DIR="$DEFAULT_STATE_DIR"

# ---------- 环境与权限 ----------

detect_root() {
  local d
  for d in "$DEFAULT_ROOT" /opt/workbuddy; do
    if [ -f "$d/resources/app.asar" ]; then
      printf '%s' "$d"
      return 0
    fi
  done
  if command -v dpkg-query >/dev/null 2>&1; then
    d=$(dpkg-query -L workbuddy 2>/dev/null | sed -n 's#^\(.*\)/resources/app\.asar$#\1#p' | head -n1)
    if [ -n "$d" ]; then printf '%s' "$d"; return 0; fi
  fi
  if command -v rpm >/dev/null 2>&1; then
    d=$(rpm -ql workbuddy 2>/dev/null | sed -n 's#^\(.*\)/resources/app\.asar$#\1#p' | head -n1)
    if [ -n "$d" ]; then printf '%s' "$d"; return 0; fi
  fi
  return 1
}

ensure_root() {
  if [ -z "$APP_ROOT" ]; then
    APP_ROOT=$(detect_root) || die "没找到 WorkBuddy 安装目录（默认找 /opt/WorkBuddy）。用 --root 指定，例如 --root /opt/WorkBuddy"
  fi
  [ -f "$APP_ROOT/resources/app.asar" ] || die "$APP_ROOT 下没有 resources/app.asar，路径不对？"
}

maybe_elevate() {
  [ "$MODE" = check ] && return 0
  [ "$DRY_RUN" -eq 1 ] && return 0
  [ "$(id -u)" -eq 0 ] && return 0
  [ "$NO_ELEVATE" -eq 1 ] && die "需要 root 权限：请用 sudo 运行"
  command -v sudo >/dev/null 2>&1 || die "需要 root 权限：请用 root 运行，或先安装 sudo"
  [ -f "$0" ] || die "需要 root 权限：当前是通过管道执行的，请改用 curl ... | sudo bash"
  log "需要 root 权限，切换到 sudo 重新执行"
  exec sudo -- "$0" "${ORIG_ARGS[@]}"
}

# ---------- 小工具 ----------

hex_to_bytes() { # hex_to_bytes <hex> <输出文件>
  local esc
  esc=$(printf '%s' "$1" | sed 's/../\\x&/g')
  printf '%b' "$esc" >"$2"
}

count_occurrences() { # count_occurrences <文件> <字面串>
  local n
  n=$(grep -aoF -- "$2" "$1" 2>/dev/null | wc -l | tr -d ' ')
  printf '%s' "${n:-0}"
}

record_revert() { # record_revert <文件> <偏移> <长度>
  local hex
  hex=$(dd if="$1" bs=1 skip="$2" count="$3" status=none | od -An -v -tx1 | tr -d ' \n')
  printf '%s\t%s\t%s\n' "$1" "$2" "$hex" >>"$STATE_DIR/revert.tsv"
}

# ---------- 打补丁 ----------

write_shim() {
  local tmp
  tmp=$(mktemp)
  cat >"$tmp" <<'EOF'
// workbuddy-linux: fix-tls shim（由 scripts/fix-tls.sh 写入；--revert 会删掉本文件）
"use strict";
const tls = require("tls");
try { tls.DEFAULT_MIN_VERSION = "TLSv1.3"; } catch (e) {}
EOF
  if [ -f "$SHIM" ] && cmp -s "$tmp" "$SHIM" && [ "$FORCE" -eq 0 ]; then
    rm -f "$tmp"
    log "TLS shim 已存在且内容一致：$SHIM"
    return 0
  fi
  if [ "$DRY_RUN" -eq 1 ]; then
    rm -f "$tmp"
    log "[dry-run] 将写入 TLS shim：$SHIM"
    return 0
  fi
  mkdir -p "$(dirname "$SHIM")"
  install -m 0644 "$tmp" "$SHIM"
  rm -f "$tmp"
  log "已写入 TLS shim：$SHIM"
}

patch_asar() { # patch_asar <asar> <锚点注释>
  local asar=$1 marker=$2 code
  local -a hits=() targets=()
  local hit off len repl tmp prev

  code=$(printf 'require("%s");' "$SHIM")
  len=${#marker}
  if [ "${#code}" -gt "$len" ]; then
    die "shim 路径太长（$SHIM），require 语句 ${#code} 字节超过锚点长度 $len 字节。请换一个更短的 --shim 路径。"
  fi

  mapfile -t hits < <(grep -aboF -- "$marker" "$asar" 2>/dev/null || true)

  if [ "${#hits[@]}" -eq 0 ]; then
    if grep -qaF -- "$code" "$asar"; then
      log "已打过补丁（锚点已被替换）：$marker"
      ALREADY=$((ALREADY + 1))
    else
      warn "在 app.asar 里找不到锚点：$marker（上游改了打包结构？）"
      MISSING=$((MISSING + 1))
    fi
    return 0
  fi

  # 只认行首的锚点（//#region 注释一定在行首）；源码映射等地方出现的同名字符串不碰
  for hit in "${hits[@]}"; do
    off=${hit%%:*}
    if [ "$off" -eq 0 ]; then
      targets+=("$off")
      continue
    fi
    prev=$(dd if="$asar" bs=1 skip=$((off - 1)) count=1 status=none | od -An -tx1 | tr -d ' \n')
    if [ "$prev" = "0a" ]; then
      targets+=("$off")
    fi
  done
  if [ "${#targets[@]}" -eq 0 ]; then
    if grep -qaF -- "$code" "$asar"; then
      log "已打过补丁（锚点已被替换）：$marker"
      ALREADY=$((ALREADY + 1))
      return 0
    fi
    mapfile -t targets < <(printf '%s\n' "${hits[@]%%:*}")
  fi

  if [ "${#hits[@]}" -gt 1 ]; then
    log "锚点出现 ${#hits[@]} 次，按行首匹配处理 ${#targets[@]} 处：$marker"
  fi

  for off in "${targets[@]}"; do
    repl=$(printf '%s%*s' "$code" $((len - ${#code})) '')
    if [ "$DRY_RUN" -eq 1 ]; then
      log "[dry-run] 将在 $asar 偏移 $off 处替换 ${len} 字节：$code"
      continue
    fi
    tmp=$(mktemp)
    printf '%s' "$repl" >"$tmp"
    record_revert "$asar" "$off" "$len"
    dd if="$tmp" of="$asar" bs=1 seek="$off" conv=notrunc status=none
    rm -f "$tmp"
    PATCHED=$((PATCHED + 1))
    log "已注入 app.asar 偏移 $off：$marker"
  done
}

patch_cli() { # patch_cli <文件>
  local f=$1 code tmp
  code=$(printf 'require("%s");' "$SHIM")

  if [ ! -f "$f" ]; then
    warn "找不到 CLI 入口：$f（跳过）"
    MISSING=$((MISSING + 1))
    return 0
  fi
  if grep -qF -- "$code" "$f"; then
    log "已打过补丁：$f"
    ALREADY=$((ALREADY + 1))
    return 0
  fi
  if [ "$DRY_RUN" -eq 1 ]; then
    log "[dry-run] 将在 $f 的 shebang 后插入：$code"
    return 0
  fi

  [ -f "$f.wbtls-bak" ] || cp -p "$f" "$f.wbtls-bak"
  tmp=$(mktemp)
  {
    head -n 1 "$f"
    printf '%s\n' "$code"
    tail -n +2 "$f"
  } >"$tmp"
  cat "$tmp" >"$f"
  rm -f "$tmp"
  PATCHED=$((PATCHED + 1))
  log "已注入 CLI 入口：$f"
}

# ---------- 撤销 ----------

revert_all() {
  local rec="$STATE_DIR/revert.tsv"
  local file off hex tmp restored=0 entry f

  if [ -f "$rec" ]; then
    while IFS=$'\t' read -r file off hex; do
      [ -n "$file" ] || continue
      if [ ! -f "$file" ]; then
        warn "回滚目标不存在，跳过：$file"
        continue
      fi
      if [ "$DRY_RUN" -eq 1 ]; then
        log "[dry-run] 将把 $file 偏移 $off 处写回原始字节"
        continue
      fi
      tmp=$(mktemp)
      hex_to_bytes "$hex" "$tmp"
      dd if="$tmp" of="$file" bs=1 seek="$off" conv=notrunc status=none
      rm -f "$tmp"
      restored=$((restored + 1))
      log "已恢复原始字节：$file 偏移 $off"
    done <"$rec"
    if [ "$DRY_RUN" -eq 0 ]; then
      rm -f "$rec"
    fi
  else
    log "没有 asar 回滚记录：$rec"
  fi

  for entry in "${CLI_ENTRIES[@]}"; do
    f="$APP_ROOT/resources/app.asar.unpacked/cli/bin/$entry"
    if [ -f "$f.wbtls-bak" ]; then
      if [ "$DRY_RUN" -eq 1 ]; then
        log "[dry-run] 将恢复 CLI 入口：$f"
      else
        cp -p "$f.wbtls-bak" "$f"
        rm -f "$f.wbtls-bak"
        restored=$((restored + 1))
        log "已恢复 CLI 入口：$f"
      fi
    fi
  done

  if [ -f "$SHIM" ] && grep -q 'workbuddy-linux: fix-tls shim' "$SHIM"; then
    if [ "$DRY_RUN" -eq 1 ]; then
      log "[dry-run] 将删除 TLS shim：$SHIM"
    else
      rm -f "$SHIM"
      log "已删除 TLS shim：$SHIM"
    fi
  fi

  log "撤销完成（恢复 $restored 处）。重启 WorkBuddy 生效。"
}

# ---------- 状态检查 ----------

check_all() {
  local asar="$APP_ROOT/resources/app.asar"
  local code marker entry f state shim_state

  code=$(printf 'require("%s");' "$SHIM")
  if [ -f "$SHIM" ]; then shim_state="(存在)"; else shim_state="(缺失)"; fi

  printf '安装目录 : %s\n' "$APP_ROOT"
  printf 'TLS shim : %s %s\n' "$SHIM" "$shim_state"

  for marker in "${MARKERS[@]}"; do
    if [ "$(count_occurrences "$asar" "$marker")" -gt 0 ]; then
      state="未打补丁"
    elif [ "$(count_occurrences "$asar" "$code")" -gt 0 ]; then
      state="已打补丁"
    else
      state="锚点缺失（版本可能已变）"
    fi
    printf 'app.asar : %-62s %s\n' "${marker#//#region }" "$state"
  done

  for entry in "${CLI_ENTRIES[@]}"; do
    f="$APP_ROOT/resources/app.asar.unpacked/cli/bin/$entry"
    if [ ! -f "$f" ]; then
      state="文件不存在"
    elif grep -qF -- "$code" "$f"; then
      state="已打补丁"
    else
      state="未打补丁"
    fi
    printf 'CLI      : %-62s %s\n' "$entry" "$state"
  done
}

# ---------- 自安装 ----------

install_self() {
  local tmp
  if [ -f "$0" ] && [ "$(basename "$0")" != "bash" ]; then
    install -m 0755 "$0" "$SELF_DEST"
  else
    tmp=$(mktemp)
    curl -fsSL --connect-timeout 20 --max-time 60 "$SELF_URL" -o "$tmp" || die "下载脚本失败：$SELF_URL"
    install -m 0755 "$tmp" "$SELF_DEST"
    rm -f "$tmp"
  fi
  log "已安装到 $SELF_DEST（可在启动器里调用：sudo -n $SELF_DEST --quiet）"
}

# ---------- 主流程 ----------

ensure_root

case "$MODE" in
  check)
    check_all
    exit 0
    ;;
  revert)
    maybe_elevate
    revert_all
    exit 0
    ;;
esac

maybe_elevate
if [ "$DRY_RUN" -eq 0 ]; then
  mkdir -p "$STATE_DIR"
fi

if pgrep -x workbuddy >/dev/null 2>&1 || pgrep -x WorkBuddy >/dev/null 2>&1; then
  warn "检测到 WorkBuddy 正在运行；补丁会在下次启动生效，建议先完全退出（含托盘进程）再打"
fi

log "WorkBuddy 安装目录：$APP_ROOT"
write_shim

marker=""
for marker in "${MARKERS[@]}"; do
  patch_asar "$APP_ROOT/resources/app.asar" "$marker"
done

entry=""
for entry in "${CLI_ENTRIES[@]}"; do
  patch_cli "$APP_ROOT/resources/app.asar.unpacked/cli/bin/$entry"
done

if [ "$INSTALL_SELF" -eq 1 ] && [ "$DRY_RUN" -eq 0 ]; then
  install_self
fi

if [ "$DRY_RUN" -eq 0 ] && [ "$PATCHED" -eq 0 ] && [ "$ALREADY" -eq 0 ] && [ "$MISSING" -gt 0 ]; then
  die "没有找到任何可补丁的入口，WorkBuddy 的打包结构可能变了。请把上面的警告和版本号贴到 issue #1。"
fi

log "完成：新打 $PATCHED 处，已存在 $ALREADY 处，缺失 $MISSING 处"
log "请完全退出并重新启动 WorkBuddy，然后试登录 / 发一条消息"
if [ "$QUIET" -eq 0 ]; then
  cat <<'EOF' >&2

提示:
  - 只支持 TLS 1.2 的域名（wb.tencentbuddy.com、ardot.tencent.com）在 Node 侧会不可达，
    这是服务端限制，不是补丁的问题（主域名正常就不影响日常使用）。
  - 重装 / 升级会覆盖 /opt/WorkBuddy，补丁需要重打：sudo ./scripts/fix-tls.sh
  - 撤销：sudo ./scripts/fix-tls.sh --revert
EOF
fi
