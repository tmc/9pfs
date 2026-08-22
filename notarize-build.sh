#!/usr/bin/env bash
set -euo pipefail

# Notarize and staple a Developer ID build of NinePFSHost.app.
#
#   ./notarize-build.sh /tmp/9pfs-devid-build
#
# The input must be a developer-id build (NINEPFS_DEVID=yes) of build-appex.sh:
# hardened runtime, real timestamp, Developer ID Application signature. This
# uploads the app to Apple's notary service, waits for the verdict, and on
# acceptance staples the ticket so the app passes Gatekeeper offline. A zero
# exit means the app really is notarized and stapled.
#
# Credentials resolve through resolve_notary_args in scriptlib.sh:
#   NINEPFS_NOTARY_PROFILE  a `notarytool store-credentials` keychain profile.
#   App Store Connect API key, from these (env overrides config.yaml):
#     NINEPFS_ASC_KEY_ID / NINEPFS_ASC_ISSUER_ID / NINEPFS_ASC_KEY_PATH
#     else ~/.appstoreconnect/config.yaml (key_id, issuer_id) + the key file
#     under ~/.appstoreconnect/private_keys/AuthKey_<key_id>.p8.
#
# Notarization uploads the binary to Apple. The script prints its plan and stops
# unless CONFIRM_9PFS_NOTARIZE=yes is set.

dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=scriptlib.sh
. "$dir/scriptlib.sh"

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

notary_args=()
notary_credential=
resolve_notary_args || die "no notarization credentials"

zip=$build_dir/NinePFSHost.zip

cat <<EOF
9pfs notarization plan

  app:        $app
  zip:        $zip
  credential: $notary_credential

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

notary_submit "$zip" "$build_dir" || die "notarization failed"
staple_and_verify "$app" app || die "app did not end up notarized and stapled"

echo "notarize-build: done — $app is notarized and stapled"
