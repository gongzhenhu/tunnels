# 隧道命令：交给菜单栏 Tunnels.app 托管，命令连上就返回，不再占着终端
# 用法同原来；状态、重连、端口冲突都在菜单栏里看

# tun70 [服务器端口] [本地端口]：banma-70 服务器端口 → 本地（默认 14725 → Clash 7890）
tun70() { tunnel reverse banma-70 "${1:-14725}" "${2:-7890}"; }

# tun70off [端口]：只关 App 托管的反向隧道，不会误杀别的 autossh
tun70off() { tunnel off reverse banma-70 "$@"; }

# forward70 <本地端口> [服务器端口]：本地 → banma-70 服务器端口
forward70() {
  [[ -z "$1" ]] && { echo "用法: forward70 <本地端口> [服务器端口]" >&2; return 1; }
  tunnel forward banma-70 "$1" "${2:-$1}"
}

# forward70off [端口]：不带端口关全部，带端口只关那一条
forward70off() { tunnel off forward banma-70 "$@"; }
