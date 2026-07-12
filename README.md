# Remote Linux development bootstrap

用于无桌面 Ubuntu/Debian 远程服务器的开发环境配置脚本。安装分成两个阶段：基础环境
完全就绪后，再单独安装和登录 Codex CLI。

## 包含内容

### 基础环境

- Zsh、Oh My Zsh
- tmux、[gpakosz/.tmux](https://github.com/gpakosz/.tmux)
- Mihomo 用户级 systemd 服务及自动订阅更新
- Neovim、htop、nvtop（仓库可用时）、ripgrep、fd、tree、rsync、wget、zip/unzip
- Git LFS
- GCC/G++、CMake、Ninja、pkg-config
- Python 3 开发头文件、pip、venv
- FFmpeg、ImageMagick
- OpenCV/PyTorch 等无桌面环境常用的 OpenGL/X11 运行库

### Codex 环境

- OpenAI Codex CLI 官方安装器
- 自动发现 Mihomo mixed port
- 支持显式代理或强制直连
- `proxy`、`proxy-on`、`proxy-off`、`codex-proxy` 辅助命令

## 第一阶段：基础环境

把两个脚本复制到远程服务器，以目标普通用户执行。不要对整个脚本使用 `sudo`：

```bash
chmod +x bootstrap-remote.sh install-codex.sh

MIHOMO_SUBSCRIPTION_URL='你的 Clash/Mihomo 订阅地址' \
  ./bootstrap-remote.sh
```

也可以交互输入订阅地址：

```bash
./bootstrap-remote.sh
```

基础脚本默认只在 `127.0.0.1` 监听：

- HTTP/SOCKS mixed proxy：`7890`
- Mihomo controller：`9090`

订阅地址保存在 `~/.config/mihomo/config.yaml`，权限为 `600`。Mihomo 数据位于
`~/.local/share/mihomo`，服务定义位于 `~/.config/systemd/user/mihomo.service`。

基础环境完成后，退出 SSH 并重新登录，让 Zsh 和新的 `PATH` 生效。

## 第二阶段：Codex CLI

```bash
./install-codex.sh
```

脚本默认读取 Mihomo 配置并通过代理安装。也可以覆盖：

```bash
./install-codex.sh --proxy http://127.0.0.1:7890
./install-codex.sh --no-proxy
```

首次运行时按照官方提示完成账户登录：

```bash
codex-proxy
```

## 常用命令

```bash
proxy git clone https://github.com/example/project.git
proxy curl https://api.ipify.org

proxy-on
proxy-off

mihomo-status
mihomo-log
```

## 选项

```bash
./bootstrap-remote.sh --help
./install-codex.sh --help
```

基础脚本支持跳过 Mihomo：

```bash
./bootstrap-remote.sh --skip-mihomo
```

## 安全与幂等

- 代理端口和 controller 不对公网开放。
- Mihomo 作为当前用户运行，不以 root 运行。
- 配置中的订阅 URL 按密钥处理，不输出到日志。
- 现有 `.zshrc`、tmux 或 Mihomo 配置在替换前会生成时间戳备份。
- 重复执行不会重复插入 Zsh 辅助函数。
- Codex 登录凭据由 Codex 自己管理，脚本不会读取或保存凭据。

如果服务器开始时无法访问 GitHub，可先导出已有代理的 `HTTP_PROXY`、
`HTTPS_PROXY` 和 `ALL_PROXY` 后运行基础脚本；`curl` 与 `git` 会继承这些变量。
