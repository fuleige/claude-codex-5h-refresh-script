# claude-codex-5h-refresh-script

每天在固定的北京时间给 Claude Code 发一条极短的消息，让 5 小时用量窗口从这些时间点开始计时。Codex 的脚本之后会加进来。

默认在 06:00、11:00、16:00 触发，窗口就是 6–11、11–16、16–21 首尾相接，白天能多拿到一次重置。

| 脚本 | 说明 |
| --- | --- |
| `claude-5h-refresh.sh` | Claude Code |
| Codex | 待添加 |

## 依赖

- bash、curl
- 已登录的 `claude` CLI
- 一个 HTTP(S) 代理（能直连的机器用 `--proxy direct`）

不依赖 cron、systemd 或其他服务，后台进程就是脚本自己。

## 快速开始

```bash
./claude-5h-refresh.sh start --proxy http://127.0.0.1:7890  # 检查代理，保存配置，启动后台进程
./claude-5h-refresh.sh enable-autostart                      # 可选：在 ~/.bashrc 里加入自启
./claude-5h-refresh.sh status                                # 查看状态和下次触发时间
```

## 命令

| 命令 | 作用 |
| --- | --- |
| `start [--proxy URL]` | 检查代理（不通会在终端里询问），保存配置，启动后台进程 |
| `stop` / `restart` | 停止 / 重启 |
| `status` | 运行状态、下次触发时间、最近日志 |
| `test [--proxy URL]` | 立即发送一次，验证整条链路 |
| `check-proxy [--proxy URL]` | 只检查代理 |
| `logs [行数]` | 查看日志 |
| `enable-autostart` / `disable-autostart` | 在 `~/.bashrc` 里加入 / 移除自启 |

## 工作方式

- **时区**：按 UTC+8 计算触发时间（Asia/Shanghai 没有夏令时），与本机时区设置无关，也不需要 tzdata。
- **代理检查**：先确认代理端口已开启，再经代理访问 `https://www.google.com/generate_204`，两步都通过才继续。启动时和每次触发前都会检查，触发时不通会每分钟重试，最多 15 次。
- **发送**：在干净的环境里用 Haiku 发一句话，不加载用户设置、MCP 和工具，不保存会话记录。每次开销极小。
- **窗口对齐**：从输出里读取 5h 窗口的重置时间。如果消息落进了 15 分钟内就要结束的旧窗口，等它结束后再发一次。
- **补发**：后台进程启动时，30 分钟内刚错过的触发点会立即补发。
- **自启**：`enable-autostart` 会在 `~/.bashrc` 末尾加一段，打开交互 shell 时如果后台进程没在运行就静默拉起。适合没有 systemd 的容器。

## 配置

配置、日志和状态放在 `~/.claude-5h-refresh/`（可用环境变量 `CLAUDE_5H_HOME` 修改）。`config.env` 可以手动编辑，后台进程每轮都会重新读取，不用重启。

| 变量 | 默认值 | 说明 |
| --- | --- | --- |
| `SLOTS` | `06:00 11:00 16:00` | 北京时间触发点，空格分隔 |
| `MODEL` | `haiku` | 发送消息用的模型 |
| `PROMPT` | `Reply with exactly: ok` | 发送的内容 |
| `PROXY_URL` | | 代理地址，或 `direct` |
| `CATCHUP_SECONDS` | `1800` | 启动时补发的时间范围 |
| `ALIGN_GRACE_SECONDS` | `900` | 窗口对齐的等待上限 |
| `PROXY_RETRIES` | `15` | 触发时代理不通的重试次数 |
| `SEND_RETRIES` | `3` | 发送失败的重试次数 |

## 注意

- 只在 Linux 上测试过。
- 用了 `~/.bashrc` 自启的话，容器重启后要打开一次交互终端，后台进程才会被拉起。
