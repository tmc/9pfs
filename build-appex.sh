#!/usr/bin/env bash
set -euo pipefail

# Assemble the 9pfs FSKit extension as a Swift @main app-extension linked
# against the Go filesystem operations built as a c-archive.
#
#   ./build-appex.sh /tmp/9pfs-build
#
# Set CODESIGN_IDENTITY to sign the bundles. For an installed test the script
# also needs development provisioning profiles whose application identifiers
# match dev.tmc.apple.examples.fskit.9pfs (host) and
# dev.tmc.apple.examples.fskit.9pfs.extension (extension); the extension
# profile must grant com.apple.developer.fskit.fsmodule. Matching profiles are
# auto-discovered from ~/Library/MobileDevice/Provisioning Profiles; set
# NINEPFS_REQUIRE_PROFILES=yes to fail early when they are missing.
#
# Two signing styles:
#
#   development (default) — Apple Development identity, ad-hoc timestamp, no
#     hardened runtime. For local installed tests on a registered device.
#
#   developer-id (NINEPFS_DEVID=yes) — Developer ID Application identity, real
#     RFC3161 timestamp, hardened runtime. The embedded profile must be a
#     Developer ID profile (MAC_APP_DIRECT) whose certificate matches
#     CODESIGN_IDENTITY; the script verifies the match up front. Sign with the
#     repository's static minimal entitlements, NOT the profile's keychain/team
#     boilerplate, or AMFI rejects the sandboxed binary at launch. The resulting
#     build is the input to notarize-build.sh.

dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=scriptlib.sh
. "$dir/scriptlib.sh"
out=${1:-/tmp/9pfs-build}
# The bundle ids and product names are constants, not knobs: they are written
# into the checked-in Info.plists, asserted by verify_signed_build, and baked
# into the provisioning profiles, so a build that changed them could not pass
# the repository's own verification.
bundle_id=dev.tmc.apple.examples.fskit.9pfs.extension
product=NinePFSExtension
host_bundle_id=dev.tmc.apple.examples.fskit.9pfs
host_product=NinePFSHost
identity=${CODESIGN_IDENTITY:-}
extension_profile=${NINEPFS_EXTENSION_PROFILE:-}
host_profile=${NINEPFS_HOST_PROFILE:-}
require_profiles=${NINEPFS_REQUIRE_PROFILES:-}
if [[ "${NINEPFS_DEVID:-}" == yes ]]; then
	signing_style=developer-id
else
	signing_style=development
fi

bundle=$out/$product.appex
fsbundle=$out/9pfs.fs
app=$out/$host_product.app
contents=$bundle/Contents
macos=$contents/MacOS
frameworks=$contents/Frameworks
objdir=$out/obj
extension_entitlements=$out/$product.entitlements.plist
host_entitlements=$out/$host_product.entitlements.plist

rm -rf "$bundle" "$fsbundle" "$app" "$objdir"
mkdir -p "$macos" "$frameworks" "$objdir"

# find_profile prints the first profile matching bundle id $1, the fskit-module
# entitlement if $2 is yes, and — when signing — the certificate behind
# $identity. Without that last test a stale profile for the same bundle id wins
# on directory order and the build dies at the cert<->profile check with a
# usable profile sitting right beside it.
find_profile() {
	local want_bundle_id=$1
	local want_fskit=$2
	local profiles_dir=$HOME/Library/MobileDevice/Provisioning\ Profiles
	local profile app_id has_fskit want_cert got_cert

	[[ -d "$profiles_dir" ]] || return 1
	if [[ -n "$identity" ]]; then
		want_cert=$(identity_sha1 "$identity")
	fi
	for profile in "$profiles_dir"/*; do
		[[ -f "$profile" ]] || continue
		if ! security cms -D -i "$profile" > "$out/profile-search.plist" 2>/dev/null; then
			continue
		fi
		app_id=$(/usr/libexec/PlistBuddy -c 'Print :Entitlements:com.apple.application-identifier' "$out/profile-search.plist" 2>/dev/null || true)
		[[ "${app_id#*.}" == "$want_bundle_id" ]] || continue
		has_fskit=$(/usr/libexec/PlistBuddy -c 'Print :Entitlements:com.apple.developer.fskit.fsmodule' "$out/profile-search.plist" 2>/dev/null || true)
		if [[ "$want_fskit" == yes && "$has_fskit" != true ]]; then
			continue
		fi
		if [[ -n "$want_cert" ]]; then
			got_cert=no
			while read -r fingerprint; do
				if [[ "$fingerprint" == "$want_cert" ]]; then
					got_cert=yes
					break
				fi
			done < <(profile_cert_sha1s "$profile")
			[[ "$got_cert" == yes ]] || continue
		fi
		rm -f "$out/profile-search.plist"
		printf '%s\n' "$profile"
		return 0
	done
	rm -f "$out/profile-search.plist"
	return 1
}

profile_entitlements() {
	local profile=$1
	local entitlements=$2

	security cms -D -i "$profile" > "$out/profile.plist"
	/usr/libexec/PlistBuddy -x -c 'Print :Entitlements' "$out/profile.plist" > "$entitlements"
	rm -f "$out/profile.plist"
}

ensure_bool_entitlement() {
	local entitlements=$1
	local key=$2
	if ! /usr/libexec/PlistBuddy -c "Print :$key" "$entitlements" >/dev/null 2>&1; then
		/usr/libexec/PlistBuddy -c "Add :$key bool true" "$entitlements"
	fi
}

ensure_array_string_entitlement() {
	local entitlements=$1
	local key=$2
	local value=$3
	if ! /usr/libexec/PlistBuddy -c "Print :$key" "$entitlements" >/dev/null 2>&1; then
		/usr/libexec/PlistBuddy -c "Add :$key array" "$entitlements"
	fi
	if ! /usr/libexec/PlistBuddy -c "Print :$key" "$entitlements" | grep -qx "    $value"; then
		/usr/libexec/PlistBuddy -c "Add :$key: string $value" "$entitlements"
	fi
}

verify_profile_app_id() {
	local profile=$1
	local want_bundle_id=$2
	local plist app_id
	plist=$(mktemp)
	security cms -D -i "$profile" >"$plist" 2>/dev/null
	app_id=$(/usr/libexec/PlistBuddy -c 'Print :Entitlements:com.apple.application-identifier' "$plist" 2>/dev/null || true)
	rm -f "$plist"
	if [[ -z "$app_id" || "${app_id#*.}" != "$want_bundle_id" ]]; then
		echo "provisioning profile $profile has application identifier ${app_id:-<none>}, want *.$want_bundle_id" >&2
		exit 1
	fi
}

prepare_entitlements() {
	local profile=$1
	local base=$2
	local entitlements=$3
	local role=$4
	local want_bundle_id=$5

	# Developer ID builds embed the profile (it carries the restricted
	# fskit.fsmodule grant) but sign with the static minimal entitlements: a
	# sandboxed Developer-ID binary cannot satisfy the keychain-access-groups /
	# team-identifier that a profile's entitlements carry, and AMFI rejects it
	# at launch (-413) if it tries. Development builds without a profile also
	# use the static entitlements; only a development build *with* a profile
	# inherits the profile's entitlements (the device-locked dev flow).
	if [[ -n "$profile" ]]; then
		[[ -f "$profile" ]] || { echo "missing provisioning profile: $profile" >&2; exit 1; }
		verify_profile_app_id "$profile" "$want_bundle_id"
	fi
	if [[ -z "$profile" || "$signing_style" != development ]]; then
		cp "$base" "$entitlements"
		return
	fi

	# Only here are the entitlements derived rather than checked in: a profile's
	# entitlements carry the team's boilerplate but not necessarily the keys this
	# file system needs, so add whichever are missing. The static files already
	# carry all of them.
	profile_entitlements "$profile" "$entitlements"
	ensure_bool_entitlement "$entitlements" "com.apple.security.app-sandbox"
	case "$role" in
	extension)
		ensure_bool_entitlement "$entitlements" "com.apple.developer.fskit.fsmodule"
		ensure_bool_entitlement "$entitlements" "com.apple.security.network.client"
		;;
	host)
		ensure_array_string_entitlement "$entitlements" \
			"com.apple.security.temporary-exception.mach-lookup.global-name" \
			"com.apple.filesystems.fskitd"
		;;
	esac
}

if [[ -n "$identity" ]]; then
	if [[ -z "$extension_profile" ]]; then
		extension_profile=$(find_profile "$bundle_id" yes || true)
	fi
	if [[ -z "$host_profile" ]]; then
		host_profile=$(find_profile "$host_bundle_id" no || true)
	fi
fi

if [[ "$signing_style" == developer-id ]]; then
	# A Developer ID build is meaningless without a profile carrying the
	# restricted fskit.fsmodule grant and the cert it is signed with.
	require_profiles=yes
fi

if [[ "$require_profiles" == yes ]]; then
	[[ -n "$extension_profile" ]] || {
		echo "missing matching extension profile for $bundle_id with com.apple.developer.fskit.fsmodule" >&2
		exit 1
	}
	[[ -n "$host_profile" ]] || {
		echo "missing matching host profile for $host_bundle_id" >&2
		exit 1
	}
fi

if [[ "$signing_style" == developer-id ]]; then
	[[ -n "$identity" ]] || { echo "developer-id mode needs CODESIGN_IDENTITY" >&2; exit 1; }
	# Fail now on the cert<->profile mismatch rather than at AMFI launch.
	require_cert_in_profile "$identity" "$extension_profile"
	require_cert_in_profile "$identity" "$host_profile"
fi

# codesign_bundle signs $1 with the active style, applying the entitlements in
# $2. Development uses an ad-hoc timestamp and no hardened runtime (device-locked
# dev flow); developer-id uses a real RFC3161 timestamp and the hardened runtime,
# both required for notarization.
codesign_bundle() {
	local target=$1
	local entitlements=$2
	if [[ "$signing_style" == developer-id ]]; then
		codesign --force --timestamp --options runtime \
			--entitlements "$entitlements" --sign "$identity" "$target"
	else
		codesign --force --timestamp=none \
			--entitlements "$entitlements" --sign "$identity" "$target"
	fi
}

# Build the Go filesystem operations as a c-archive. The cshared build tag
# exports NinePFSInit/NinePFSConfigureFileSystem/NinePFS*Resource for the Swift
# entrypoint to call. A throwaway module file lets the build resolve the local
# apple module and the patched p9 client without a checked-in replace.
p9src=$objdir/p9-src
moddir=$objdir/mod
modfile=$moddir/go.mod
go_archive=$objdir/libNinePFS.a
mkdir -p "$moddir"

prepare_p9_module "$p9src"
# Carry go.mod through verbatim, but resolve any relative apple replace target
# to an absolute path: the temp modfile lives in a scratch dir where a relative
# "../.." would no longer point at the monorepo. A pinned require (no replace,
# the shipped configuration) or an already-absolute replace passes through
# untouched.
rewrite_apple_replace "$dir/go.mod" > "$modfile"
cp "$dir/go.sum" "${modfile%.mod}.sum"
{
	echo
	echo "replace github.com/hugelgupf/p9 => $p9src"
} >> "$modfile"

deploy_target=${MACOSX_DEPLOYMENT_TARGET:-15.4}
(cd "$dir" && GOWORK=off GOFLAGS="-modfile=$modfile" \
	MACOSX_DEPLOYMENT_TARGET="$deploy_target" \
	CGO_CFLAGS="-mmacosx-version-min=$deploy_target ${CGO_CFLAGS:-}" \
	CGO_LDFLAGS="-mmacosx-version-min=$deploy_target ${CGO_LDFLAGS:-}" \
	go build -tags cshared \
		-ldflags "-extldflags=-mmacosx-version-min=$deploy_target" \
		-buildmode=c-archive -o "$go_archive" .)
rm -f "${go_archive%.a}.h"

# Compile the ObjC NinePFileSystem class and the Swift @main entrypoint, and
# link them with the Go archive into the extension executable.
header=$dir/native/appex/NinePFileSystem.h
objc_source=$dir/native/appex/NinePFileSystem.m
objc_object=$objdir/NinePFileSystem.o
# One deployment target drives the Go/C flags above and the Swift/clang target
# here; two independent settings could silently disagree.
swift_target=$(uname -m)-apple-macos$deploy_target

xcrun clang -fobjc-arc -fmodules \
	-target "$swift_target" \
	-I "$dir/native/appex" \
	-c "$objc_source" -o "$objc_object"
xcrun swiftc -O -parse-as-library \
	-target "$swift_target" \
	-application-extension \
	-framework Foundation \
	-framework ExtensionFoundation \
	-framework FSKit \
	-import-objc-header "$header" \
	"$dir/native/appex/NinePFSExtension.swift" "$objc_object" "$go_archive" \
	-Xlinker -e -Xlinker _NSExtensionMain \
	-Xlinker -rpath -Xlinker @executable_path/../Frameworks \
	-o "$macos/$product"

cp "$dir/native/appex/Info.plist" "$contents/Info.plist"

prepare_entitlements "$extension_profile" "$dir/native/appex/NinePFSExtension.entitlements" "$extension_entitlements" extension "$bundle_id"
if [[ -n "$extension_profile" ]]; then
	cp "$extension_profile" "$contents/embedded.provisionprofile"
fi

if [[ -n "$identity" ]]; then
	codesign_bundle "$macos/$product" "$extension_entitlements"
	codesign_bundle "$bundle" "$extension_entitlements"
fi

# The 9pfs.fs mount-helper bundle is only needed for plain `mount -t 9pfs`;
# direct `/sbin/mount -F -t 9pfs` does not use it.
mkdir -p "$fsbundle/Contents/Resources"
cp "$dir/native/fsbundle/Info.plist" "$fsbundle/Contents/Info.plist"
cp "$dir/native/mounthelper/mount_9pfs" "$fsbundle/Contents/Resources/mount_9pfs"
chmod +x "$fsbundle/Contents/Resources/mount_9pfs"

# Build the host app and embed the extension under Contents/Extensions.
mkdir -p "$app/Contents/MacOS" "$app/Contents/Extensions"
xcrun swiftc -O -parse-as-library \
	-target "$swift_target" \
	-application-extension \
	-framework FSKit \
	-framework SwiftUI \
	"$dir/native/host/App.swift" \
	-o "$app/Contents/MacOS/$host_product"
cp "$dir/native/host/Info.plist" "$app/Contents/Info.plist"
cp -R "$bundle" "$app/Contents/Extensions/$product.appex"
prepare_entitlements "$host_profile" "$dir/native/host/NinePFSHost.entitlements" "$host_entitlements" host "$host_bundle_id"
if [[ -n "$host_profile" ]]; then
	cp "$host_profile" "$app/Contents/embedded.provisionprofile"
fi
if [[ -n "$identity" ]]; then
	# Sign the embedded extension first (codesign signs inside-out), then the
	# host app, so the host's seal covers the already-sealed extension.
	codesign_bundle "$app/Contents/Extensions/$product.appex/Contents/MacOS/$product" "$extension_entitlements"
	codesign_bundle "$app/Contents/Extensions/$product.appex" "$extension_entitlements"
	codesign_bundle "$app" "$host_entitlements"
fi

echo "$bundle"
echo "$fsbundle"
echo "$app"
