# peon-ping adapter for GitHub Copilot (Windows)
# Translates GitHub Copilot hook events into peon.ps1 stdin JSON
#
# Setup: Add to .github/hooks/peon-ping.json in your repository,
# or let install.ps1 auto-register %USERPROFILE%\.copilot\hooks\peon-ping.json:
#   {
#     "version": 1,
#     "hooks": {
#       "sessionStart": [
#         { "type": "command", "powershell": "powershell -NoProfile -File %USERPROFILE%\\.claude\\hooks\\peon-ping\\adapters\\copilot.ps1 sessionStart" }
#       ],
#       "userPromptSubmitted": [
#         { "type": "command", "powershell": "powershell -NoProfile -File %USERPROFILE%\\.claude\\hooks\\peon-ping\\adapters\\copilot.ps1 userPromptSubmitted" }
#       ],
#       "postToolUse": [
#         { "type": "command", "powershell": "powershell -NoProfile -File %USERPROFILE%\\.claude\\hooks\\peon-ping\\adapters\\copilot.ps1 agentStop" }
#       ],
#       "errorOccurred": [
#         { "type": "command", "powershell": "powershell -NoProfile -File %USERPROFILE%\\.claude\\hooks\\peon-ping\\adapters\\copilot.ps1 errorOccurred" }
#       ]
#     }
#   }

param(
    [string]$Event = "sessionStart"
)

$ErrorActionPreference = "SilentlyContinue"

# Determine peon-ping install directory
$PeonDir = if ($env:CLAUDE_PEON_DIR) { $env:CLAUDE_PEON_DIR }
           else { Join-Path $env:USERPROFILE ".claude\hooks\peon-ping" }

$PeonScript = Join-Path $PeonDir "peon.ps1"
if (-not (Test-Path $PeonScript)) { exit 0 }

# Read JSON from stdin
$inputJson = $null
try {
    if ([Console]::IsInputRedirected) {
        $stream = [Console]::OpenStandardInput()
        $reader = New-Object System.IO.StreamReader($stream, [System.Text.Encoding]::UTF8)
        $raw = $reader.ReadToEnd()
        $reader.Close()
        if ($raw) { $inputJson = $raw | ConvertFrom-Json }
    }
} catch { if ($env:PEON_DEBUG -eq "1") { Write-Warning "peon-ping: [copilot] ConvertFrom-Json failed: $_" } }
if (-not $inputJson) { $inputJson = [PSCustomObject]@{} }

# Extract common fields
$sessionId = if ($inputJson.sessionId) { $inputJson.sessionId } else { "copilot-$PID" }
$cwd = if ($inputJson.cwd) { $inputJson.cwd } else { $PWD.Path }

# Map Copilot hook events to peon.ps1 PascalCase events
$mapped = $null
$notificationType = ""
$permissionMode = if ($inputJson.permission_mode) { [string]$inputJson.permission_mode }
                  elseif ($inputJson.permissionMode) { [string]$inputJson.permissionMode }
                  elseif ($inputJson.approvalMode) { [string]$inputJson.approvalMode }
                  else { "" }
$toolName = if ($inputJson.tool_name) { [string]$inputJson.tool_name }
            elseif ($inputJson.toolName) { [string]$inputJson.toolName }
            elseif ($inputJson.tool) { [string]$inputJson.tool }
            else { "Bash" }
if (-not $toolName -or $toolName.ToLower() -in @("bash", "sh", "shell")) {
    $toolName = "Bash"
}
$errorText = if ($inputJson.error) { [string]$inputJson.error }
             elseif ($inputJson.message) { [string]$inputJson.message }
             elseif ($inputJson.stderr) { [string]$inputJson.stderr }
             elseif ($inputJson.failureMessage) { [string]$inputJson.failureMessage }
             else { "" }

switch ($Event) {
    "sessionStart" {
        $mapped = "SessionStart"
    }
    "sessionEnd" {
        # Session end — no sound
        exit 0
    }
    "userPromptSubmitted" {
        # First prompt → SessionStart (greeting); subsequent → UserPromptSubmit (spam detection)
        $markerFile = Join-Path $PeonDir ".copilot-session-$sessionId"

        # Clean up old markers (>24h)
        Get-ChildItem -Path $PeonDir -Filter ".copilot-session-*" -File 2>$null | Where-Object {
            $_.LastWriteTime -lt (Get-Date).AddDays(-1)
        } | Remove-Item -Force 2>$null

        if (-not (Test-Path $markerFile)) {
            New-Item -ItemType File -Path $markerFile -Force | Out-Null
            $mapped = "SessionStart"
        } else {
            $mapped = "UserPromptSubmit"
        }
    }
    "agentStop" {
        $mapped = "Stop"
    }
    "subagentStop" {
        $mapped = "SubagentStop"
    }
    "preToolUse" {
        # Only surface explicit approval/permission prompts; otherwise preToolUse is too noisy.
        $hint = @(
            [string]$inputJson.notification_type,
            [string]$inputJson.decision,
            [string]$inputJson.approvalState,
            $permissionMode
        ) -join " "
        if ($hint.ToLower() -match "permission|approval|ask|prompt|review") {
            $mapped = "Notification"
            $notificationType = "permission_prompt"
        } else {
            exit 0
        }
    }
    "postToolUse" {
        # Successful postToolUse fires on every tool call; only forward failures.
        $statusText = if ($inputJson.status) { [string]$inputJson.status }
                      elseif ($inputJson.result) { [string]$inputJson.result }
                      else { "" }
        $exitCode = 0
        if ($null -ne $inputJson.exitCode -and "$($inputJson.exitCode)" -ne "") {
            $exitCode = [int]$inputJson.exitCode
        } elseif ($null -ne $inputJson.exit_code -and "$($inputJson.exit_code)" -ne "") {
            $exitCode = [int]$inputJson.exit_code
        } elseif ($null -ne $inputJson.code -and "$($inputJson.code)" -ne "") {
            $exitCode = [int]$inputJson.code
        }

        $failed = $false
        if ($null -ne $inputJson.success) {
            $failed = -not [bool]$inputJson.success
        }
        if ($exitCode -ne 0) {
            $failed = $true
        }
        if ($statusText.ToLower() -match "error|fail|denied|cancel") {
            $failed = $true
        }
        if ($errorText) {
            $failed = $true
        }

        if ($failed) {
            $mapped = "PostToolUseFailure"
        } else {
            exit 0
        }
    }
    "errorOccurred" {
        # Error occurred during session
        $mapped = "PostToolUseFailure"
    }
    default {
        # Unknown event — skip
        exit 0
    }
}

# Build CESP JSON payload
$payload = @{
    hook_event_name   = $mapped
    notification_type = $notificationType
    cwd               = $cwd
    session_id        = $sessionId
    permission_mode   = $permissionMode
    source            = "copilot"
}

if ($mapped -eq "PostToolUseFailure") {
    $payload["tool_name"] = $toolName
    $payload["error"] = if ($errorText) { $errorText } else { "Copilot event: $Event" }
}

$payloadJson = $payload | ConvertTo-Json -Compress

# Pipe to peon.ps1
$payloadJson | powershell -NoProfile -NonInteractive -File $PeonScript 2>$null

exit 0
