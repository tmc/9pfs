module github.com/tmc/9pfs

go 1.25.0

require (
	9fans.net/go v0.0.7
	github.com/ebitengine/purego v0.11.0-alpha.6 // indirect
)

require github.com/tmc/apple v0.6.18

require (
	github.com/hugelgupf/p9 v0.4.2-0.20260625151848-3fd948847ea4
	github.com/u-root/uio v0.0.0-20230305220412-3e8cd9d6bf63 // indirect
	golang.org/x/sys v0.15.0 // indirect
)

// The fork is three open upstream pull requests, merged:
//
//	https://github.com/hugelgupf/p9/pull/110 — p9: SetXattr and RemoveXattr on
//	  the client, which upstream leaves as ENOSYS. p9LBackend calls them, so a
//	  build without it mounts fine and fails every xattr write.
//	https://github.com/hugelgupf/p9/pull/111 — fsimpl/localfs: SetAttr fields
//	  upstream accepts and drops, chmod and utimes among them.
//	https://github.com/hugelgupf/p9/pull/112 — fsimpl/localfs: StatFS, which
//	  templatefs leaves unimplemented, so a client sees a volume of unknown
//	  size. localfs serves the live test and the bundled 9pdemo.
//
// Drop this replace once all three land upstream and a release carries them.
replace github.com/hugelgupf/p9 => github.com/tmc/p9 v0.0.0-20260826220913-8b2da0c94980
