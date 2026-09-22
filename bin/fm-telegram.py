#!/usr/bin/env python3
"""Telegram Bot API engine for fm-telegram.sh.

This script is private to fm-telegram.sh and is invoked with environment
variables set by that script. It performs no state management of its own;
all durable records, wakes, and offset advances are owned by fm-telegram.sh.
"""

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
_MARKDOWN_LINK = re.compile(r"\[([^\]\n]+)\]\(((?:https?|tg)://(?:[^\s()]|\([^\s()]*\))+)\)")


def _utf16_len(text):
    return len(text.encode("utf-16-le")) // 2


def _render_telegram_text(text):
    """Render the reply Markdown subset as explicit Telegram message entities.

    Telegram's sendMessage accepts entities instead of parse_mode. Keeping the
    visible text separate from formatting means characters such as ``<``, ``&``
    and MarkdownV2 punctuation remain literal without escaping.
    """
    text = (text or "").replace("\r\n", "\n").replace("\r", "\n")
    lines = []
    for source_line in text.split("\n"):
        line = source_line.rstrip()
        if not line.strip() and (not lines or not lines[-1]):
            continue
        lines.append(line)
    normalized = "\n".join(lines).strip()
    if not normalized:
        return "", []

    rendered = []
    entities = []
    for line_number, line in enumerate(normalized.split("\n")):
        if line_number:
            rendered.append("\n")
        cursor = 0
        while cursor < len(line):
            candidates = []
            link = _MARKDOWN_LINK.search(line, cursor)
            if link:
                candidates.append((link.start(), link.end(), "link", link))
            markup = _INLINE_MARKUP.search(line, cursor)
            if markup:
                candidates.append((markup.start(), markup.end(), "markup", markup))
            if not candidates:
                rendered.append(line[cursor:])
                break
            start, end, kind, match = min(candidates, key=lambda item: item[0])
            rendered.append(line[cursor:start])
            entity_start = len("".join(rendered))
            if kind == "link":
                label, url = match.group(1), match.group(2)
                rendered.append(label)
                entities.append({"type": "text_link", "start": entity_start, "end": entity_start + len(label), "url": url})
            elif match.group(1) is not None:
                content = match.group(1)
                rendered.append(content)
                entities.append({"type": "bold", "start": entity_start, "end": entity_start + len(content)})
            else:
                content = match.group(2)
                rendered.append(content)
                entities.append({"type": "code", "start": entity_start, "end": entity_start + len(content)})
            cursor = end

    return "".join(rendered), entities


def _split_telegram_text(text, max_len=4096):
    """Render and split replies, preserving entities in every API chunk."""
    rendered_text, entities = _render_telegram_text(text)
    if not rendered_text:
        return [{"text": "", "entities": []}]
    chunks = []
    start = 0
    while start < len(rendered_text):
        end = min(start + max_len, len(rendered_text))
        if end < len(rendered_text):
            line_end = rendered_text.rfind("\n", start, end + 1)
            if line_end > start:
                end = line_end
            crossing = [entity for entity in entities if entity["start"] < end < entity["end"]]
            if crossing and crossing[0]["start"] > start:
                end = crossing[0]["start"]
            if end == start:
                end = min(start + max_len, len(rendered_text))
        chunk_entities = []
        for entity in entities:
            overlap_start = max(start, entity["start"])
            overlap_end = min(end, entity["end"])
            if overlap_start < overlap_end:
                chunk_entity = {
                    "type": entity["type"],
                    "offset": _utf16_len(rendered_text[start:overlap_start]),
                    "length": _utf16_len(rendered_text[overlap_start:overlap_end]),
                }
                if "url" in entity:
                    chunk_entity["url"] = entity["url"]
                chunk_entities.append(chunk_entity)
        chunk = rendered_text[start:end]
        if chunk.strip():
            chunks.append({"text": chunk, "entities": chunk_entities})
        start = end
        if start < len(rendered_text) and rendered_text[start] == "\n":
            start += 1
    return chunks or [{"text": "", "entities": []}]


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

    chunks = _split_telegram_text(text, 4096)
    url = _api_url(prefix, token, "sendMessage")
    total = len(chunks)
    for i, chunk in enumerate(chunks, start=1):
        if i > 1:
            time.sleep(rate)
        payload = {"chat_id": chat_id, "text": chunk["text"]}
        if chunk["entities"]:
            payload["entities"] = chunk["entities"]
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
