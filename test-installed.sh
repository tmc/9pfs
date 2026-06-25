#!/usr/bin/env bash
set -euo pipefail

# Mount the installed 9pfs extension and exercise it through the FSKit path.
#
#   ./test-installed.sh [MOUNTPOINT]        # disposable 9P2000.L server (default)
#   ./test-installed.sh URL MOUNTPOINT      # mount a server you already run
#
# With no URL it starts a disposable patched p9ufs and mounts it; with a URL it
# mounts that instead. Requires the signed host app installed in /Applications
# and the extension enabled in System Settings (checked by preflight-installed).

dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=scriptlib.sh
. "$dir/scriptlib.sh"

die() { echo "test-installed: $*" >&2; exit 1; }

[[ -x /Applications/NinePFSHost.app/Contents/MacOS/NinePFSHost ]] ||
	die "install signed NinePFSHost.app in /Applications first"

require_no_active_9pfs_mounts

tmp=$(mktemp -d "${TMPDIR:-/tmp}/9pfs-installed.XXXXXX")
tmp=$(cd -- "$tmp" && pwd -P)
server_pid=
cleanup() {
	set +e
	if [[ -n "${mnt:-}" ]] && mount | awk '{print $3}' | grep -qx "$mnt"; then
		umount "$mnt" 2>/dev/null || diskutil unmount force "$mnt" 2>/dev/null || true
	fi
	[[ -n "$server_pid" ]] && { kill "$server_pid" 2>/dev/null; wait "$server_pid" 2>/dev/null; }
	rm -rf "$tmp"
}
trap cleanup EXIT

# Two call shapes: a URL plus mountpoint (bring your own server), or just a
# mountpoint (start a disposable one).
if [[ $# -ge 2 ]]; then
	url=$1
	mnt=$2
else
	mnt=${1:-$tmp/mnt}
	root=$tmp/export
	mkdir -p "$root"
	printf 'hello from mounted 9p2000.l\n' >"$root/README"

	p9src=$tmp/p9-src
	"$dir/prepare-p9-module.sh" "$p9src"
	server_bin=$tmp/p9ufs
	(cd "$p9src" && GOWORK=off go build -o "$server_bin" ./cmd/p9ufs)

	port=$((20000 + RANDOM % 20000))
	addr=127.0.0.1:$port
	"$server_bin" -root "$root" "$addr" >"$tmp/p9ufs.log" 2>&1 &
	server_pid=$!
	for _ in $(seq 1 300); do
		nc -z 127.0.0.1 "$port" >/dev/null 2>&1 && break
		kill -0 "$server_pid" 2>/dev/null || { cat "$tmp/p9ufs.log" >&2; die "p9ufs exited before ready"; }
		sleep 0.1
	done
	url="ninep://$addr?dialect=9p2000l"
fi

mkdir -p "$mnt"
mount | awk '{print $3}' | grep -qx "$mnt" && die "$mnt is already mounted"

"$dir/preflight-installed.sh"
/Applications/NinePFSHost.app/Contents/MacOS/NinePFSHost --fskit-probe

echo "test-installed: mounting $url at $mnt"
if ! /sbin/mount -F -t 9pfs "$url" "$mnt"; then
	mount | awk '{print $3}' | grep -qx "$mnt" || die "mount failed and $mnt is not mounted"
fi

ls -la "$mnt"
mkdir "$mnt/codex-dir"
printf 'written through mounted 9pfs\n' >"$mnt/codex-dir/a.txt"
cat "$mnt/codex-dir/a.txt"
mv "$mnt/codex-dir/a.txt" "$mnt/codex-dir/b.txt"
truncate -s 8 "$mnt/codex-dir/b.txt"
test "$(cat "$mnt/codex-dir/b.txt")" = "written "
chmod 600 "$mnt/codex-dir/b.txt"
touch -t 202001020304 "$mnt/codex-dir/b.txt"
test "$(stat -f '%m' "$mnt/codex-dir/b.txt")" = "1577963040" || die "mtime mismatch"

if [[ "$url" == *9p2000l* ]]; then
	ln -s b.txt "$mnt/codex-dir/sym"
	test "$(readlink "$mnt/codex-dir/sym")" = "b.txt"
	ln "$mnt/codex-dir/b.txt" "$mnt/codex-dir/hard"
	xattr -w user.codex value "$mnt/codex-dir/b.txt"
	test "$(xattr -p user.codex "$mnt/codex-dir/b.txt")" = "value"
	xattr -d user.codex "$mnt/codex-dir/b.txt"
	rm "$mnt/codex-dir/sym" "$mnt/codex-dir/hard"
fi

rm "$mnt/codex-dir/b.txt"
rmdir "$mnt/codex-dir"

echo "9pfs: installed FSKit mount read/write/rename/chmod/mtime/truncate/link/xattr/remove ok"
