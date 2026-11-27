#!/bin/sh
# serve.sh — lifecycle wrapper for the codex-ticketing MCP server.
#
# Manages the shared ticketing server through a pid file written next to
# wherever the ticket DB resolves to. Agents use this to find, start, and
# restart the server instead of spawning duplicates.
#
# Usage:
#   serve.sh [status]        show running state, pid, port, DB path (default)
#   serve.sh start           start the server (no-op if already running)
#   serve.sh stop            stop the server and remove the pid file
#   serve.sh restart         stop, then start
#   --repo-local             resolve the DB/pid under <git repo root>/.ticketing/
#
# DB / pid-file resolution (same order as app/main.lua):
#   1. TICKETS_DB env        pid file goes beside the given DB path
#   2. --repo-local          <git repo root>/.ticketing/server.pid
#   3. default               ~/.codex/ticketing/server.pid
set -eu

# Caller's cwd is the default --repo-local search root; script_dir locates
# run.sh. Skill dir in a checkout or a release bundle both resolve to
# <root>/skills/codex-ticketing/serve.sh with run.sh at the root.
script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)

run_sh="$script_dir/../../run.sh"

cmd=status
repo_local=0
for a in "$@"; do
	case $a in
		start | stop | restart | status) cmd=$a ;;
		--repo-local) repo_local=1 ;;
		-h | --help) sed -n '2,17p' "$0"; exit 0 ;;
		*) printf 'serve.sh: unknown argument %s\n' "$a" >&2; exit 64 ;;
	esac
done

if [ -n "${TICKETS_DB:-}" ]; then
	db_path=$TICKETS_DB
	repo_local=0
elif [ "$repo_local" -eq 1 ]; then
	if repo_root=$(git rev-parse --show-toplevel 2>/dev/null); then
		:
	else
		repo_root=$PWD
	fi
	db_path=$repo_root/.ticketing/tickets.db
else
	db_path="${HOME:?HOME not set; set TICKETS_DB or use --repo-local}/.codex/ticketing/tickets.db"
fi

db_dir=$(dirname -- "$db_path")
if abs_dir=$(CDPATH='' cd -- "$db_dir" 2>/dev/null && pwd); then
	db_dir=$abs_dir
fi
pid_file=$db_dir/server.pid
port=${PORT:-8080}

alive() {
	pid=$1
	case $pid in '' | *[!0-9]*) return 1 ;; esac
	kill -0 -- "$pid" 2>/dev/null
}

running() {
	[ -f "$pid_file" ] && alive "$(cat -- "$pid_file")"
}

wait_ready() {
	i=0
	while [ "$i" -lt 15 ]; do
		if curl -sf --max-time 2 "http://127.0.0.1:${port}/" >/dev/null 2>&1; then
			return 0
		fi
		i=$((i + 1))
		sleep 1
	done
	return 1
}

do_status() {
	if running; then
		printf 'running pid=%s port=%s db=%s pid_file=%s\n' \
			"$(cat -- "$pid_file")" "$port" "$db_path" "$pid_file"
	elif [ -f "$pid_file" ]; then
		printf 'stale pid_file=%s (pid %s not alive) db=%s\n' \
			"$pid_file" "$(cat -- "$pid_file")" "$db_path"
		return 1
	else
		printf 'not running port=%s db=%s pid_file=%s\n' \
			"$port" "$db_path" "$pid_file"
		return 1
	fi
}

do_start() {
	if running; then
		printf 'already running pid=%s port=%s db=%s\n' \
			"$(cat -- "$pid_file")" "$port" "$db_path"
		return 0
	fi
	mkdir -p "$db_dir"
	rm -f -- "$pid_file"
	if [ "$repo_local" -eq 1 ]; then
		set -- --repo-local
	else
		set --
	fi
	# Detach the server from the invoking shell as well as its stdin.  On macOS,
	# nohup alone can still leave the child tied to the short-lived agent shell,
	# which makes the pid file look valid until the launcher exits.
	if command -v setsid >/dev/null 2>&1; then
		nohup setsid sh "$run_sh" "$@" </dev/null >"$db_dir/server.log" 2>&1 &
	else
		nohup sh "$run_sh" "$@" </dev/null >"$db_dir/server.log" 2>&1 &
	fi
	pid=$!
	printf '%s\n' "$pid" >"$pid_file"
	if wait_ready; then
		[ "$cmd" = restart ] && printf 'restarted' || printf 'started'
		printf ' pid=%s port=%s db=%s\n' "$pid" "$port" "$db_path"
		return 0
	fi
	printf 'server failed to answer on port %s; pidfile kept, log tail:\n' "$port" >&2
	tail -n 20 -- "$db_dir/server.log" >&2 || true
	return 1
}

do_stop() {
	if running; then
		pid=$(cat -- "$pid_file")
		kill -- "$pid" 2>/dev/null || true
		i=0
		while alive "$pid" && [ "$i" -lt 10 ]; do
			i=$((i + 1))
			sleep 1
		done
		if alive "$pid"; then
			kill -9 -- "$pid" 2>/dev/null || true
		fi
		rm -f -- "$pid_file"
		printf 'stopped pid=%s db=%s\n' "$pid" "$db_path"
	else
		rm -f -- "$pid_file"
		printf 'not running (pid file removed: %s)\n' "$pid_file"
	fi
}

case $cmd in
	start) do_start ;;
	stop) do_stop ;;
	restart) do_stop; do_start ;;
	status) do_status ;;
esac
