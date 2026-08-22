package main

import (
	"testing"

	"github.com/tmc/apple/x/fskitbridge"
)

// capableBackend is a backend that claims every optional capability.
type capableBackend struct{ backend }

func (capableBackend) supportsSymlinks() bool     { return true }
func (capableBackend) supportsHardLinks() bool    { return true }
func (capableBackend) supportsOwnerChanges() bool { return true }

func (capableBackend) volumeStats() (volumeStats, error) {
	return volumeStats{BlockSize: 512, TotalBlocks: 100, FreeBlocks: 40, AvailBlocks: 30, TotalFiles: 9, FreeFiles: 4}, nil
}

// TestCapabilitiesSurviveTheErrnoWrapper checks that the optional capability
// interfaces are still visible once a backend is wrapped for errno
// translation.
//
// They are implemented on the concrete backend, while errnoBackend embeds the
// backend interface, and embedding an interface promotes only that
// interface's methods. Without explicit forwarding the type assertions fail
// against the wrapper, and every mount reported no symbolic links and no hard
// links -- including 9P2000.L mounts where both work and are covered by the
// installed test. Nothing failed; the volume just described itself wrongly.
func TestCapabilitiesSurviveTheErrnoWrapper(t *testing.T) {
	inner := capableBackend{newSmokeBackend()}
	if !supportsSymlinks(inner) || !supportsHardLinks(inner) {
		t.Fatal("test backend does not claim the capabilities it implements")
	}
	var wrapped backend = errnoBackend{inner}
	if !supportsSymlinks(wrapped) {
		t.Error("symbolic links not visible through errnoBackend")
	}
	if !supportsHardLinks(wrapped) {
		t.Error("hard links not visible through errnoBackend")
	}
	if _, ok := backendVolumeStats(wrapped); !ok {
		t.Error("volume statistics not visible through errnoBackend")
	}
	if !supportsOwnerChanges(wrapped) {
		t.Error("owner changes not visible through errnoBackend")
	}
}

// TestSetAttributesReportsWhatItDidNotApply checks that SetAttributes returns
// only the fields it applied. FSKit takes an unconsumed attribute as one the
// file system does not support, so returning a declined chown as applied
// would report a silent success to the caller.
func TestSetAttributesReportsWhatItDidNotApply(t *testing.T) {
	uid, gid, flags := uint32(501), uint32(20), uint32(1)

	// A backend without owner support declines the chown but still applies
	// the rest of the request.
	v := newNinepVolume(newSmokeBackend(), false)
	root, err := v.Root()
	if err != nil {
		t.Fatal(err)
	}
	mode := uint32(0600)
	set := fskitbridge.SetAttributes{Mode: &mode, UID: &uid, GID: &gid, Flags: &flags}
	applied, err := v.SetAttributes(root, set)
	if err != nil {
		t.Fatal(err)
	}
	if applied.UID != nil || applied.GID != nil {
		t.Error("owner reported as applied by a backend that cannot change it")
	}
	if applied.Flags != nil {
		t.Error("file flags reported as applied; 9P has no equivalent")
	}
	if applied.Mode == nil {
		t.Error("mode reported as unapplied, but it was")
	}
	// The request itself must come back untouched: a caller may keep it.
	if set.UID != &uid || set.GID != &gid || set.Flags != &flags {
		t.Error("SetAttributes modified the request it was given")
	}

	// A backend with owner support keeps the chown.
	v = newNinepVolume(capableBackend{newSmokeBackend()}, false)
	if root, err = v.Root(); err != nil {
		t.Fatal(err)
	}
	applied, err = v.SetAttributes(root, fskitbridge.SetAttributes{UID: &uid, GID: &gid})
	if err != nil {
		t.Fatal(err)
	}
	if applied.UID == nil || applied.GID == nil {
		t.Error("owner reported as unapplied by a backend that supports it")
	}
}

// TestVolumeStatisticsUseTheBackend checks that a backend reporting statfs
// is believed, and that one that cannot report it still yields a usable
// answer rather than zeroes: callers divide by the total.
func TestVolumeStatisticsUseTheBackend(t *testing.T) {
	if _, ok := backendVolumeStats(newSmokeBackend()); ok {
		t.Fatal("the smoke backend should not claim statfs support")
	}
	stats, ok := backendVolumeStats(capableBackend{newSmokeBackend()})
	if !ok {
		t.Fatal("a backend implementing statsCapable was not consulted")
	}
	if stats.TotalBlocks != 100 || stats.FreeBlocks != 40 {
		t.Errorf("stats = %+v, want the backend's numbers", stats)
	}
}
