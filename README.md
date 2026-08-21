# 9pfs

`9pfs` mounts a real 9P server through macOS FSKit. The file system operations
are implemented in Go; a small Swift `@main` shell supplies the
ExtensionFoundation entry point. It speaks classic 9P2000 (via `9fans.net/go`)
and 9P2000.L (via `github.com/hugelgupf/p9`).

## Download and mount

A notarized Developer ID build runs on any Mac without rebuilding or registering
a device. Download `NinePFSHost-<version>.zip` from the releases, then:

```sh
shasum -a 256 -c NinePFSHost-<version>.zip.sha256
ditto -x -k NinePFSHost-<version>.zip .
spctl -a -vvv --type install NinePFSHost.app   # source=Notarized Developer ID

sudo cp -R NinePFSHost.app /Applications/NinePFSHost.app
open /Applications/NinePFSHost.app             # registers the extension
```

Enable the extension in System Settings > General > Login Items & Extensions >
File System Extensions. The host app shows the module's live enabled/disabled
status, so you can confirm the toggle took effect (see
[Troubleshooting](#troubleshooting-the-install) if it cannot read that status),
then mount:

```sh
/sbin/mount -F -t 9pfs 'ninep://127.0.0.1:5640?dialect=9p2000l' /path/to/mountpoint
```

The install (`sudo`) and the System Settings toggle are the one-time interactive
steps macOS requires for any third-party file-system extension.

## Troubleshooting the install

The status the host app shows comes from FSKit's installed-module list, and that
list is not always complete: on some systems it names only the modules macOS
ships (`exfat`, `msdos`, …) and omits every third-party module, this one
included. The app reports that as **Status unavailable** — the module's state
could not be read, which is not the same as the module being missing. If
System Settings lists a "9pfs" toggle, the module is registered.

The one cause worth ruling out first is a damaged copy of the app. Only a
properly signed copy is told about third-party modules; the same bundle
unsigned, or with its signature broken by an unarchiver that dropped symlinks
or permissions, sees Apple's modules alone. Check it:

```sh
codesign -vv --deep --strict /Applications/NinePFSHost.app
spctl -a -vvv --type install /Applications/NinePFSHost.app   # source=Notarized Developer ID
```

If either complains, re-extract the download with `ditto -x -k` (not a
double-click unarchiver or plain `unzip`) and reinstall.

Registration is worth checking directly:

```sh
pluginkit -mAvvv -p com.apple.fskit.fsmodule
```

A leading `+` on `dev.tmc.apple.examples.fskit.9pfs.extension` means registered
and enabled. The path printed under it is the app copy macOS registered; if that
is not the copy you have been opening, delete the other copies and open
`/Applications/NinePFSHost.app` again — only one copy wins.

Either way, the mount is the real test; it does not consult the module list:

```sh
mkdir -p ~/9pfs-mnt
/sbin/mount -F -t 9pfs 'ninep://127.0.0.1:5640?dialect=9p2000l' ~/9pfs-mnt
```

**Copy Diagnostics** in the app puts the macOS version, the module list, and
what the app made of it on the pasteboard — paste that into a bug report. The
same text without the app:

```sh
/Applications/NinePFSHost.app/Contents/MacOS/NinePFSHost --fskit-probe
```

and for a failing mount, the extension's own log:

```sh
log stream --predicate 'process == "NinePFSExtension" OR eventMessage CONTAINS "9pfs"' --info
```

## Build it yourself

```sh
./build-appex.sh /tmp/9pfs-build       # builds NinePFSExtension.appex, 9pfs.fs, NinePFSHost.app
```

To install and run a build signed with your own Apple Development identity:

```sh
CODESIGN_IDENTITY='Apple Development: Your Name (TEAMID)' \
  ./build-appex.sh /tmp/9pfs-build
sudo cp -R /tmp/9pfs-build/NinePFSHost.app /Applications/NinePFSHost.app
open /Applications/NinePFSHost.app
```

Signing needs development provisioning profiles whose application identifiers
match `dev.tmc.apple.examples.fskit.9pfs` and
`dev.tmc.apple.examples.fskit.9pfs.extension`; the extension profile must grant
`com.apple.developer.fskit.fsmodule`. `build-appex.sh` auto-discovers matching
profiles from `~/Library/MobileDevice/Provisioning Profiles`. A development
build is device-locked; to produce one that runs on any Mac, use the Developer
ID path under [Distribution](#distribution).

Direct FSKit mounts use `/sbin/mount -F -t 9pfs` and do not need the `.fs`
bundle; install it under `/Library/Filesystems/9pfs.fs` only for plain
`mount -t 9pfs`.

## Mount URLs

```text
ninep://host[:port][/aname][?dialect=9p2000]
tcp://host[:port][/aname][?dialect=9p2000l]
unix:///path/to/socket?dialect=9p2000l
```

The default port is 5640 and the default dialect is classic 9P2000. Use
`ninep://` for installed FSKit mounts (`9p://` is accepted by the Go parser but
is not a valid FSKit resource scheme).

## Architecture

The Go side is one package. Three files carry the work:

  - `backend.go` — the `backend` interface and its 9P implementations
    (`ninePBackend` for 9P2000, `p9LBackend` for 9P2000.L).
  - `fskit_bridge.go` — implements the `x/fskitbridge` volume interfaces on top
    of the backend. The shared `fskitbridge.Server` owns the FSKit side: class
    registration, operation selectors, item identity, reply blocks, and errno
    reporting.
  - `cshared.go` — the `//export`ed entry points, each a one-line wrapper over a
    process-wide `fskitbridge.Extension` (lazy retryable init, last-error, reply
    fallback, panic recovery). A c-archive cannot re-export Go functions from an
    imported package, so the wrappers live here while the logic lives in the
    bridge. `errno.go` translates the backends' error vocabularies into Darwin
    `syscall.Errno` values.

The native side lives under `native/`: `appex/` is the Swift
`UnaryFileSystemExtension` and its Objective-C principal class; `host/` is the
app that registers and enables the extension; `fsbundle/` and `mounthelper/` are
the optional `.fs` bundle for plain `mount -t 9pfs`. The Go side builds as a
c-archive exporting `NinePFSInit` and `NinePFSConfigureFileSystem`; the Swift
executable links the archive and calls them before
`UnaryFileSystemExtension.main()`.

The Apple framework bindings and the FSKit bridge come from
`github.com/tmc/apple` (`foundation`, `fskit`, `objc`, … and `x/fskitbridge`),
pinned in `go.mod`. Nothing in this repository is generated.

## What works

`9pfs` maps a 9P client connection into FSKit volume callbacks.

| Operation | 9P2000 | 9P2000.L |
| --- | --- | --- |
| stat, readdir, lookup, read, write | yes | yes |
| create file/directory, remove | yes | yes |
| rename | same-directory | yes |
| chmod, truncate | yes | yes |
| mtime | server-dependent | yes |
| symlink, readlink, hard link | no | yes |
| extended attributes | no | yes |
| open/close, access checks, statistics | yes | yes |

Not implemented: device-node creation, advisory locking, and authentication
beyond the local-user or anonymous attach defaults.

## Verify

```sh
./verify-local.sh                 # shell/plist lint, go vet, go test, live checks, bundle assembly
./test-live.sh [9p2000|9p2000l]   # TestLive against a disposable server (default: both dialects)
```

Both `test-live.sh` and `build-appex.sh` patch a temporary copy of
`github.com/hugelgupf/p9` (`prepare_p9_module` in `scriptlib.sh`), and the two
halves of `p9-9pfs.patch` differ in reach:

  - `p9/client_file.go` adds `SetXattr` and `RemoveXattr`, which upstream
    returns `ENOSYS` for. `p9LBackend` calls them, so this half **ships**: a
    build without it mounts normally and fails every extended-attribute write.
    The read half (`GetXattr`, `ListXattrs`) is already upstream.
  - `fsimpl/localfs/localfs.go` teaches the `p9ufs` test server chmod and
    utimes, which it otherwise accepts and drops. Test-only.

Neither changes a module dependency, which is the uncomfortable part: the
shipped extension contains p9 code that `go.mod` does not describe. The fix is
upstreaming the client half, not carrying the patch better.

`.github/workflows/ci.yml` runs `verify-local.sh` on `macos-15` and `macos-26`,
and reports what FSKit's installed-module list names on each. It stops there:
loading the module needs a signature carrying
`com.apple.developer.fskit.fsmodule`, and enabling it needs the System Settings
toggle, which no hosted runner can click. Mounting stays a local check
(`test-installed.sh`).

With the extension installed and enabled, exercise the real mount:

```sh
./test-installed.sh "$HOME/9pfs-mnt-$(date +%s)"                 # disposable server
./test-installed.sh 'ninep://host:5640?dialect=9p2000l' "$mnt"   # your own server
```

It mounts with `/sbin/mount -F -t 9pfs` and verifies listing, read, write,
rename, truncate, chmod, mtime, symlink, hard link, xattr, and remove. It
refuses to run while another 9pfs mount is active unless
`NINEPFS_ALLOW_ACTIVE_MOUNTS=yes`.

## Distribution

`release.sh` produces the downloadable artifact: a Developer ID build, notarized
and stapled, packaged as a zip with a checksum.

```sh
CODESIGN_IDENTITY='Developer ID Application: Your Name (TEAMID)' \
  ./release.sh v0.1.0
```

It builds in Developer ID mode (`NINEPFS_DEVID=yes`), notarizes
(`CONFIRM_9PFS_NOTARIZE=yes`), packages the stapled app with a SHA-256 checksum,
and optionally `gh release create`s it (`CONFIRM_9PFS_PUBLISH=yes`). Two
constraints, both enforced by the scripts:

  - **Cert ↔ profile match.** The embedded `MAC_APP_DIRECT` profile must embed
    the same certificate `CODESIGN_IDENTITY` signs with, or AMFI rejects the
    extension at launch with `-413 "No matching profile found"`. `build-appex.sh`
    compares SHA-1 fingerprints up front. Generate a matching profile with `asc
    profiles create --type MAC_APP_DIRECT --bundle <id> --certs <cert-id>`, and
    pass it with `NINEPFS_EXTENSION_PROFILE` / `NINEPFS_HOST_PROFILE`.
  - **Static minimal entitlements.** Developer ID mode signs with the
    repository's static entitlements, not the profile's keychain/team
    boilerplate — a sandboxed Developer ID binary cannot satisfy
    `keychain-access-groups` or `team-identifier`.

Notarization credentials resolve from `NINEPFS_NOTARY_PROFILE` (a
`notarytool store-credentials` keychain profile) or an App Store Connect API key
(`NINEPFS_ASC_KEY_ID` / `NINEPFS_ASC_ISSUER_ID` / `NINEPFS_ASC_KEY_PATH`, else
`~/.appstoreconnect/`).

## Developing against a local apple checkout

```sh
go mod edit -replace github.com/tmc/apple=/path/to/apple
```

The build scripts resolve a relative replace target to an absolute path before
copying `go.mod` into a scratch module (`rewrite_apple_replace` in
`scriptlib.sh`). Drop the replace and `go get github.com/tmc/apple@<commit>` to
return to a pinned version.

## Notes

macOS ships `/sbin/mount_9p`, but it only mounts VM-provided virtio 9p by
IORegistry tag, not arbitrary servers, and does not exercise this bridge. An
experimental `dlopen`-based entrypoint was explored but is not part of this file
system; it lives on the `research/extension-main-probe` branch.
