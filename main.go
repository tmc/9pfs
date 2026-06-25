//go:build darwin

// Command 9pfs is a macOS FSKit file system that mounts a 9P server.
//
// The file system operations are implemented in Go and built as a c-archive
// (see cshared.go); a small Swift @main shell under native/ links the archive
// and supplies the ExtensionFoundation entry point. This package has no
// standalone command behavior: main exists only because Go's c-archive build
// mode requires the main package to declare it. Exercise the 9P side with
// TestLive (test-live.sh) and the FSKit callbacks with TestFSKitSmoke.
package main

func main() {}
