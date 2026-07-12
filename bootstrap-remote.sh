#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_NAME=${0##*/}
MIHOMO_SUBSCRIPTION_URL=${MIHOMO_SUBSCRIPTION_URL:-}
MIHOMO_MIXED_PORT=${MIHOMO_MIXED_PORT:-7890}
MIHOMO_CONTROLLER_PORT=${MIHOMO_CONTROLLER_PORT:-9090}
TARGET_USER=$(id -un)
INSTALL_MIHOMO=1
ENABLE_LINGER=1
CHANGE_SHELL=1

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
一键配置 Ubuntu/Debian 远程开发环境。

用法：
  ./bootstrap-remote.sh [选项]

选项：
  --subscription-url URL  Mihomo 的 Clash/Mihomo 订阅地址
  --mixed-port PORT        本地 HTTP/SOCKS mixed 端口，默认 7890
  --controller-port PORT   本地 API 端口，默认 9090
  --skip-mihomo            不安装或配置 Mihomo
  --no-linger              不启用 systemd user linger
  --no-chsh                不把登录 shell 改成 zsh
  -h, --help               显示帮助

也可使用环境变量：
  MIHOMO_SUBSCRIPTION_URL
  MIHOMO_MIXED_PORT
  MIHOMO_CONTROLLER_PORT

示例：
  MIHOMO_SUBSCRIPTION_URL='https://example.com/sub' ./bootstrap-remote.sh

注意：请以目标普通用户运行，不要使用 sudo 执行整个脚本。脚本会在需要时调用 sudo。
EOF
}

while (($#)); do
  case "$1" in
    --subscription-url)
      (($# >= 2)) || die "--subscription-url 缺少参数"
      MIHOMO_SUBSCRIPTION_URL=$2
      shift 2
      ;;
    --mixed-port)
      (($# >= 2)) || die "--mixed-port 缺少参数"
      MIHOMO_MIXED_PORT=$2
      shift 2
      ;;
    --controller-port)
      (($# >= 2)) || die "--controller-port 缺少参数"
      MIHOMO_CONTROLLER_PORT=$2
      shift 2
      ;;
    --skip-mihomo)
      INSTALL_MIHOMO=0
      shift
      ;;
    --no-linger)
      ENABLE_LINGER=0
      shift
      ;;
    --no-chsh)
      CHANGE_SHELL=0
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
[[ -r /etc/os-release ]] || die "无法识别 Linux 发行版"
# shellcheck disable=SC1091
source /etc/os-release
case "${ID:-}" in
  ubuntu|debian) ;;
  *) die "当前仅支持 Ubuntu/Debian，检测到：${ID:-unknown}" ;;
esac

if ((EUID == 0)) && [[ -n ${SUDO_USER:-} && ${SUDO_USER} != root ]]; then
  die "不要用 sudo 运行整个脚本；请切回用户 ${SUDO_USER} 后直接执行"
fi

if ((EUID == 0)); then
  SUDO=()
else
  command -v sudo >/dev/null 2>&1 || die "需要 sudo，请先由管理员安装或以 root 用户运行"
  SUDO=(sudo)
fi

is_port() {
  [[ $1 =~ ^[0-9]+$ ]] && ((1 <= 10#$1 && 10#$1 <= 65535))
}

is_port "$MIHOMO_MIXED_PORT" || die "无效 mixed port：$MIHOMO_MIXED_PORT"
is_port "$MIHOMO_CONTROLLER_PORT" || die "无效 controller port：$MIHOMO_CONTROLLER_PORT"
[[ $MIHOMO_MIXED_PORT != "$MIHOMO_CONTROLLER_PORT" ]] || die "两个端口不能相同"

backup_file() {
  local path=$1 stamp backup
  [[ -e $path || -L $path ]] || return 0
  stamp=$(date +%Y%m%d-%H%M%S)
  backup="${path}.backup.${stamp}"
  cp -a -- "$path" "$backup"
  log "已备份 $path -> $backup"
}

move_aside() {
  local path=$1 stamp destination
  [[ -e $path || -L $path ]] || return 0
  stamp=$(date +%Y%m%d-%H%M%S)
  destination="${path}.replaced.${stamp}"
  mv -- "$path" "$destination"
  log "已移动 $path -> $destination"
}

replace_managed_block() {
  local file=$1 begin=$2 end=$3 content=$4 tmp
  mkdir -p "$(dirname "$file")"
  touch "$file"
  tmp=$(mktemp)
  awk -v begin="$begin" -v end="$end" '
    $0 == begin { skipping = 1; next }
    $0 == end { skipping = 0; next }
    !skipping { print }
  ' "$file" >"$tmp"
  printf '\n%s\n%s\n%s\n' "$begin" "$content" "$end" >>"$tmp"
  mv "$tmp" "$file"
}

log "安装系统软件包"
"${SUDO[@]}" apt-get update
"${SUDO[@]}" env DEBIAN_FRONTEND=noninteractive apt-get install -y \
  build-essential ca-certificates cmake curl fd-find ffmpeg git git-lfs gzip htop \
  imagemagick jq libgl1 libglib2.0-0 libsm6 libxext6 libxrender1 neovim \
  ninja-build openssl perl pkg-config python3-dev python3-pip python3-venv \
  ripgrep rsync sed tmux tree unzip wget zip zsh

git lfs install --skip-repo

mkdir -p "$HOME/.local/bin"
if ! command -v fd >/dev/null 2>&1 && command -v fdfind >/dev/null 2>&1; then
  ln -sfn "$(command -v fdfind)" "$HOME/.local/bin/fd"
fi

if apt-cache show nvtop >/dev/null 2>&1; then
  "${SUDO[@]}" env DEBIAN_FRONTEND=noninteractive apt-get install -y nvtop || \
    warn "nvtop 安装失败，跳过这个可选的 GPU 监控工具"
fi

NVIM_CONFIG_DIR=$HOME/.config/nvim
if [[ ! -e $NVIM_CONFIG_DIR/init.lua && ! -e $NVIM_CONFIG_DIR/init.vim ]]; then
  mkdir -p "$NVIM_CONFIG_DIR"
  cat >"$NVIM_CONFIG_DIR/init.lua" <<'EOF'
vim.opt.number = true
vim.opt.relativenumber = true
vim.opt.mouse = "a"
vim.opt.termguicolors = true
vim.opt.expandtab = true
vim.opt.shiftwidth = 4
vim.opt.tabstop = 4
vim.opt.smartindent = true
vim.opt.ignorecase = true
vim.opt.smartcase = true
vim.opt.splitright = true
vim.opt.splitbelow = true
vim.opt.undofile = true
vim.opt.updatetime = 250
EOF
fi

log "配置 Oh My Zsh"
if [[ ! -d $HOME/.oh-my-zsh/.git ]]; then
  if [[ -e $HOME/.oh-my-zsh || -L $HOME/.oh-my-zsh ]]; then
    move_aside "$HOME/.oh-my-zsh"
  fi
  git clone --depth=1 https://github.com/ohmyzsh/ohmyzsh.git "$HOME/.oh-my-zsh"
else
  log "Oh My Zsh 已存在，跳过克隆"
fi

if [[ ! -f $HOME/.zshrc ]]; then
  cp "$HOME/.oh-my-zsh/templates/zshrc.zsh-template" "$HOME/.zshrc"
elif ! grep -Fq 'oh-my-zsh.sh' "$HOME/.zshrc"; then
  backup_file "$HOME/.zshrc"
  cat >>"$HOME/.zshrc" <<'EOF'

export ZSH="$HOME/.oh-my-zsh"
ZSH_THEME="robbyrussell"
plugins=(git sudo tmux)
source "$ZSH/oh-my-zsh.sh"
EOF
fi

ZSH_BLOCK=$(cat <<EOF
export PATH="\$HOME/.local/bin:\$PATH"
export EDITOR="\${EDITOR:-vi}"
export NO_PROXY="localhost,127.0.0.1,::1"
export no_proxy="\$NO_PROXY"

proxy-on() {
  export HTTP_PROXY="http://127.0.0.1:${MIHOMO_MIXED_PORT}"
  export HTTPS_PROXY="http://127.0.0.1:${MIHOMO_MIXED_PORT}"
  export ALL_PROXY="socks5h://127.0.0.1:${MIHOMO_MIXED_PORT}"
  export http_proxy="\$HTTP_PROXY" https_proxy="\$HTTPS_PROXY" all_proxy="\$ALL_PROXY"
}

proxy-off() {
  unset HTTP_PROXY HTTPS_PROXY ALL_PROXY http_proxy https_proxy all_proxy
}

proxy() {
  if (( \$# == 0 )); then
    echo "usage: proxy command [args...]" >&2
    return 2
  fi
  HTTP_PROXY="http://127.0.0.1:${MIHOMO_MIXED_PORT}" \\
  HTTPS_PROXY="http://127.0.0.1:${MIHOMO_MIXED_PORT}" \\
  ALL_PROXY="socks5h://127.0.0.1:${MIHOMO_MIXED_PORT}" \\
  http_proxy="http://127.0.0.1:${MIHOMO_MIXED_PORT}" \\
  https_proxy="http://127.0.0.1:${MIHOMO_MIXED_PORT}" \\
  all_proxy="socks5h://127.0.0.1:${MIHOMO_MIXED_PORT}" \\
  command "\$@"
}

alias mihomo-status='systemctl --user status mihomo --no-pager'
alias mihomo-log='journalctl --user -u mihomo -f'
EOF
)
replace_managed_block "$HOME/.zshrc" \
  '# >>> remote-dev-bootstrap >>>' \
  '# <<< remote-dev-bootstrap <<<' \
  "$ZSH_BLOCK"

LOGIN_PATH_BLOCK='export PATH="$HOME/.local/bin:$PATH"'
for login_profile in "$HOME/.profile" "$HOME/.zprofile"; do
  replace_managed_block "$login_profile" \
    '# >>> remote-dev-login-path >>>' \
    '# <<< remote-dev-login-path <<<' \
    "$LOGIN_PATH_BLOCK"
done
if [[ -e $HOME/.bash_profile ]]; then
  replace_managed_block "$HOME/.bash_profile" \
    '# >>> remote-dev-login-path >>>' \
    '# <<< remote-dev-login-path <<<' \
    "$LOGIN_PATH_BLOCK"
fi

if ((CHANGE_SHELL)); then
  ZSH_PATH=$(command -v zsh)
  CURRENT_LOGIN_SHELL=$(getent passwd "$TARGET_USER" | cut -d: -f7)
  if [[ $CURRENT_LOGIN_SHELL != "$ZSH_PATH" ]]; then
    log "将登录 shell 设置为 $ZSH_PATH"
    "${SUDO[@]}" chsh -s "$ZSH_PATH" "$TARGET_USER"
  fi
fi

log "配置 tmux 和 gpakosz/.tmux"
if [[ ! -d $HOME/.tmux/.git ]]; then
  if [[ -e $HOME/.tmux || -L $HOME/.tmux ]]; then
    move_aside "$HOME/.tmux"
  fi
  git clone --depth=1 https://github.com/gpakosz/.tmux.git "$HOME/.tmux"
else
  log "$HOME/.tmux 已存在，跳过克隆"
fi

if [[ -e $HOME/.tmux.conf && ! -L $HOME/.tmux.conf ]]; then
  move_aside "$HOME/.tmux.conf"
fi
ln -sfn .tmux/.tmux.conf "$HOME/.tmux.conf"
if [[ ! -e $HOME/.tmux.conf.local ]]; then
  cp "$HOME/.tmux/.tmux.conf.local" "$HOME/.tmux.conf.local"
fi

install_mihomo() {
  local dpkg_arch asset_prefix release_json asset_json url digest archive binary expected actual
  dpkg_arch=$(dpkg --print-architecture)
  case "$dpkg_arch" in
    amd64) asset_prefix='mihomo-linux-amd64-v' ;;
    arm64) asset_prefix='mihomo-linux-arm64-v8-v' ;;
    armhf) asset_prefix='mihomo-linux-armv7-v' ;;
    *) die "Mihomo 暂不支持架构：$dpkg_arch" ;;
  esac

  log "查询并安装最新稳定版 Mihomo ($dpkg_arch)"
  release_json=$(mktemp)
  curl -fsSL --retry 3 \
    https://api.github.com/repos/MetaCubeX/mihomo/releases/latest \
    -o "$release_json"
  asset_json=$(jq -c --arg prefix "$asset_prefix" '
    [.assets[]
      | select(.name | startswith($prefix))
      | select(.name | endswith(".gz"))][0]
  ' "$release_json")
  [[ $asset_json != null ]] || die "未找到适合 $dpkg_arch 的 Mihomo 发布包"
  url=$(jq -r '.browser_download_url' <<<"$asset_json")
  digest=$(jq -r '.digest // empty' <<<"$asset_json")
  archive=$(mktemp --suffix=.gz)
  binary=$(mktemp)
  curl -fL --retry 3 "$url" -o "$archive"

  if [[ $digest == sha256:* ]]; then
    expected=${digest#sha256:}
    actual=$(sha256sum "$archive" | awk '{print $1}')
    [[ $actual == "$expected" ]] || die "Mihomo SHA-256 校验失败"
  else
    warn "GitHub API 未返回 SHA-256，无法自动校验发布包"
  fi

  gzip -dc "$archive" >"$binary"
  install -m 0755 "$binary" "$HOME/.local/bin/mihomo"
  rm -f "$release_json" "$archive" "$binary"
  "$HOME/.local/bin/mihomo" -v
}

configure_mihomo() {
  local config_dir state_dir service_dir secret_file secret escaped_url config_file
  config_dir=$HOME/.config/mihomo
  state_dir=$HOME/.local/share/mihomo
  service_dir=$HOME/.config/systemd/user
  secret_file=$config_dir/controller-secret
  config_file=$config_dir/config.yaml

  if [[ -z $MIHOMO_SUBSCRIPTION_URL ]]; then
    if [[ -t 0 ]]; then
      read -rsp '请输入 Clash/Mihomo 订阅地址：' MIHOMO_SUBSCRIPTION_URL
      printf '\n'
    else
      die "非交互运行时必须提供 --subscription-url 或 MIHOMO_SUBSCRIPTION_URL"
    fi
  fi
  [[ $MIHOMO_SUBSCRIPTION_URL == http://* || $MIHOMO_SUBSCRIPTION_URL == https://* ]] || \
    die "订阅地址必须以 http:// 或 https:// 开头"

  mkdir -p "$config_dir" "$state_dir/providers" "$service_dir"
  chmod 700 "$config_dir" "$state_dir"
  if [[ ! -s $secret_file ]]; then
    openssl rand -hex 24 >"$secret_file"
  fi
  chmod 600 "$secret_file"
  secret=$(<"$secret_file")
  escaped_url=${MIHOMO_SUBSCRIPTION_URL//\'/\'\'}

  if [[ -e $config_file ]]; then
    backup_file "$config_file"
  fi
  cat >"$config_file" <<EOF
# managed-by: remote-dev-bootstrap
mixed-port: ${MIHOMO_MIXED_PORT}
allow-lan: false
bind-address: 127.0.0.1
mode: rule
log-level: info
ipv6: false

external-controller: 127.0.0.1:${MIHOMO_CONTROLLER_PORT}
secret: '${secret}'

proxy-providers:
  subscription:
    type: http
    url: '${escaped_url}'
    path: ./providers/subscription.yaml
    interval: 3600
    health-check:
      enable: true
      url: https://www.gstatic.com/generate_204
      interval: 300
      timeout: 5000
      lazy: true

proxy-groups:
  - name: AUTO
    type: url-test
    use:
      - subscription
    url: https://www.gstatic.com/generate_204
    interval: 300
    tolerance: 50

  - name: PROXY
    type: select
    proxies:
      - AUTO
      - DIRECT
    use:
      - subscription

rules:
  - MATCH,PROXY
EOF
  chmod 600 "$config_file"

  cat >"$service_dir/mihomo.service" <<'EOF'
[Unit]
Description=Mihomo proxy service
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=%h/.local/bin/mihomo -d %h/.local/share/mihomo -f %h/.config/mihomo/config.yaml
Restart=on-failure
RestartSec=3
NoNewPrivileges=true
PrivateTmp=true
LimitNOFILE=1048576

[Install]
WantedBy=default.target
EOF

  log "检查 Mihomo 配置"
  "$HOME/.local/bin/mihomo" -t -d "$state_dir" -f "$config_file"

  if systemctl --user daemon-reload && systemctl --user enable --now mihomo; then
    systemctl --user --no-pager --full status mihomo || true
  else
    warn "systemd 用户服务暂不可用；重新登录后执行：systemctl --user enable --now mihomo"
  fi

  if ((ENABLE_LINGER)); then
    if "${SUDO[@]}" loginctl enable-linger "$TARGET_USER"; then
      log "已启用 linger，退出 SSH 后 Mihomo 仍会运行"
    else
      warn "无法启用 linger；需要管理员执行：sudo loginctl enable-linger $TARGET_USER"
    fi
  fi
}

if ((INSTALL_MIHOMO)); then
  install_mihomo
  configure_mihomo
fi

log "安装完成"
cat <<'EOF'

后续操作：
  1. 退出 SSH 并重新登录，让 zsh 成为登录 shell。
  2. Mihomo 状态：mihomo-status
  3. Mihomo 日志：mihomo-log
  4. 单个命令走代理：proxy curl https://api.ipify.org
  5. 当前 shell 全局启用/关闭代理：proxy-on / proxy-off
  6. 单独运行 install-codex.sh 安装 Codex CLI。
EOF
if ((INSTALL_MIHOMO)); then
  cat <<EOF

本地监听：
  mixed proxy  127.0.0.1:${MIHOMO_MIXED_PORT}
  controller   127.0.0.1:${MIHOMO_CONTROLLER_PORT}
EOF
fi
