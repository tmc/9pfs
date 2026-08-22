#!/usr/bin/env bash
set -euo pipefail

# Run the live backend test (TestLive) against a disposable 9p server.
#
#   ./test-live.sh [9p2000|9p2000l]   (default: both)
#
# Each dialect needs its own server; start_9p_server in scriptlib.sh supplies
# it. This script's own job is the scratch modfile: TestLive exercises xattr
# writes, which only the patched p9 client implements, so the test binary has
# to be compiled against the patched module rather than the one go.mod names.
# The op matrix lives in live_test.go.

dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=scriptlib.sh
. "$dir/scriptlib.sh"

dialects=("$@")
if [[ ${#dialects[@]} -eq 0 ]]; then
	dialects=(9p2000 9p2000l)
fi

tmp=$(mktemp -d "${TMPDIR:-/tmp}/9pfs-live.XXXXXX")
tmp=$(cd -- "$tmp" && pwd -P) # normalize: a // in a replace target trips up go
server_pid=
cleanup() {
	[[ -n "$server_pid" ]] && { kill "$server_pid" 2>/dev/null; wait "$server_pid" 2>/dev/null; }
	rm -rf "$tmp"
}
trap cleanup EXIT

# Patched p9 module + scratch modfile so the .L server and the test compile
# against the local chmod/mtime/xattr patch.
p9src=$tmp/p9-src
modfile=$tmp/go.mod
prepare_p9_module "$p9src"
rewrite_apple_replace "$dir/go.mod" >"$modfile"
cp "$dir/go.sum" "${modfile%.mod}.sum"
printf '\nreplace github.com/hugelgupf/p9 => %s\n' "$p9src" >>"$modfile"

for dialect in "${dialects[@]}"; do
	root=$tmp/export-$dialect
	mkdir -p "$root"
	printf 'hello from live 9p\n' >"$root/README"

	start_9p_server "$dialect" "$root" "$tmp" "$p9src"

	status=0
	# The export path lets the test change a file behind the server's back,
	# which is how it checks that attributes are read rather than cached.
	NINEPFS_LIVE_ADDR=$server_addr NINEPFS_LIVE_DIALECT=$dialect \
		NINEPFS_LIVE_EXPORT=$root \
		GOWORK=off GOFLAGS="-modfile=$modfile" \
		go test "$dir" -run TestLive -count=1 -v || status=$?

	kill "$server_pid" 2>/dev/null || true
	wait "$server_pid" 2>/dev/null || true
	server_pid=
	[[ $status -eq 0 ]] || exit $status
done

echo "9pfs: live backend test ok (${dialects[*]})"
