#!/usr/bin/env bash

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

# prepare_p9_module copies github.com/hugelgupf/p9@v0.4.1 from the module
# cache into $1 and applies the local 9pfs patch. The patch adds server-side
# chmod/mtime and a client xattr implementation that the upstream p9ufs test
# server lacks, so the live tests exercise the FSKit path rather than stopping
# at the server. It is local to the build and does not change module
# dependencies. scriptlib_dir is the directory holding this library.
prepare_p9_module() {
	local dest=${1:?"usage: prepare_p9_module dest"}
	local modcache
	modcache=$(GOWORK=off go env GOMODCACHE)
	rm -rf "$dest"
	mkdir -p "$dest"
	cp -R "$modcache/github.com/hugelgupf/p9@v0.4.1/." "$dest/"
	chmod -R u+w "$dest"
	patch -d "$dest" -p1 < "$scriptlib_dir/p9-v0.4.1-9pfs.patch"
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
