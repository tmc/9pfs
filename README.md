# 9pfs

`9pfs` mounts a real 9P server through macOS FSKit. The filesystem operations
are implemented in Go; a small Swift `@main` shell supplies the
ExtensionFoundation entrypoint.

It speaks both classic 9P2000 (via `9fans.net/go`) and 9P2000.L (via
`github.com/hugelgupf/p9`).

## Dependencies

The Apple framework bindings and the FSKit bridge come from
`github.com/tmc/apple`: the generated Objective-C bindings (`foundation`,
`fskit`, `objc`, …) and `x/fskitbridge`, which owns the FSKit selector
implementations. `9pfs` supplies only the pure-Go volume on top of that bridge.
The `go.mod` pins `github.com/tmc/apple` to a published commit; nothing else in
this repository is generated.

To develop against a local checkout of the bindings, add a temporary replace:

```sh
go mod edit -replace github.com/tmc/apple=/path/to/apple
```

The build scripts honor it: a relative replace target is resolved to an
absolute path before the build copies `go.mod` into a scratch module
(`rewrite_apple_replace` in `scriptlib.sh`). Drop the replace and `go get
github.com/tmc/apple@<commit>` to return to a pinned version.

## Architecture

Three files implement the extension:

  - `backend.go` — the `backend` interface and its 9P implementations
    (`ninePBackend` for 9P2000, `p9LBackend` for 9P2000.L). One concern: turn a
    9P connection into stat/read/write/create/remove/rename/setattr/xattr calls.
  - `fskit_bridge.go` — implements the `x/fskitbridge` volume interfaces on
    top of the backend. The shared `fskitbridge.Server` owns the FSKit side:
    class registration, operation selectors, item identity, reply blocks, and
    errno reporting.
  - `cshared.go` — startup: the `//export`ed entry points (`NinePFSInit`,
    `NinePFSConfigureFileSystem`, `NinePFS*Resource`) that create the bridge
    server against the Swift-provided `NinePFileSystem` class and route the
    FSKit calls to it.

The native side lives in `appex/`: `NinePFSExtension.swift` is a nine-line
`UnaryFileSystemExtension` whose `fileSystem` is the `NinePFileSystem` class,
and `NinePFileSystem.m`/`.h` is that Objective-C principal class. The Go side
builds as a c-archive exporting `NinePFSInit` and `NinePFSConfigureFileSystem`;
the Swift executable links the archive and the class and calls them before
`UnaryFileSystemExtension.main()`.

## Download and mount (notarized release)

A notarized Developer ID build runs on any Mac without rebuilding or
registering a device. Download `NinePFSHost-<version>.zip` from the releases,
verify it, and install:

```sh
shasum -a 256 -c NinePFSHost-<version>.zip.sha256
ditto -x -k NinePFSHost-<version>.zip .
# Gatekeeper accepts it offline (the notarization ticket is stapled):
spctl -a -vvv --type install NinePFSHost.app   # source=Notarized Developer ID

sudo cp -R NinePFSHost.app /Applications/NinePFSHost.app
open /Applications/NinePFSHost.app             # registers the extension
```

Then enable the extension in System Settings > General > Login Items &
Extensions > File System Extensions, and mount:

```sh
/sbin/mount -F -t 9pfs 'ninep://127.0.0.1:5640?dialect=9p2000l' /path/to/mountpoint
```

The install (`sudo`) and the System Settings toggle are one-time, interactive
steps macOS requires for any third-party file-system extension. The release is
signed by its publisher's team; to ship under your own team, rebuild and
notarize with the commands under "Distribution" below.

## Simplest path to a mount

```sh
# 1. Build the extension, the .fs mount-helper bundle, and the host app.
./build-appex.sh /tmp/9pfs-build

# 2. Sign and install (see "Installing" below), then enable the extension in
#    System Settings > General > Login Items & Extensions > File System Extensions.

# 3. Mount a 9P2000.L server through FSKit.
/sbin/mount -F -t 9pfs 'ninep://127.0.0.1:5640?dialect=9p2000l' /path/to/mountpoint
```

`build-appex.sh` produces:

```text
/tmp/9pfs-build/NinePFSExtension.appex
/tmp/9pfs-build/9pfs.fs
/tmp/9pfs-build/NinePFSHost.app
```

Bundle structure:

```text
NinePFSExtension.appex/Contents/
  Info.plist                       NSExtension keys + principal class
  MacOS/NinePFSExtension           Swift @main + Go c-archive
  embedded.provisionprofile        (when signed)
9pfs.fs/Contents/
  Info.plist
  Resources/mount_9pfs             helper for plain `mount -t 9pfs`
NinePFSHost.app/Contents/
  MacOS/NinePFSHost                enables/lists the extension
  Extensions/NinePFSExtension.appex
```

## Mount URLs

The Go bridge parses the resource URL in `loadResource`:

```text
ninep://host[:port][/aname][?dialect=9p2000]
tcp://host[:port][/aname][?dialect=9p2000l]
unix:///path/to/socket?dialect=9p2000l
```

The default TCP port is 5640; the default dialect is classic 9P2000. Use
`ninep://` for installed FSKit mounts (`9p://` is accepted by the Go parser but
is not a valid FSKit resource scheme).

## CLI: verify the 9P side

The same command exercises the 9P client directly, without FSKit:

```sh
GOWORK=off go run . -dialect 9p2000 -net tcp -addr 127.0.0.1:5640 -ls /
GOWORK=off go run . -dialect 9p2000 -addr 127.0.0.1:5640 -cat /README
GOWORK=off go run . -dialect 9p2000l -addr 127.0.0.1:5640 -ls /
```

Use `-aname` when the server exports a named tree.

## Local verification

```sh
./verify-local.sh
```

This runs shell/plist lint, `go vet`, `go test` (including `TestFSKitSmoke`,
which drives the FSKit callbacks against an in-memory tree), classic and `.L`
live 9P checks, and the default bundle assembly.

The live checks start disposable servers and exercise the real client:

```sh
./test-live-9p2000.sh     # classic 9P2000 via 9fans.net/go
./test-live-9p2000l.sh    # 9P2000.L via github.com/hugelgupf/p9
```

These scripts patch a temporary copy of `github.com/hugelgupf/p9@v0.4.1`: its
`p9ufs` server localfs ignores chmod and does not honor mtime, and its client
xattr methods return `ENOSYS`. The patch adds server-side chmod/mtime and a
client xattr implementation so the FSKit path is exercised rather than stopping
at the test server. It is local to the build and does not change module
dependencies. (The earlier Darwin compile fix this once carried is now upstream
in v0.4.1, so the patch is two hunks rather than three.)

See `FEATURES.md` for the supported/unsupported operation matrix and
`READINESS.md` for verification state.

## Installing

For an installed test, sign the bundles and install the host app:

```sh
CODESIGN_IDENTITY='Apple Development: Your Name (TEAMID)' \
NINEPFS_REQUIRE_PROFILES=yes \
./build-appex.sh /tmp/9pfs-build
./verify-signed-build.sh /tmp/9pfs-build
./install-local.sh /tmp/9pfs-build      # prints commands; copies only with CONFIRM_9PFS_INSTALL=yes
```

Signing needs development provisioning profiles whose application identifiers
match `dev.tmc.apple.examples.fskit.9pfs` and
`dev.tmc.apple.examples.fskit.9pfs.extension`; the extension profile must grant
`com.apple.developer.fskit.fsmodule`. The script auto-discovers matching
profiles from `~/Library/MobileDevice/Provisioning Profiles`.

`NinePFSHost.app` must be copied to `/Applications` and enabled through System
Settings. Direct FSKit mounts use `/sbin/mount -F -t 9pfs` and do not need the
`.fs` bundle; install it under `/Library/Filesystems/9pfs.fs` only for plain
`mount -t 9pfs`.

The development build above is signed with an Apple Development identity and a
device-locked profile — fine for local testing on a registered Mac, but it will
not launch elsewhere. To produce a build that runs on any Mac, use the
Developer ID path below.

## Distribution (notarized Developer ID build)

`release.sh` produces the downloadable artifact: a Developer ID build, notarized
and stapled, packaged as a zip with a checksum.

```sh
CODESIGN_IDENTITY='Developer ID Application: Your Name (TEAMID)' \
  ./release.sh v0.1.0
```

It runs three steps, gating each outward-facing one:

  - `build-appex.sh` in **Developer ID mode** (`NINEPFS_DEVID=yes`): hardened
    runtime, a real timestamp, and the Developer ID Application signature.
  - `notarize-build.sh`: upload to Apple's notary service and staple the ticket
    (set `CONFIRM_9PFS_NOTARIZE=yes`).
  - package the stapled app and write its SHA-256 checksum; optionally
    `gh release create` (set `CONFIRM_9PFS_PUBLISH=yes` with a git remote).

Developer ID mode differs from the development build in two ways that matter,
both enforced by the scripts:

  - **Cert ↔ profile match.** The embedded provisioning profile
    (`MAC_APP_DIRECT`, granting `com.apple.developer.fskit.fsmodule`) must embed
    the same certificate `CODESIGN_IDENTITY` signs with. `build-appex.sh`
    compares SHA-1 fingerprints up front and refuses a mismatch — otherwise AMFI
    rejects the extension at launch with `-413 "No matching profile found"`. Pass
    profiles with `NINEPFS_EXTENSION_PROFILE` / `NINEPFS_HOST_PROFILE`, or let
    the script auto-discover them. To generate a matching profile:

    ```sh
    asc certs list -o wide        # find the DEVELOPER_ID_APPLICATION cert id you hold
    asc bundles list -o wide      # find the App ID resource ids
    asc profiles create --type MAC_APP_DIRECT --bundle <id> --certs <cert-id>
    asc profiles download <profile-id> -o out.provisionprofile
    ```

  - **Static minimal entitlements.** Developer ID mode signs with the
    repository's static entitlements, not the profile's keychain/team boilerplate
    — a sandboxed Developer ID binary cannot satisfy `keychain-access-groups` or
    `team-identifier`, and AMFI would reject it at launch.

Notarization credentials resolve from `NINEPFS_NOTARY_PROFILE` (a
`notarytool store-credentials` keychain profile) or an App Store Connect API key
(`NINEPFS_ASC_KEY_ID` / `NINEPFS_ASC_ISSUER_ID` / `NINEPFS_ASC_KEY_PATH`, else
`~/.appstoreconnect/config.yaml` and `~/.appstoreconnect/private_keys/`).

## Installed mount gate

```sh
./preflight-installed.sh
./test-installed-live-9p2000l.sh "$HOME/9pfs-mnt-$(date +%s)"
```

The gate starts a disposable 9P2000.L server, mounts it with
`/sbin/mount -F -t 9pfs`, and verifies mounted directory listing, read, write,
rename, truncate, chmod, mtime, symlink, hardlink, xattr, and remove. It
refuses to run while another 9pfs mount is active unless
`NINEPFS_ALLOW_ACTIVE_MOUNTS=yes` is set.

To inspect an already-mounted volume read-only:

```sh
./show-live-mount.sh /path/to/active/9pfs-mount
```

## Notes

macOS ships `/sbin/mount_9p`, but it only accepts `mount_9p [-r] fs_tag`, where
the tag is an `AppleVirtIO9P` IORegistry device property — useful for
VM-provided virtio 9p, not arbitrary 9p servers, and it does not exercise this
bridge.

An experimental entrypoint that `dlopen`s a Swift shim and resolves the
ExtensionFoundation main without entering it was explored, but is not part of
this filesystem; it lives on the `research/extension-main-probe` branch (and,
in fuller form, under `examples/fskit/9pfs-research/` in `github.com/tmc/apple`).
The Swift `@main` path above is the supported way to build and mount.
