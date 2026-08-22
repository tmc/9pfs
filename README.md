# 9pfs

`9pfs` mounts a real 9P server as a volume on macOS, through FSKit. The file
system operations are implemented in Go; a small Swift `@main` shell supplies
the ExtensionFoundation entry point. It speaks classic 9P2000 (via
`9fans.net/go`) and 9P2000.L (via `github.com/hugelgupf/p9`).

## Install

Download `NinePFSHost-<version>.dmg` from the [releases][releases], open it, and
drag `NinePFSHost.app` onto the `Applications` alias beside it. The image is
signed and notarized, so opening it is the whole verification step — and no
`sudo` is involved: the extension rides inside the app bundle rather than being
installed system-wide.

Open the app once from `/Applications` to register the extension, then turn on
**9pfs** in System Settings > General > Login Items & Extensions > File System
Extensions. That toggle is the one interactive step macOS requires of any
third-party file system. The app shows the extension's live status, so you can
see the toggle take effect.

> Upgrading over an existing install can switch that toggle back off. If a mount
> fails right after replacing the app, check there first.

The release also carries a `.zip` of the same stapled app for scripted installs.
Extract it with `ditto -x -k`, never a double-click unarchiver — one that drops
symlinks or permissions breaks the signature, and a broken signature is the
usual cause of the app not being able to read its own status.

[releases]: https://github.com/tmc/9pfs/releases

## Mount

The app ships a demo 9P server, so there is something to mount without setting
one up. It prints the mount command for its own address:

```sh
/Applications/NinePFSHost.app/Contents/MacOS/9pdemo
```

It serves a few sample files from a temporary directory, which it removes when
you stop it. The files are writable, so a mount can be exercised rather than
only listed.

To mount a server of your own:

```sh
mkdir -p ~/9pfs
/sbin/mount -F -t 9pfs 'ninep://HOST:5640?dialect=9p2000l' ~/9pfs
```

`HOST` is your 9P server — `127.0.0.1` if it runs on this Mac. The mount point
has to exist first; mounting onto a missing directory fails with the unhelpful
`invalid file system`. Accepted URLs:

```text
ninep://host[:port][/aname][?dialect=9p2000]
tcp://host[:port][/aname][?dialect=9p2000l]
unix:///path/to/socket?dialect=9p2000l
```

The default port is 5640 and the default dialect is classic 9P2000. Use
`ninep://` for installed FSKit mounts (`9p://` parses but is not a valid FSKit
resource scheme).

Add `persistentids=1` if your server derives its QID paths from the underlying
files, so that a QID path names the same file after a remount:

```sh
/sbin/mount -F -t 9pfs 'ninep://HOST:5640?dialect=9p2000l&persistentids=1' ~/9pfs
```

The mount then reports persistent object IDs, so an item keeps its identity
across a remount and follows a file through a rename. It is a mount option
because nothing in 9P distinguishes a server that derives QID paths from one
that hands out a counter, and claiming persistence falsely would hand out IDs
that mean a different file next time.

This does not enable document version storage. macOS reserves that for local
volumes, and an FSKit file system backed by a URL resource is classified as
non-local (`IsLocal` is 0, `MNT_LOCAL` is unset), with no API to assert
otherwise. TextEdit and other versioning applications warn about it on any
9pfs mount; saving works, older versions are simply not kept.

## What works

| Operation | 9P2000 | 9P2000.L |
| --- | --- | --- |
| stat, readdir, lookup, read, write | yes | yes |
| create file/directory, remove | yes | yes |
| rename | same-directory | yes |
| chmod, truncate | yes | yes |
| mtime | server-dependent | yes |
| atime, ctime, birth time | atime only | yes |
| link count | 1 | from the server |
| owner, chown | see below | see below |
| symlink, readlink, hard link | no | yes |
| extended attributes | no | yes |
| open/close, access checks | yes | yes |
| volume size and free space | placeholder | yes |
| persistent object IDs | opt-in | opt-in |

Attributes a dialect cannot report are substituted rather than left at zero: a
missing timestamp becomes the modification time, and a classic 9P2000 mount
reports the local user as the owner, because that dialect names its owners with
strings that do not map to numeric IDs.

Ownership does not survive the mount, whatever the dialect reports. A mount made
by an ordinary user always carries `noowners` (`MNT_IGNORE_OWNERSHIP`) — `-o
owners` is accepted and ignored, since enabling ownership requires root. Under
it the kernel reports the mounting user as the owner of every file and discards
what the file system said, and it answers `chown` itself without passing it
down: `chgrp` through the mount exits 0, changes nothing, and the server never
hears about it. A 9P2000.L mount does read and apply ownership, and that is
asserted in the live tests, above the kernel; it is simply not what `ls -l`
shows you.

Not implemented: device-node creation, file flags (`chflags`, which 9P has no
equivalent for), advisory locking, and authentication beyond the local-user or
anonymous attach defaults.

Out of reach rather than unimplemented: document version storage, which macOS
offers only on local volumes, and extended-attribute support is not advertised
to the kernel even where it works — `FSVolumeSupportedCapabilities` has no
setter for it.

<details>
<summary><b>If the app cannot read its status, or a mount fails</b></summary>

The status comes from FSKit's installed-module list, and that list is not always
complete: on some systems it names only the modules macOS ships (`exfat`,
`msdos`, …) and omits every third-party one, this included. The app reports that
as **Status unavailable** — the state could not be read, which is not the same
as the extension being missing. If System Settings lists a "9pfs" toggle, it is
registered, and mounting works regardless.

The cause worth ruling out first is a damaged copy. Only a properly signed copy
is told about third-party modules; the same bundle unsigned, or with its
signature broken by an unarchiver that dropped symlinks or permissions, sees
Apple's modules alone.

```sh
codesign -vv --deep --strict /Applications/NinePFSHost.app
spctl -a -vvv --type install /Applications/NinePFSHost.app   # source=Notarized Developer ID
```

If either complains, reinstall from the `.dmg`. Registration is worth checking
directly too:

```sh
pluginkit -mAvvv -p com.apple.fskit.fsmodule
```

A leading `+` on `dev.tmc.apple.examples.fskit.9pfs.extension` means registered
and enabled. The path printed under it is the copy macOS registered; if that is
not the copy you have been opening, delete the others and open
`/Applications/NinePFSHost.app` again — only one copy wins.

The mount is the real test either way; it does not consult the module list. For
a bug report, **Copy Diagnostics** in the app puts the macOS version, the module
list, and what the app made of it on the pasteboard. The same text without the
app:

```sh
/Applications/NinePFSHost.app/Contents/MacOS/NinePFSHost --fskit-probe
```

and for a failing mount, the extension's own log:

```sh
log stream --predicate 'process == "NinePFSExtension" OR eventMessage CONTAINS "9pfs"' --info
```

</details>

<details>
<summary><b>Build from source</b></summary>

```sh
./build-appex.sh /tmp/9pfs-build       # NinePFSExtension.appex, 9pfs.fs, NinePFSHost.app
```

To install and run a build signed with your own Apple Development identity:

```sh
CODESIGN_IDENTITY='Apple Development: Your Name (TEAMID)' \
  ./build-appex.sh /tmp/9pfs-build
cp -R /tmp/9pfs-build/NinePFSHost.app /Applications/NinePFSHost.app
open /Applications/NinePFSHost.app
```

Signing needs development provisioning profiles whose application identifiers
match `dev.tmc.apple.examples.fskit.9pfs` and
`dev.tmc.apple.examples.fskit.9pfs.extension`; the extension profile must grant
`com.apple.developer.fskit.fsmodule`. `build-appex.sh` auto-discovers matching
profiles from `~/Library/MobileDevice/Provisioning Profiles`. A development
build is device-locked; for one that runs on any Mac, see **Making a release**.

Direct FSKit mounts use `/sbin/mount -F -t 9pfs` and do not need the `.fs`
bundle; install it under `/Library/Filesystems/9pfs.fs` only for plain
`mount -t 9pfs`.

To develop against a local `github.com/tmc/apple` checkout:

```sh
go mod edit -replace github.com/tmc/apple=/path/to/apple
```

The build scripts resolve a relative replace target to an absolute path before
copying `go.mod` into a scratch module (`rewrite_apple_replace` in
`scriptlib.sh`). Drop the replace and `go get github.com/tmc/apple@<version>`
to return to a published version.

</details>

<details>
<summary><b>Tests and CI</b></summary>

```sh
./verify-local.sh                 # shell/plist lint, go vet, go test, live checks, bundle assembly
./test-live.sh [9p2000|9p2000l]   # TestLive against a disposable server (default: both dialects)
```

With the extension installed and enabled, exercise the real mount:

```sh
./test-installed.sh "$HOME/9pfs-mnt-$(date +%s)"                 # disposable server
./test-installed.sh 'ninep://host:5640?dialect=9p2000l' "$mnt"   # your own server
```

It mounts with `/sbin/mount -F -t 9pfs` and verifies listing, read, write,
rename, truncate, chmod, mtime, symlink, hard link, xattr, and remove. It
refuses to run while another 9pfs mount is active unless
`NINEPFS_ALLOW_ACTIVE_MOUNTS=yes`.

`.github/workflows/ci.yml` runs `verify-local.sh` on `macos-15` and `macos-26`
and reports what FSKit's installed-module list names on each. It stops there:
loading the module needs a signature carrying
`com.apple.developer.fskit.fsmodule`, and enabling it needs the System Settings
toggle, which no hosted runner can click. Mounting stays a local check.

**The p9 patch.** `test-live.sh` and `build-appex.sh` patch a temporary copy of
`github.com/hugelgupf/p9` (`prepare_p9_module` in `scriptlib.sh`). The two
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

</details>

<details>
<summary><b>Making a release</b></summary>

`release.sh` produces the downloadable artifacts: a Developer ID build,
notarized and stapled, packaged as a drag-install `.dmg` and a `.zip` with a
SHA-256 checksum beside each.

```sh
CODESIGN_IDENTITY='Developer ID Application: Your Name (TEAMID)' \
  ./release.sh v0.1.0
```

It builds in Developer ID mode (`NINEPFS_DEVID=yes`), notarizes
(`CONFIRM_9PFS_NOTARIZE=yes`), packages, and optionally `gh release create`s
(`CONFIRM_9PFS_PUBLISH=yes`). The disk image is signed and notarized in its own
right, so it costs a second trip to Apple.

To publish assets an earlier run already produced, skipping the build and the
uploads:

```sh
CONFIRM_9PFS_PUBLISH=yes NINEPFS_PUBLISH_ONLY=yes ./release.sh v0.1.0
```

That re-checks the checksums and the image's staple first, since nothing is
rebuilt. Only the build directory is discarded between runs, so a run that stops
at the notarization gate leaves an existing release's artifacts intact.

Two constraints, both enforced by the scripts:

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

</details>

<details>
<summary><b>Architecture</b></summary>

The Go side is one package. Three files carry the work:

  - `backend.go` — the `backend` interface and its 9P implementations
    (`ninePBackend` for 9P2000, `p9LBackend` for 9P2000.L).
  - `fskit_bridge.go` — implements the `fskitbridge` volume interfaces on top
    of the backend. The `fskitbridge.Server` owns the FSKit side: class
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

The Apple framework bindings come from `github.com/tmc/apple` (`foundation`,
`fskit`, `objc`, …), pinned in `go.mod`. The FSKit bridge is
`github.com/tmc/apple/x/fskitbridge`. Nothing in this repository is generated.

macOS ships `/sbin/mount_9p`, but it only mounts VM-provided virtio 9p by
IORegistry tag, not arbitrary servers, and does not exercise this bridge. An
experimental `dlopen`-based entrypoint was explored but is not part of this file
system; it lives on the `research/extension-main-probe` branch.

</details>
