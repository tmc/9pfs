# Adopting sparkle-go (assessment)

Status: draft on the `sparkle` branch. Nothing is wired up yet.

## Why look at this

Updates are manual today: download a `.dmg` from the releases page, drag, open
once to re-register the extension. The Discord report that prompted v0.1.7 was
partly this — the reporter could not say which build they were running, and had
no path to a newer one short of noticing a release existed.

## What sparkle-go is, and what it is not

[`tmc/sparkle-go`](https://github.com/tmc/sparkle-go) drives
Sparkle.framework from Go through the ObjC runtime, with no CGo. Its runtime
API (`sparkle.Wire`, `sparkle.New`) is built around
[`tmc/macgo`](https://github.com/tmc/macgo): `Wire` hangs off macgo's
`PostCreateHook`, which runs between bundle creation and signing, and that is
the seam that gets Sparkle.framework inside the code signature.

9pfs has no such seam. `NinePFSHost.app` is a Swift SwiftUI `@main` app
compiled by `build-appex.sh` with `xcrun swiftc`; the Go in this repository is
a c-archive linked into the FSKit app extension. There is no Go `main`, no
macgo, and no bundle for macgo to create.

So the two halves of sparkle-go land differently here:

  - **Release side — usable as-is.** `appcast.Sign` and
    `cmd/sparkle-go-appcast` compute the base64 `sparkle:edSignature` for a
    release zip. Nothing about that cares what language the app is written in.
    It replaces shelling out to Sparkle's `sign_update`. Appcast XML assembly
    is not implemented upstream yet.
  - **Runtime side — not applicable.** Embedding Sparkle and instantiating
    `SPUStandardUpdaterController` would be ordinary Sparkle called from
    `App.swift`, which is less code here than routing through Go would be.

## What adoption would actually require

1. `build-appex.sh` materializes Sparkle.framework into
   `NinePFSHost.app/Contents/Frameworks/`, signed before the host app's seal
   (the script already signs inside-out for the appex, so the ordering exists).
2. `App.swift` creates an updater and adds a Check for Updates item.
3. `Info.plist` gains `SUFeedURL` and `SUPublicEDKey`.
4. `release.sh` signs the zip with the EdDSA key and publishes an
   `appcast.xml` alongside the existing assets.
5. Sandbox plumbing: Sparkle 2 installs through XPC services for sandboxed
   apps, which need `mach-lookup` exceptions. The host entitlements already
   carry one for `com.apple.filesystems.fskitd`, so the shape is established.

## The blocking question, answered: no

**A Sparkle-style in-place replacement de-registers the FSKit extension, and
it does not come back.**

Sparkle installs with `renamex_np(..., RENAME_SWAP)` (`SUFileManager.m:360`,
via `SUPlainInstaller.m:244`) and then touches the bundle's mtime to nudge
LaunchServices. Nothing in Sparkle knows what an appex is; whatever happens is
emergent from those file operations. So the swap was run directly, on a real
install, with the extension registered and enabled:

    before   4 plug-ins, `+ dev.tmc.apple.examples.fskit.9pfs.extension` enabled
    swap     renamex_np RENAME_SWAP → 0; new CDHash in place; notarization and
             staple intact (`spctl -a` accepted, `codesign --verify --deep
             --strict` clean)
    after    3 plug-ins — the 9pfs row is *gone*, not disabled

The row did not return after any of: three relaunches over ~40 seconds,
removing the superseded bundle copy, `pluginkit -a` on the appex,
`lsregister -f -R` on the app, a full move-out-and-copy-back reinstall, or
`pluginkit -r` followed by restarting `pkd`. The app is intact and correctly
signed throughout; only the registration is lost.

This is worse than losing the toggle. A user who never touches System Settings
would go from a working mount to an extension the system does not know exists,
with no in-app remedy — the host app is sandboxed and cannot run `pluginkit`.
Restoring it appears to need at least a login cycle.

Two caveats, stated because they bound the claim. The first swap left the
superseded bundle in `/Applications` briefly, which Sparkle would have
trashed; removing it changed nothing, so the duplicate was not the cause. And
this is one machine, one macOS version (26.6.2, build 25G83) — the behaviour
is FSKit/PlugInKit policy about a CDHash change under a stable path, not
something Sparkle chooses, so it could differ across releases.

The variant 9C2E asked for — the same swap with a 9p volume actively mounted —
could not be run: it needs a registered extension, and the experiment consumed
the only one on this machine.

## Recommendation

Do not adopt in-app Sparkle updates for this bundle layout. The failure is not
in Sparkle and not in sparkle-go; it is that an FSKit module's registration
does not survive having its bundle replaced underneath it.

Worth taking anyway, independent of any updater:

  - EdDSA release signing, if an appcast ever becomes useful. On a machine
    with Xcode, Sparkle's own `sign_update` is as good as
    `cmd/sparkle-go-appcast` — that command exists to drop the Sparkle CLI
    dependency from Go CI, which is not a problem this repository has.
  - `cmd/sparkle-go-verify-bundle`, which is neither Sparkle- nor
    sparkle-go-specific: it walks any `.app` and reports hardened-runtime and
    secure-timestamp state for every nested signable, which here means the
    appex and the `9pdemo` helper. That is a real gap in `verify-local.sh`.

If updates are worth revisiting, the question to answer first is what makes
FSKit forget a module — because that same behaviour presumably bites a plain
drag-install upgrade over an existing copy, which is what the download page
tells people to do.
