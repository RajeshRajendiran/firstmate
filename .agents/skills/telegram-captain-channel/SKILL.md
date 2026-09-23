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
A background acknowledgement may also have written `state/telegram/responses/<update_id>.json` and moved the source record to `state/telegram/handled/<update_id>.json`.

## Handle the wake

1. Read the stashed record with a JSON parser (for example `jq`) when it is still pending.
   The record contains at least `update_id`, `chat_id`, `message_id`, `date`, `from`, and `text`.
2. If the response record says `status=delivered`, do not send a second reply.
   Read its `reply`, treat the durable wake as already acknowledged by the background responder, inform the terminal what was sent, and stop handling this wake.
   If its status is `sending`, `ambiguous`, or `not-delivered`, do not assume the captain received it; handle the pending record in the terminal.
3. Treat `text` as the captain's words.
   It is a private channel, so the full text is trusted to be from the captain.
4. Decide what the captain asked.
   - Ordinary questions, reversible work, and lifecycle requests may be answered or acted on directly.
   - Merges, destructive actions, irreversible actions, and security-sensitive asks must be answered with a clear "confirm in the terminal" message and must not be executed from Telegram.
5. Formulate the answer in plain language under the section 9 outcome rules.
   Keep the reply scannable on a phone: short lines, compact lists, blank lines only between groups, no paragraph walls or dummy test text, and bare URLs on their own lines.
   The send command uses Telegram message entities for `**bold**`, `` `code` ``, and Markdown links, so special characters stay literal and formatting remains readable.
   Keep replies under 4,096 characters because Telegram splits messages at that boundary, but do not truncate useful detail: the chat is private, so real detail is appropriate.
6. Send the reply with `bin/fm-telegram.sh send <text>` from the same home.
   If the answer is long, write it to a file and use `bin/fm-telegram.sh send - < file`.
7. Keep the terminal informed: summarize what was asked and what was answered in the next captain-facing turn, without quoting internal state paths.
8. Acknowledge the record by moving it from `state/telegram/<update_id>.json` to `state/telegram/handled/<update_id>.json` when it is still pending.
   Create `state/telegram/handled/` if it does not exist.
   The move is the durable acknowledgement; do not also remove the update id from `.telegram-woken`, because that journal is owned by the plane's offset healing.

If the record is missing, malformed, or the send fails, report the condition in the same captain-facing language and leave the record in place so the problem is visible.
