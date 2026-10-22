import unittest
from _responses_compat import responses_sse_chunk


class ResponseIdentityTests(unittest.TestCase):
    def stream(self, events):
        state = {}
        return [chunk for ev in events
                if (chunk := responses_sse_chunk(ev, state)) is not None]

    def completed(self, rid=None, output=None):
        response = {"output": output or []}
        if rid:
            response["id"] = rid
        return {"type": "response.completed", "response": response}

    def test_created_metadata_and_deduplication(self):
        chunks = self.stream([
            {"type": "response.created", "response": {"id": "resp_first", "model": "test-model"}},
            {"type": "response.output_text.delta", "delta": "hello"},
            {"type": "response.output_text.done", "text": "hello"},
            self.completed("resp_first", [{"type": "message", "content": [
                {"type": "output_text", "text": "hello!"}]}]),
        ])
        self.assertEqual([c["id"] for c in chunks], ["resp_first"] * 2)
        self.assertEqual([c["model"] for c in chunks], ["test-model"] * 2)
        self.assertEqual("".join(c["choices"][0]["delta"].get("content", "") for c in chunks), "hello!")

    def test_distinct_requests(self):
        for created in (True, False):
            ids = []
            for index in range(2):
                events = []
                if created:
                    events.append({"type": "response.created", "response": {"id": f"resp_{index}"}})
                events += [{"type": "response.output_text.delta", "delta": "text"}, self.completed(f"resp_{index}")]
                chunks = self.stream(events)
                self.assertEqual(len({c["id"] for c in chunks}), 1)
                ids.append(chunks[0]["id"])
            self.assertNotEqual(*ids)

    def test_completed_only_tools_and_usage(self):
        event = self.completed("resp_tool", [{"type": "function_call", "call_id": "call_real",
                                               "name": "Read", "arguments": "{}"}])
        event["response"]["usage"] = {"input_tokens": 3, "output_tokens": 2, "total_tokens": 5}
        chunk = self.stream([event])[0]
        self.assertEqual(chunk["id"], "resp_tool")
        self.assertEqual(chunk["choices"][0]["delta"]["tool_calls"][0]["id"], "call_real")
        self.assertEqual(chunk["choices"][0]["finish_reason"], "tool_calls")
        self.assertEqual(chunk["usage"]["total_tokens"], 5)

    def test_errors_are_not_assistant_content(self):
        for event in ({"error": {"message": "failure"}},
                      {"type": "error", "error": {"message": "failure"}},
                      {"type": "response.failed", "response": {"error": {"message": "failure"}}},
                      {"type": "response.incomplete", "response": {
                          "incomplete_details": {"reason": "content_filter"}}}):
            state = {}
            chunk = responses_sse_chunk(event, state)
            self.assertIn("error", chunk)
            self.assertNotIn("choices", chunk)
            self.assertTrue(state["failed"])
            self.assertFalse(state["completed"])

    def test_token_limit_preserves_text_but_not_partial_tools(self):
        event = {"type": "response.incomplete", "response": {
            "incomplete_details": {"reason": "max_output_tokens"},
            "output": [{"type": "message", "content": [{"type": "output_text", "text": "partial"}]},
                       {"type": "function_call", "name": "Bash", "arguments": "{"}]}}
        chunk = self.stream([event])[0]
        self.assertEqual(chunk["choices"][0]["finish_reason"], "length")
        self.assertEqual(chunk["choices"][0]["delta"], {"content": "partial"})

    def test_missing_terminal_identity(self):
        first = self.stream([self.completed()])[0]
        second = self.stream([self.completed()])[0]
        self.assertNotEqual(first["id"], second["id"])


if __name__ == "__main__":
    unittest.main()