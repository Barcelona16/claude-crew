"""Offline JoyCode proxy regression tests; no installed service or credentials used."""
import gzip
import importlib.util
import io
import json
import os
from pathlib import Path
import socket
import threading
import unittest
from unittest.mock import Mock, patch

SOURCE = Path(__file__).with_name("joycode_proxy.py")
with patch.dict(os.environ, {"JOYCODE_HMAC_SECRET": "test-only-signing-value"}):
    spec = importlib.util.spec_from_file_location("joycode_under_test", SOURCE)
    proxy = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(proxy)
END = chr(91) + "DONE" + chr(93)


def data(event, newline=True):
    return ("data: " + json.dumps(event) + ("\n\n" if newline else "")).encode()


def completed():
    return {"type": "response.completed", "response": {
        "id": "resp_test", "status": "completed", "model": "test-model",
        "output": [{"type": "message", "content": [
            {"type": "output_text", "text": "hello"}]}],
        "usage": {"input_tokens": 2, "output_tokens": 1, "total_tokens": 3}}}


class Response:
    def __init__(self, chunks=(), error=None, headers=None):
        self.chunks = iter(chunks)
        self.error = error
        self.headers = headers or {}
        self.closed = False

    def read1(self, size):
        chunk = next(self.chunks, None)
        if chunk is not None:
            return chunk
        if self.error:
            raise self.error
        return b""

    def read(self):
        return b"".join(self.chunks)

    def close(self):
        self.closed = True


def handler():
    h = object.__new__(proxy.Handler)
    h.wfile = io.BytesIO()
    h.send_response = Mock()
    h.send_header = Mock()
    h.end_headers = Mock()
    return h


def frames(h):
    return [json.loads(line[6:]) for line in h.wfile.getvalue().decode().splitlines()
            if line.startswith("data: ") and line[6:] != END]


class ConfigTests(unittest.TestCase):
    def test_env_precedence(self):
        with patch.dict(os.environ, {"JOYCODE_HMAC_SECRET": "test-value",
                                    "JOYCODE_HMAC_SECRET_FILE": "/unreadable"}, clear=True):
            self.assertEqual(proxy._load_hmac_secret(), "test-value")

    def test_missing_and_blank_config(self):
        for env in ({}, {"JOYCODE_HMAC_SECRET": " "}):
            with patch.dict(os.environ, env, clear=True), self.assertRaises(RuntimeError):
                proxy._load_hmac_secret()

    def test_secure_file(self):
        st = Mock(st_mode=0o100600, st_uid=os.getuid(), st_dev=1, st_ino=2)
        with patch.dict(os.environ, {"JOYCODE_HMAC_SECRET_FILE": "test-file"}, clear=True), \
                patch.object(proxy.os, "lstat", return_value=st), \
                patch.object(proxy.os, "open", return_value=42) as opened, \
                patch.object(proxy.os, "fstat", return_value=st), \
                patch.object(proxy.os, "fdopen", return_value=io.StringIO("test-value\n")):
            self.assertEqual(proxy._load_hmac_secret(), "test-value")
            self.assertTrue(opened.call_args.args[1] & os.O_NOFOLLOW)

    def test_bad_file_permissions_type_owner(self):
        for mode, uid in ((0o100644, os.getuid()), (0o120600, os.getuid()),
                          (0o040600, os.getuid()), (0o100600, os.getuid() + 1)):
            st = Mock(st_mode=mode, st_uid=uid)
            with patch.dict(os.environ, {"JOYCODE_HMAC_SECRET_FILE": "test-file"}, clear=True), \
                    patch.object(proxy.os, "lstat", return_value=st), \
                    self.assertRaises(RuntimeError):
                proxy._load_hmac_secret()

    def test_timeout(self):
        with patch.dict(os.environ, {}, clear=True):
            self.assertEqual(proxy._load_upstream_timeout(), 300)
        for value in ("0", "-1", "nan", "inf", "bad"):
            with patch.dict(os.environ, {"JOYCODE_UPSTREAM_TIMEOUT": value}, clear=True), \
                    self.assertRaises(RuntimeError):
                proxy._load_upstream_timeout()
        with patch.dict(os.environ, {"JOYCODE_UPSTREAM_TIMEOUT": "12.5"}, clear=True):
            self.assertEqual(proxy._load_upstream_timeout(), 12.5)


class StreamTests(unittest.TestCase):
    def test_success_identity_split_usage_and_tail(self):
        h = handler()
        first = {"type": "response.output_text.delta", "delta": "hel"}
        h._stream_response(Response([data(first), data(completed(), False)]), "", True)
        output = frames(h)
        self.assertEqual(len({f["id"] for f in output}), 1)
        self.assertEqual([f["choices"][0]["delta"].get("content", "") for f in output],
                         ["hel", "lo", ""])
        self.assertEqual(output[-1]["choices"][0]["finish_reason"], "stop")
        self.assertEqual(output[-1]["usage"]["total_tokens"], 3)
        self.assertTrue(h.wfile.getvalue().endswith(("data: " + END + "\n\n").encode()))

    def test_bad_tails_never_emit_finish(self):
        for tail in (b"data: broken", data([]), b"garbage\n", data({"type": "unknown"})):
            h = handler()
            try:
                h._stream_response(Response([data(completed()), tail]), "", True)
            except ValueError:
                h._sse_error("Invalid stream", "invalid_stream")
            self.assertNotIn(END.encode(), h.wfile.getvalue())
            self.assertTrue(frames(h)[-1].get("error"))
            self.assertFalse(any(f.get("choices", [{}])[0].get("finish_reason") for f in frames(h)))

    def test_missing_terminal(self):
        h = handler()
        h._stream_response(Response([data({"type": "response.output_text.delta", "delta": "hello"})]), "", True)
        self.assertEqual(frames(h)[-1]["error"]["code"], "missing_terminal")
        self.assertNotIn(END.encode(), h.wfile.getvalue())

    def test_failed_and_incomplete(self):
        events = [{"error": {"message": "failed"}}, {"type": "error"},
                  {"type": "response.failed", "response": {"error": {"code": "test"}}},
                  {"type": "response.incomplete", "response": {
                      "incomplete_details": {"reason": "content_filter"}}}]
        for event in events:
            h = handler()
            h._stream_response(Response([data(event), data(completed())]), "", True)
            self.assertEqual(list(frames(h)[0]), ["error"])
            self.assertNotIn(END.encode(), h.wfile.getvalue())

    def test_length(self):
        event = completed()
        event["type"] = "response.incomplete"
        event["response"]["status"] = "incomplete"
        event["response"]["incomplete_details"] = {"reason": "max_output_tokens"}
        h = handler()
        h._stream_response(Response([data(event)]), "", True)
        self.assertEqual(frames(h)[-1]["choices"][0]["finish_reason"], "length")

    def test_gzip(self):
        h = handler()
        encoded = gzip.compress(data(completed()))
        h._stream_response(Response([encoded[:7], encoded[7:]]), "gzip", True)
        self.assertEqual(frames(h)[-1]["choices"][0]["finish_reason"], "stop")

    def test_passthrough_read_error_and_finally(self):
        h = handler()
        h._body = Mock(return_value=b'{"model":"test-model","stream":true}')
        h._watch_cancel = Mock()
        resp = Response([data({"choices": [{"delta": {"content": "hi"}, "finish_reason": None}]})],
                        error=TimeoutError("private upstream detail"))
        with patch.object(proxy, "_load_state", return_value=({"masterBaseUrl": "http://test"}, [])), \
                patch.object(proxy, "_headers", return_value={}), \
                patch.object(proxy.urllib.request, "urlopen", return_value=resp) as opened:
            h._chat(True)
        self.assertTrue(resp.closed)
        self.assertEqual(opened.call_args.kwargs["timeout"], proxy.UPSTREAM_TIMEOUT)
        self.assertEqual(frames(h)[-1]["error"]["code"], "stream_read_error")
        self.assertNotIn(b"private upstream detail", h.wfile.getvalue())

    def test_compat_failed_state_contract(self):
        for result in (None, {"error": {"message": "test failure", "type": "upstream_error", "code": "test"}}):
            def convert(event, state):
                state["failed"] = True
                return result
            h = handler()
            with patch.object(proxy.rcompat, "responses_sse_chunk", side_effect=convert):
                h._stream_response(Response([data({"type": "response.created"})]), "", True)
            self.assertTrue(frames(h)[-1].get("error"))
            self.assertNotIn(END.encode(), h.wfile.getvalue())

    def test_nonstream_and_http_error_release(self):
        for resp in (Response([b'{"choices":[]}']), Response(error=TimeoutError())):
            h = handler()
            h._body = Mock(return_value=b'{"model":"test-model"}')
            h._watch_cancel = Mock()
            with patch.object(proxy, "_load_state", return_value=({"masterBaseUrl": "http://test"}, [])), \
                    patch.object(proxy, "_headers", return_value={}), \
                    patch.object(proxy.urllib.request, "urlopen", return_value=resp):
                h._chat(True)
            self.assertTrue(resp.closed)
        h = handler()
        h._body = Mock(return_value=b'{"model":"test-model"}')
        error = proxy.urllib.error.HTTPError("http://test", 503, "unavailable", {}, io.BytesIO(b"private"))
        with patch.object(proxy, "_load_state", return_value=({"masterBaseUrl": "http://test"}, [])), \
                patch.object(proxy, "_headers", return_value={}), \
                patch.object(proxy.urllib.request, "urlopen", side_effect=error):
            h._chat(True)
        self.assertTrue(error.closed)
        self.assertNotIn(b"private", h.wfile.getvalue())

    def test_invalid_completed_status(self):
        for status in (None, "failed", "incomplete"):
            event = completed()
            event["response"]["status"] = status
            h = handler()
            try:
                h._stream_response(Response([data(event)]), "", True)
            except ValueError:
                h._sse_error("Invalid stream", "invalid_stream")
            self.assertTrue(frames(h)[-1].get("error"))
            self.assertNotIn(END.encode(), h.wfile.getvalue())

    def test_cancel_closes_upstream_promptly(self):
        client, peer = socket.socketpair()
        h = handler()
        h.connection = client
        resp = Response()
        upstream = Mock()
        resp.fp = Mock(raw=Mock(_sock=upstream))
        stop, cancelled = threading.Event(), threading.Event()
        watcher = threading.Thread(target=h._watch_cancel, args=(resp, stop, cancelled))
        watcher.start()
        peer.close()
        try:
            self.assertTrue(cancelled.wait(1))
            watcher.join(1)
            self.assertTrue(resp.closed)
            upstream.shutdown.assert_called_once_with(socket.SHUT_RDWR)
        finally:
            stop.set()
            watcher.join(1)
            client.close()


if __name__ == "__main__":
    unittest.main()