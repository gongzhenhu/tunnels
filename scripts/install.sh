#!/bin/zsh
# 编译并安装到 ~/Applications/Tunnels.app，命令行入口链接到 ~/.local/bin/tunnel
set -euo pipefail
cd "${0:A:h}/.."

swift build -c release

APP="$HOME/Applications/Tunnels.app"
STAGE="build/Tunnels.app"
rm -rf "$STAGE"
mkdir -p "$STAGE/Contents/MacOS"
cp .build/release/Tunnels "$STAGE/Contents/MacOS/"
cp Resources/Info.plist "$STAGE/Contents/"
codesign --force --sign - "$STAGE"

# 退出正在运行的旧版本（隧道开关状态会保留，新版本启动后自动恢复）
osascript -e 'quit app id "dev.tunnels.menubar"' 2>/dev/null || true
for _ in {1..20}; do pgrep -f "$APP/Contents/MacOS/Tunnels" >/dev/null || break; sleep 0.2; done

mkdir -p "$HOME/Applications" "$HOME/.local/bin"
rm -rf "$APP"
cp -R "$STAGE" "$APP"
ln -sf "$APP/Contents/MacOS/Tunnels" "$HOME/.local/bin/tunnel"

open "$APP"
echo "✅ 已安装：$APP"
echo "   命令行：tunnel help"
