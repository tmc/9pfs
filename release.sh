#!/usr/bin/env bash
set -euo pipefail

# Produce a downloadable, notarized 9pfs release: a Developer ID build of
# NinePFSHost.app, notarized and stapled, packaged as a drag-install disk image
# and as a zip, each with a SHA-256 checksum.
#
#   CODESIGN_IDENTITY='Developer ID Application: NAME (TEAMID)' \
#     ./release.sh v0.1.0 [out_dir]
#
# Steps (each outward-facing step is gated):
#   1. build-appex.sh in developer-id mode (hardened runtime, real timestamp).
#   2. notarize-build.sh (upload to Apple, staple)         — CONFIRM_9PFS_NOTARIZE=yes
#   3. package the STAPLED app as a .dmg and a .zip, notarize and staple the
#      image, and write a SHA-256 checksum beside each.
#   4. optional: gh release create <tag> with the assets   — CONFIRM_9PFS_PUBLISH=yes
#
# The release notes are fixed install instructions; set NINEPFS_RELEASE_NOTES to
# append what changed in this release.
#
# To publish assets this script already produced, without rebuilding or paying
# for another trip to Apple:
#
#   CONFIRM_9PFS_PUBLISH=yes NINEPFS_PUBLISH_ONLY=yes ./release.sh v0.1.0 [out_dir]
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
publish_only=${NINEPFS_PUBLISH_ONLY:-}

die() { echo "release: $*" >&2; exit 1; }

# install_notes are the same for every release: how to install the artifacts.
# NINEPFS_RELEASE_NOTES, if set, is appended below them to say what changed.
install_notes="Notarized Developer ID build of the 9pfs FSKit file system. Open the disk image and drag NinePFSHost.app to Applications, open it once to register the extension, enable 9pfs in System Settings > General > Login Items & Extensions > File System Extensions, then mount with /sbin/mount -F -t 9pfs. See README for details."

build_dir=$out/build
app=$build_dir/NinePFSHost.app
dmg=$out/NinePFSHost-$tag.dmg
zip=$out/NinePFSHost-$tag.zip

# checksum_for writes $1.sha256 next to $1, holding the bare filename so that
# `shasum -a 256 -c` works from the directory the assets were downloaded into.
checksum_for() {
	local asset=$1
	( cd "$(dirname "$asset")" && shasum -a 256 "$(basename "$asset")" > "$asset.sha256" )
}

if [[ "$publish_only" == yes ]]; then
	# Publishing what a previous run produced. Nothing is rebuilt and nothing is
	# uploaded to Apple, so the artifacts have to be checked rather than trusted.
	[[ -f "$dmg" && -f "$zip" ]] || die "no artifacts to publish in $out (run without NINEPFS_PUBLISH_ONLY first)"
	for asset in "$dmg" "$zip"; do
		[[ -f "$asset.sha256" ]] || die "missing checksum: $asset.sha256"
		( cd "$out" && shasum -a 256 -c "$(basename "$asset").sha256" >/dev/null ) ||
			die "checksum mismatch: $asset"
	done
	xcrun stapler validate "$dmg" >/dev/null 2>&1 || die "disk image is not stapled: $dmg"
	echo "release: verified existing artifacts in $out"
else
	identity=${CODESIGN_IDENTITY:?release.sh needs CODESIGN_IDENTITY (a Developer ID Application identity)}

	echo "release: building developer-id bundle in $build_dir"
	# Only the build directory is discarded. Artifacts from a previous run stay
	# until they are replaced below, so a run that stops early (at the
	# notarization gate, say) does not destroy a release that was already made.
	rm -rf "$build_dir"
	mkdir -p "$build_dir"
	CODESIGN_IDENTITY="$identity" NINEPFS_DEVID=yes NINEPFS_VERSION="${tag#v}" \
		"$dir/build-appex.sh" "$build_dir" >/dev/null
	verify_signed_build "$build_dir"

	echo "release: notarizing"
	# notarize-build.sh owns the notarization gate and the staple verification:
	# it prints its plan and stops when unconfirmed, and exits non-zero unless
	# the app ends up notarized and stapled. This script only decides what to do
	# next.
	"$dir/notarize-build.sh" "$build_dir"
	if [[ "${CONFIRM_9PFS_NOTARIZE:-}" != yes ]]; then
		echo
		echo "release: stopping after build — set CONFIRM_9PFS_NOTARIZE=yes to notarize+package" >&2
		exit 0
	fi

	# The zip carries the stapled app for scripted installs; the disk image is
	# what a person downloads, and it is signed and notarized in its own right so
	# that opening it is the only verification step required.
	echo "release: packaging $zip"
	rm -f "$zip" "$zip.sha256"
	/usr/bin/ditto -c -k --keepParent "$app" "$zip"
	checksum_for "$zip"

	echo "release: packaging $dmg"
	rm -f "$dmg" "$dmg.sha256"
	make_dmg "$app" "$dmg"
	# Name the image explicitly: codesign otherwise derives the identifier from
	# the file name, so it would change with every version tag.
	codesign --force --timestamp \
		--identifier dev.tmc.apple.examples.fskit.9pfs.dmg \
		--sign "$identity" "$dmg"
	notary_args=()
	notary_credential=
	resolve_notary_args || die "no notarization credentials"
	notary_submit "$dmg" "$build_dir" || die "disk image notarization failed"
	staple_and_verify "$dmg" dmg || die "disk image did not end up notarized and stapled"
	checksum_for "$dmg"
fi

cat <<EOF

release: artifacts ready
  $dmg
  $zip

$(cat "$dmg.sha256")
$(cat "$zip.sha256")
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
gh release create "$tag" "$dmg" "$dmg.sha256" "$zip" "$zip.sha256" \
	--repo "$(git -C "$dir" remote get-url origin)" \
	--title "9pfs $tag" \
	--notes "$install_notes${NINEPFS_RELEASE_NOTES:+

$NINEPFS_RELEASE_NOTES}"

echo "release: published $tag"
