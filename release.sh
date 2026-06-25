#!/usr/bin/env bash
set -euo pipefail

# Produce a downloadable, notarized 9pfs release: a Developer ID build of
# NinePFSHost.app, notarized and stapled, packaged as a zip with a checksum.
#
#   CODESIGN_IDENTITY='Developer ID Application: NAME (TEAMID)' \
#     ./release.sh v0.1.0 [out_dir]
#
# Steps (each outward-facing step is gated):
#   1. build-appex.sh in developer-id mode (hardened runtime, real timestamp).
#   2. notarize-build.sh (upload to Apple, staple)         — CONFIRM_9PFS_NOTARIZE=yes
#   3. zip the STAPLED app + write a SHA-256 checksum.
#   4. optional: gh release create <tag> with the assets   — CONFIRM_9PFS_PUBLISH=yes
#
# Profiles: developer-id mode needs Developer ID provisioning profiles (type
# MAC_APP_DIRECT) whose embedded cert matches CODESIGN_IDENTITY. Pass them with
# NINEPFS_EXTENSION_PROFILE / NINEPFS_HOST_PROFILE, or let build-appex.sh
# auto-discover from ~/Library/MobileDevice/Provisioning Profiles. build-appex.sh
# verifies the cert<->profile match before signing.

dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=scriptlib.sh
. "$dir/scriptlib.sh"

tag=${1:?usage: release.sh TAG [OUT_DIR]}
out=${2:-/tmp/9pfs-release-$tag}
identity=${CODESIGN_IDENTITY:?release.sh needs CODESIGN_IDENTITY (a Developer ID Application identity)}

die() { echo "release: $*" >&2; exit 1; }

build_dir=$out/build
app=$build_dir/NinePFSHost.app
asset=$out/NinePFSHost-$tag.zip
checksum=$asset.sha256

echo "release: building developer-id bundle in $build_dir"
rm -rf "$out"
mkdir -p "$build_dir"
CODESIGN_IDENTITY="$identity" NINEPFS_DEVID=yes "$dir/build-appex.sh" "$build_dir" >/dev/null
"$dir/verify-signed-build.sh" "$build_dir"

echo "release: notarizing"
# notarize-build.sh is itself gated; pass the confirmation through.
CONFIRM_9PFS_NOTARIZE="${CONFIRM_9PFS_NOTARIZE:-}" "$dir/notarize-build.sh" "$build_dir"
if [[ "${CONFIRM_9PFS_NOTARIZE:-}" != yes ]]; then
	echo
	echo "release: stopping after build — set CONFIRM_9PFS_NOTARIZE=yes to notarize+package" >&2
	exit 0
fi

# A stapled app carries its ticket offline; confirm before packaging. stapler
# validate's CloudKit lookup is flaky, so retry, then fall back to Gatekeeper,
# which reads the stapled ticket without the network.
staple_ok=
for _ in 1 2 3; do
	if xcrun stapler validate "$app" >/dev/null 2>&1; then staple_ok=yes; break; fi
done
if [[ -z "$staple_ok" ]]; then
	spctl -a -vvv --type install "$app" 2>&1 | grep -q 'source=Notarized Developer ID' ||
		die "app is not notarized/stapled: $app"
fi

echo "release: packaging $asset"
rm -f "$asset" "$checksum"
/usr/bin/ditto -c -k --keepParent "$app" "$asset"
( cd "$out" && shasum -a 256 "$(basename "$asset")" > "$checksum" )

cat <<EOF

release: artifacts ready
  $asset
  $checksum

$(cat "$checksum")
EOF

if [[ "${CONFIRM_9PFS_PUBLISH:-}" != yes ]]; then
	echo
	echo "release: set CONFIRM_9PFS_PUBLISH=yes (with a configured git remote) to gh release create $tag" >&2
	exit 0
fi

command -v gh >/dev/null || die "gh not found; cannot publish"
git -C "$dir" remote get-url origin >/dev/null 2>&1 ||
	die "no git remote 'origin'; push the repo before publishing"

echo "release: creating GitHub release $tag"
gh release create "$tag" "$asset" "$checksum" \
	--repo "$(git -C "$dir" remote get-url origin)" \
	--title "9pfs $tag" \
	--notes "Notarized Developer ID build of the 9pfs FSKit file system. Download, open NinePFSHost.app, enable the extension in System Settings, then mount with /sbin/mount -F -t 9pfs. See README for details."

echo "release: published $tag"
