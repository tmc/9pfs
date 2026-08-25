//go:build darwin

package main

import (
	"bytes"
	"os"
	"path/filepath"
	"testing"
)

// TestLive exercises a backend against a real 9p server over the loopback.
// The server is started by test-live.sh, which builds p9ufs, exports a
// README, and passes the address and dialect through the environment. Without those, the test skips, so plain `go test` stays
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

	// The server's own view of ownership and timestamps has to reach us:
	// reporting the local user on every file, or the modification time as
	// all four timestamps, is what this file system did before it kept
	// these fields. 9P2000.L reports them; classic 9P2000 names owners
	// with strings and has no change or birth time.
	switch {
	case linux && !readme.HasOwner:
		t.Error("9p2000.l reported no owner for /README")
	case linux && readme.Links == 0:
		t.Error("9p2000.l reported no link count for /README")
	case linux && readme.Changed == 0:
		t.Error("9p2000.l reported no change time for /README")
	case linux:
		t.Logf("/README owner %d:%d, %d link(s), atime %d ctime %d btime %d",
			readme.UID, readme.GID, readme.Links, readme.Accessed, readme.Changed, readme.Born)
	case readme.HasOwner:
		t.Error("9p2000 claimed a numeric owner; the dialect names owners with strings")
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

	// A volume must report the link the server now sees, not the attributes
	// it cached when the file was looked up. The link was made through the
	// parent directory, so nothing touched this file's own item: answering
	// from the cache reported one link, and would have gone on reporting a
	// stale size and mtime for as long as the item lived -- which on a
	// server shared with other clients is until unmount.
	if link, err := b.Stat("/dir/renamed.txt"); err != nil {
		t.Fatalf("stat after hardlink: %v", err)
	} else if link.Links != 2 {
		t.Errorf("link count after hardlink = %d, want 2", link.Links)
	}
	v := newNinepVolume(b, false)
	root, err := v.Root()
	if err != nil {
		t.Fatalf("root: %v", err)
	}
	dir, err := v.Lookup(root, "dir")
	if err != nil {
		t.Fatalf("lookup dir: %v", err)
	}
	linked, err := v.Lookup(dir, "renamed.txt")
	if err != nil {
		t.Fatalf("lookup renamed.txt: %v", err)
	}
	if _, err := b.CreateLink("/dir/renamed.txt", "/dir/hard2.txt"); err != nil {
		t.Fatalf("second hardlink: %v", err)
	}
	// The item was looked up before this link existed, so a cached answer
	// says 2 and a fresh one says 3.
	if attrs, err := v.Attributes(linked); err != nil {
		t.Fatalf("attributes after second hardlink: %v", err)
	} else if attrs.LinkCount() != 3 {
		t.Errorf("volume reports %d links after a link made behind its back, want 3", attrs.LinkCount())
	}
	if err := b.Remove("/dir/hard2.txt"); err != nil {
		t.Fatalf("remove second hardlink: %v", err)
	}

	// Ownership has to be asserted here rather than through a mount. A mount
	// made by an ordinary user carries noowners, under which the kernel
	// reports the mounting user as the owner of everything and never passes
	// the file system's answer through. This is the layer where the answer
	// still exists.
	export := os.Getenv("NINEPFS_LIVE_EXPORT")
	if gid := secondaryGID(); export != "" && gid != 0 {
		if err := os.Chown(filepath.Join(export, "dir", "renamed.txt"), -1, int(gid)); err != nil {
			t.Fatalf("chown export file: %v", err)
		}
		attrs, err := v.Attributes(linked)
		if err != nil {
			t.Fatalf("attributes after chown: %v", err)
		}
		if attrs.Gid() != gid {
			t.Errorf("volume reports gid %d, want the server's %d", attrs.Gid(), gid)
		}
		if attrs.Uid() != uint32(os.Getuid()) {
			t.Errorf("volume reports uid %d, want the server's %d", attrs.Uid(), os.Getuid())
		}
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

// secondaryGID returns a group the current process belongs to that is not its
// primary group, or 0 if there is none. Asserting ownership needs one: a file
// in the primary group cannot distinguish the server's answer from the local
// credentials, which is how a file system reporting its own uid and gid for
// every file went unnoticed.
func secondaryGID() uint32 {
	groups, err := os.Getgroups()
	if err != nil {
		return 0
	}
	for _, g := range groups {
		if g != os.Getgid() && g > 0 {
			return uint32(g)
		}
	}
	return 0
}
