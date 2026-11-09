# Tunnels

macOS 菜单栏 SSH 隧道管理。替代 `~/.zshrc` 里的 `tun70` / `forward70` 系列命令。

- 每条隧道单独开关，状态实时可见：已连接 / 连接中 / 重连中（附原因）/ 失败
- App 自己监管 ssh 进程：断线指数退避重连，网络恢复、睡眠唤醒后立即重连
- 端口冲突给出明确原因；被外部进程占用时直接指出是哪个进程，可一键结束
- 反向隧道持续检测本地目标端口（如 Clash 7890），没在监听时标黄
- 新建转发时列出服务器上的监听端口，你自己的进程排在前面
- 识别不是本 App 起的 ssh/autossh 隧道，可单独结束或接管
- 主机取自 `~/.ssh/config`，复用其中的密钥、跳板、Keychain 设置；需要免密登录。被 ProxyJump / ProxyCommand 引用的跳板机不出现在主机列表里，其他不想看到的主机用 `tunnel hide` 隐藏
- 开机启动，并恢复上次开着的隧道

## 安装

```sh
./scripts/install.sh
```

编译后装到 `~/Applications/Tunnels.app`，命令行入口链接到 `~/.local/bin/tunnel`。只需要 Command Line Tools，不需要 Xcode。

## 命令行

```
tunnel forward <主机> <本地端口> [服务器端口]
tunnel reverse <主机> <服务器端口> [本地端口]
tunnel off [forward|reverse] [主机] [端口]
tunnel rm  [forward|reverse] [主机] [端口]
tunnel ls
tunnel hide <主机>    # 在新建隧道的主机列表里隐藏；unhide 恢复
```

App 没开时命令会自动拉起它。`shell/tunnels.zsh` 是基于它重写的 `tun70` / `forward70` 系列函数。

## 文件

| 路径 | 内容 |
|---|---|
| `~/Library/Application Support/Tunnels/tunnels.json` | 隧道列表和开关状态 |
| `~/Library/Application Support/Tunnels/control.sock` | 命令行与 App 通信 |

App 起的 ssh 进程带 `-o Tag=tunnels-app`，App 异常退出后下次启动会清理残留。

## 开发用工具

`scripts/` 下几个排查界面问题的小工具，用 `swiftc -O scripts/<名字>.swift -o build/<名字>` 编译：

| 工具 | 用途 |
|---|---|
| `ax [open] [keep] [press <标签前缀>]` | 读取菜单的辅助功能树，即 VoiceOver 实际读到的标签；可按标签按下按钮 |
| `click <x> <y>` | 在屏幕坐标发送一次真实鼠标点击 |
| `windows [次数]` | 每 0.2 秒打印菜单窗口的位置和尺寸 |

`tunnel _snapshot <路径> [dark] [add] [all] [expand] [edit]` 把菜单离屏渲染成 PNG。会抢走菜单焦点，只在菜单关闭时使用。
