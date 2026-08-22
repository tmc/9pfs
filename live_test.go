//go:build darwin

package main

import (
	"bytes"
	"os"
	"testing"
)

// TestLive exercises a backend against a real 9p server over the loopback.
// The server is started by test-live.sh, which builds the patched p9ufs,
// exports a README, and passes the address and dialect through the
// environment. Without those, the test skips, so plain `go test` stays
// offline and fast.
func TestLive(t *testing.T) {
	addr := os.Getenv("NINEPFS_LIVE_ADDR")
	dialect := os.Getenv("NINEPFS_LIVE_DIALECT")
	if addr == "" || dialect == "" {
		t.Skip("set NINEPFS_LIVE_ADDR and NINEPFS_LIVE_DIALECT (see test-live.sh)")
	}

	b, err := dialBackend(dialect, "tcp", addr, "")
	if err != nil {
		t.Fatalf("dial %s %s: %v", dialect, addr, err)
	}
	defer b.Close()

	linux := dialect == "9p2000l" || dialect == "linux"

	if got, err := b.ReadFile("/README"); err != nil {
		t.Fatalf("read /README: %v", err)
	} else if want := "hello from live 9p\n"; string(got) != want {
		t.Fatalf("/README = %q, want %q", got, want)
	}

	// QID paths are what persistent object IDs are built on, so check that
	// this server reports them and keeps them steady. Whether they also
	// survive a restart of the server is a property of the server, not
	// something a client can test, which is why the capability is opted
	// into per mount rather than assumed.
	readme, err := b.Stat("/README")
	if err != nil {
		t.Fatalf("stat /README: %v", err)
	}
	switch again, err := b.Stat("/README"); {
	case err != nil:
		t.Fatalf("stat /README again: %v", err)
	case readme.QIDPath == 0:
		t.Logf("server reports no QID path; it cannot support persistent object IDs")
	case again.QIDPath != readme.QIDPath:
		t.Errorf("QID path for /README changed between stats: %d then %d", readme.QIDPath, again.QIDPath)
	}

	// 9P2000.L carries statfs, so those mounts report the server's real
	// numbers instead of a placeholder. 9P2000 has no statfs.
	switch stats, ok := backendVolumeStats(b); {
	case ok && !linux:
		t.Errorf("9p2000 reported volume statistics %+v; the dialect has no statfs", stats)
	case !ok && linux:
		t.Error("9p2000.l did not report volume statistics")
	case ok && stats.TotalBlocks == 0:
		t.Errorf("volume statistics report no blocks at all: %+v", stats)
	case ok:
		t.Logf("volume statistics: %+v", stats)
	}

	// 9P2000 (export9p) exercises files at the root: no subdirectory or
	// rename-into-dir. The .L path below adds those plus symlink/hardlink/xattr.
	file := "/codex.txt"
	if linux {
		if _, err := b.Create("/dir", 0755, true); err != nil {
			t.Fatalf("mkdir: %v", err)
		}
		file = "/dir/renamed.txt"
	}

	payload := []byte("written through 9p")
	if _, err := b.Create("/codex.txt", 0644, false); err != nil {
		t.Fatalf("create: %v", err)
	}
	if _, err := b.WriteFile("/codex.txt", 0, payload); err != nil {
		t.Fatalf("write: %v", err)
	}
	if got, err := b.ReadFile("/codex.txt"); err != nil {
		t.Fatalf("read back: %v", err)
	} else if !bytes.Equal(got, payload) {
		t.Fatalf("read back = %q, want %q", got, payload)
	}
	if linux {
		if err := b.Rename("/codex.txt", file); err != nil {
			t.Fatalf("rename: %v", err)
		}
	}

	size := uint64(8)
	if _, err := b.SetAttr(file, setAttr{Size: &size}); err != nil {
		t.Fatalf("truncate: %v", err)
	}
	if got, err := b.ReadFile(file); err != nil {
		t.Fatalf("read truncated: %v", err)
	} else if string(got) != "written " {
		t.Fatalf("truncated = %q, want %q", got, "written ")
	}

	mode := uint32(0600)
	if _, err := b.SetAttr(file, setAttr{Mode: &mode}); err != nil {
		t.Fatalf("chmod: %v", err)
	}
	if info, err := b.Stat(file); err != nil {
		t.Fatalf("stat: %v", err)
	} else if info.Mode&0777 != 0600 {
		t.Fatalf("mode = %04o, want 0600", info.Mode&0777)
	}

	mtime := uint64(1577934240)
	if _, err := b.SetAttr(file, setAttr{Modified: &mtime}); err != nil {
		t.Fatalf("set mtime: %v", err)
	}
	if info, err := b.Stat(file); err != nil {
		t.Fatalf("stat mtime: %v", err)
	} else if info.Modified != mtime {
		// export9p does not always persist mtime; the .L server does.
		if linux {
			t.Fatalf("mtime = %d, want %d", info.Modified, mtime)
		}
		t.Logf("9p2000 server did not persist mtime (got %d); continuing", info.Modified)
	}

	if !linux {
		// 9P2000 stops here: no symlink, hardlink, or xattr.
		if err := b.Remove(file); err != nil {
			t.Fatalf("remove: %v", err)
		}
		return
	}

	if _, err := b.CreateSymlink("/dir/link.txt", "renamed.txt"); err != nil {
		t.Fatalf("symlink: %v", err)
	}
	if got, err := b.Readlink("/dir/link.txt"); err != nil {
		t.Fatalf("readlink: %v", err)
	} else if got != "renamed.txt" {
		t.Fatalf("readlink = %q, want renamed.txt", got)
	}
	if _, err := b.CreateLink("/dir/renamed.txt", "/dir/hard.txt"); err != nil {
		t.Fatalf("hardlink: %v", err)
	}

	xattr := []byte("xattr through 9p")
	if err := b.SetXattr("/dir/renamed.txt", "user.codex", xattr); err != nil {
		t.Fatalf("setxattr: %v", err)
	}
	// macOS may add its own xattrs (e.g. com.apple.provenance), so assert
	// presence of ours rather than an exact list.
	if names, err := b.ListXattr("/dir/renamed.txt"); err != nil {
		t.Fatalf("listxattr: %v", err)
	} else if !contains(names, "user.codex") {
		t.Fatalf("listxattr = %v, want to contain user.codex", names)
	}
	if got, err := b.GetXattr("/dir/renamed.txt", "user.codex"); err != nil {
		t.Fatalf("getxattr: %v", err)
	} else if !bytes.Equal(got, xattr) {
		t.Fatalf("getxattr = %q, want %q", got, xattr)
	}
	if err := b.RemoveXattr("/dir/renamed.txt", "user.codex"); err != nil {
		t.Fatalf("rmxattr: %v", err)
	}
	if names, err := b.ListXattr("/dir/renamed.txt"); err != nil {
		t.Fatalf("listxattr after remove: %v", err)
	} else if contains(names, "user.codex") {
		t.Fatalf("xattr still present after removal: %v", names)
	}

	for _, name := range []string{"/dir/hard.txt", "/dir/link.txt", "/dir/renamed.txt", "/dir"} {
		if err := b.Remove(name); err != nil {
			t.Fatalf("remove %s: %v", name, err)
		}
	}
}

func contains(names []string, want string) bool {
	for _, name := range names {
		if name == want {
			return true
		}
	}
	return false
}
