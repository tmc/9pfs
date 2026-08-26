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

## The blocking question: still open

An earlier revision of this document concluded that a Sparkle-style in-place
replacement de-registers the FSKit extension permanently. **That was wrong, and
the retraction matters more than the original claim.**

What was run: Sparkle's install mechanically — `renamex_np(..., RENAME_SWAP)`
(`SUFileManager.m:360`, via `SUPlainInstaller.m:244`) plus the mtime touch —
against a real install with the extension registered and enabled. Afterwards
`pluginkit` listed three fsmodules instead of four, and nothing recovered it:
not relaunching, not removing the superseded bundle, not `pluginkit -a`, not
`lsregister -f -R`, not a full reinstall from the notarized `.dmg`, not a
reboot.

The cause was not the swap. The bundle being swapped in was v0.1.7, which
numbered itself `0.1.7` where every earlier build carried `1.0`. PlugInKit keeps
one record per extension bundle id and prefers the highest version; this machine
held a stale `1.0` record for a long-deleted app, that record won, its URL did
not resolve, and PlugInKit dropped the extension rather than falling back. The
`pkd` log said so on every discovery pass:

    pkd: (LaunchServices) could not resolve URL while initializing a bundle record!
    pkd: (PlugInKitDaemon) [discovery] Final plugin count: 3

Installing a build numbered `2.0` restored registration in under ten seconds,
enabled, with the mount test passing end to end. See `version_floor` in
`scriptlib.sh`.

So the swap is unconvicted. It has not been shown to preserve registration
either — the experiment that would show it never ran against a correctly
numbered build. Whoever picks this up should rerun it: swap a build whose
version is above every stale record, and watch `pluginkit`. Only then does the
appex question have an answer.

## Recommendation

Unchanged in outcome, changed in reasoning: do not adopt in-app Sparkle updates
yet, but for want of evidence rather than because of it.

What the episode did establish is a real hazard for any updater that replaces
this bundle: the app's version number is load-bearing. An update that lowers it,
or a stale record that outranks it, does not degrade gracefully — the file
system disappears from System Settings with no in-app remedy, because the host
app is sandboxed and cannot run `pluginkit`. An updater would have to guarantee
monotonic versions and clean up superseded copies. Sparkle does trash the old
bundle; whether that is sufficient is exactly what the rerun would tell us.

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
