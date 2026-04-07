#!/bin/bash
# peon-ping adapter for GitHub Copilot CLI
# Translates GitHub Copilot hook events into peon.sh stdin JSON
#
# Setup (user-level — applies to all repos):
#   Create ~/.copilot/hooks/peon-ping.json:
#   {
#     "version": 1,
#     "hooks": {
#       "sessionStart": [
#         { "type": "command", "bash": "bash ~/.claude/hooks/peon-ping/adapters/copilot.sh sessionStart" }
#       ],
#       "userPromptSubmitted": [
#         { "type": "command", "bash": "bash ~/.claude/hooks/peon-ping/adapters/copilot.sh userPromptSubmitted" }
#       ],
#       "postToolUse": [
#         { "type": "command", "bash": "bash ~/.claude/hooks/peon-ping/adapters/copilot.sh postToolUse" }
#       ],
#       "errorOccurred": [
#         { "type": "command", "bash": "bash ~/.claude/hooks/peon-ping/adapters/copilot.sh errorOccurred" }
#       ]
#     }
#   }
#
# The installer auto-creates this file when ~/.copilot exists.

set -euo pipefail

PEON_DIR="${CLAUDE_PEON_DIR:-${CLAUDE_CONFIG_DIR:-$HOME/.claude}/hooks/peon-ping}"

COPILOT_EVENT="${1:-sessionStart}"

# Copilot sends JSON with session data on stdin (timestamp, cwd, sessionId, etc.)
if [ -t 0 ]; then
  INPUT="{}"
else
  INPUT=$(cat)
fi

# Extract fields using python3 (no jq dependency)
SESSION_ID=$(echo "$INPUT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('sessionId',''))" 2>/dev/null || echo "")
[ -z "$SESSION_ID" ] && SESSION_ID="copilot-$$"
CWD=$(echo "$INPUT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('cwd',''))" 2>/dev/null || echo "")
[ -z "$CWD" ] && CWD="${PWD}"

# Map Copilot hook events to peon.sh PascalCase events
case "$COPILOT_EVENT" in
  sessionStart)
    EVENT="SessionStart"
    ;;
  sessionEnd)
    # Session end — no sound (not yet mapped in peon.sh)
    exit 0
    ;;
  userPromptSubmitted)
    # Prompt submitted — SessionStart handles greeting, this handles spam detection
    SESSION_MARKER="$PEON_DIR/.copilot-session-${SESSION_ID}"
    find "$PEON_DIR" -name ".copilot-session-*" -mtime +0 -delete 2>/dev/null
    if [ ! -f "$SESSION_MARKER" ]; then
      touch "$SESSION_MARKER"
      EVENT="SessionStart"
    else
      EVENT="UserPromptSubmit"
    fi
    ;;
  preToolUse)
    # Before tool execution — skip (too noisy)
    exit 0
    ;;
  postToolUse)
    # After tool execution — treat as task completion
    EVENT="Stop"
    ;;
  errorOccurred)
    # Error occurred during session
    EVENT="PostToolUseFailure"
    ;;
  *)
    # Unknown event — skip
    exit 0
    ;;
esac

# Build CESP JSON payload and pipe to peon.sh
_EVENT="$EVENT" _SID="$SESSION_ID" _CWD="$CWD" python3 -c "
import json, os
event = os.environ['_EVENT']
payload = {
    'hook_event_name': event,
    'notification_type': '',
    'cwd': os.environ['_CWD'],
    'session_id': os.environ['_SID'],
    'permission_mode': '',
}
if event == 'PostToolUseFailure':
    payload['tool_name'] = 'Bash'
    payload['error'] = 'errorOccurred'
print(json.dumps(payload))
" | bash "$PEON_DIR/peon.sh"
