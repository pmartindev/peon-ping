#!/bin/bash
# peon-ping adapter for GitHub Copilot CLI / cloud agent hooks
# Translates Copilot hook events into peon.sh stdin JSON.

set -euo pipefail

# Handle both local-repo usage and installed usage.
PEON_DIR="${CLAUDE_PEON_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
[ -f "$PEON_DIR/peon.sh" ] || PEON_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/hooks/peon-ping"
PEON_SH="$PEON_DIR/peon.sh"
[ -f "$PEON_SH" ] || exit 0

COPILOT_EVENT="${1:-sessionStart}"
if [ -t 0 ]; then
  COPILOT_INPUT=""
else
  COPILOT_INPUT="$(cat)"
fi

PAYLOAD="$(
  _COPILOT_EVENT="$COPILOT_EVENT" \
  _COPILOT_INPUT="$COPILOT_INPUT" \
  _COPILOT_PEON_DIR="$PEON_DIR" \
  python3 - <<'PY'
import json
import os
import re
import time


def first_non_empty(*values):
    for value in values:
        if value is None:
            continue
        if isinstance(value, str):
            if value.strip():
                return value.strip()
        else:
            return value
    return ""


def parse_int(value):
    if value in (None, ""):
        return None
    try:
        return int(value)
    except Exception:
        return None


raw_event = str(os.environ.get("_COPILOT_EVENT", "sessionStart") or "sessionStart").strip()
raw_input = os.environ.get("_COPILOT_INPUT", "").strip()
peon_dir = os.environ.get("_COPILOT_PEON_DIR", "")

data = {}
if raw_input:
    try:
        parsed = json.loads(raw_input)
        if isinstance(parsed, dict):
            data = parsed
    except Exception:
        data = {}

raw_session_id = str(first_non_empty(data.get("sessionId"), data.get("session_id"), f"copilot-{os.getpid()}"))
session_id = re.sub(r"[^A-Za-z0-9._:-]", "-", raw_session_id).strip("-")
if not session_id:
    session_id = f"copilot-{os.getpid()}"

cwd = str(first_non_empty(data.get("cwd"), os.environ.get("PWD", ""), "/"))
permission_mode = str(first_non_empty(data.get("permission_mode"), data.get("permissionMode"), data.get("approvalMode"), ""))
notification_type = str(first_non_empty(data.get("notification_type"), "")).lower()
tool_name = str(first_non_empty(data.get("tool_name"), data.get("toolName"), data.get("tool"), "Bash")).strip()
if not tool_name or tool_name.lower() in ("bash", "sh", "shell"):
    tool_name = "Bash"
tool_name = tool_name[:64]
error_text = str(first_non_empty(data.get("error"), data.get("message"), data.get("stderr"), data.get("failureMessage"), "")).strip()

mapped_event = ""

if raw_event == "sessionStart":
    mapped_event = "SessionStart"
elif raw_event == "sessionEnd":
    raise SystemExit(0)
elif raw_event == "userPromptSubmitted":
    marker_file = os.path.join(peon_dir, f".copilot-session-{session_id}")
    try:
        now = time.time()
        for name in os.listdir(peon_dir):
            if not name.startswith(".copilot-session-"):
                continue
            path = os.path.join(peon_dir, name)
            if os.path.isfile(path) and now - os.path.getmtime(path) > 86400:
                os.remove(path)
    except OSError:
        pass

    if os.path.exists(marker_file):
        mapped_event = "UserPromptSubmit"
    else:
        try:
            open(marker_file, "a", encoding="utf-8").close()
        except OSError:
            pass
        mapped_event = "SessionStart"
elif raw_event == "agentStop":
    mapped_event = "Stop"
elif raw_event == "subagentStop":
    mapped_event = "SubagentStop"
elif raw_event == "preToolUse":
    hint = " ".join(
        str(v)
        for v in (
            notification_type,
            permission_mode,
            data.get("decision", ""),
            data.get("approvalState", ""),
        )
        if v not in (None, "")
    ).lower()
    if any(token in hint for token in ("permission", "approval", "ask", "prompt", "review")):
        mapped_event = "Notification"
        notification_type = "permission_prompt"
    else:
        raise SystemExit(0)
elif raw_event == "postToolUse":
    exit_code = parse_int(first_non_empty(data.get("exitCode"), data.get("exit_code"), data.get("code")))
    status = str(first_non_empty(data.get("status"), data.get("result"), "")).strip().lower()
    success = data.get("success")

    failed = False
    if isinstance(success, bool):
        failed = not success
    if exit_code is not None and exit_code != 0:
        failed = True
    if status in ("error", "failed", "failure", "denied", "cancelled", "canceled"):
        failed = True
    if error_text:
        failed = True

    if failed:
        mapped_event = "PostToolUseFailure"
    else:
        raise SystemExit(0)
elif raw_event == "errorOccurred":
    mapped_event = "PostToolUseFailure"
else:
    raise SystemExit(0)

payload = {
    "hook_event_name": mapped_event,
    "notification_type": notification_type,
    "cwd": cwd,
    "session_id": session_id,
    "permission_mode": permission_mode,
    "source": "copilot",
}

if mapped_event == "PostToolUseFailure":
    payload["tool_name"] = tool_name
    payload["error"] = (error_text or f"Copilot event: {raw_event}")[:180]

print(json.dumps(payload))
PY
)"

if [ -n "$PAYLOAD" ]; then
  printf '%s\n' "$PAYLOAD" | bash "$PEON_SH" >/dev/null 2>&1 || true
fi
