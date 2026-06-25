#!/usr/bin/env bash

# rewrite_apple_replace prints a go.mod to stdout with any relative
# "replace github.com/tmc/apple => <relative>" target rewritten to an
# absolute path, resolved against the directory holding the go.mod. Builds
# that copy go.mod into a scratch modfile need this because a relative
# replace target stops resolving once the file moves. A pinned require with
# no replace (the shipped configuration) and an already-absolute replace
# both pass through unchanged.
rewrite_apple_replace() {
	local gomod=$1
	local base
	base=$(cd -- "$(dirname -- "$gomod")" && pwd)
	awk -v base="$base" '
		/^replace github.com\/tmc\/apple => / && $4 !~ /^\// {
			cmd = "cd " base " && cd " $4 " && pwd"
			cmd | getline abs
			close(cmd)
			print $1, $2, $3, abs
			next
		}
		{ print }
	' "$gomod"
}

ninepfs_active_mounts() {
	mount | awk '$0 ~ /\(9pfs[,)]/ {print $3}'
}

require_no_active_9pfs_mounts() {
	local mounts

	if [[ "${NINEPFS_ALLOW_ACTIVE_MOUNTS:-}" == "yes" ]]; then
		return 0
	fi
	mounts=$(ninepfs_active_mounts)
	if [[ -n "$mounts" ]]; then
		echo "9pfs: active 9pfs mount(s) present; refusing to continue" >&2
		printf '%s\n' "$mounts" >&2
		echo "9pfs: unmount them first, or set NINEPFS_ALLOW_ACTIVE_MOUNTS=yes for a deliberate probe window" >&2
		return 1
	fi
}
