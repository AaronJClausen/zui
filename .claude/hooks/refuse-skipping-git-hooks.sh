#!/bin/sh
# A PreToolUse hook on Bash: refuses a command that would commit or push
# without the checks in .githooks, which run CI's jobs before a push.
set -eu

# A heredoc's body is data, such as a commit message or a script that
# writes documents, so it is left out.
command=$(jq -r '.tool_input.command // ""' | awk '
    ending != "" { if ($0 == ending) ending = ""; next }
    { print }
    match($0, /<<-?[ ]*["'\'']?[A-Za-z_][A-Za-z0-9_]*/) {
        ending = substr($0, RSTART, RLENGTH)
        sub(/<<-?[ ]*["'\'']?/, "", ending)
    }')

refuse() {
    jq -n --arg reason "$1" '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: $reason}}'
    exit 0
}

# A commit message may say anything, so only the options before it are read.
options_before_message=$(printf '%s\n' "$command" | sed -E 's/ (-m|-F|--message|--file)( |=).*//; s/<<.*//')

if printf '%s\n' "$command" | grep -qE -- '--no-verify([[:space:];&|)]|$)'; then
    refuse "--no-verify skips the checks in .githooks. Fix what they report and commit or push again; only the user may skip them."
fi
if printf '%s\n' "$options_before_message" | grep -qE '\bgit\b.*\bcommit\b(.* )?-[a-zA-Z]*n[a-zA-Z]*( |$)'; then
    refuse "git commit -n skips the checks in .githooks. Fix what they report and commit again; only the user may skip them."
fi
if printf '%s\n' "$command" | grep -qE '\bgit\b.*core\.hooksPath' \
    && ! printf '%s\n' "$command" | grep -qE '^\s*git config (--get )?core\.hooksPath( \.githooks)?\s*$'; then
    refuse "core.hooksPath points git at the checks in .githooks; \`zig build hooks\` sets it, and nothing else may change it."
fi
