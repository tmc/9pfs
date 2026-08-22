#!/usr/bin/env bash

# Message prefixes follow one rule across these scripts: "9pfs:" introduces the
# single line that states a gate's verdict ("9pfs: local verification ok"),
# while the name of the script or helper doing the work introduces everything
# else — progress and errors ("release: packaging ...", "verify-signed-build:
# missing app: ..."). Grepping a CI log for "^9pfs:" therefore yields the
# results and nothing else.

# scriptlib_dir is the directory holding this library, for helpers that need a
# repository-relative path (for example the p9 patch).
scriptlib_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)

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

# identity_sha1 prints the lowercase SHA-1 fingerprint (no colons) of the
# codesigning identity named by $1, as it appears in the keychain. The identity
# may be a full common name ("Developer ID Application: Name (TEAMID)") or a
# 40-hex fingerprint; in the latter case it is returned normalized.
identity_sha1() {
	local identity=$1
	if [[ "$identity" =~ ^[0-9A-Fa-f]{40}$ ]]; then
		printf '%s\n' "$identity" | tr 'A-F' 'a-f'
		return 0
	fi
	security find-certificate -c "$identity" -Z 2>/dev/null |
		awk '/^SHA-1 hash:/ {print tolower($3); exit}'
}

# profile_cert_sha1s prints the lowercase SHA-1 fingerprint of each Developer ID
# certificate embedded in the provisioning profile named by $1, one per line.
# The certificates live in the profile's decoded DeveloperCertificates array;
# they are exported as base64 (binary-safe, unlike piping raw DER through the
# shell) and fingerprinted with openssl.
profile_cert_sha1s() {
	local profile=$1
	local plist certs_xml
	plist=$(mktemp)
	certs_xml=$(mktemp)
	if ! security cms -D -i "$profile" >"$plist" 2>/dev/null; then
		rm -f "$plist" "$certs_xml"
		return 1
	fi
	/usr/libexec/PlistBuddy -x -c 'Print :DeveloperCertificates' "$plist" >"$certs_xml" 2>/dev/null
	awk '
		/<data>/      { collecting = 1; b64 = ""; next }
		/<\/data>/    { print b64; collecting = 0; next }
		collecting    { gsub(/[ \t]/, ""); b64 = b64 $0 }
	' "$certs_xml" | while read -r b64; do
		[[ -n "$b64" ]] || continue
		printf '%s' "$b64" | base64 -D 2>/dev/null |
			openssl x509 -inform DER -noout -fingerprint -sha1 2>/dev/null |
			sed -e 's/.*=//' -e 's/://g' | tr 'A-F' 'a-f'
	done
	rm -f "$plist" "$certs_xml"
}

# require_cert_in_profile fails unless the SHA-1 of signing identity $1 appears
# among the certificates embedded in provisioning profile $2. This catches the
# cert<->profile mismatch that otherwise surfaces only at AMFI launch as
# -413 "No matching profile found".
require_cert_in_profile() {
	local identity=$1
	local profile=$2
	local want got
	want=$(identity_sha1 "$identity")
	if [[ -z "$want" ]]; then
		echo "signing: cannot resolve SHA-1 for identity: $identity" >&2
		return 1
	fi
	while read -r got; do
		[[ "$got" == "$want" ]] && return 0
	done < <(profile_cert_sha1s "$profile")
	echo "signing: identity $identity ($want) is not embedded in profile $profile" >&2
	echo "signing: regenerate the profile against the cert you hold, e.g." >&2
	echo "  asc profiles create --type MAC_APP_DIRECT --bundle <id> --certs <asc-cert-id>" >&2
	return 1
}

# prepare_p9_module copies the github.com/hugelgupf/p9 version required by
# go.mod into $1 and applies p9-9pfs.patch. The patch has two halves and they
# are not alike:
#
#   p9/client_file.go — SetXattr and RemoveXattr, which upstream leaves as
#     ENOSYS. p9LBackend calls them, so this half is part of the product: a
#     build without it mounts fine and fails every xattr write. Upstream
#     already implements the read half (GetXattr, ListXattrs).
#
#   fsimpl/localfs/localfs.go — chmod, utimes and statfs, which upstream
#     either drops silently or leaves unimplemented. localfs serves both the
#     live test and the bundled 9pdemo, so this half ships too: without the
#     statfs hunk the demo reports a volume of unknown size.
#
# Both are local to the build and change no module dependency, so they ship in
# binaries whose go.mod advertises stock p9. Retiring either means landing it
# upstream. scriptlib_dir is the directory holding this library.
prepare_p9_module() {
	local dest=${1:?"usage: prepare_p9_module dest"}
	local src
	# Download first: a fresh checkout has no module cache, and go list alone
	# reports an empty directory for a module that has not been fetched.
	src=$(cd "$scriptlib_dir" && GOWORK=off go mod download github.com/hugelgupf/p9 &&
		GOWORK=off go list -m -f '{{.Dir}}' github.com/hugelgupf/p9)
	if [[ -z "$src" ]]; then
		echo "prepare_p9_module: cannot locate github.com/hugelgupf/p9" >&2
		return 1
	fi
	rm -rf "$dest"
	mkdir -p "$dest"
	cp -R "$src/." "$dest/"
	chmod -R u+w "$dest"
	patch -d "$dest" -p1 < "$scriptlib_dir/p9-9pfs.patch"
}

export9p_version=v1.18.0

# start_9p_server starts a disposable 9p server exporting ROOT on the loopback
# and waits until it accepts connections. DIALECT picks the server: 9p2000 uses
# knusbaum/go9p's export9p, 9p2000.L uses the p9ufs built from the patched p9
# source in P9SRC (see prepare_p9_module). WORKDIR holds the built binaries and
# the server log. On success the address is in $server_addr and the process id
# in $server_pid, which the caller kills.
#
# The port is random and the launch is retried: two servers started in the same
# second can pick the same port, and the loser dies at bind time, which is
# indistinguishable from a readiness timeout unless the launch is retried.
start_9p_server() {
	local dialect=$1 root=$2 workdir=$3 p9src=${4:-}
	local bin log port moddir

	case "$dialect" in
	9p2000)
		bin=$workdir/export9p
		if [[ ! -x "$bin" ]]; then
			# Build from a throwaway pinned module so the binary is cached and
			# hermetic rather than resolved through the proxy on every run.
			moddir=$workdir/export9p-mod
			mkdir -p "$moddir"
			(
				cd "$moddir" || exit
				GOWORK=off go mod init ninepfs.test/export9p >/dev/null 2>&1
				GOWORK=off go get "github.com/knusbaum/go9p/cmd/export9p@$export9p_version" >/dev/null 2>&1
				GOWORK=off go build -o "$bin" github.com/knusbaum/go9p/cmd/export9p
			)
		fi
		;;
	9p2000l)
		[[ -n "$p9src" ]] || {
			echo "start_9p_server: 9p2000l needs a prepared p9 source" >&2
			return 1
		}
		bin=$workdir/p9ufs
		[[ -x "$bin" ]] || (cd "$p9src" && GOWORK=off go build -o "$bin" ./cmd/p9ufs)
		;;
	*)
		echo "start_9p_server: unknown dialect $dialect" >&2
		return 1
		;;
	esac

	log=$workdir/server-$dialect.log
	for _ in 1 2 3; do
		port=$((20000 + RANDOM % 20000))
		server_addr=127.0.0.1:$port
		case "$dialect" in
		9p2000) "$bin" -dir "$root" -address "$server_addr" -noperm >"$log" 2>&1 & ;;
		9p2000l) "$bin" -root "$root" "$server_addr" >"$log" 2>&1 & ;;
		esac
		server_pid=$!
		for _ in $(seq 1 300); do
			if nc -z 127.0.0.1 "$port" >/dev/null 2>&1; then
				return 0
			fi
			kill -0 "$server_pid" 2>/dev/null || break
			sleep 0.1
		done
		kill "$server_pid" 2>/dev/null || true
		wait "$server_pid" 2>/dev/null || true
	done

	echo "start_9p_server: $dialect server did not become ready at $server_addr" >&2
	cat "$log" >&2
	server_pid=
	return 1
}

# resolve_notary_args fills the notary_args array with notarytool credentials
# and notary_credential with a one-line description of what it found.
# Precedence: NINEPFS_NOTARY_PROFILE (a `notarytool store-credentials` keychain
# profile), then an App Store Connect API key from NINEPFS_ASC_KEY_ID /
# NINEPFS_ASC_ISSUER_ID / NINEPFS_ASC_KEY_PATH, else ~/.appstoreconnect.
#
# Both results are globals rather than output, because a caller that wrote
# `cred=$(resolve_notary_args)` would run this in a subshell and silently get
# an empty notary_args back.
resolve_notary_args() {
	local asc_config key_id issuer_id key_path

	if [[ -n "${NINEPFS_NOTARY_PROFILE:-}" ]]; then
		notary_args=(--keychain-profile "$NINEPFS_NOTARY_PROFILE")
		notary_credential="keychain profile $NINEPFS_NOTARY_PROFILE"
		return 0
	fi

	asc_config=${NINEPFS_ASC_CONFIG:-$HOME/.appstoreconnect/config.yaml}
	key_id=${NINEPFS_ASC_KEY_ID:-$(awk '$1 == "key_id:" {print $2; exit}' "$asc_config" 2>/dev/null)}
	issuer_id=${NINEPFS_ASC_ISSUER_ID:-$(awk '$1 == "issuer_id:" {print $2; exit}' "$asc_config" 2>/dev/null)}
	[[ -n "$key_id" ]] || { echo "notary: no API key id (set NINEPFS_ASC_KEY_ID or NINEPFS_NOTARY_PROFILE)" >&2; return 1; }
	[[ -n "$issuer_id" ]] || { echo "notary: no API issuer id (set NINEPFS_ASC_ISSUER_ID or NINEPFS_NOTARY_PROFILE)" >&2; return 1; }
	key_path=${NINEPFS_ASC_KEY_PATH:-$HOME/.appstoreconnect/private_keys/AuthKey_$key_id.p8}
	[[ -f "$key_path" ]] || { echo "notary: API key file not found: $key_path (set NINEPFS_ASC_KEY_PATH)" >&2; return 1; }
	notary_args=(--key "$key_path" --key-id "$key_id" --issuer "$issuer_id")
	notary_credential="API key $key_id (issuer $issuer_id)"
}

# notary_submit uploads $1 to Apple's notary service, waits for the verdict,
# and fails with the notary log if it is anything but Accepted. Requires
# notary_args (see resolve_notary_args). $2 is a directory for the submission
# log.
notary_submit() {
	local artifact=$1 workdir=$2
	local submit_log status submission_id

	submit_log=$workdir/notarytool-submit.json
	echo "notary: submitting $(basename "$artifact") (waiting for verdict)"
	if ! xcrun notarytool submit "$artifact" "${notary_args[@]}" --wait \
		--output-format json >"$submit_log"; then
		cat "$submit_log" >&2
		echo "notary: submit failed" >&2
		return 1
	fi
	# notarytool --output-format json emits a single object:
	#   {"status":"Accepted","message":"...","id":"<uuid>"}
	# Pull each value by its own key so field order does not matter.
	status=$(sed -n 's/.*"status":"\([^"]*\)".*/\1/p' "$submit_log")
	submission_id=$(sed -n 's/.*"id":"\([^"]*\)".*/\1/p' "$submit_log")
	echo "notary: submission $submission_id status=$status"
	if [[ "$status" != "Accepted" ]]; then
		echo "notary: fetching log for $submission_id" >&2
		xcrun notarytool log "$submission_id" "${notary_args[@]}" >&2 || true
		return 1
	fi
}

# staple_and_verify staples the notarization ticket to $1 and confirms
# Gatekeeper accepts it. $2 is the kind, app or dmg, which selects the
# assessment: an app is assessed as an install, a disk image as something the
# user opens. Callers take a zero exit as proof the artifact is notarized and
# stapled, so this asserts rather than reports.
staple_and_verify() {
	local artifact=$1 kind=$2
	local ok='' assessment

	echo "notary: stapling ticket to $artifact"
	xcrun stapler staple "$artifact"
	# stapler staple already validates what it just wrote; a second validate can
	# fail transiently on CloudKit ticket-lookup timeouts. Retry, then fall back
	# to Gatekeeper, which reads the stapled ticket offline.
	for _ in 1 2 3; do
		if xcrun stapler validate "$artifact" >/dev/null 2>&1; then
			ok=yes
			break
		fi
	done
	[[ -n "$ok" ]] || echo "notary: stapler validate flaky (network); relying on Gatekeeper below" >&2

	echo "notary: Gatekeeper assessment"
	case "$kind" in
	app) assessment=$(spctl -a -vvv --type install "$artifact" 2>&1 || true) ;;
	dmg) assessment=$(spctl -a -vvv --type open --context context:primary-signature "$artifact" 2>&1 || true) ;;
	*) echo "staple_and_verify: unknown kind $kind" >&2; return 1 ;;
	esac
	printf '%s\n' "$assessment"
	case "$assessment" in
	*"source=Notarized Developer ID"*) ;;
	*) echo "notary: $artifact is not notarized/stapled" >&2; return 1 ;;
	esac
}

# make_dmg builds the drag-install disk image at $2 from the app at $1: the app
# beside a symlink to /Applications, so opening the image and dragging one onto
# the other is the whole install. Read-only and compressed (UDZO), which is what
# a signed and notarized image has to be. ditto rather than cp preserves the
# symlinks and extended attributes the app's signature covers.
make_dmg() {
	local app=$1 dmg=$2
	local staging

	staging=$(mktemp -d)
	/usr/bin/ditto "$app" "$staging/$(basename "$app")"
	ln -s /Applications "$staging/Applications"
	rm -f "$dmg"
	hdiutil create -quiet -srcfolder "$staging" -volname 9pfs \
		-fs HFS+ -format UDZO -imagekey zlib-level=9 "$dmg"
	rm -rf "$staging"
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
		echo "active-mounts: 9pfs mount(s) present; refusing to continue" >&2
		printf '%s\n' "$mounts" >&2
		echo "active-mounts: unmount them first, or set NINEPFS_ALLOW_ACTIVE_MOUNTS=yes for a deliberate probe window" >&2
		return 1
	fi
}

# verify_signed_build checks a freshly signed build directory ($1): the bundle
# ids, the FSKit extension point, a strict deep signature, and the sandbox /
# fskit-module / network-client entitlements. release.sh runs it after a
# developer-id build, before notarizing.
verify_signed_build() {
	local build_dir=${1:?"usage: verify_signed_build BUILD_DIR"}
	local app=$build_dir/NinePFSHost.app
	local appex=$app/Contents/Extensions/NinePFSExtension.appex
	local extension_bin=$appex/Contents/MacOS/NinePFSExtension

	[[ -d "$app" ]] || { echo "verify-signed-build: missing app: $app" >&2; return 1; }
	[[ -d "$appex" ]] || { echo "verify-signed-build: missing extension: $appex" >&2; return 1; }
	[[ -x "$extension_bin" ]] || { echo "verify-signed-build: missing extension executable: $extension_bin" >&2; return 1; }

	codesign --verify --deep --strict "$app"

	local host_id extension_id extension_point
	host_id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Contents/Info.plist")
	extension_id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$appex/Contents/Info.plist")
	extension_point=$(/usr/libexec/PlistBuddy -c 'Print :EXAppExtensionAttributes:EXExtensionPointIdentifier' "$appex/Contents/Info.plist")

	[[ "$host_id" == "dev.tmc.apple.examples.fskit.9pfs" ]] ||
		{ echo "verify-signed-build: unexpected host bundle id: $host_id" >&2; return 1; }
	[[ "$extension_id" == "dev.tmc.apple.examples.fskit.9pfs.extension" ]] ||
		{ echo "verify-signed-build: unexpected extension bundle id: $extension_id" >&2; return 1; }
	[[ "$extension_point" == "com.apple.fskit.fsmodule" ]] ||
		{ echo "verify-signed-build: unexpected extension point: $extension_point" >&2; return 1; }

	local host_entitlements extension_entitlements
	host_entitlements=$(mktemp)
	extension_entitlements=$(mktemp)
	codesign -d --entitlements :- "$app" >"$host_entitlements" 2>/dev/null
	codesign -d --entitlements :- "$appex" >"$extension_entitlements" 2>/dev/null

	local rc=0
	/usr/libexec/PlistBuddy -c 'Print :com.apple.security.app-sandbox' "$host_entitlements" | grep -qx true ||
		{ echo "verify-signed-build: host is missing app sandbox entitlement" >&2; rc=1; }
	/usr/libexec/PlistBuddy -c 'Print :com.apple.security.app-sandbox' "$extension_entitlements" | grep -qx true ||
		{ echo "verify-signed-build: extension is missing app sandbox entitlement" >&2; rc=1; }
	/usr/libexec/PlistBuddy -c 'Print :com.apple.developer.fskit.fsmodule' "$extension_entitlements" | grep -qx true ||
		{ echo "verify-signed-build: extension is missing fskit module entitlement" >&2; rc=1; }
	/usr/libexec/PlistBuddy -c 'Print :com.apple.security.network.client' "$extension_entitlements" | grep -qx true ||
		{ echo "verify-signed-build: extension is missing network client entitlement" >&2; rc=1; }
	rm -f "$host_entitlements" "$extension_entitlements"

	# The demo server is the one bundled binary that must NOT be sandboxed: the
	# user runs it from a terminal, and the sandbox would deny it the export
	# directory and the listening socket. Nothing else would catch that, since a
	# sandboxed demo still signs, ships, and launches — it just fails to serve.
	local demo=$app/Contents/MacOS/9pdemo demo_entitlements
	[[ -x "$demo" ]] || { echo "verify-signed-build: missing demo server: $demo" >&2; return 1; }
	codesign --verify --strict "$demo" ||
		{ echo "verify-signed-build: demo server is not validly signed" >&2; return 1; }
	demo_entitlements=$(mktemp)
	codesign -d --entitlements :- "$demo" >"$demo_entitlements" 2>/dev/null
	if /usr/libexec/PlistBuddy -c 'Print :com.apple.security.app-sandbox' "$demo_entitlements" 2>/dev/null | grep -qx true; then
		echo "verify-signed-build: demo server is sandboxed; it must be signed without entitlements" >&2
		rc=1
	fi
	rm -f "$demo_entitlements"

	[[ $rc -eq 0 ]] || return 1

	echo "9pfs: signed build verification ok ($host_id, $extension_id)"
}

# preflight_installed checks that the signed host app is installed and the FSKit
# extension is registered and enabled, before test-installed mounts it. It
# verifies the installed app/extension, the host signature, the embedded
# provisioning profiles (app ids and the fskit-module grant), PlugInKit
# registration, and that --fskit-probe reports the module enabled.
preflight_installed() {
	local app=${NINEPFS_INSTALLED_APP:-/Applications/NinePFSHost.app}
	local fsbundle=${NINEPFS_INSTALLED_FSBUNDLE:-/Library/Filesystems/9pfs.fs}
	local host_id=dev.tmc.apple.examples.fskit.9pfs
	local extension_id=dev.tmc.apple.examples.fskit.9pfs.extension
	local fail=0

	_preflight_profile_value() {
		local profile=$1 key=$2 plist
		plist=$(mktemp)
		if security cms -D -i "$profile" >"$plist" 2>/dev/null; then
			/usr/libexec/PlistBuddy -c "Print :Entitlements:$key" "$plist" 2>/dev/null || true
		fi
		rm -f "$plist"
	}

	[[ -d "$app" ]] && echo "ok: installed host app" ||
		{ echo "missing: installed host app"; fail=1; }
	[[ -d "$app/Contents/Extensions/NinePFSExtension.appex" ]] && echo "ok: installed extension" ||
		{ echo "missing: installed extension"; fail=1; }
	if [[ -x "$fsbundle/Contents/Resources/mount_9pfs" ]]; then
		echo "ok: installed mount helper"
	else
		echo "note: no installed mount helper at $fsbundle/Contents/Resources/mount_9pfs"
		echo "hint: direct /sbin/mount -F -t 9pfs does not require the helper"
	fi

	if [[ -d "$app" ]]; then
		codesign --verify --deep --strict "$app" >/dev/null 2>&1 && echo "ok: host signature" ||
			{ echo "missing: host signature is not strict-valid"; fail=1; }
	fi

	local host_profile=$app/Contents/embedded.provisionprofile
	local extension_profile=$app/Contents/Extensions/NinePFSExtension.appex/Contents/embedded.provisionprofile

	if [[ -f "$host_profile" ]]; then
		local host_app_id
		host_app_id=$(_preflight_profile_value "$host_profile" com.apple.application-identifier)
		[[ "${host_app_id#*.}" == "$host_id" ]] && echo "ok: host profile matches $host_id" ||
			{ echo "missing: host profile app id ${host_app_id:-<none>} does not match $host_id"; fail=1; }
	else
		echo "missing: host embedded provisioning profile for $host_id"
		echo "hint: rebuild with NINEPFS_HOST_PROFILE or a matching auto-discovered profile"
		fail=1
	fi

	if [[ -f "$extension_profile" ]]; then
		local extension_app_id
		extension_app_id=$(_preflight_profile_value "$extension_profile" com.apple.application-identifier)
		[[ "${extension_app_id#*.}" == "$extension_id" ]] && echo "ok: extension profile matches $extension_id" ||
			{ echo "missing: extension profile app id ${extension_app_id:-<none>} does not match $extension_id"; fail=1; }
		[[ "$(_preflight_profile_value "$extension_profile" com.apple.developer.fskit.fsmodule)" == true ]] &&
			echo "ok: extension profile grants com.apple.developer.fskit.fsmodule" ||
			{ echo "missing: extension profile does not grant com.apple.developer.fskit.fsmodule"; fail=1; }
	else
		echo "missing: extension embedded provisioning profile for $extension_id"
		echo "hint: rebuild with NINEPFS_EXTENSION_PROFILE granting com.apple.developer.fskit.fsmodule"
		fail=1
	fi

	if pluginkit -m -A -D -i "$extension_id" 2>/dev/null | grep -q "$extension_id"; then
		echo "ok: PlugInKit registration"
	else
		echo "missing: PlugInKit registration for $extension_id"
		fail=1
	fi

	if [[ -x "$app/Contents/MacOS/NinePFSHost" ]]; then
		local probe
		probe=$("$app/Contents/MacOS/NinePFSHost" --fskit-probe 2>&1 || true)
		printf '%s\n' "$probe"
		# The probe lists one indented module per line: "<id> enabled=<bool> <path>".
		if printf '%s\n' "$probe" | grep -qE "^[[:space:]]*$extension_id enabled=true"; then
			echo "ok: FSKit reports module enabled"
		elif printf '%s\n' "$probe" | grep -qE "^[[:space:]]*$extension_id enabled=false"; then
			echo "missing: FSKit reports module disabled; enable it in System Settings"
			echo "hint: $app/Contents/MacOS/NinePFSHost --open-fskit-settings"
			fail=1
		elif printf '%s\n' "$probe" | grep -q '^status: Status unavailable'; then
			echo "missing: FSKit named no third-party module, so it cannot confirm $extension_id"
			echo "hint: pluginkit -mAvvv -p com.apple.fskit.fsmodule"
			fail=1
		else
			echo "missing: FSKit does not list $extension_id"
			fail=1
		fi
	else
		echo "missing: host probe executable"
		fail=1
	fi

	[[ "$fail" -eq 0 ]] || { echo "preflight-installed: failed" >&2; return 1; }
	echo "9pfs: installed preflight ok"
}
