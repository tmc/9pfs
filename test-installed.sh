#!/usr/bin/env bash
set -euo pipefail

# Mount the installed 9pfs extension and exercise it through the FSKit path.
#
#   ./test-installed.sh [MOUNTPOINT]        # disposable 9P2000.L server (default)
#   ./test-installed.sh URL MOUNTPOINT      # mount a server you already run
#
# With no URL it starts a disposable patched p9ufs and mounts it; with a URL it
# mounts that instead. Requires the signed host app installed in /Applications
# and the extension enabled in System Settings (checked by preflight_installed).

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
	prepare_p9_module "$p9src"
	start_9p_server 9p2000l "$root" "$tmp" "$p9src" || die "no disposable server"
	url="ninep://$server_addr?dialect=9p2000l"
fi

mkdir -p "$mnt"
mount | awk '{print $3}' | grep -qx "$mnt" && die "$mnt is already mounted"

preflight_installed
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
test ! -e "$mnt/codex-dir/a.txt" || die "rename left the source behind"
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
	test ! -e "$mnt/codex-dir/sym" || die "remove reported success but sym is still there"
	test ! -e "$mnt/codex-dir/hard" || die "remove reported success but hard is still there"
fi

# Rename onto a name that already exists: the path an atomic save takes, and
# the one a rename to a fresh name never reaches.
printf 'over\n' >"$mnt/codex-dir/over.txt"
mv "$mnt/codex-dir/b.txt" "$mnt/codex-dir/over.txt" || die "rename over an existing file failed"
test ! -e "$mnt/codex-dir/b.txt" || die "rename over an existing file left the source behind"
test "$(cat "$mnt/codex-dir/over.txt")" = "written " || die "rename over an existing file did not replace it"

# A zero exit from rm is not a removal. Asserting only that these commands
# succeed is what let a remove that silently did nothing pass here while this
# script printed "remove ok".
rm "$mnt/codex-dir/over.txt"
test ! -e "$mnt/codex-dir/over.txt" || die "remove reported success but the file is still there"
rmdir "$mnt/codex-dir"
test ! -e "$mnt/codex-dir" || die "rmdir reported success but the directory is still there"

echo "9pfs: installed FSKit mount read/write/rename/chmod/mtime/truncate/link/xattr/remove ok"
