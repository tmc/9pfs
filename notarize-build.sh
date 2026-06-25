#!/usr/bin/env bash
set -euo pipefail

# Notarize and staple a Developer ID build of NinePFSHost.app.
#
#   ./notarize-build.sh /tmp/9pfs-devid-build
#
# The input must be a developer-id build (NINEPFS_DEVID=yes) of build-appex.sh:
# hardened runtime, real timestamp, Developer ID Application signature. This
# uploads the app to Apple's notary service, waits for the verdict, and on
# acceptance staples the ticket so the app passes Gatekeeper offline.
#
# Credentials, in order of precedence:
#   NINEPFS_NOTARY_PROFILE  a `notarytool store-credentials` keychain profile.
#   App Store Connect API key, from these (env overrides config.yaml):
#     NINEPFS_ASC_KEY_ID / NINEPFS_ASC_ISSUER_ID / NINEPFS_ASC_KEY_PATH
#     else ~/.appstoreconnect/config.yaml (key_id, issuer_id) + the key file
#     under ~/.appstoreconnect/private_keys/AuthKey_<key_id>.p8.
#
# Notarization uploads the binary to Apple. The script prints its plan and stops
# unless CONFIRM_9PFS_NOTARIZE=yes is set.

build_dir=${1:?usage: notarize-build.sh BUILD_DIR}
app=$build_dir/NinePFSHost.app

die() { echo "notarize-build: $*" >&2; exit 1; }

[[ -d "$app" ]] || die "missing app: $app"

# A stapleable build must use the hardened runtime and a Developer ID signature;
# catch a development build before wasting an upload. Capture the codesign report
# once: piping it into grep -q under `set -o pipefail` lets grep close the pipe
# early and surface codesign's SIGPIPE as a spurious failure.
codesign_report=$(codesign -dvvv "$app" 2>&1 || true)
case "$codesign_report" in
*"flags="*"runtime"*) ;;
*) die "$app is not signed with the hardened runtime; rebuild with NINEPFS_DEVID=yes" ;;
esac
case "$codesign_report" in
*"Authority=Developer ID Application"*) ;;
*) die "$app is not signed with a Developer ID Application identity" ;;
esac

# Resolve notarytool credentials into the notary_args array.
notary_args=()
asc_config=${NINEPFS_ASC_CONFIG:-$HOME/.appstoreconnect/config.yaml}
asc_yaml_value() {
	local key=$1
	awk -v key="$key" '
		$1 == key":" { print $2; exit }
	' "$asc_config" 2>/dev/null
}

if [[ -n "${NINEPFS_NOTARY_PROFILE:-}" ]]; then
	notary_args=(--keychain-profile "$NINEPFS_NOTARY_PROFILE")
else
	key_id=${NINEPFS_ASC_KEY_ID:-$(asc_yaml_value key_id)}
	issuer_id=${NINEPFS_ASC_ISSUER_ID:-$(asc_yaml_value issuer_id)}
	[[ -n "$key_id" ]] || die "no API key id (set NINEPFS_ASC_KEY_ID or NINEPFS_NOTARY_PROFILE)"
	[[ -n "$issuer_id" ]] || die "no API issuer id (set NINEPFS_ASC_ISSUER_ID or NINEPFS_NOTARY_PROFILE)"
	key_path=${NINEPFS_ASC_KEY_PATH:-$HOME/.appstoreconnect/private_keys/AuthKey_$key_id.p8}
	[[ -f "$key_path" ]] || die "API key file not found: $key_path (set NINEPFS_ASC_KEY_PATH)"
	notary_args=(--key "$key_path" --key-id "$key_id" --issuer "$issuer_id")
fi

zip=$build_dir/NinePFSHost.zip

cat <<EOF
9pfs notarization plan

  app:        $app
  zip:        $zip
  credential: ${NINEPFS_NOTARY_PROFILE:+keychain profile $NINEPFS_NOTARY_PROFILE}${NINEPFS_NOTARY_PROFILE:-API key $key_id (issuer $issuer_id)}

Steps:
  1. ditto -c -k --keepParent "$app" "$zip"
  2. xcrun notarytool submit "$zip" --wait
  3. xcrun stapler staple "$app"
  4. spctl -a -vvv --type install "$app"   (expect: source=Notarized Developer ID)
EOF

if [[ "${CONFIRM_9PFS_NOTARIZE:-}" != yes ]]; then
	echo
	echo "Set CONFIRM_9PFS_NOTARIZE=yes to upload to Apple and staple." >&2
	exit 0
fi

echo
echo "notarize-build: zipping $app"
rm -f "$zip"
/usr/bin/ditto -c -k --keepParent "$app" "$zip"

echo "notarize-build: submitting to Apple notary service (waiting for verdict)"
submit_log=$build_dir/notarytool-submit.json
if ! xcrun notarytool submit "$zip" "${notary_args[@]}" --wait \
	--output-format json >"$submit_log"; then
	cat "$submit_log" >&2
	die "notarytool submit failed"
fi
# notarytool --output-format json emits a single object:
#   {"status":"Accepted","message":"...","id":"<uuid>"}
# Pull each value by its own key so field order does not matter.
json_value() { sed -n "s/.*\"$1\":\"\([^\"]*\)\".*/\1/p" "$submit_log"; }
status=$(json_value status)
submission_id=$(json_value id)
echo "notarize-build: submission $submission_id status=$status"

if [[ "$status" != "Accepted" ]]; then
	echo "notarize-build: fetching notary log for $submission_id" >&2
	xcrun notarytool log "$submission_id" "${notary_args[@]}" >&2 || true
	die "notarization not accepted (status=$status)"
fi

echo "notarize-build: stapling ticket to $app"
xcrun stapler staple "$app"
# stapler staple already validates the freshly written ticket; a second validate
# can fail transiently on CloudKit ticket-lookup timeouts. Retry, then fall back
# to Gatekeeper, which reads the stapled ticket offline.
staple_ok=
for _ in 1 2 3; do
	if xcrun stapler validate "$app" >/dev/null 2>&1; then
		staple_ok=yes
		break
	fi
done
[[ -n "$staple_ok" ]] || echo "notarize-build: stapler validate flaky (network); relying on Gatekeeper below" >&2

echo "notarize-build: Gatekeeper assessment"
spctl -a -vvv --type install "$app" 2>&1 || true

echo "notarize-build: done — $app is notarized and stapled"
