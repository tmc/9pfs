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

## The blocking question

**Does a Sparkle in-place replacement preserve the FSKit extension's
registration and the user's System Settings toggle?**

The app ships an embedded `NinePFSExtension.appex` that `pluginkit` registers
and the user enables by hand. If swapping the bundle drops either, every
update ends with a silently broken mount and a trip to System Settings — worse
than the manual `.dmg` it replaced. This has to be tested on a real install
before any of the above is worth writing; it is not answerable from source.

Asked 9C2E (sparkle-go) whether Sparkle has been exercised against a bundle
with an embedded ExtensionKit extension, and whether the sandboxed installer
path has been tested at all. Their answer decides whether this proceeds.

## Recommendation (provisional)

Take the release-side piece now — signing releases with an EdDSA key costs
little and is a prerequisite for anything later — and gate the in-app updater
on the appex-preservation test.
