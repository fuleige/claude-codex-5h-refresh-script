#!/usr/bin/env python3
"""Codex CLI adapter. Only JSON summaries go to stdout; never read auth tokens."""

import argparse
import collections
import json
import os
import selectors
import signal
import subprocess
import tempfile
import time


class RpcError(RuntimeError):
    pass


def stop_process(proc):
    """All CLI children have their own process group, including on timeout."""
    if proc.poll() is None:
        try:
            os.killpg(proc.pid, signal.SIGTERM)
        except ProcessLookupError:
            return
        try:
            proc.wait(timeout=3)
        except subprocess.TimeoutExpired:
            try:
                os.killpg(proc.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            proc.wait()


class AppServer:
    def __init__(self, args):
        self.timeout = args.rpc_timeout
        self.next_id = 0
        self.buffer = b""
        self.messages = collections.deque()
        # No threads are created here, so this process never starts model/tools.
        # auto supports the normal file login and OS keyring login alike.
        self.proc = subprocess.Popen(
            [args.codex, "app-server", "-c", 'model_provider="openai"',
             "-c", 'cli_auth_credentials_store="auto"'],
            cwd=args.work_dir, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL, start_new_session=True,
        )
        self.selector = selectors.DefaultSelector()
        self.selector.register(self.proc.stdout, selectors.EVENT_READ)

    def __enter__(self):
        return self

    def __exit__(self, *unused):
        self.selector.close()
        self.proc.stdin.close()
        stop_process(self.proc)
        self.proc.stdout.close()

    def write(self, message):
        try:
            self.proc.stdin.write((json.dumps(message) + "\n").encode())
            self.proc.stdin.flush()
        except (BrokenPipeError, OSError) as exc:
            raise RpcError("Codex App Server 提前退出，请检查 CLI 版本与配置") from exc

    def read(self, deadline):
        while not self.messages:
            left = deadline - time.monotonic()
            if left <= 0 or not self.selector.select(left):
                raise RpcError("读取 Codex App Server 超时")
            chunk = os.read(self.proc.stdout.fileno(), 65536)
            if not chunk:
                raise RpcError("Codex App Server 提前退出，请检查 CLI 版本与配置")
            self.buffer += chunk
            while b"\n" in self.buffer:
                line, self.buffer = self.buffer.split(b"\n", 1)
                if line.strip():
                    try:
                        message = json.loads(line)
                    except ValueError as exc:
                        raise RpcError("Codex App Server 返回了无效 JSON") from exc
                    if not isinstance(message, dict):
                        raise RpcError("Codex App Server 返回了无效消息")
                    self.messages.append(message)
        return self.messages.popleft()

    def request(self, method, params=None):
        self.next_id += 1
        request_id = self.next_id
        self.write({"id": request_id, "method": method, "params": params or {}})
        deadline = time.monotonic() + self.timeout
        while True:
            message = self.read(deadline)
            # Don't expose any interactive login, token refresh or approval flow.
            if "method" in message:
                if "id" in message:
                    self.write({"id": message["id"], "error": {
                        "code": -32601, "message": "Interactive requests are unsupported"}})
                continue
            if message.get("id") != request_id:
                continue
            if "error" in message:
                error = message["error"]
                raise RpcError("%s: %s" % (method, error.get("message", "RPC error")))
            if not isinstance(message.get("result"), dict):
                raise RpcError("%s 缺少有效结果" % method)
            return message["result"]

    def initialize(self):
        self.request("initialize", {"clientInfo": {
            "name": "codex_5h_refresh", "title": "Codex 5h refresh", "version": "1.0.0"}})
        self.write({"method": "initialized", "params": {}})


def summary(status, message="", window=None):
    window = window or {}
    return {"status": status, "message": message,
            "resets_at": window.get("resetsAt"), "used_percent": window.get("usedPercent")}


def codex_windows(payload):
    """Never mistake another metered bucket (or a weekly window) for Codex 5h."""
    buckets = payload.get("rateLimitsByLimitId") or {}
    bucket = buckets.get("codex")
    if bucket is None:
        bucket = payload.get("rateLimits") or {}
        if bucket.get("limitId") not in (None, "codex"):
            bucket = {}
    windows = []
    for key in ("primary", "secondary"):
        window = bucket.get(key)
        if not isinstance(window, dict):
            continue
        duration, reset, used = (window.get(k) for k in
                                 ("windowDurationMins", "resetsAt", "usedPercent"))
        if (isinstance(duration, (int, float)) and duration > 0
                and type(reset) is int and reset > 0
                and isinstance(used, (int, float)) and 0 <= used <= 100):
            windows.append(window)
    return windows


def five_hour(windows):
    return next((w for w in windows if w["windowDurationMins"] == 300), None)


def quota_decision(windows, grace):
    current = time.time()
    # A longer quota takes precedence: waiting for 5h doesn't restore weekly quota.
    blocked = [w for w in windows if w["usedPercent"] >= 100 and w["resetsAt"] > current]
    long_window = next((w for w in blocked if w["windowDurationMins"] != 300), None)
    if long_window:
        return summary("blocked", "Codex 较长周期额度（如周额度）已用尽，放弃本次触发", five_hour(windows))
    window = five_hour(blocked)
    if window:
        if window["resetsAt"] - current <= grace:
            return summary("align", "Codex 5h 额度已用尽，旧窗口即将结束，等待后再发送", window)
        return summary("blocked", "Codex 5h 额度已用尽，距离重置超过等待上限，放弃本次触发", window)
    return None


def execute(args):
    command = [args.codex, "exec", "--ignore-user-config", "--ephemeral", "--json",
               "--skip-git-repo-check", "--sandbox", "read-only", "--color", "never",
               "-c", 'cli_auth_credentials_store="auto"',
               "-c", 'model_provider="openai"',
               "-c", 'model_reasoning_effort="low"',
               "-c", 'approval_policy="never"',
               "-c", 'web_search="disabled"',
               "-c", "features.shell_tool=false",
               "-c", "features.multi_agent=false",
               "-c", "project_doc_max_bytes=0",
               "-c", 'history.persistence="none"',
               "-c", 'developer_instructions="Reply briefly to the user. Do not use tools."']
    if args.model:
        command.extend(["--model", args.model])
    # Read from stdin so configurable prompts starting with '-' are safe as well.
    command.append("-")
    with tempfile.TemporaryFile() as output:
        proc = subprocess.Popen(command, cwd=args.work_dir, stdin=subprocess.PIPE,
                                stdout=output, stderr=subprocess.STDOUT, start_new_session=True)
        try:
            proc.communicate(args.prompt.encode(), timeout=args.timeout)
        except subprocess.TimeoutExpired:
            return False, "Codex 发送超时，已终止本次调用"
        finally:
            stop_process(proc)
        output.seek(0)
        completed = failed = answered = False
        error = "未收到完整的 turn.completed 和模型回复"
        for line in output:
            try:
                event = json.loads(line)
            except ValueError:
                continue
            if not isinstance(event, dict):
                continue
            kind = event.get("type")
            if kind == "turn.completed":
                completed = True
            elif kind == "item.completed":
                item = event.get("item") or {}
                if item.get("type") == "agent_message" and item.get("text", "").strip():
                    answered = True
            elif kind == "turn.failed":
                failed = True
                error = (event.get("error") or {}).get("message", "turn.failed")
            elif kind == "error":
                error = event.get("message", "Codex error")
        if proc.returncode == 0 and completed and answered and not failed:
            return True, ""
        return False, "Codex 发送失败 (exit %s): %s" % (proc.returncode, error)


def run(args):
    with AppServer(args) as rpc:
        rpc.initialize()
        account = rpc.request("account/read", {"refreshToken": False}).get("account") or {}
        if account.get("type") != "chatgpt":
            return summary("fatal", "需要通过 ChatGPT 登录的 Codex CLI，请先运行 codex login；API key 不适用此策略")
        if args.mode == "check":
            return summary("ok")
        limits = rpc.request("account/rateLimits/read")
        windows = codex_windows(limits)
        decision = quota_decision(windows, args.align_grace)
        if decision:
            return decision
        if limits.get("ordinaryUsageAllowed") is False:
            return summary("blocked", "服务端当前不允许使用套餐额度，放弃本次触发", five_hour(windows))
        success, message = execute(args)
        try:
            windows = codex_windows(rpc.request("account/rateLimits/read"))
        except RpcError:
            # A completed inference must not be replayed because a later probe failed.
            if success:
                return summary("ok", "已发送，但随后查询额度失败，无法确认 5h 窗口时间")
            return summary("error", message)
        if success:
            return summary("ok", window=five_hour(windows))
        return quota_decision(windows, args.align_grace) or summary("error", message)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mode", choices=("check", "send"))
    parser.add_argument("--codex", required=True)
    parser.add_argument("--work-dir", required=True)
    parser.add_argument("--model", default="")
    parser.add_argument("--prompt", default="Reply with exactly: ok")
    parser.add_argument("--timeout", type=int, default=180)
    parser.add_argument("--rpc-timeout", type=int, default=30)
    parser.add_argument("--align-grace", type=int, default=900)
    args = parser.parse_args()
    def interrupted(signum, frame):
        raise SystemExit(128 + signum)
    signal.signal(signal.SIGTERM, interrupted)
    signal.signal(signal.SIGHUP, interrupted)
    try:
        result = run(args)
    except (RpcError, OSError, ValueError) as exc:
        result = summary("error", str(exc))
    # No raw CLI output, account email, tokens, or model messages are logged.
    result["message"] = " ".join(str(result["message"]).split())[:500]
    print(json.dumps(result, ensure_ascii=False))
    return 0 if result["status"] in ("ok", "align") else 1


if __name__ == "__main__":
    raise SystemExit(main())
