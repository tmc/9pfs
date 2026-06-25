#!/usr/bin/env bash
set -euo pipefail

# Run the live backend test (TestLive) against a disposable 9p server.
#
#   ./test-live.sh [9p2000|9p2000l]   (default: both)
#
# Each dialect needs its own server: classic 9P2000 uses knusbaum/go9p's
# export9p, 9P2000.L uses the patched hugelgupf/p9 p9ufs. This script exports a
# README, starts the right server, and runs `go test -run TestLive` with the
# address and dialect in the environment. The op matrix lives in live_test.go;
# this script only supplies a server.

dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=scriptlib.sh
. "$dir/scriptlib.sh"

export9p_version=v1.18.0

dialects=("$@")
if [[ ${#dialects[@]} -eq 0 ]]; then
	dialects=(9p2000 9p2000l)
fi

tmp=$(mktemp -d "${TMPDIR:-/tmp}/9pfs-live.XXXXXX")
tmp=$(cd -- "$tmp" && pwd -P) # normalize: a // in a replace target trips up go
trap 'rm -rf "$tmp"' EXIT

# Patched p9 module + scratch modfile so the .L server and the test compile
# against the local chmod/mtime/xattr patch.
p9src=$tmp/p9-src
modfile=$tmp/go.mod
"$dir/prepare-p9-module.sh" "$p9src"
rewrite_apple_replace "$dir/go.mod" >"$modfile"
cp "$dir/go.sum" "${modfile%.mod}.sum"
printf '\nreplace github.com/hugelgupf/p9 => %s\n' "$p9src" >>"$modfile"

# start_server DIALECT ROOT ADDR LOG -> sets server_pid. export9p speaks classic
# 9P2000; p9ufs speaks 9P2000.L. export9p is built from a throwaway pinned
# module so the build is cached and hermetic (no run-time proxy lookup).
start_server() {
	local dialect=$1 root=$2 addr=$3 log=$4
	case "$dialect" in
	9p2000)
		local bin=$tmp/export9p
		if [[ ! -x "$bin" ]]; then
			local moddir=$tmp/export9p-mod
			mkdir -p "$moddir"
			(
				cd "$moddir"
				GOWORK=off go mod init ninepfs.test/export9p >/dev/null 2>&1
				GOWORK=off go get "github.com/knusbaum/go9p/cmd/export9p@$export9p_version" >/dev/null 2>&1
				GOWORK=off go build -o "$bin" github.com/knusbaum/go9p/cmd/export9p
			)
		fi
		"$bin" -dir "$root" -address "$addr" -noperm >"$log" 2>&1 &
		;;
	9p2000l)
		local bin=$tmp/p9ufs
		[[ -x "$bin" ]] || (cd "$p9src" && GOWORK=off go build -o "$bin" ./cmd/p9ufs)
		"$bin" -root "$root" "$addr" >"$log" 2>&1 &
		;;
	*)
		echo "test-live: unknown dialect $dialect" >&2
		return 1
		;;
	esac
	server_pid=$!
}

for dialect in "${dialects[@]}"; do
	root=$tmp/export-$dialect
	mkdir -p "$root"
	printf 'hello from live 9p\n' >"$root/README"

	port=$((20000 + RANDOM % 20000))
	addr=127.0.0.1:$port
	log=$tmp/server-$dialect.log
	start_server "$dialect" "$root" "$addr" "$log"

	ready=
	for _ in $(seq 1 300); do
		if nc -z 127.0.0.1 "$port" >/dev/null 2>&1; then
			ready=1
			break
		fi
		kill -0 "$server_pid" 2>/dev/null || break
		sleep 0.1
	done
	if [[ -z "$ready" ]]; then
		echo "9pfs: $dialect server did not become ready at $addr" >&2
		cat "$log" >&2
		kill "$server_pid" 2>/dev/null || true
		exit 1
	fi

	NINEPFS_LIVE_ADDR=$addr NINEPFS_LIVE_DIALECT=$dialect \
		GOWORK=off GOFLAGS="-modfile=$modfile" \
		go test "$dir" -run TestLive -count=1 -v
	status=$?

	kill "$server_pid" 2>/dev/null || true
	wait "$server_pid" 2>/dev/null || true
	[[ $status -eq 0 ]] || exit $status
done

echo "9pfs: live backend test ok (${dialects[*]})"
