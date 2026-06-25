#!/usr/bin/env bash
set -euo pipefail

dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
build_dir=${1:-/tmp/9pfs-verify-local-build}

cd "$dir"

# Shell and plist lint.
for script in *.sh; do
	/bin/bash -n "$script"
done

for plist in appex/Info.plist fsbundle/Info.plist host/Info.plist; do
	plutil -lint "$plist"
done

# Go tests, including the in-memory FSKit callback smoke path (TestFSKitSmoke).
GOWORK=off go vet ./...
GOWORK=off go test ./... -count=1

# Live backend operations against a disposable server (both dialects).
./test-live.sh

# Default extension/bundle assembly.
./build-appex.sh "$build_dir"

echo "9pfs: local verification ok"
