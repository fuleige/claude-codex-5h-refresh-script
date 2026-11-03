"""Offline tests: fake the official CLI boundary, never spend real account quota."""

import datetime
import importlib.util
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time
import unittest


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "codex-5h-refresh.sh"
HELPER = ROOT / "lib/codex_refresh.py"
SPEC = importlib.util.spec_from_file_location("codex_refresh", HELPER)
ADAPTER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(ADAPTER)

FAKE_CODEX = r'''#!/usr/bin/env python3
import json, os, sys, time
from pathlib import Path
base = Path(__file__).resolve().parent
scenario = json.loads((base / "scenario.json").read_text())
def record(value):
    with (base / "calls.jsonl").open("a") as f:
        f.write(json.dumps(value) + "\n")
def emit(value):
    print(json.dumps(value), flush=True)
if "--help" in sys.argv:
    print("--ignore-user-config --ephemeral")
    sys.exit(0)
if sys.argv[1] == "exec":
    record({"exec": sys.argv[2:], "prompt": sys.stdin.read(), "pid": os.getpid(),
            "env": {k: v for k, v in os.environ.items()
                    if k in ("OPENAI_API_KEY", "CODEX_API_KEY", "CODEX_HOME", "HTTPS_PROXY", "ALL_PROXY")}})
    time.sleep(scenario.get("exec_sleep", 0))
    for event in scenario.get("events", [
        {"type": "item.completed", "item": {"type": "agent_message", "text": "ok"}},
        {"type": "turn.completed", "usage": {"input_tokens": 1, "output_tokens": 1}}
    ]):
        emit(event)
    sys.exit(scenario.get("exit_code", 0))
count = 0
for line in sys.stdin:
    req = json.loads(line)
    method = req.get("method")
    record({"method": method, "pid": os.getpid()})
    if "id" not in req:
        continue
    if method == "initialize":
        emit({"id": req["id"], "result": {"userAgent": "test"}})
    elif method == "account/read":
        emit({"id": req["id"], "result": {"account": {"type": scenario.get("auth", "chatgpt")}}})
    elif method == "account/rateLimits/read":
        count += 1
        time.sleep(scenario.get("rpc_sleep", 0))
        # Notifications interleave with responses, with arbitrary JSON whitespace.
        emit({"method": "account/rateLimits/updated", "params": {}})
        if scenario.get("probe_error") or (count > 1 and scenario.get("post_error")):
            emit({"id": req["id"], "error": {"code": -1, "message": "offline"}})
        else:
            payload = scenario.get("after") if count > 1 and "after" in scenario else scenario["before"]
            emit({"id": req["id"], "result": payload})
'''


def window(minutes=300, used=1, left=18000):
    return {"windowDurationMins": minutes, "usedPercent": used, "resetsAt": int(time.time()) + left}


def limits(primary=None, secondary=None):
    return {"rateLimits": {"primary": primary, "secondary": secondary}}


class CodexTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="codex-5h-test-")
        self.base = Path(self.temp.name)
        self.fake = self.base / "codex"
        self.fake.write_text(FAKE_CODEX)
        self.fake.chmod(0o755)
        self.scenario = {"before": limits(window())}
        self.env = dict(os.environ, CODEX_5H_HOME=str(self.base / "state"))

    def tearDown(self):
        self.temp.cleanup()

    def write_scenario(self):
        (self.base / "scenario.json").write_text(json.dumps(self.scenario))

    def calls(self):
        path = self.base / "calls.jsonl"
        return [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []

    def helper(self, *extra):
        self.write_scenario()
        proc = subprocess.run([sys.executable, str(HELPER), "send", "--codex", str(self.fake),
                               "--work-dir", str(self.base), *extra], text=True, capture_output=True, timeout=12)
        self.assertEqual(proc.stderr, "")
        return json.loads(proc.stdout), proc.returncode

    def shell(self, code):
        self.write_scenario()
        return subprocess.run(["bash", "-c", 'source "$1"; ' + code, "test", str(SCRIPT), str(self.fake)],
                              env=self.env, text=True, capture_output=True, timeout=12)

    def assert_no_send(self):
        self.assertFalse(any("exec" in call for call in self.calls()))

    def test_success_and_post_send_window(self):
        after = window(left=17900)
        self.scenario["after"] = limits(after)
        result, rc = self.helper()
        self.assertEqual((result["status"], rc, result["resets_at"]), ("ok", 0, after["resetsAt"]))
        call = next(c for c in self.calls() if "exec" in c)
        self.assertIn("--ignore-user-config", call["exec"])
        self.assertIn("--ephemeral", call["exec"])
        self.assertEqual(call["prompt"], "Reply with exactly: ok")

    def test_map_prefers_codex_over_other_buckets(self):
        expected = window()
        self.scenario["before"] = {"rateLimits": {"primary": window(used=100)},
                                    "rateLimitsByLimitId": {"codex": {"primary": expected},
                                                           "other": {"primary": window(used=100)}}}
        result, rc = self.helper()
        self.assertEqual((result["status"], rc, result["resets_at"]), ("ok", 0, expected["resetsAt"]))

    def test_five_hour_can_be_secondary(self):
        self.scenario["before"] = limits(window(10080), window())
        result, _ = self.helper()
        self.assertIsNotNone(result["resets_at"])

    def test_weekly_exhaustion_wins_over_expiring_five_hour(self):
        self.scenario["before"] = limits(window(used=100, left=10), window(10080, 100, 86400))
        result, rc = self.helper()
        self.assertEqual((result["status"], rc), ("blocked", 1))
        self.assert_no_send()

    def test_exhausted_near_reset_waits_without_sending(self):
        self.scenario["before"] = limits(window(used=100, left=20))
        result, rc = self.helper()
        self.assertEqual((result["status"], rc), ("align", 0))
        self.assert_no_send()

    def test_exhausted_far_reset_stops(self):
        self.scenario["before"] = limits(window(used=100, left=5000))
        result, rc = self.helper()
        self.assertEqual((result["status"], rc), ("blocked", 1))
        self.assert_no_send()

    def test_explicit_backend_denial_stops(self):
        self.scenario["before"]["ordinaryUsageAllowed"] = False
        result, rc = self.helper()
        self.assertEqual((result["status"], rc), ("blocked", 1))
        self.assert_no_send()

    def test_api_key_login_is_rejected_before_inference(self):
        self.scenario["auth"] = "apiKey"
        result, rc = self.helper()
        self.assertEqual((result["status"], rc), ("fatal", 1))
        self.assert_no_send()

    def test_no_five_hour_window_is_not_invented(self):
        self.scenario["before"] = limits(window(10080))
        result, rc = self.helper()
        self.assertEqual((result["status"], rc, result["resets_at"]), ("ok", 0, None))

    def test_other_bucket_is_not_used_as_codex(self):
        self.scenario["before"] = {"rateLimits": {"limitId": "other", "primary": window()}}
        result, _ = self.helper()
        self.assertIsNone(result["resets_at"])

    def test_failed_probe_does_not_send(self):
        self.scenario["probe_error"] = True
        result, rc = self.helper()
        self.assertEqual((result["status"], rc), ("error", 1))
        self.assert_no_send()

    def test_failed_post_probe_preserves_success_without_stale_window(self):
        self.scenario["post_error"] = True
        result, rc = self.helper()
        self.assertEqual((result["status"], rc, result["resets_at"]), ("ok", 0, None))
        self.assertEqual(sum("exec" in c for c in self.calls()), 1)

    def test_nonzero_exit_is_not_success(self):
        self.scenario["exit_code"] = 1
        result, rc = self.helper()
        self.assertEqual((result["status"], rc), ("error", 1))

    def test_failed_turn_is_not_success(self):
        self.scenario["events"] = [{"type": "turn.failed", "error": {"message": "offline"}}]
        result, rc = self.helper()
        self.assertEqual((result["status"], rc), ("error", 1))

    def test_start_notification_alone_is_not_success(self):
        self.scenario["events"] = [{"type": "thread.started", "thread_id": "test"}]
        result, rc = self.helper()
        self.assertEqual((result["status"], rc), ("error", 1))

    def test_rate_limit_race_is_detected_after_failure(self):
        self.scenario["events"] = [{"type": "turn.failed", "error": {"message": "rate limit"}}]
        self.scenario["after"] = limits(window(used=100, left=15))
        result, rc = self.helper()
        self.assertEqual((result["status"], rc), ("align", 0))

    def test_exec_timeout_terminates_cli(self):
        self.scenario["exec_sleep"] = 20
        result, rc = self.helper("--timeout", "1")
        self.assertEqual((result["status"], rc), ("error", 1))
        self.assertIn("超时", result["message"])
        for call in self.calls():
            with self.assertRaises(ProcessLookupError):
                os.kill(call["pid"], 0)

    def test_rpc_timeout_terminates_cli(self):
        self.scenario["rpc_sleep"] = 20
        result, rc = self.helper("--rpc-timeout", "1")
        self.assertEqual((result["status"], rc), ("error", 1))
        self.assert_no_send()

    def test_clean_environment_and_custom_codex_home(self):
        self.env.update(OPENAI_API_KEY="must-not-be-inherited", CODEX_API_KEY="must-not-be-inherited",
                        ALL_PROXY="must-not-be-inherited")
        result = self.shell('CODEX_BIN="$2"; CODEX_AUTH_HOME="$STATE_DIR/auth"; PROXY_URL=direct; run_codex send')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout)["status"], "ok")
        call = next(c for c in self.calls() if "exec" in c)
        self.assertEqual(call["env"], {"CODEX_HOME": str(self.base / "state/auth")})

    def test_slot_calculation_crosses_midnight_with_unsorted_slots(self):
        now = int(datetime.datetime(2026, 11, 3, 16, 5, tzinfo=datetime.timezone.utc).timestamp())
        result = self.shell('SLOTS="16:00 06:00 11:00"; prev_slot %d; next_slot %d' % (now, now))
        values = [int(v) for v in result.stdout.splitlines()]
        self.assertEqual(values, [now - (8 * 3600 + 5 * 60), now + (6 * 3600 - 5 * 60)])

    def test_invalid_config_is_rejected(self):
        for config in ('SLOTS="25:00"', 'SLOTS="   "', 'SEND_RETRIES=0', 'ALIGN_GRACE_SECONDS=-1'):
            with self.subTest(config=config):
                result = self.shell(config + '; load_config')
                self.assertNotEqual(result.returncode, 0)

    def test_alignment_retries_at_most_once(self):
        result = self.shell('''
            now() { echo 1000; }
            wait_proxy() { return 0; }
            count=0
            send_once() { count=$((count + 1)); LAST_RESET=1100; LAST_USED=1; echo "send:$count"; return 0; }
            sleep_until() { echo "wait:$1"; }
            trigger test
        ''')
        self.assertEqual(result.returncode, 1)
        self.assertEqual(result.stdout.splitlines(), ["send:1", "wait:1130", "send:2"])

    def test_exhausted_alignment_waits_before_first_send(self):
        result = self.shell('''
            now() { echo 1000; }
            wait_proxy() { return 0; }
            count=0
            send_once() {
              count=$((count + 1)); echo "attempt:$count"
              if [ "$count" = 1 ]; then LAST_RESET=1100; return 2; fi
              LAST_RESET=19000; return 0
            }
            sleep_until() { echo "wait:$1"; }
            trigger test
        ''')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.splitlines(), ["attempt:1", "wait:1130", "attempt:2"])

    def test_send_lock_prevents_concurrent_trigger(self):
        result = self.shell('''
            mkdir -p "$STATE_DIR"
            exec 7>"$SEND_LOCK"; flock -n 7
            trigger test
        ''')
        self.assertEqual(result.returncode, 1)
        self.assertIn("已有触发", result.stderr)

    def test_autostart_is_idempotent_and_removable(self):
        result = self.shell('''
            BASHRC="$STATE_DIR.bashrc"
            enable_autostart; enable_autostart
            [ "$(grep -cF "$MARK_BEGIN" "$BASHRC")" = 1 ] || exit 2
            disable_autostart
            ! grep -qF "$MARK_BEGIN" "$BASHRC"
        ''')
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_daemon_catchup_stop_cleans_up_active_codex(self):
        self.scenario["exec_sleep"] = 30
        self.write_scenario()
        curl = self.base / "curl"
        curl.write_text("#!/bin/sh\nprintf 204\n")
        curl.chmod(0o755)
        env = dict(self.env, PATH=str(self.base) + os.pathsep + os.environ["PATH"])
        state = self.base / "state"
        state.mkdir()
        slot = time.strftime("%H:%M", time.gmtime(time.time() + 8 * 3600))
        (state / "config.env").write_text(
            "CODEX_BIN='%s'\nPROXY_URL=direct\nSLOTS='%s'\nSEND_TIMEOUT_SECONDS=60\n" % (self.fake, slot))
        def command(name):
            return subprocess.run([str(SCRIPT), name], env=env, text=True, capture_output=True, timeout=12)
        try:
            started = command("start")
            self.assertEqual(started.returncode, 0, started.stdout + started.stderr)
            deadline = time.monotonic() + 5
            while time.monotonic() < deadline and not any("exec" in c for c in self.calls()):
                time.sleep(0.05)
            self.assertTrue(any("exec" in c for c in self.calls()), (state / "refresh.log").read_text())
            stopped = command("stop")
            self.assertEqual(stopped.returncode, 0, stopped.stderr)
            self.assertFalse((state / "daemon.pid").exists())
            deadline = time.monotonic() + 5
            for call in self.calls():
                while time.monotonic() < deadline:
                    cmdline = Path("/proc/%d/cmdline" % call["pid"])
                    if not cmdline.exists() or not cmdline.read_bytes():
                        break
                    time.sleep(0.05)
                else:
                    self.fail("orphan Codex process %d" % call["pid"])
            lock = subprocess.run(["flock", "-n", str(state / "send.lock"), "true"])
            self.assertEqual(lock.returncode, 0, "stopped trigger must release its send lock")
        finally:
            command("stop")


if __name__ == "__main__":
    unittest.main()
