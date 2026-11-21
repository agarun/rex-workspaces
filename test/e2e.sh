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

REX_SERVER=$sock XDG_CACHE_HOME=$T/cache XDG_STATE_HOME=$T/xstate CLAUDE_CONFIG_DIR=$T/claude REX_SESSION= REX_BLOCK= REX_CLIENT= rex server run --listen "$sock" --state-dir "$T/state" --restore=false --config "$T/cfg/init.lua" \
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
shape() {
  view "$1" | jq -r --arg w "$2" '
    def s: if .block_id then "." else (.split.direction[0:1]) + "(" + (.split.before | s) + " " + (.split.after | s) + ")" end;
    .windows[] | select(.label == $w) | .layers[] | select(.kind == "tiled") | .layout | s'
}
hooks() { tr '\n' ',' < "$T/out/hooks.log" 2>/dev/null; }

echo "config"
check=$(rex config check "$T/cfg/init.lua" 2>&1)
has "config check passes" "$check" "actions: 33"
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
eq "grid tab is two rows of two" "$(shape alpha agents)" "v(h(. .) h(. .))"
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

echo "save a session as a workspace"
d=$(R do workspace_capture session=alpha save=false --json)
eq "named after the session" "$(jq -r .name <<<"$d")" alpha
eq "grid read back" "$(jq -c '.spec.tabs[0] | [.split, [.panes[].label]]' <<<"$d")" '["grid",["one","two","three","four"]]'
eq "pane folder relative to root" "$(jq -r '.spec.tabs[0].panes[1].cwd' <<<"$d")" web
eq "servers kept from the workspace" "$(jq -c '[.spec.servers[].label]' <<<"$d")" '["api","web"]'
eq "focused tab kept" "$(jq -r .spec.focus <<<"$d")" logs
has "warns about the taken name" "$(jq -r '.notes | join(" ")' <<<"$d")" 'named "alpha" exists'
R do workspace_capture session=alpha name=alpha-copy >/dev/null
eq "saved to the file" "$(jq -c '.workspaces["alpha-copy"] | [.tabs[0].split, (.servers | length)]' "$T/workspaces.json")" '["grid",2]'
eq "saved spec is valid" "$(R do workspace_list --json | jq '.errors | length')" 0
R do workspace_remove name=alpha-copy >/dev/null
scratch=$(R new scratch --cwd "$T/root" --json | jq -r .session_id)
R split -s "$scratch" --focus=false --cwd "$T/root/web" >/dev/null
right=$(R session inspect "$scratch" --json | jq -r '.windows[0].layers[0].layout.split.after.block_id')
R split -s "$scratch" -b "$right" --split=below --focus=false >/dev/null
below=$(R session inspect "$scratch" --json | jq -r '.windows[0].layers[0].layout.split.after.split.after.block_id')
R block call -s "$scratch" -b "$below" write '{"data":"sleep 300\n"}' >/dev/null
for _ in $(seq 40); do
  [[ $(R block call -s "$scratch" -b "$below" process | jq -r .foreground.name) == sleep ]] && break
  sleep 0.25
done
R do workspace_capture session=scratch name=scratch-ws >/dev/null
eq "main and side stack saved" "$(jq -c '.workspaces["scratch-ws"].tabs[0] | [.split, (.panes[1].split), .panes[1].panes[0].cwd]' "$T/workspaces.json")" '["right","down","web"]'
eq "running command saved" "$(jq -r '.workspaces["scratch-ws"].tabs[0].panes[1].panes[1].cmd' "$T/workspaces.json")" "sleep 300"
eq "idle shell has no command" "$(jq -r '.workspaces["scratch-ws"].tabs[0].panes[0].cmd // "none"' "$T/workspaces.json")" none
R do workspace_start name=scratch-ws select=false >/dev/null
eq "reopens with the same layout" "$(shape scratch-ws "$(view scratch-ws | jq -r '.windows[0].label')")" "h(. v(. .))"
R do workspace_close name=scratch-ws >/dev/null
R kill scratch >/dev/null 2>&1
R do workspace_remove name=scratch-ws >/dev/null

echo "worktrees"
mkrepo() {
  local dir=$1 branch=$2
  mkdir -p "$dir/app" && touch "$dir/app/f"
  git init -q "$dir"
  git -C "$dir" -c user.email=t@t -c user.name=t -c commit.gpgsign=false add .
  git -C "$dir" -c user.email=t@t -c user.name=t -c commit.gpgsign=false commit -qm init
  git -C "$dir" worktree add -q "$dir.$branch" -b "$branch"
}
mkrepo "$T/one" feat
mkrepo "$T/two" fix
one_feat=$(cd "$T/one.feat" && pwd -P) two_fix=$(cd "$T/two.fix" && pwd -P) two_main=$(cd "$T/two" && pwd -P)
pane() { printf '{"label":"%s","cwd":"%s","cmd":"pwd -P > %s"%s}' "$1" "$2" "$T/out/$1-pwd" "${3:+,\"worktree\":\"$3\"}"; }
spec="{\"root\":\"$T\",\"tabs\":[{\"name\":\"t\",\"panes\":[$(pane one "$T/one/app" feat),$(pane two "$T/two/app" "$T/two.fix"),$(pane three "$T/two/app")]}]}"
R do workspace_save --args "{\"name\":\"wt\",\"spec\":$spec}" >/dev/null
R config reload >/dev/null
R do workspace_start name=wt select=false >/dev/null
wait_for "$T/out/one-pwd" app 1; wait_for "$T/out/two-pwd" app 1; wait_for "$T/out/three-pwd" app 1
eq "pane runs in the worktree named by branch" "$(cat "$T/out/one-pwd")" "$one_feat/app"
eq "pane in another repository runs in the worktree named by path" "$(cat "$T/out/two-pwd")" "$two_fix/app"
eq "pane without a worktree stays" "$(cat "$T/out/three-pwd")" "$two_main/app"
R do workspace_close name=wt >/dev/null
R do workspace_save --args "{\"name\":\"wt\",\"previous\":\"wt\",\"spec\":{\"root\":\"$T\",\"servers\":[{\"label\":\"s\",\"cwd\":\"$T/one\",\"cmd\":\"true\",\"worktree\":\"nope\"}]}}" >/dev/null
R config reload >/dev/null
r=$(R do workspace_start name=wt 2>&1)
has "unknown worktree is an error" "$r" 'no worktree "nope" for s in wt'
eq "nothing opened" "$(sid_of wt)" ""
git -C "$T/one" branch lonely
R do workspace_save --args "{\"name\":\"wt\",\"previous\":\"wt\",\"spec\":{\"root\":\"$T\",\"servers\":[{\"label\":\"s\",\"cwd\":\"$T/one\",\"cmd\":\"true\",\"worktree\":\"lonely\"}]}}" >/dev/null
R config reload >/dev/null
r=$(R do workspace_start name=wt 2>&1)
has "a branch without a worktree says how to make one" "$r" 'branch "lonely" has no worktree. Create one with: git -C'
R do workspace_remove name=wt >/dev/null

echo "stop all"
R do workspace_close name=alpha --json >/dev/null
eq "session closed" "$(sid_of alpha)" ""
wait_for "$T/out/interrupted.log" api 3 && ok "servers interrupted first" || no "servers interrupted first"

echo "configurable stop"
stop_spec() {
  jq -nc --arg root "$T/root" --arg svc "sh $repo/test/fixtures/server.sh svc $T/out" --arg panes "$1" --arg keep "$2" '{
    name: "stopper",
    spec: {
      root: $root, stop_timeout: 2, stop: { servers: "interrupt", panes: $panes },
      servers: [{ label: "svc", cmd: $svc }],
      tabs: [{ name: "work", panes: [{ label: "busy" }, { label: "keep", stop: $keep }, { label: "idle" }] }]
    }
  }'
}
save_stop() { R do workspace_save --args "$(stop_spec "$1" "$2" | jq -c --arg p "${3:-}" 'if $p != "" then .previous = $p else . end')" >/dev/null; }
block_of() { view stopper | jq -r --arg l "$1" '[.windows[].layers[].blocks[] | select(.label == $l)][0].block_id // empty'; }
fg_of() { R block call -s "$(sid_of stopper)" -b "$(block_of "$1")" process | jq -r .foreground.name; }
run_in() {
  R block call -s "$(sid_of stopper)" -b "$(block_of "$1")" write '{"data":"sleep 300\n"}' >/dev/null
  for _ in $(seq 40); do [[ $(fg_of "$1") == sleep ]] && return 0; sleep 0.25; done
  return 1
}
work_panes() { view stopper | jq -r '[.windows[] | select(.label == "work") | .layers[] | select(.kind == "tiled") | .blocks[].label] | join(",")'; }
save_stop interrupt leave
R do workspace_start name=stopper select=false >/dev/null
wait_for "$T/out/started.log" svc 1 && ok "stopper starts" || no "stopper starts"
run_in busy && run_in keep && ok "panes run sleep 300" || no "panes run sleep 300"
R do workspace_restart name=stopper select=false >/dev/null
wait_for "$T/out/started.log" svc 2 && ok "restart restarts the server" || no "restart restarts the server"
eq "restart leaves busy panes running" "$(fg_of busy),$(fg_of keep)" "sleep,sleep"
r=$(R do workspace_stop name=stopper --json)
eq "stop message" "$(jq -r .message <<<"$r")" "Stopped stopper: interrupted 1 server, interrupted 1 pane."
eq "servers=interrupt keeps the server pane" "$(floats stopper)" "svc:minimized"
eq "server pane is idle" "$(fg_of svc)" "$(basename "${SHELL:-sh}")"
eq "panes=interrupt stops the busy pane" "$(fg_of busy)" "$(basename "${SHELL:-sh}")"
eq "interrupted panes stay" "$(work_panes)" "busy,keep,idle"
eq "stop=leave on a pane wins" "$(fg_of keep)" sleep
save_stop close leave stopper
run_in busy && ok "busy pane runs again" || no "busy pane runs again"
R do workspace_stop name=stopper >/dev/null
eq "panes=close closes them, the override stays" "$(work_panes)" "keep"
eq "the overridden pane still runs" "$(fg_of keep)" sleep
save_stop close close stopper
r=$(R do workspace_stop name=stopper --json)
eq "last pane kept" "$(work_panes)" "keep"
has "last pane interrupted, not closed" "$(fg_of keep)" "$(basename "${SHELL:-sh}")"
has "message says why" "$(jq -r .message <<<"$r")" "Kept keep open so the session is not left empty."
R do workspace_close name=stopper >/dev/null
R do workspace_remove name=stopper >/dev/null

echo "freeze and thaw"
mkdir -p "$T/bin"
cc -x c -o "$T/bin/opencode" -DLOG="\"$T/out/agent-args.log\"" - <<'C'
#include <signal.h>
#include <stdio.h>
#include <unistd.h>
static void quit(int sig) {
  (void)sig;
  printf("\nContinue  opencode -s ses_fake42\n");
  fflush(stdout);
  _exit(0);
}
int main(int argc, char **argv) {
  FILE *f = fopen(LOG, "a");
  for (int i = 1; i < argc; i++) fprintf(f, "%s ", argv[i]);
  fprintf(f, "\n");
  fclose(f);
  signal(SIGINT, quit);
  for (;;) pause();
}
C
cp "$T/bin/opencode" "$T/bin/claude"
R do workspace_save --args "$(jq -nc --arg root "$T/root" --arg svc "sh $repo/test/fixtures/server.sh nap $T/out" '{
  name: "napper",
  spec: {
    root: $root, stop_timeout: 2,
    servers: [{ label: "svc", cmd: $svc }],
    tabs: [{ name: "work", panes: [{ label: "agent" }, { label: "sh" }, { label: "agent2" }] }]
  }
}')" >/dev/null
R config reload >/dev/null
nap_block() { view napper | jq -r --arg l "$1" '[.windows[].layers[].blocks[] | select(.label == $l)][0].block_id // empty'; }
nap_proc() { R block call -s "$(sid_of napper)" -b "$(nap_block "$1")" process; }
nap_fg() { nap_proc "$1" | jq -r .foreground.name; }
nap_state() { ps -o stat= -p "$(nap_proc "$1" | jq -r .foreground.pid)" | cut -c1; }
nap_write() { R block call -s "$(sid_of napper)" -b "$(nap_block "$1")" write "$(jq -nc --arg d "$2" '{data:$d}')" >/dev/null; }
nap_listed() { R do workspace_list --json | jq -r --arg k "$1" '.workspaces[] | select(.name == "napper") | .[$k]'; }
R do workspace_start name=napper select=false >/dev/null
wait_for "$T/out/started.log" nap 1 && ok "napper starts" || no "napper starts"
nap_write agent "$T/bin/opencode"$'\n'
for _ in $(seq 40); do [[ $(nap_fg agent) == opencode ]] && break; sleep 0.25; done
nap_write sh $'echo marker-$((6*7))\n'
nap_write agent2 "$T/bin/claude"$'\n'
for _ in $(seq 40); do [[ $(nap_fg agent2) == claude ]] && break; sleep 0.25; done
mkdir -p "$T/claude/sessions"
printf '{"pid":%s,"sessionId":"cl-77"}' "$(nap_proc agent2 | jq -r .foreground.pid)" > "$T/claude/sessions/$(nap_proc agent2 | jq -r .foreground.pid).json"
wait_for "$T/out/agent-args.log" "" 1
r=$(R do workspace_freeze name=napper --json)
has "freeze says what it paused" "$(jq -r .message <<<"$r")" "Froze napper: .* processes in 4 panes."
eq "agent is stopped" "$(nap_state agent)" T
eq "server is stopped" "$(nap_state svc)" T
eq "list shows frozen" "$(nap_listed frozen)" true
has "freezing again is a no-op" "$(R do workspace_freeze name=napper --json | jq -r .message)" "already frozen"
r=$(R do workspace_thaw name=napper --json)
eq "thaw message" "$(jq -r .message <<<"$r")" "Thawed napper."
eq "agent runs again" "$(nap_state agent)" S
eq "agent kept the foreground" "$(nap_fg agent)" opencode
eq "list shows thawed" "$(nap_listed frozen)" false
R do workspace_freeze name=napper >/dev/null
R do workspace_stop name=napper >/dev/null
wait_for "$T/out/interrupted.log" nap 1 && ok "stop thaws first, then Ctrl-C reaches the server" || no "stop thaws first, then Ctrl-C reaches the server"
eq "nothing left frozen" "$(nap_listed frozen)" false

echo "snooze and resume"
R do workspace_start name=napper select=false >/dev/null
wait_for "$T/out/started.log" nap 2 && ok "server back" || no "server back"
r=$(R do workspace_snooze name=napper --json)
eq "snooze message" "$(jq -r .message <<<"$r")" "Snoozed napper. Open it to resume."
eq "session closed" "$(sid_of napper)" ""
eq "list shows snoozed" "$(nap_listed snoozed)" true
snap="$T/xstate/rex-workspaces/snoozed/napper.json"
eq "opencode resumes the conversation it printed" "$(jq -r '.spec.tabs[0].panes[0].cmd' "$snap")" "$T/bin/opencode --session ses_fake42"
eq "claude resumes the conversation in its session file" "$(jq -r '.spec.tabs[0].panes[2].cmd' "$snap")" "$T/bin/claude --resume cl-77"
has "idle shell keeps its screen" "$(jq -r '.screens["2"]' "$snap")" "marker-42"
r=$(R do workspace_open name=napper --json)
eq "open resumes" "$(jq -c '[.created, .resumed]' <<<"$r")" "[true,true]"
eq "snooze forgotten" "$(test -e "$snap" && echo kept || echo gone)" gone
eq "list no longer snoozed" "$(nap_listed snoozed)" false
wait_for "$T/out/agent-args.log" "--session ses_fake42" 1 && ok "opencode started with its session" || no "opencode started with its session" "$(cat "$T/out/agent-args.log")"
wait_for "$T/out/agent-args.log" "--resume cl-77" 1 && ok "claude started with its session" || no "claude started with its session" "$(cat "$T/out/agent-args.log")"
wait_for "$T/out/started.log" nap 3 && ok "server started again" || no "server started again"
for _ in $(seq 40); do grep -q marker-42 <<<"$(R capture -s "$(sid_of napper)" -b "$(nap_block sh)")" && break; sleep 0.25; done
has "old output is back" "$(R capture -s "$(sid_of napper)" -b "$(nap_block sh)")" "marker-42"
for _ in $(seq 40); do [[ $(nap_fg sh) != sh ]] && break; sleep 0.25; done
eq "then a normal shell" "$(nap_fg sh)" "$(basename "${SHELL:-sh}")"
eq "screen file removed" "$(ls "$T/xstate/rex-workspaces/screens" 2>/dev/null | wc -l | tr -d ' ')" 0
R do workspace_snooze name=napper >/dev/null
r=$(R do workspace_close name=napper --json)
eq "close discards a snooze" "$(jq -r .message <<<"$r")" "Discarded the snooze of napper."
eq "nothing snoozed" "$(nap_listed snoozed)" false
R do workspace_remove name=napper >/dev/null

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
has "loads in Rex" "$(rex config check "$x/rex/init.lua" 2>&1)" "actions: 26"

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
  wait_screen "╭ ○ beta " && ok "no number before the name" || no "no number before the name" "$(screen | head -6)"
  has "status label is lowercase" "$(screen)" " stopped "
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
  jq -e --argjson a "$list_bounds" --argjson b "$edit_bounds" -n '$b[3] >= $a[3] and (($b[1] + $b[3] / 2 - 0.5) | fabs) < 1e-6' >/dev/null &&
    ok "editor window is centered and no shorter" || no "editor window is centered and no shorter" "$list_bounds -> $edit_bounds"
  R send-key -s "$home_sid" -b "$pane" escape
  wait_screen "Open  enter" && ok "esc goes back" || no "esc goes back" "$(screen | head -3)"
  eq "list shrinks the window back" "$(bounds)" "$list_bounds"
  type_in "/bet"
  wait_screen "Filter  bet" && ok "filter takes typing" || no "filter takes typing" "$(screen | head -3)"
  if grep -q " alpha " <<<"$(screen)"; then no "filter hides non-matches" "$(screen)"; else ok "filter hides non-matches"; fi
  R send-key -s "$home_sid" -b "$pane" escape
  wait_screen " alpha " && ok "esc clears the filter" || no "esc clears the filter" "$(screen)"
  R send-key -s "$home_sid" -b "$pane" w
  wait_screen "Check the name, tabs and panes" && ok "w saves this session in the form" || no "w saves this session in the form" "$(screen)"
  has "name defaults to the session" "$(screen)" "Name .*Home"
  R send-key -s "$home_sid" -b "$pane" escape
  wait_screen "Open  enter" && ok "esc leaves without saving" || no "esc leaves without saving" "$(screen | head -3)"
  R do workspace_ui -s "$home_sid" >/dev/null
  eq "shortcut toggles it closed" "$(R session inspect "$home_sid" --json | jq '[.windows[0].layers[] | select(.kind == "floating")] | length')" 0

  echo "form keeps per-item stop"
  R do workspace_save --args '{"name":"rt","spec":{"root":"/tmp","key":"ctrl+cmd+8","stop":{"panes":"interrupt"},"servers":[{"label":"s","cmd":"x","stop":"leave","worktree":"feat"}],"tabs":[{"name":"t","panes":[{"label":"p","stop":"close"}]}]}}' >/dev/null
  R do workspace_edit name=rt -s "$home_sid" >/dev/null
  pane=$(R session inspect "$home_sid" --json | jq -r '.windows[0].layers[] | select(.kind == "floating") | .blocks[0].block_id')
  wait_screen "Save  ctrl+s" && ok "edit opens the form" || no "edit opens the form" "$(screen | tail -6)"
  type_in $'\x13'
  wait_screen "Saved rt" && ok "form saves" || no "form saves" "$(screen | tail -4)"
  eq "overrides survive the form" "$(jq -c '.workspaces.rt | [.stop.panes, .servers[0].stop, .tabs[0].panes[0].stop, .servers[0].worktree]' "$T/workspaces.json")" '["interrupt","leave","close","feat"]'
  type_in $'\x04'
  wait_screen "Copy of rt" && ok "duplicate makes an unsaved copy" || no "duplicate makes an unsaved copy" "$(screen | tail -4)"
  type_in $'\x13'
  wait_screen "Saved rt copy" && ok "copy saves" || no "copy saves" "$(screen | tail -4)"
  eq "copy keeps worktrees, drops the shortcut" "$(jq -c '.workspaces["rt copy"] | [.servers[0].worktree, .key]' "$T/workspaces.json")" '["feat",null]'
  eq "original kept" "$(jq -r '.workspaces.rt.key' "$T/workspaces.json")" "ctrl+cmd+8"
  R do workspace_remove name="rt copy" >/dev/null
  R do workspace_remove name=rt >/dev/null
fi

echo "workspace folders"
mkdir -p "$T/ws/qa"
printf '{"workspaces":{"prod-api":{"root":"/tmp"}}}\n' > "$T/ws/prod.json"
printf '{"workspaces":{"qa1":{"root":"/tmp"},"qa2":{"root":"/tmp"}}}\n' > "$T/ws/qa/qa.json"
mkdir -p "$T/ws/.git"
printf '{"workspaces":{"hidden":{"root":"/tmp"}}}\n' > "$T/ws/.git/x.json"
cp "$T/cfg/init.lua" "$T/init.lua.bak"
printf 'require("rex-workspaces").setup{ files = { "%s", "%s" } }\n' "$T/workspaces.json" "$T/ws" > "$T/cfg/init.lua"
R config reload >/dev/null
eq "folder files are read, nested too, hidden folders skipped" "$(R do workspace_list --json | jq -c '[.workspaces[].name | select(. == "prod-api" or . == "hidden" or startswith("qa"))]')" '["prod-api","qa1","qa2"]'
R do workspace_save --args '{"name":"qa2","previous":"qa2","spec":{"root":"/var"}}' >/dev/null
eq "save goes back to the nested file" "$(jq -r '.workspaces.qa2.root' "$T/ws/qa/qa.json")" "/var"
cp "$T/init.lua.bak" "$T/cfg/init.lua"
R config reload >/dev/null

echo
echo "$pass passed, $fail failed"
((fail == 0))
