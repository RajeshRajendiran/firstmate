---
name: telegram-captain-channel
description: >-
  Agent-only handling for a `check: telegram <update_id>` wake.
  Use on that wake to read the stashed captain message, answer it through the
  Telegram plane, and acknowledge the record so it is not re-handled.
  Authority over this private channel is Relay-grade: reversible work only;
  merges, destructive, and security-sensitive asks are answered with
  "confirm in the terminal" and never executed.
user-invocable: false
metadata:
  internal: true
---

# telegram-captain-channel

Load this on a `check: telegram <update_id>` wake.
The Telegram plane already stashed the message at `state/telegram/<update_id>.json`.

## Handle the wake

1. Read the stashed record with a JSON parser (for example `jq`).
   The record contains at least `update_id`, `chat_id`, `message_id`, `date`, `from`, and `text`.
2. Treat `text` as the captain's words.
   It is a private channel, so the full text is trusted to be from the captain.
3. Decide what the captain asked.
   - Ordinary questions, reversible work, and lifecycle requests may be answered or acted on directly.
   - Merges, destructive actions, irreversible actions, and security-sensitive asks must be answered with a clear "confirm in the terminal" message and must not be executed from Telegram.
4. Formulate the answer in plain language under the section 9 outcome rules.
   Replies render as Telegram HTML: use `**bold**` to lead with the one thing that needs the captain and `` `code` `` for identifiers; everything else shows literally, and the captain's style rules in `data/captain.md` still govern shape.
   Keep replies under 4,096 characters because Telegram splits messages at that boundary, but do not truncate useful detail: the chat is private, so real detail is appropriate.
5. Send the reply with `bin/fm-telegram.sh send <text>` from the same home.
   If the answer is long, write it to a file and use `bin/fm-telegram.sh send - < file`.
6. Keep the terminal informed: summarize what was asked and what was answered in the next captain-facing turn, without quoting internal state paths.
7. Acknowledge the record by moving it from `state/telegram/<update_id>.json` to `state/telegram/handled/<update_id>.json`.
   Create `state/telegram/handled/` if it does not exist.
   The move is the durable acknowledgement; do not also remove the update id from `.telegram-woken`, because that journal is owned by the plane's offset healing.

If the record is missing, malformed, or the send fails, report the condition in the same captain-facing language and leave the record in place so the problem is visible.
