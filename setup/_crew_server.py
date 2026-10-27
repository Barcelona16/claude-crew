#!/usr/bin/env python3
"""crew_proxy.server — entry point: main() and server lifecycle."""

import atexit
import logging
import threading
import time
from http.server import ThreadingHTTPServer

from _crew_config import CCR_URL, COOLDOWN, FAIL_N, KEYS_FILE, POLICY, CCR_CFG, PORT, log
from _crew_handler import Handler
from _crew_stats import STATS, USAGE, LATENCY, UsageSeries

def main():
    log.info("listening on http://127.0.0.1:%d  ->  CCR %s", PORT, CCR_URL)
    log.info("keys=%s policy=%s ccr=%s", KEYS_FILE, POLICY, CCR_CFG)
    log.info("breaker: trip after %d fails, cooldown %.0fs", FAIL_N, COOLDOWN)
    USAGE.load()
    log.info("usage series loaded (%d logins)", len(USAGE._buckets))
    LATENCY.load()
    log.info("latency series loaded (%d models)", len(LATENCY._buckets))
    atexit.register(lambda: USAGE.flush(force=True))
    atexit.register(lambda: LATENCY.flush(force=True))
    # 2026-10-20:请求线程未捕获异常默认只打印 traceback(见 ConnectionResetError 日志)。
    # 装线程级 excepthook:记录后静默 —— 线程崩不影响 accept 循环,但记一条结构化日志
    # 方便 dashboard/doctor 归因(不是自愈,是可观测)。
    def _thread_excepthook(args):
        log.warning("thread %s crashed: %s: %s", args.thread.name,
                    args.exc_type.__name__, args.exc_value)
    threading.excepthook = _thread_excepthook
    def _usage_flusher():
        while True:
            time.sleep(UsageSeries.FLUSH_MIN_SEC)
            USAGE.flush()
            LATENCY.flush()
            # Prune at ~5-min cadence (20s tick) — cheap dict walk, keeps memory/file small.
            LATENCY.prune()
    threading.Thread(target=_usage_flusher, daemon=True).start()
    # 2026-10-20 自愈:serve_forever 意外崩(非 KeyboardInterrupt)→ 关旧 socket 重建重听,
    # 不退出进程(launchd KeepAlive 重拉有 ThrottleInterval=5s 空窗,期间所有会话请求全挂)。
    # 重建失败(EADDRINUSE 等端口被占)才放退出 —— 那种交给 launchd/doctor 处理。
    while True:
        try:
            server = ThreadingHTTPServer(("127.0.0.1", PORT), Handler)
        except OSError as e:
            log.error("bind :%d failed: %s — exiting (launchd/doctor 会接手)", PORT, e)
            raise SystemExit(1)
        try:
            log.info("serve_forever on :%d", PORT)
            server.serve_forever()
        except KeyboardInterrupt:
            log.info("stopped")
            try:
                server.server_close()
            except OSError:
                pass
            return
        except Exception as e:
            log.error("serve_forever crashed: %s — rebuilding server", e)
            try:
                server.server_close()
            except OSError:
                pass
            time.sleep(1)  # 防疯狂重建;正常崩溃一秒后重听

