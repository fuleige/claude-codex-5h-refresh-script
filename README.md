# claude-codex-5h-refresh-script

每天在固定的北京时间给 Claude Code / Codex CLI 发一条极短的消息，尝试让自然恢复后的 5 小时用量窗口从这些时间点开始计时。

默认在 **06:00、11:00、16:00（UTC+8）** 触发，目标窗口为 6–11、11–16、16–21。实际窗口和额度由服务端决定；已经开始的窗口不能被消息提前重置，也不会增加套餐额度或绕过周限额。

调度按每天固定时间点运行，不是从进程启动时开始每隔 5 小时循环发送。默认 16:00 之后的下一个触发点是次日 06:00，可通过 `SLOTS` 调整。

| 脚本 | 说明 |
| --- | --- |
| `claude-5h-refresh.sh` | Claude Code，原有实现 |
| `codex-5h-refresh.sh` | Codex CLI，使用 ChatGPT 登录和服务端额度查询 |

不依赖 cron、systemd，后台进程由脚本自己管理。两个脚本可以独立运行，分别保存配置、日志和状态。

## 依赖

- 共用：Linux、bash、curl；HTTP(S) 代理，或能直连时使用 `--proxy direct`。
- Claude：已登录的 `claude` CLI。
- Codex：Python **3.8+**、`flock` 和 `setsid`（通常由 Linux 的 `util-linux` 提供），以及已通过 **ChatGPT 登录**的 `codex` CLI。Python 只使用标准库，无需 pip 安装。
- Codex CLI 必须支持 `exec --ignore-user-config`、`--ephemeral` 和 App Server 的 `account/read`、`account/rateLimits/read`。本次通过 CLI **0.165.0** 验证，脚本会检查必需的 exec 参数，旧版需先升级。

复制 Codex 脚本到其他机器时，需要同时保留同目录下的 `lib/codex_refresh.py`。

## 快速开始

Claude：

```bash
./claude-5h-refresh.sh start --proxy http://127.0.0.1:7890
./claude-5h-refresh.sh enable-autostart  # 可选
./claude-5h-refresh.sh status
```

Codex：

```bash
codex login  # 选择 ChatGPT 登录；已经登录可跳过
./codex-5h-refresh.sh test --proxy http://127.0.0.1:7890
./codex-5h-refresh.sh start
./codex-5h-refresh.sh enable-autostart  # 可选
./codex-5h-refresh.sh status
```

能直连的机器，首次运行改用 `./codex-5h-refresh.sh test --proxy direct`。`test` 会实际消耗一次极短回复的额度；旧窗口即将结束时，可能等待最多 15 分钟再补发一次。

## 命令

两个脚本使用同样的命令，将下表命令接在脚本名之后即可。

| 命令 | 作用 |
| --- | --- |
| `start [--proxy URL]` | 检查代理，保存配置，启动后台进程；Codex 还会检查 ChatGPT 登录 |
| `stop` / `restart` | 停止 / 重启；`restart` 支持 `--proxy URL` |
| `status` | 运行状态、配置、下次触发时间、最近日志；不发送消息 |
| `test [--proxy URL]` | 立即发送一次，验证整条链路 |
| `check-proxy [--proxy URL]` | 只检查代理 |
| `logs [行数]` | 查看日志 |
| `enable-autostart` / `disable-autostart` | 在 `~/.bashrc` 里加入 / 移除自启 |
| `ensure` | 已配置且未运行时静默启动，供 `.bashrc` 使用 |

## 调度与代理

- **时区**：固定按 UTC+8 计算，与本机时区无关，不依赖 tzdata。
- **代理检查**：先检查端口，再访问 `https://www.google.com/generate_204`。该检查只确认基础连通性，Codex 的服务访问和登录问题仍可能在发送时出现。支持 HTTP(S) 代理或 `direct`。
- **重试**：每次触发前检查代理，默认每分钟重试，最多 15 次。普通发送错误最多尝试 3 次。
- **补发**：后台进程启动时，30 分钟内刚错过的触发点会立即补发。同一个触发点会记录为已处理，发送失败后也不会在守护循环中无限重复；可用 `test` 手动重试。
- **自启**：`enable-autostart` 写入 `~/.bashrc`，打开交互 shell 时检查并拉起后台进程。机器或容器重启后，需要打开一次交互终端。

### 如何判断是否已触发

脚本分别记录计划时间点是否已处理、消息是否发送成功，以及服务端的窗口时间：

| 检查 | 判断依据 | 含义 |
| --- | --- | --- |
| 计划时间点是否已处理 | 本地 `last_slot` | 守护进程在执行前记录该时间点，避免重复处理；不代表消息已经发送成功 |
| Codex 消息是否发送成功 | CLI 正常退出、收到 `turn.completed` 和模型回复，且没有 `turn.failed` | 确认这次消息完成，失败原因写入 `refresh.log` |
| 是否落进即将结束的旧窗口 | 服务端返回的 5 小时窗口重置时间 `resetsAt` | 判断是否需要等待后补发，不把一次成功回复直接当作新窗口已开启 |

普通发送错误在本次触发内最多尝试 `SEND_RETRIES` 次。尝试结束后，该计划时间点仍保留为已处理；守护循环不会再次执行这个时间点。`test` 可手动重试，不修改 `last_slot`。

## Codex 的窗口策略

1. 通过官方 `codex app-server` 的 stdio JSON-RPC 接口检查账户，确认是 ChatGPT 登录，再读取额度。API key 登录不适用订阅窗口策略，会在发送前停止。
2. 优先读取 `rateLimitsByLimitId.codex`，兼容旧版 `rateLimits`；只把 `windowDurationMins=300` 识别为 5 小时窗口，按服务端 `resetsAt` 计算等待时间。
3. 5 小时额度用尽且距离重置超过 `ALIGN_GRACE_SECONDS`，或者较长周期额度（如周额度）用尽，本次结束。若服务端明确返回不允许使用套餐额度，也会停止。
4. 5 小时额度已用尽，但旧窗口将在 15 分钟内结束，则先等待到重置时间后 30 秒再发送。如果额度尚可用，则先发一条极短消息，随后重新查询窗口；落进即将结束的旧窗口时，同样等到结束后补发一次。
5. 每次触发最多进行一次窗口对齐。服务端未返回明确的 5 小时窗口时，只记录无法确认，不推算一个新的重置时间。消息发送成功但后续额度查询失败，也不会因此重复发送。

发送阶段使用 `codex exec --ignore-user-config --ephemeral --json`，在独立工作目录中运行，使用只读沙箱，关闭命令执行和网页搜索，不加载用户 `config.toml`，不保存会话记录。默认使用低推理强度和一句 `Reply with exactly: ok`。脚本不会继承 API key 或调用方会话变量；登录凭据的读取与刷新交由 Codex CLI 自己处理。

Codex 用进程锁避免守护进程重复启动，并用发送锁避免 `test` 与定时发送同时执行。`stop` 会终止本脚本的等待和发送子进程。

官方协议与参数：[App Server](https://learn.chatgpt.com/docs/app-server)、[CLI 参考](https://learn.chatgpt.com/docs/developer-commands?surface=cli)、[登录方式](https://learn.chatgpt.com/docs/auth)。不同套餐的窗口规则可能变化，以[官方额度说明](https://learn.chatgpt.com/docs/pricing)与账号实际返回为准。

## 配置

| 用途 | Claude | Codex |
| --- | --- | --- |
| 默认状态目录 | `~/.claude-5h-refresh/` | `~/.codex-5h-refresh/` |
| 自定义状态目录环境变量 | `CLAUDE_5H_HOME` | `CODEX_5H_HOME` |
| CLI 路径配置 | `CLAUDE_BIN` | `CODEX_BIN` |

状态目录内包含 `config.env`、`refresh.log` 和运行状态文件。`config.env` 是 Bash 配置文件，只应填写自己信任的内容；守护进程每轮读取，修改后可 `restart` 使新时间点立即生效。

共用配置：

| 变量 | 默认值 | 说明 |
| --- | --- | --- |
| `SLOTS` | `06:00 11:00 16:00` | 北京时间，空格分隔的 HH:MM |
| `PROMPT` | `Reply with exactly: ok` | 发送的内容 |
| `PROXY_URL` | 空 | 代理地址或 `direct`；首次通过检查后保存 |
| `CATCHUP_SECONDS` | `1800` | 启动时补发范围 |
| `ALIGN_GRACE_SECONDS` | `900` | 旧窗口对齐的等待上限 |
| `PROXY_RETRIES` | `15` | 代理检查最多尝试次数 |
| `SEND_RETRIES` | `3` | 普通发送错误最多尝试次数 |
| `LOG_MAX_BYTES` | `1048576` | 超过后保留最近 3000 行 |

Codex 配置：

| 变量 | 默认值 | 说明 |
| --- | --- | --- |
| `MODEL` | 空字符串 | 使用 Codex CLI 内置默认模型；不继承用户 `config.toml` 的模型。也可填写自己账号可用、使用 Codex 额度的模型 |
| `CODEX_AUTH_HOME` | 首次运行时的 `$CODEX_HOME`，未设置则 `~/.codex` | Codex 登录目录，绝对路径；保存后后台运行和自启使用同一目录 |
| `SEND_TIMEOUT_SECONDS` | `180` | 单次 Codex 消息调用超时，秒 |
| `RPC_TIMEOUT_SECONDS` | `30` | 单次 App Server 查询超时，秒 |
| `RETRY_SECONDS` | `60` | 代理和普通发送错误的重试间隔，秒 |

Claude 的 `MODEL` 默认仍为 `haiku`，原有发送和窗口解析逻辑保持不变。

如果要指定 Codex 模型，可以编辑 `~/.codex-5h-refresh/config.env` 中的 `MODEL`。使用非默认模型时，应确认它消耗的是脚本查询的 `codex` 额度桶；脚本不会根据其他额度桶推断窗口。

## 验证

```bash
bash -n codex-5h-refresh.sh
python3 -m unittest discover -s tests -v
```

自动测试使用模拟 CLI，覆盖窗口解析、限流、错误/超时、环境隔离、跨日调度、补发、进程锁、自启配置和发送过程中的停止清理，不消耗真实额度。

本版本的 26 项自动测试及 Bash 语法检查已通过，并在 Codex CLI 0.165.0 上完成了 ChatGPT 登录检查、真实额度查询及一次 `gpt-6-luna` 短消息发送验证。旧窗口等待和补发分支由模拟测试验证。
