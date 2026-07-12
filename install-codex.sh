#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_NAME=${0##*/}
CODEX_INSTALL_URL=https://chatgpt.com/codex/install.sh
PROXY_URL=${CODEX_PROXY_URL:-}
PROXY_MODE=auto

log() {
  printf '\033[1;34m[%s]\033[0m %s\n' "$SCRIPT_NAME" "$*"
}

warn() {
  printf '\033[1;33m[%s] WARN:\033[0m %s\n' "$SCRIPT_NAME" "$*" >&2
}

die() {
  printf '\033[1;31m[%s] ERROR:\033[0m %s\n' "$SCRIPT_NAME" "$*" >&2
  exit 1
}

usage() {
  cat <<'EOF'
安装或更新 OpenAI Codex CLI。

用法：
  ./install-codex.sh [选项]

选项：
  --proxy URL   指定 HTTP/Mixed 代理，例如 http://127.0.0.1:7890
  --no-proxy    强制直连
  -h, --help    显示帮助

环境变量：
  CODEX_PROXY_URL  等价于 --proxy

默认行为：自动读取 ~/.config/mihomo/config.yaml 中的 mixed-port；如果代理
可用，就通过它下载安装，否则回退到直连。
EOF
}

while (($#)); do
  case "$1" in
    --proxy)
      (($# >= 2)) || die "--proxy 缺少参数"
      PROXY_URL=$2
      PROXY_MODE=required
      shift 2
      ;;
    --no-proxy)
      PROXY_URL=
      PROXY_MODE=disabled
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "未知参数：$1"
      ;;
  esac
done

[[ $(uname -s) == Linux ]] || die "本脚本只支持 Linux"
command -v curl >/dev/null 2>&1 || die "缺少 curl；请先运行 bootstrap-remote.sh"

discover_mihomo_proxy() {
  local config=$HOME/.config/mihomo/config.yaml port
  [[ -r $config ]] || return 1
  port=$(awk '/^[[:space:]]*mixed-port:[[:space:]]*[0-9]+/ {
    sub(/.*:[[:space:]]*/, ""); print; exit
  }' "$config")
  [[ $port =~ ^[0-9]+$ ]] || return 1
  printf 'http://127.0.0.1:%s\n' "$port"
}

if [[ $PROXY_MODE == auto && -z $PROXY_URL ]]; then
  PROXY_URL=$(discover_mihomo_proxy || true)
fi

INSTALLER=$(mktemp)
trap 'rm -f "$INSTALLER"' EXIT

download_direct() {
  curl -fsSL --retry 2 --connect-timeout 15 --max-time 120 \
    "$CODEX_INSTALL_URL" -o "$INSTALLER"
}

download_with_proxy() {
  curl -fsSL --retry 5 --retry-all-errors --connect-timeout 15 --max-time 180 \
    --proxy "$PROXY_URL" "$CODEX_INSTALL_URL" -o "$INSTALLER"
}

USE_PROXY=0
if [[ -n $PROXY_URL ]]; then
  log "尝试通过代理 $PROXY_URL 下载 Codex 官方安装器"
  if download_with_proxy; then
    USE_PROXY=1
  elif [[ $PROXY_MODE == required ]]; then
    die "指定的代理不可用：$PROXY_URL"
  else
    warn "Mihomo 代理不可用，改用直连"
    download_direct || die "无法下载 Codex 官方安装器"
  fi
else
  log "直连下载 Codex 官方安装器"
  download_direct || die "直连下载失败；请使用 --proxy URL 重试"
fi

log "执行 OpenAI 官方安装器"
if ((USE_PROXY)); then
  HTTP_PROXY=$PROXY_URL \
  HTTPS_PROXY=$PROXY_URL \
  ALL_PROXY=$PROXY_URL \
  http_proxy=$PROXY_URL \
  https_proxy=$PROXY_URL \
  all_proxy=$PROXY_URL \
    sh "$INSTALLER"
else
  sh "$INSTALLER"
fi

export PATH="$HOME/.local/bin:$PATH"
if command -v codex >/dev/null 2>&1; then
  codex --version
else
  warn "安装器已完成，但当前 shell 尚未找到 codex；重新登录后再试"
fi

cat <<'EOF'

Codex CLI 已安装。

首次使用：
  codex-proxy

如果没有安装基础脚本提供的辅助函数：
  HTTP_PROXY=http://127.0.0.1:7890 \
  HTTPS_PROXY=http://127.0.0.1:7890 \
  ALL_PROXY=socks5h://127.0.0.1:7890 \
  codex

首次启动时，请按照 Codex 提示完成账户登录。
EOF
