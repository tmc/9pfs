package main

import "testing"

// capableBackend is a backend that claims every optional capability.
type capableBackend struct{ backend }

func (capableBackend) supportsSymlinks() bool  { return true }
func (capableBackend) supportsHardLinks() bool { return true }

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
