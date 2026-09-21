#!/usr/bin/env python3
"""Telegram Bot API engine for fm-telegram.sh.

This script is private to fm-telegram.sh and is invoked with environment
variables set by that script. It performs no state management of its own;
all durable records, wakes, and offset advances are owned by fm-telegram.sh.
"""

import html
import json
import os
import re
import subprocess
import sys
import time


def _curl_cmd(url, method="GET", json_payload=None, timeout=30, include_code=False):
    cmd = ["curl", "-sS", "--max-time", str(timeout), "-X", method]
    if json_payload is not None:
        cmd.extend(["-H", "Content-Type: application/json", "-d", json.dumps(json_payload)])
    if include_code:
        cmd.extend(["-w", "\n%{http_code}"])
    cmd.extend(["-K", "-"])
    return cmd


def _run_curl(url, method="GET", json_payload=None, timeout=30, include_code=False):
    proc = subprocess.run(
        _curl_cmd(url, method, json_payload, timeout, include_code),
        input=f'url = "{url}"\n',
        capture_output=True,
        text=True,
    )
    out = proc.stdout
    if include_code:
        idx = out.rfind("\n")
        if idx >= 0:
            body = out[:idx]
            code = out[idx + 1 :].strip()
        else:
            body = ""
            code = out.strip()
        return body, proc.returncode, code
    return out, proc.returncode


def _api_url(prefix, token, method):
    return f"{prefix}/bot{token}/{method}"


_INLINE_MARKUP = re.compile(r"\*\*(.+?)\*\*|`(.+?)`")
_TAG_FOR = {0: "b", 1: "code"}


def _render_tokens(text):
    """Render plain text to HTML tokens: ("open"|"close", tag), ("nl", "\n"), ("text", escaped).

    Only **bold** and `code` are recognised, and only within one line, so a tag
    never spans a newline. Everything else is escaped literally.
    """
    tokens = []

    def add_text(raw):
        for ch in raw:
            tokens.append(("text", html.escape(ch, quote=False)))

    for n, line in enumerate(text.split("\n")):
        if n:
            tokens.append(("nl", "\n"))
        pos = 0
        for m in _INLINE_MARKUP.finditer(line):
            add_text(line[pos : m.start()])
            idx = 0 if m.group(1) is not None else 1
            tag = _TAG_FOR[idx]
            tokens.append(("open", tag))
            add_text(m.group(idx + 1))
            tokens.append(("close", tag))
            pos = m.end()
        add_text(line[pos:])
    return tokens


def _tok_str(tok):
    kind, val = tok
    if kind == "open":
        return f"<{val}>"
    if kind == "close":
        return f"</{val}>"
    return val


def _closers(stack):
    return "".join(f"</{t}>" for t in reversed(stack))


def _apply(stack, tok):
    kind, val = tok
    if kind == "open":
        return stack + [val]
    if kind == "close":
        return stack[:-1]
    return stack


def _split_telegram_html(text, max_len=4096):
    """Render text to Telegram HTML and split into chunks of at most max_len.

    Prefers newline boundaries; a tag spanning a boundary is closed at the end of
    one chunk and reopened at the start of the next, so every chunk is well formed.
    """
    tokens = _render_tokens(text or "")
    n = len(tokens)
    chunks = []
    i = 0
    stack = []
    while True:
        cur = len("".join(f"<{t}>" for t in stack))
        st = list(stack)
        j = i
        last_nl = None
        while j < n:
            new_st = _apply(st, tokens[j])
            if cur + len(_tok_str(tokens[j])) + len(_closers(new_st)) > max_len and j > i:
                break
            cur += len(_tok_str(tokens[j]))
            if tokens[j][0] == "nl":
                last_nl = (j, list(st))
            st = new_st
            j += 1
        opens = "".join(f"<{t}>" for t in stack)
        if j >= n:
            chunks.append(opens + "".join(_tok_str(t) for t in tokens[i:j]) + _closers(st))
            return chunks
        if last_nl is not None:
            k, st_k = last_nl
            chunks.append(opens + "".join(_tok_str(t) for t in tokens[i:k]) + _closers(st_k))
            i, stack = k + 1, st_k
        else:
            chunks.append(opens + "".join(_tok_str(t) for t in tokens[i:j]) + _closers(st))
            i, stack = j, st


def _html_to_plain(chunk):
    return html.unescape(re.sub(r"</?(?:b|code)>", "", chunk))


def _is_markup_rejection(status, body):
    """True when Telegram refused the message for a markup (entity parsing) reason."""
    if status["verdict"] != "not-delivered":
        return False
    try:
        data = json.loads(body)
    except (json.JSONDecodeError, TypeError):
        return False
    desc = data.get("description", "") if isinstance(data, dict) else ""
    return "parse entities" in desc.lower() or "can't parse" in desc.lower()


def _classify_send(body, rc, code):
    if rc != 0:
        return {"verdict": "ambiguous", "reason": f"curl error {rc}"}
    if not code.isdigit():
        return {"verdict": "ambiguous", "reason": "no HTTP response code"}
    code_i = int(code)
    if code_i < 200 or code_i >= 300:
        return {"verdict": "not-delivered", "reason": f"HTTP {code}"}
    try:
        data = json.loads(body)
    except json.JSONDecodeError as exc:
        return {"verdict": "ambiguous", "reason": f"invalid JSON: {exc}"}
    if not isinstance(data, dict):
        return {"verdict": "ambiguous", "reason": "unexpected response"}
    if data.get("ok"):
        return {"verdict": "delivered", "reason": ""}
    return {"verdict": "not-delivered", "reason": f"telegram error: {data.get('description', '')}"}


def _message_summary(text, max_len=120):
    if not text:
        return ""
    first = text.splitlines()[0]
    first = first.replace("\t", " ")
    if len(first) > max_len:
        return first[: max_len - 3] + "..."
    return first


def cmd_poll():
    token = os.environ["FM_TELEGRAM_BOT_TOKEN"]
    chat_id = os.environ["FM_TELEGRAM_CAPTAIN_CHAT_ID"]
    prefix = os.environ.get("FM_TELEGRAM_API_URL_PREFIX", "https://api.telegram.org")
    timeout = int(os.environ.get("FM_TELEGRAM_POLL_TIMEOUT", "30"))
    offset = int(os.environ.get("FM_TELEGRAM_OFFSET", "0"))
    long_poll = max(1, timeout - 5)
    limit = 100

    url = f"{_api_url(prefix, token, 'getUpdates')}?offset={offset + 1}&limit={limit}&timeout={long_poll}"
    body, rc = _run_curl(url, method="GET", timeout=timeout)
    if rc != 0:
        print(f"fm-telegram: poll failed: curl error {rc}", file=sys.stderr)
        return 1
    try:
        data = json.loads(body)
    except json.JSONDecodeError as exc:
        print(f"fm-telegram: poll failed: invalid JSON: {exc}", file=sys.stderr)
        return 1
    if not isinstance(data, dict) or not data.get("ok"):
        desc = data.get("description", "") if isinstance(data, dict) else ""
        print(f"fm-telegram: poll failed: telegram error: {desc}", file=sys.stderr)
        return 1

    updates = data.get("result", [])
    for update in updates:
        msg = update.get("message") or update.get("edited_message") or update.get("channel_post")
        if not msg:
            continue
        chat = msg.get("chat", {})
        cid = chat.get("id")
        if str(cid) != str(chat_id):
            # Count only messages from a different chat, not non-chat updates.
            if cid is not None:
                print(f"D {update['update_id']}")
            continue
        text = msg.get("text", "")
        record = {
            "update_id": update["update_id"],
            "chat_id": cid,
            "message_id": msg.get("message_id"),
            "date": msg.get("date"),
            "from": msg.get("from", {}).get("username") or msg.get("from", {}).get("id"),
            "text": text,
            "summary": _message_summary(text),
        }
        print(f"A {json.dumps(record, separators=(',', ':'))}")
    return 0


def cmd_send():
    if len(sys.argv) < 3:
        print("fm-telegram: send requires a text file path", file=sys.stderr)
        return 2
    text_path = sys.argv[2]
    try:
        with open(text_path, "r", encoding="utf-8") as fh:
            text = fh.read()
    except OSError as exc:
        print(f"fm-telegram: cannot read text: {exc}", file=sys.stderr)
        return 1

    token = os.environ["FM_TELEGRAM_BOT_TOKEN"]
    chat_id = os.environ["FM_TELEGRAM_CAPTAIN_CHAT_ID"]
    prefix = os.environ.get("FM_TELEGRAM_API_URL_PREFIX", "https://api.telegram.org")
    timeout = int(os.environ.get("FM_TELEGRAM_SEND_TIMEOUT", "30"))
    rate = float(os.environ.get("FM_TELEGRAM_SEND_RATE_LIMIT", "1"))

    chunks = _split_telegram_html(text, 4096)
    url = _api_url(prefix, token, "sendMessage")
    total = len(chunks)
    for i, chunk in enumerate(chunks, start=1):
        if i > 1:
            time.sleep(rate)
        payload = {"chat_id": chat_id, "text": chunk, "parse_mode": "HTML"}
        body, rc, code = _run_curl(url, method="POST", json_payload=payload, timeout=timeout, include_code=True)
        status = _classify_send(body, rc, code)
        if _is_markup_rejection(status, body):
            print(f"fallback: {i}/{total}: formatting rejected ({status['reason']}); resending unformatted")
            payload = {"chat_id": chat_id, "text": _html_to_plain(chunk)}
            body, rc, code = _run_curl(url, method="POST", json_payload=payload, timeout=timeout, include_code=True)
            status = _classify_send(body, rc, code)
        if status["reason"]:
            print(f"{status['verdict']}: {i}/{total}: {status['reason']}")
        else:
            print(f"{status['verdict']}: {i}/{total}")
        if status["verdict"] != "delivered":
            return 1
    return 0


def main():
    if len(sys.argv) < 2:
        print("fm-telegram.py: missing subcommand", file=sys.stderr)
        return 2
    sub = sys.argv[1]
    if sub == "poll":
        return cmd_poll()
    if sub == "send":
        return cmd_send()
    print(f"fm-telegram.py: unknown subcommand: {sub}", file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main())
