#!/bin/zsh
# Moves one running Claude profile onto OpenAccs's shared ~/.claude: wait until it is idle, quit it, let
# OpenAccs import its history (OpenAccs does this when it sees the profile stopped), then relaunch it on
# the shared folder. If OpenAccs doesn't finish, relaunch it exactly as before. Never starts a second
# Claude on the same folder.
#
#   scripts/handoff-profile.sh <data-dir> <legacy-config-dir> [delay-seconds]
#
# Run it detached when the calling session lives inside that profile:
#   perl -MPOSIX -e 'fork and exit; POSIX::setsid(); exec @ARGV' scripts/handoff-profile.sh … >/dev/null 2>&1 </dev/null
set -u
data=${1:?data dir}
legacy=${2:?legacy config dir}
delay=${3:-0}
app=/Applications/Claude.app
accounts="$HOME/Library/Application Support/OpenAccs/accounts.json"
log="$HOME/Library/Application Support/OpenAccs/handoff.log"
say() { print -r -- "$(date '+%H:%M:%S') $*" >> "$log" }

# The main process on $data. -a: pgrep hides its own ancestors unless asked, and our caller may be one.
main_pid() {
  local pid args
  for pid in $(pgrep -a -x Claude); do
    args=$(ps -ww -o args= -p $pid)
    [[ $args == *"--type="* ]] && continue
    [[ "$args " == *" --user-data-dir=$data "* ]] && { print $pid; return }
  done
}

# Any process still using this profile: helpers (--user-data-dir) or its Claude Code CLIs (<data>/claude-code/...).
profile_busy() {
  pgrep -a -f -- "--user-data-dir=$data" >/dev/null || ps -axww -o comm= | grep -qF -- "$data/claude-code/"
}

# Sessions of this profile that another running profile has open on an older shared copy (two writers
# on one conversation). Only those whose copy here is ahead of the shared one matter.
open_elsewhere() {
  local id f g
  ps -axww -o comm=,args= | grep -v -F -- "$data/" | grep -o -E -- '--resume=[0-9a-f-]{36}' | cut -d= -f2 | sort -u |
    while read -r id; do
      f=( "$legacy"/projects/*/$id.jsonl(N) ); (( $#f )) || continue
      g=( "$HOME"/.claude/projects/*/$id.jsonl(N) )
      (( $#g )) && (( $(stat -f %z $f[1]) <= $(stat -f %z $g[1]) )) && continue
      print -r -- $id
    done
}

# Written in the last 20 s under the legacy projects folder = a session is working.
recently_written() { [[ -n $(find "$legacy/projects" -type f -mtime -20s -print -quit 2>/dev/null) ]] }

still_legacy() {  # 0 = still legacy, 1 = migrated, 2 = not in OpenAccs, anything else = error
  /usr/bin/python3 -I - "$accounts" "$data" <<'PY'
import json, sys
accounts, data = sys.argv[1], sys.argv[2]
for a in json.load(open(accounts)):
    c = a.get("claude") or {}
    if c.get("dataDir") == data:
        sys.exit(0 if c.get("legacyConfigDir") else 1)
sys.exit(2)
PY
}

launch() {  # clean environment: `open` passes ours on to the app
  if [[ -n $(main_pid) ]]; then say "already running on $data; not launching a second one"; exit 0; fi
  local i
  for i in 1 2 3; do  # a pending Claude update may be swapping the app right now
    env -i HOME="$HOME" USER="$USER" PATH=/usr/bin:/bin:/usr/sbin:/sbin /usr/bin/open -n -a "$app" "$@" && return
    say "open failed; retrying"; sleep 10
  done
  say "couldn't open Claude; open the profile from OpenAccs"; exit 1
}

say "handoff start: $data (delay ${delay}s)"
sleep $delay
pgrep -x OpenAccs >/dev/null || { say "OpenAccs is not running; nothing done"; exit 1 }
still_legacy; rc=$?
case $rc in
  0) ;;
  1) say "already on ~/.claude; nothing to do"; exit 0 ;;
  *) say "profile not in OpenAccs or accounts.json unreadable ($rc); nothing done"; exit 1 ;;
esac
for i in {1..720}; do
  ids=$(open_elsewhere)
  [[ -z $ids ]] && break
  (( i == 1 )) && say "waiting: open in another profile on an older copy: ${ids//$'\n'/ }"
  sleep 5
done
[[ -z $(open_elsewhere) ]] || { say "still open elsewhere after 60 min; nothing done"; exit 1 }
for i in {1..120}; do recently_written || break; sleep 5; done
recently_written && { say "a session is still working after 10 min; nothing done"; exit 1 }

pid=$(main_pid)
[[ -n $pid ]] || { say "no Claude found on $data; nothing done"; exit 1 }
say "quitting pid $pid"
/usr/bin/osascript -l JavaScript -e "ObjC.import('AppKit'); \$.NSRunningApplication.runningApplicationWithProcessIdentifier($pid).terminate" >/dev/null 2>&1
for i in {1..240}; do kill -0 $pid 2>/dev/null || break; sleep 0.5; done
if kill -0 $pid 2>/dev/null; then say "Claude didn't quit within 2 min; a quit dialog may still be open. If you confirm it later, open the profile from OpenAccs."; exit 1; fi
for i in {1..60}; do profile_busy || break; sleep 0.5; done
say "quit"

for i in {1..600}; do still_legacy; rc=$?; (( rc == 0 )) || break; sleep 1; done
if (( rc != 1 )); then
  say "OpenAccs didn't migrate (status $rc); relaunching on the old folder"
  launch --env CLAUDE_CONFIG_DIR="$legacy" --args --user-data-dir="$data"
  exit 1
fi
say "migrated; waiting for the session sync"
cards="$data/claude-code-sessions"
last=""; same=0
for i in {1..120}; do
  now=$(find "$cards" -name 'local_*.json' 2>/dev/null | wc -l | tr -d ' ')
  if [[ $now == $last ]]; then
    (( ++same >= 5 )) && break
  else
    same=0
  fi
  last=$now; sleep 1
done
say "cards now: $last; launching on ~/.claude"
launch --args --user-data-dir="$data"
say "done"
