package main

import "testing"

// capableBackend is a backend that claims both optional capabilities.
type capableBackend struct{ backend }

func (capableBackend) supportsSymlinks() bool  { return true }
func (capableBackend) supportsHardLinks() bool { return true }

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
}
