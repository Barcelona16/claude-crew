# _responses_compat.py — OpenAI Responses API 兼容层(被 joycode_proxy.py 加载)
# JoyCode 的 GPT-6.x 系模型 adapterType=openai-response,只认 Responses API;而 CCR 的
# OpenAI transformer 发的是 chat completions 格式。两个方向都要转:
#   入向: messages→input、max_tokens→max_output_tokens
#   出向: response.output[]→choices[0].message,SSE 事件→chat.completion chunks
# 目标:让 :8765 对调用方保持纯 chat completions 语义,GPT-6.x 与其他模型无差别。

import json
import uuid


def _tool_content_text(content):
    """tool 结果消息的 content(str 或 [{type:text,...}] 列表)→ 纯文本。"""
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        return "".join(p.get("text", "") for p in content if isinstance(p, dict))
    return ""


def to_responses_request(payload, stream):
    """chat completions 请求 → Responses API 请求 dict。"""
    out = {"model": payload.get("model"), "stream": stream}
    msgs = payload.get("messages") or []
    inp = []
    sys_texts = []
    for m in msgs:
        role = m.get("role", "user")
        content = m.get("content")
        if role == "system":
            if isinstance(content, str):
                sys_texts.append(content)
            continue
        # role=tool(工具执行结果):Responses API 没有 tool role,要用 function_call_output
        # item 传;其 call_id 必须对应前面 assistant tool_calls 里的 id。assistant 的
        # tool_calls 也要转成 function_call item(2026-10-22 实测:不转则上游报
        # "Invalid value: 'tool'" → 流里只回 error 事件 → 客户端空回复)。
        if role == "tool":
            inp.append({"type": "function_call_output",
                        "call_id": m.get("tool_call_id", ""),
                        "output": _tool_content_text(content)})
            continue
        if role == "assistant" and m.get("tool_calls"):
            # assistant 消息带 tool_calls:文本(若有)走普通消息,每个 tool_call 一个
            # function_call item(arguments 是 JSON 字符串,原样传)。
            text = _tool_content_text(content)
            if text:
                inp.append({"role": "assistant",
                            "content": [{"type": "output_text", "text": text}]})
            for tc in m["tool_calls"]:
                fn = (tc.get("function") or {})
                inp.append({"type": "function_call",
                            "call_id": tc.get("id", ""),
                            "name": fn.get("name", ""),
                            "arguments": fn.get("arguments", "{}")})
            continue
        if isinstance(content, str):
            typ = "output_text" if role == "assistant" else "input_text"
            inp.append({"role": role, "content": [{"type": typ, "text": content}]})
        elif isinstance(content, list):
            parts = []
            for p in content:
                t = p.get("type", "text")
                if t == "text":
                    typ = "output_text" if role == "assistant" else "input_text"
                    parts.append({"type": typ, "text": p.get("text", "")})
                elif t == "image_url":
                    parts.append({"type": "input_image",
                                  "image_url": (p.get("image_url") or {}).get("url", "")})
            if parts:
                inp.append({"role": role, "content": parts})
    if sys_texts:
        out["instructions"] = "\n\n".join(sys_texts)
    out["input"] = inp
    # 参数映射。max_output_tokens 上游(GPT-6.x responses 通道)硬性最小值 16:
    # 小于 16 上游直接 invalid_request_error(实测 CCR 的 haiku 槽发 max_tokens=10 →
    # 上游拒 → 流里只回一个 error 事件)。钳到 16,保住这类小请求。
    if "max_tokens" in payload:
        out["max_output_tokens"] = max(16, payload["max_tokens"])
    if "max_completion_tokens" in payload:
        out["max_output_tokens"] = max(16, payload["max_completion_tokens"])
    if "temperature" in payload:
        out["temperature"] = payload["temperature"]
    if "top_p" in payload:
        out["top_p"] = payload["top_p"]
    if "user" in payload:
        out["user"] = payload["user"]
    # tools:functions / function_call → Responses 工具格式
    if payload.get("tools"):
        rtools = []
        for t in payload["tools"]:
            fn = t.get("function") or t
            name = fn.get("name") or t.get("name")
            if not name:
                continue
            rtools.append({"type": "function", "name": name,
                           "description": fn.get("description", ""),
                           "parameters": fn.get("parameters",
                                                {"type": "object", "properties": {}})})
        if rtools:
            out["tools"] = rtools
    if payload.get("tool_choice") in ("auto", "none", "required"):
        out["tool_choice"] = payload["tool_choice"]
    return out


def responses_to_chat(resp):
    """Responses API 非流式响应 → chat completions 响应。"""
    text = ""
    tool_calls = []
    idx = 0
    for item in (resp.get("output") or []):
        itype = item.get("type", "")
        if itype == "message":
            for part in (item.get("content") or []):
                if part.get("type") == "output_text":
                    text += part.get("text", "")
        elif itype == "function_call":
            tc = {"id": item.get("call_id") or item.get("id") or f"call_{idx}",
                  "type": "function",
                  "function": {"name": item.get("name", ""),
                                   "arguments": item.get("arguments", "{}")}}
            tool_calls.append(tc)
            idx += 1
    msg = {"role": "assistant", "content": text or None}
    if tool_calls:
        msg["tool_calls"] = tool_calls
    usage = resp.get("usage") or {}
    finish = "tool_calls" if tool_calls else ("length" if resp.get("status") == "incomplete" else "stop")
    return {
        "id": resp.get("id") or "resp",
        "object": "chat.completion",
        "created": resp.get("created_at") or 0,
        "model": resp.get("model", ""),
        "choices": [{"index": 0, "message": msg, "finish_reason": finish}],
        "usage": {
            "prompt_tokens": usage.get("input_tokens", 0),
            "completion_tokens": usage.get("output_tokens", 0),
            "total_tokens": usage.get("total_tokens",
                                      usage.get("input_tokens", 0) + usage.get("output_tokens", 0)),
        },
    }


def responses_sse_chunk(ev, state=None):
    """Responses API SSE 事件 → chat completions SSE chunk(或 None 跳过)。

    只映射文本增量与 tool_call 增量;created/completed 等控制事件给空壳或跳过。
    末尾补 [DONE] 由调用方处理。
    """
    state = state if state is not None else {}
    texts = state.setdefault("texts", {})
    etype = ev.get("type", "")
    response = ev.get("response") or {}
    # Metadata can precede content or arrive only at completion. Once emitted,
    # the client-visible identity must never change within this request.
    if not state.get("id_locked") and response.get("id"):
        state["response_id"] = response["id"]
    if "response_id" not in state:
        state["response_id"] = "resp_" + uuid.uuid4().hex
    if response.get("model"):
        state["model"] = response["model"]
    model = state.get("model") or None
    # 上游 error 事件(无 type 字段,如 ""error"":""cause"":""...):
    # 不能静默吞 - 否则客户端只收到 "[DONE]",表现为"空回复"(2026-10-22 实测:
    # CCR haiku 槽 max_tokens=10 被上游拒,流里只回一个 error 事件,13 字节)。
    # 翻译成一个带错误文本的 content chunk,让客户端看得见失败原因。
    incomplete = etype == "response.incomplete"
    reason = (response.get("incomplete_details") or {}).get("reason")
    if (ev.get("error") or etype in ("error", "response.failed")
            or response.get("status") == "failed"
            or (incomplete and reason != "max_output_tokens")):
        state["failed"] = True
        state["completed"] = False
        err = ev.get("error") or response.get("error") or {}
        if not isinstance(err, dict):
            err = {"message": str(err)}
        cause = err.get("cause") or err.get("message") or json.dumps(err, ensure_ascii=False)
        # cause 常是字符串化的嵌套 JSON,抽内层 message 让人能读
        try:
            inner = json.loads(cause)
            if isinstance(inner, dict) and inner.get("error", {}).get("message"):
                cause = inner["error"]["message"]
        except (ValueError, TypeError):
            pass
        state["id_locked"] = True
        return {"error": {"message": str(cause), "type": "upstream_error",
                          "code": err.get("code") or reason or "upstream_failed"}}
    # GPT-6.1 Sol 等模型的事件不稳定:有时只发 output_text.done / content_part.done /
    # output_item.done(一次性给全文,无 delta 增量),统一在此提取文本兜底。
    if etype in ("response.output_text.delta", "response.output_text.done",
                 "response.content_part.done", "response.output_item.done"):
        text = ev.get("delta") or ev.get("text") or ""
        if not text:
            part = ev.get("part") or {}
            text = part.get("text") or ""
        if not text:
            for c in ((ev.get("item") or {}).get("content") or []):
                text += c.get("text") or ""
        key = (ev.get("output_index", 0), ev.get("content_index", 0))
        previous = texts.get(key, "")
        if etype == "response.output_text.delta":
            texts[key] = previous + text
        else:
            texts[key] = text if text.startswith(previous) else previous
            text = text[len(previous):] if text.startswith(previous) else (text if not previous else "")
        if not text:
            return None
        state["id_locked"] = True
        return {
            "id": state["response_id"],
            "object": "chat.completion.chunk",
            "model": model,
            "choices": [{"index": 0, "delta": {"role": "assistant", "content": text},
                         "finish_reason": None}],
        }
    if etype == "response.completed" or etype == "response.incomplete":
        resp = ev.get("response") or {}
        usage = resp.get("usage") or {}
        # 收尾 chunk:把整份 tool_calls 一次性给出(delta 流里部分增量太碎,直接给终态)
        tcs = []
        idx = 0
        for item in (resp.get("output") or []):
            if item.get("type") == "function_call" and not incomplete:
                tcs.append({"index": idx,
                            "id": item.get("call_id") or f"call_{idx}",
                            "type": "function",
                            "function": {"name": item.get("name", ""),
                                         "arguments": item.get("arguments", "{}")}})
                idx += 1
        remaining = ""
        for oi, item in enumerate(resp.get("output") or []):
            if item.get("type") != "message":
                continue
            for ci, part in enumerate(item.get("content") or []):
                if part.get("type") != "output_text":
                    continue
                full = part.get("text") or ""
                previous = texts.get((oi, ci), "")
                remaining += full[len(previous):] if full.startswith(previous) else (full if not previous else "")
                texts[(oi, ci)] = full
        delta = {"content": remaining}
        if tcs:
            delta["tool_calls"] = tcs
        state["completed"] = True
        state["id_locked"] = True
        chunk = {
            "id": state["response_id"],
            "object": "chat.completion.chunk",
            "model": model,
            "choices": [{"index": 0, "delta": delta,
                         "finish_reason": "length" if incomplete else ("tool_calls" if tcs else "stop")}],
        }
        if usage:
            chunk["usage"] = {"prompt_tokens": usage.get("input_tokens", 0),
                              "completion_tokens": usage.get("output_tokens", 0),
                              "total_tokens": usage.get("total_tokens", 0)}
        return chunk
    return None
