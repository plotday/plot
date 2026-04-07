#!/usr/bin/env bash
# PreToolUse hook: Redirect Glob tool to fd.
# Glob uses ripgrep --no-ignore --hidden, scanning .git/node_modules/build artifacts.
# fd respects .gitignore by default and is significantly faster.
input=$(cat)

# macOS grep doesn't support -P; use sed instead
tool=$(echo "$input" | sed -n 's/.*"tool_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)
if [ "$tool" != "Glob" ]; then
  exit 0
fi

pattern=$(echo "$input" | sed -n 's/.*"pattern"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)
path=$(echo "$input" | sed -n 's/.*"path"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)

search_in=""
if [ -n "$path" ]; then
  search_in=" \"$path\""
fi

cat >&2 <<EOF
BLOCKED: Glob tool is unreliable (timeouts due to --no-ignore scanning node_modules).
Use fd via Bash instead. fd respects .gitignore and is much faster.

Your pattern was: $pattern
Equivalent fd commands:
  fd --type f --glob '$pattern'$search_in
  fd --type f --extension ts$search_in    # find by extension
  fd --type f 'keyword'$search_in         # find by name substring
EOF
exit 2
