#!/usr/bin/env bash
set -uo pipefail

repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
keep=0
[[ ${1:-} == -k ]] && keep=1

T=$(mktemp -d "${TMPDIR:-/tmp}/rexws.XXXXXX")
sock="unix://$T/s.sock"
mkdir -p "$T/cfg" "$T/state" "$T/out" "$T/root/web"
printf '{"scripts":{"dev":"vite","build":"vite build"}}\n' > "$T/root/web/package.json"
printf 'dev:\n\techo dev\n' > "$T/root/Makefile"
ln -s "$repo" "$T/cfg/rex-workspaces"
sed -e "s#{{ROOT}}#$T/root#g" -e "s#{{FIX}}#$repo/test/fixtures#g" -e "s#{{OUT}}#$T/out#g" \
  "$repo/test/fixtures/workspaces.json" > "$T/workspaces.json"
cat > "$T/cfg/init.lua" <<EOF
require("rex-workspaces").setup{ files = { "$T/workspaces.json" } }
EOF

REX_SERVER=$sock XDG_CACHE_HOME=$T/cache REX_SESSION= REX_BLOCK= REX_CLIENT= rex server run --listen "$sock" --state-dir "$T/state" --restore=false --config "$T/cfg/init.lua" \
  > "$T/server.log" 2>&1 &
server_pid=$!
cleanup() {
  kill "$server_pid" 2>/dev/null
  wait "$server_pid" 2>/dev/null
  if ((keep)); then echo "kept $T"; else rm -rf "$T"; fi
}
trap cleanup EXIT
for _ in $(seq 50); do [[ -S $T/s.sock ]] && break; sleep 0.1; done

R() { rex -S "$sock" --autostart=false "$@"; }
export REX_SERVER=$sock
unset REX_SESSION REX_BLOCK REX_CLIENT

pass=0 fail=0
ok() { pass=$((pass + 1)); printf '  ok   %s\n' "$1"; }
no() { fail=$((fail + 1)); printf '  FAIL %s\n' "$1"; [[ -n ${2:-} ]] && printf '       %s\n' "$2"; }
eq() { if [[ $2 == "$3" ]]; then ok "$1"; else no "$1" "expected [$3], got [$2]"; fi; }
has() { if grep -q -- "$3" <<<"$2"; then ok "$1"; else no "$1" "missing [$3] in: $(head -c 300 <<<"$2")"; fi; }

wait_for() {
  for _ in $(seq 60); do
    [[ $(grep -c -- "$2" "$1" 2>/dev/null || true) -ge $3 ]] && return 0
    sleep 0.25
  done
  return 1
}
sid_of() { R ls --json | jq -r --arg l "$1" '[(.sessions // [])[] | select(.label == $l)][0].session_id // empty'; }
view() { R session inspect "$(sid_of "$1")" --json; }
windows() { view "$1" | jq -r '[.windows[].label] | join(",")'; }
floats() { view "$1" | jq -r '[.windows[].layers[] | select(.kind == "floating") | "\(.blocks[0].label):\(.state // "normal")"] | sort | join(",")'; }
hooks() { tr '\n' ',' < "$T/out/hooks.log" 2>/dev/null; }

echo "config"
check=$(rex config check "$T/cfg/init.lua" 2>&1)
has "config check passes" "$check" "actions: 24"
actions=$(R actions 2>&1)
has "per-workspace palette entry" "$actions" "workspace_start_alpha"
has "restart entry for a workspace with servers" "$actions" "workspace_restart_beta"
has "ui action" "$actions" "workspace_ui"
has "open key" "$(R keymap 2>&1)" "cmd+o .*workspace_ui"
has "per-workspace key" "$(R keymap 2>&1)" "ctrl+cmd+9 .*workspace_open"

echo "list"
list=$(R do workspace_list --json)
eq "two workspaces" "$(jq '.workspaces | length' <<<"$list")" 2
eq "all stopped" "$(jq '[.workspaces[] | select(.running)] | length' <<<"$list")" 0
eq "no config errors" "$(jq '.errors | length' <<<"$list")" 0

echo "start (float servers)"
r=$(R do workspace_start name=alpha --json)
eq "creates the session" "$(jq .created <<<"$r")" true
eq "tabs" "$(windows alpha)" "agents,logs"
eq "focus picks the tab" "$(view alpha | jq -r '.active_window_id as $a | .windows[] | select(.window_id == $a) | .label')" "logs"
eq "servers float, api minimized" "$(floats alpha)" "api:minimized,web:normal"
wait_for "$T/out/started.log" api 1 && wait_for "$T/out/started.log" web 1 && ok "servers started" || no "servers started"
eq "start hooks" "$(hooks)" "before_start,after_start,"
eq "list shows servers up" "$(R do workspace_list --json | jq -c '.workspaces[] | select(.name == "alpha") | [.running, .servers_up]')" "[true,2]"

echo "start again"
r=$(R do workspace_start name=alpha --json)
eq "reuses the session" "$(jq -c '[.created, .started]' <<<"$r")" "[false,false]"
eq "one alpha session" "$(R ls --json | jq '[(.sessions // [])[] | select(.label == "alpha")] | length')" 1
eq "no extra hooks" "$(hooks)" "before_start,after_start,"

echo "stop"
r=$(R do workspace_stop name=alpha --json)
eq "nothing forced" "$(jq '.forced | length' <<<"$r")" 0
wait_for "$T/out/interrupted.log" api 1 && wait_for "$T/out/interrupted.log" web 1 && ok "Ctrl-C reached servers" || no "Ctrl-C reached servers"
eq "server panes closed" "$(floats alpha)" ""
eq "tabs kept" "$(windows alpha)" "agents,logs"
eq "stop hooks" "$(hooks)" "before_start,after_start,before_stop,after_stop,"

echo "open only switches"
r=$(R do workspace_open name=alpha --json)
eq "open leaves servers stopped" "$(jq -c '[.created, .started]' <<<"$r")" "[false,false]"
eq "no server panes added" "$(floats alpha)" ""

echo "start brings servers back"
r=$(R do workspace_start name=alpha --json)
eq "started, not created" "$(jq -c '[.created, .started]' <<<"$r")" "[false,true]"
eq "servers back" "$(floats alpha)" "api:minimized,web:normal"
wait_for "$T/out/started.log" api 2 && ok "api started again" || no "api started again"

echo "restart"
R do workspace_restart name=alpha --json >/dev/null
wait_for "$T/out/interrupted.log" api 2 && wait_for "$T/out/started.log" api 3 && ok "api restarted" || no "api restarted"
eq "still two servers" "$(floats alpha)" "api:minimized,web:normal"

echo "stop all"
R do workspace_close name=alpha --json >/dev/null
eq "session closed" "$(sid_of alpha)" ""
wait_for "$T/out/interrupted.log" api 3 && ok "servers interrupted first" || no "servers interrupted first"

echo "servers in a tab"
R do workspace_start name=beta --json >/dev/null
eq "default tab plus servers tab" "$(windows beta)" "main,servers"
wait_for "$T/out/started.log" worker 1 && ok "worker started" || no "worker started"
R do workspace_stop name=beta --json >/dev/null
eq "servers tab closed" "$(windows beta)" "main"
R do workspace_start name=beta --json >/dev/null
eq "servers tab back" "$(windows beta)" "main,servers"
R do workspace_close name=beta --json >/dev/null

echo "add (detects servers)"
r=$(R do workspace_add name=gamma root="$T/root" edit=false --json 2>&1)
has "returns the file" "$r" "workspaces.json"
eq "listed without reload" "$(R do workspace_list --json | jq '.workspaces | length')" 3
g=$(R do workspace_list --json | jq -c '.workspaces[] | select(.name == "gamma") | [.spec.servers[].cmd] | sort')
eq "found make dev and npm run dev" "$g" '["make dev","npm run dev"]'
has "file keeps key order" "$(cat "$T/workspaces.json")" '"workspaces": {'
dup=$(R do workspace_add name=gamma root="$T/root" edit=false 2>&1)
has "duplicate name refused" "$dup" "already exists"

echo "detect, save, remove"
d=$(R do workspace_detect root="$T/root" --json)
eq "detect lists commands" "$(jq '[.commands[].cmd] | sort | join(",")' -r <<<"$d")" "make dev,npm run build,npm run dev"
eq "detect offers a starter" "$(jq -r '.starter.servers | length' <<<"$d")" 2
s=$(R do workspace_save --args '{"name":"delta","spec":{"root":"/tmp","servers":[],"tabs":[{"name":"t","panes":[{"label":"p","cmd":""}]}]}}' --json 2>&1)
has "save writes the primary file" "$s" "workspaces.json"
eq "save drops empty values" "$(jq -c '.workspaces.delta' "$T/workspaces.json")" '{"root":"/tmp","tabs":[{"name":"t","panes":[{"label":"p"}]}]}'
bad=$(R do workspace_save --args '{"name":"eps","spec":{"servers":[{"label":"x"}]}}' 2>&1)
has "save validates" "$bad" "cmd is required"
R do workspace_save --args '{"name":"delta2","spec":{"root":"/tmp"},"previous":"delta"}' >/dev/null
eq "save renames" "$(jq -r '.workspaces | keys | join(",")' "$T/workspaces.json")" "alpha,beta,delta2,gamma"
R do workspace_remove name=delta2 >/dev/null
eq "remove" "$(jq -r '.workspaces | keys | join(",")' "$T/workspaces.json")" "alpha,beta,gamma"

echo "errors"
e=$(R do workspace_start name=nope 2>&1)
has "unknown workspace" "$e" 'no workspace named "nope"'

echo "install"
x="$T/xdg"
bin="$repo/target/release/rex-workspaces"
out1=$(XDG_CONFIG_HOME=$x "$bin" install 2>&1)
has "install reports done" "$out1" "Done."
eq "module linked next to init.lua" "$(cd "$x/rex/rex-workspaces" && pwd -P)" "$(cd "$repo" && pwd -P)"
eq "require line added once" "$(grep -c '"rex-workspaces"' "$x/rex/init.lua")" 1
has "demo workspaces.json created" "$(cat "$x/rex/workspaces.json")" '"my-project"'
out2=$(XDG_CONFIG_HOME=$x "$bin" install 2>&1)
eq "second install only reloads" "$out2" "Done. Press Cmd+O in Rex, or run: rex do workspace_list"
has "loads in Rex" "$(rex config check "$x/rex/init.lua" 2>&1)" "actions: 19"

if [[ ! -x $bin ]]; then
  echo "ui: skipped, run make build"
else
  echo "ui in a pane (keys and mouse)"
  home_sid=$(R new Home --json | jq -r .session_id)
  R do workspace_ui -s "$home_sid" >/dev/null
  pane=$(R session inspect "$home_sid" --json | jq -r '.windows[0].layers[] | select(.kind == "floating") | .blocks[0].block_id')
  has "ui opens in a float" "$pane" "block:"
  screen() { R capture -s "$home_sid" -b "$pane"; }
  wait_screen() {
    for _ in $(seq 40); do grep -q -- "$1" <<<"$(screen)" && return 0; sleep 0.25; done
    return 1
  }
  wait_screen "alpha" && ok "rows render" || no "rows render" "$(screen)"
  type_in() { R block call -s "$home_sid" -b "$pane" write "$(jq -nc --arg d "$1" '{data:$d}')" >/dev/null; }
  click_at() { type_in $'\e'"[<0;$2;$1M"; sleep 0.1; type_in $'\e'"[<0;$2;$1m"; sleep 0.3; }
  row_of() { grep -n -- "$1" <<<"$(screen)" | head -1 | cut -d: -f1; }
  col_of() {
    local line pre
    line=$(screen | sed -n "$(row_of "$1")p")
    pre=${line%%"$1"*}
    echo $(($(printf '%s' "$pre" | wc -m) + 2))
  }
  click_at "$(row_of " beta ")" 6
  click_at "$(row_of " Start ")" "$(col_of " Start ")"
  wait_screen "Started beta" && ok "click row, click start" || no "click row, click start" "$(screen | tail -4)"
  wait_screen "1 of 1 running" && ok "status goes live" || no "status goes live" "$(screen | head -6)"
  click_at "$(row_of " Close ")" "$(col_of " Close ")"
  wait_screen "Closed beta" && ok "click close" || no "click close" "$(screen | tail -4)"
  bounds() { R session inspect "$home_sid" --json | jq -c '.windows[0].layers[] | select(.kind == "floating") | .bounds'; }
  list_bounds=$(bounds)
  R send-key -s "$home_sid" -b "$pane" e
  wait_screen "Save  ctrl+s" && ok "e opens the editor" || no "e opens the editor" "$(screen | head -4)"
  wait_screen "worker" && ok "editor shows servers" || no "editor shows servers" "$(screen | head -12)"
  edit_bounds=$(bounds)
  click_at "$(row_of "See suggestions")" "$(col_of "See suggestions")"
  wait_screen "+ web build" && ok "see suggestions lists commands" || no "see suggestions lists commands" "$(screen | head -20)"
  type_in $'\x13'
  wait_screen "Saved beta" && ok "save keeps the form open" || no "save keeps the form open" "$(screen | tail -4)"
  jq -e --argjson a "$list_bounds" --argjson b "$edit_bounds" -n '$b[3] > $a[3] and $b[1] == $a[1]' >/dev/null &&
    ok "editor grows the window downward" || no "editor grows the window downward" "$list_bounds -> $edit_bounds"
  R send-key -s "$home_sid" -b "$pane" escape
  wait_screen "Open  enter" && ok "esc goes back" || no "esc goes back" "$(screen | head -3)"
  eq "list shrinks the window back" "$(bounds)" "$list_bounds"
  type_in "/bet"
  wait_screen "Filter  bet" && ok "filter takes typing" || no "filter takes typing" "$(screen | head -3)"
  if grep -q " alpha " <<<"$(screen)"; then no "filter hides non-matches" "$(screen)"; else ok "filter hides non-matches"; fi
  R send-key -s "$home_sid" -b "$pane" escape
  wait_screen " alpha " && ok "esc clears the filter" || no "esc clears the filter" "$(screen)"
  R do workspace_ui -s "$home_sid" >/dev/null
  eq "shortcut toggles it closed" "$(R session inspect "$home_sid" --json | jq '[.windows[0].layers[] | select(.kind == "floating")] | length')" 0
fi

echo
echo "$pass passed, $fail failed"
((fail == 0))
