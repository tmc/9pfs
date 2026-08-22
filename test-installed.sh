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

	# owned.txt carries a group that is not the current process's primary
	# group, so that the owner reported through the mount distinguishes the
	# server's answer from the extension's own credentials. Reporting
	# os.Getgid() for every file looked correct for as long as every file
	# tested happened to be in the primary group.
	owner_gid=$(id -G | tr ' ' '\n' | grep -vx "$(id -g)" | head -1)
	if [[ -n "$owner_gid" ]]; then
		printf 'owned\n' >"$root/owned.txt"
		chgrp "$owner_gid" "$root/owned.txt" 2>/dev/null || owner_gid=
	fi

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

# What the volume says about itself, which no operation reveals. Everything
# below this point tests that operations work; these lines test that the
# volume's description of itself matches them.
volcaps=$tmp/volcaps
build_volcaps "$volcaps"
linux=false
[[ "$url" == *9p2000l* ]] && linux=true
echo "test-installed: volume capabilities"
require_capability "$mnt" fmt.64BIT_OBJECT_IDS yes "$volcaps"
require_capability "$mnt" fmt.HIDDEN_FILES yes "$volcaps"
require_capability "$mnt" fmt.SYMBOLICLINKS "$($linux && echo yes || echo no)" "$volcaps"
require_capability "$mnt" fmt.HARDLINKS "$($linux && echo yes || echo no)" "$volcaps"
# Persistent object IDs are opt-in per mount and this URL does not ask for
# them, so claiming them here would mean the option is not doing anything.
[[ "$url" == *persistentids=* ]] ||
	require_capability "$mnt" fmt.PERSISTENTOBJECTIDS no "$volcaps"

# Volume size: 9P2000.L carries statfs and reports the server's real numbers,
# while 9P2000 has no statfs and falls back to a one-block placeholder.
blocks=$(df -k "$mnt" | awk 'NR==2 {print $2}')
if $linux; then
	[[ "$blocks" -gt 1 ]] || die "df reports $blocks blocks; 9p2000.l should report the server's size"
	echo "ok: df reports $blocks 1K-blocks"
else
	echo "ok: df reports $blocks 1K-blocks (9p2000 placeholder)"
fi

mkdir "$mnt/codex-dir"
printf 'written through mounted 9pfs\n' >"$mnt/codex-dir/a.txt"
cat "$mnt/codex-dir/a.txt"
mv "$mnt/codex-dir/a.txt" "$mnt/codex-dir/b.txt"
test ! -e "$mnt/codex-dir/a.txt" || die "rename left the source behind"
truncate -s 8 "$mnt/codex-dir/b.txt"
test "$(cat "$mnt/codex-dir/b.txt")" = "written "
chmod 600 "$mnt/codex-dir/b.txt"
# Running chmod proves nothing; the mode it produced is the assertion.
test "$(stat -f '%Lp' "$mnt/codex-dir/b.txt")" = "600" || die "chmod 600 did not take"
touch -t 202001020304 "$mnt/codex-dir/b.txt"
test "$(stat -f '%m' "$mnt/codex-dir/b.txt")" = "1577963040" || die "mtime mismatch"

# The timestamps have to be distinct. Reporting the modification time as all
# four is what this file system did until it kept the rest of the getattr, and
# no operation fails when it does: the mtime assertion above passed throughout.
# chmod moves ctime and leaves mtime, so after the touch above ctime is newer.
if $linux; then
	ctime=$(stat -f '%c' "$mnt/codex-dir/b.txt")
	mtime=$(stat -f '%m' "$mnt/codex-dir/b.txt")
	[[ "$ctime" -gt "$mtime" ]] ||
		die "ctime $ctime is not newer than mtime $mtime; timestamps are not distinct"
	echo "ok: ctime $ctime distinct from mtime $mtime"
fi

if [[ "$url" == *9p2000l* ]]; then
	ln -s b.txt "$mnt/codex-dir/sym"
	test "$(readlink "$mnt/codex-dir/sym")" = "b.txt"
	ln "$mnt/codex-dir/b.txt" "$mnt/codex-dir/hard"
	# A hard link that reports one link is a volume contradicting the
	# HARDLINKS capability asserted above. Both were wrong at once, which
	# is why neither caught the other.
	test "$(stat -f '%l' "$mnt/codex-dir/b.txt")" = "2" ||
		die "hard link created but link count is $(stat -f '%l' "$mnt/codex-dir/b.txt"), want 2"
	xattr -w user.codex value "$mnt/codex-dir/b.txt"
	test "$(xattr -p user.codex "$mnt/codex-dir/b.txt")" = "value"
	xattr -d user.codex "$mnt/codex-dir/b.txt"
	rm "$mnt/codex-dir/sym" "$mnt/codex-dir/hard"
	test ! -e "$mnt/codex-dir/sym" || die "remove reported success but sym is still there"
	test ! -e "$mnt/codex-dir/hard" || die "remove reported success but hard is still there"
fi

# Owner reporting, and chown in both directions. This needs a file whose group
# is not the extension's own primary group; without one, reporting the local
# credentials for every file is indistinguishable from reporting the server's.
if [[ -n "${owner_gid:-}" && -e "$mnt/owned.txt" ]]; then
	got_gid=$(stat -f '%g' "$mnt/owned.txt")
	if $linux; then
		[[ "$got_gid" == "$owner_gid" ]] ||
			die "owned.txt reports gid $got_gid, want the server's $owner_gid"
		echo "ok: owner reported from the server (gid $got_gid)"

		# chown works on 9P2000.L: move the file back to the primary group.
		chgrp "$(id -g)" "$mnt/owned.txt" || die "chgrp failed on 9p2000.l"
		test "$(stat -f '%g' "$mnt/owned.txt")" = "$(id -g)" ||
			die "chgrp reported success but the group did not change"
		echo "ok: chgrp applied through the mount"
	else
		# Classic 9P2000 names owners with strings, so the mount reports
		# local credentials and declines a chown. Declining has to be
		# visible: an unconsumed attribute is how the caller learns the
		# change did not happen, and a silent success is the bug.
		[[ "$got_gid" == "$(id -g)" ]] ||
			die "9p2000 reported gid $got_gid, want the local $(id -g)"
		if chgrp "$owner_gid" "$mnt/owned.txt" 2>/dev/null; then
			die "chgrp reported success on 9p2000, which cannot express one"
		fi
		echo "ok: chgrp declined on 9p2000 rather than silently doing nothing"
	fi
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
echo "9pfs: installed FSKit volume capabilities, attributes and ownership ok"
