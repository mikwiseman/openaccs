#!/bin/bash
# Runs on the server for `openaccs vps user@host`, after OpenAccs copied the staged setup to ~/.openaccs/incoming.
# Installs what is missing (Claude Code, Codex), puts the setup where each tool reads it, backing up what it
# replaces in ~/.openaccs/backups/<time>, and adds the MCP servers through Claude's own command. Never touches
# logins: each tool signs in on this server itself. Safe to run again.
set -euo pipefail

incoming="$HOME/.openaccs/incoming"
backups="$HOME/.openaccs/backups/$(date +%Y-%m-%d-%H%M%S)"
export PATH="$HOME/.local/bin:$PATH"

say() { printf '%s\n' "$*"; }
keep() { # keep <path>: move what is there into the backup folder
  local target="$1"
  if [ -e "$target" ] || [ -L "$target" ]; then
    mkdir -p "$backups/$(dirname "${target#"$HOME"/}")"
    mv "$target" "$backups/${target#"$HOME"/}"
  fi
}
place() { # place <from> <to>: replace <to> with <from> unless they are already the same
  local from="$1" to="$2"
  if [ -e "$to" ] && diff -rq "$from" "$to" >/dev/null 2>&1; then return; fi
  keep "$to"
  mkdir -p "$(dirname "$to")"
  cp -R "$from" "$to"
}
link() { # link <path> <target>
  local path="$1" target="$2"
  [ "$(readlink "$path" 2>/dev/null)" = "$target" ] && return
  keep "$path"
  mkdir -p "$(dirname "$path")"
  ln -s "$target" "$path"
}

[ "$(id -u)" != 0 ] || { say "Agents shouldn't run as root. Create a user (adduser) and run this as that user."; exit 1; }
[ -d "$incoming" ] || { say "Nothing to set up: $incoming is missing."; exit 1; }

# Tools.
if ! command -v claude >/dev/null 2>&1; then
  say "Installing Claude Code…"
  curl -fsSL https://claude.ai/install.sh | bash -s stable >/dev/null
fi
if ! command -v codex >/dev/null 2>&1; then
  say "Installing Codex…"
  curl -fsSL https://chatgpt.com/codex/install.sh | CODEX_NON_INTERACTIVE=1 sh >/dev/null
fi
export PATH="$HOME/.local/bin:$HOME/.codex/bin:$PATH"
if ! command -v bwrap >/dev/null 2>&1; then
  say "Note: the agents' sandbox needs bubblewrap: sudo apt-get install -y bubblewrap socat"
fi

# Instructions: one file, Codex reads it through a link.
if [ -f "$incoming/CLAUDE.md" ]; then
  place "$incoming/CLAUDE.md" "$HOME/.claude/CLAUDE.md"
  link "$HOME/.codex/AGENTS.md" "$HOME/.claude/CLAUDE.md"
fi

# Skills: stored once in ~/.agents/skills (Codex reads it); Claude gets a link per skill.
if [ -d "$incoming/skills" ]; then
  for dir in "$incoming"/skills/*/; do
    name=$(basename "$dir")
    place "$dir" "$HOME/.agents/skills/$name"
    link "$HOME/.claude/skills/$name" "$HOME/.agents/skills/$name"
  done
fi

# Claude's agents, commands and settings (already filtered for this server on the Mac).
for part in agents commands; do
  [ -d "$incoming/claude/$part" ] && place "$incoming/claude/$part" "$HOME/.claude/$part"
done
[ -f "$incoming/claude/settings.json" ] && place "$incoming/claude/settings.json" "$HOME/.claude/settings.json"

# Codex settings and MCP servers (generated for this server on the Mac).
[ -f "$incoming/codex/config.toml" ] && place "$incoming/codex/config.toml" "$HOME/.codex/config.toml"

# Claude's MCP servers, through its own command (it owns ~/.claude.json).
if [ -d "$incoming/claude-mcp" ]; then
  for file in "$incoming"/claude-mcp/*.json; do
    [ -e "$file" ] || continue
    name=$(basename "$file" .json)
    claude mcp remove --scope user "$name" >/dev/null 2>&1 || true
    claude mcp add-json --scope user "$name" "$(cat "$file")" >/dev/null && say "MCP: $name"
  done
fi

rm -rf "$incoming"
[ -d "$backups" ] && say "Replaced files are in $backups"
say "Claude Code $(claude --version 2>/dev/null | head -1 || echo missing)"
say "Codex $(codex --version 2>/dev/null | head -1 || echo missing)"
