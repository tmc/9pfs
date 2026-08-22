//go:build darwin

package main

import (
	"errors"
	"testing"

	"9fans.net/go/plan9"
	p9 "github.com/hugelgupf/p9/p9"
	"github.com/tmc/apple/fskit"
)

func TestClean9PPath(t *testing.T) {
	tests := []struct {
		name string
		in   string
		want string
	}{
		{"root", "/", ""},
		{"empty", "", ""},
		{"relative", "tmp/file", "tmp/file"},
		{"absolute", "/tmp/file", "tmp/file"},
		{"clean", "/tmp/../usr//glenda", "usr/glenda"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := clean9PPath(tt.in); got != tt.want {
				t.Fatalf("clean9PPath(%q) = %q, want %q", tt.in, got, tt.want)
			}
		})
	}
}

func TestModeString(t *testing.T) {
	tests := []struct {
		name string
		mode plan9.Perm
		want string
	}{
		{"file", 0444, "-"},
		{"directory", plan9.DMDIR | 0555, "d"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := modeString(uint32(tt.mode)); got != tt.want {
				t.Fatalf("modeString(%v) = %q, want %q", tt.mode, got, tt.want)
			}
		})
	}
}

func TestItemTypeFor(t *testing.T) {
	tests := []struct {
		name string
		mode uint32
		want fskit.FSItemType
	}{
		{"file", 0644, fskit.FSItemTypeFile},
		{"directory plan9", uint32(plan9.DMDIR | 0755), fskit.FSItemTypeDirectory},
		{"directory p9", uint32(p9.ModeDirectory | 0755), fskit.FSItemTypeDirectory},
		{"symlink plan9", uint32(plan9.DMSYMLINK | 0777), fskit.FSItemTypeSymlink},
		{"symlink p9", uint32(p9.ModeSymlink | 0777), fskit.FSItemTypeSymlink},
		{"fifo", uint32(p9.ModeNamedPipe | 0644), fskit.FSItemTypeFIFO},
		{"char device", uint32(p9.ModeCharacterDevice | 0600), fskit.FSItemTypeCharDevice},
		{"block device", uint32(p9.ModeBlockDevice | 0600), fskit.FSItemTypeBlockDevice},
		{"socket", uint32(p9.ModeSocket | 0600), fskit.FSItemTypeSocket},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := itemTypeFor(nodeInfo{Mode: tt.mode})
			if got != tt.want {
				t.Fatalf("itemTypeFor(%#o) = %v, want %v", tt.mode, got, tt.want)
			}
		})
	}
}

func TestNinePBackendUnsupported(t *testing.T) {
	var b ninePBackend
	tests := []struct {
		name string
		fn   func() error
	}{
		{"create symlink", func() error {
			_, err := b.CreateSymlink("link", "target")
			return err
		}},
		{"create hardlink", func() error {
			_, err := b.CreateLink("old", "new")
			return err
		}},
		{"readlink", func() error {
			_, err := b.Readlink("link")
			return err
		}},
		{"get xattr", func() error {
			_, err := b.GetXattr("file", "user.codex")
			return err
		}},
		{"set xattr", func() error {
			return b.SetXattr("file", "user.codex", []byte("value"))
		}},
		{"list xattr", func() error {
			_, err := b.ListXattr("file")
			return err
		}},
		{"remove xattr", func() error {
			return b.RemoveXattr("file", "user.codex")
		}},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if err := tt.fn(); !errors.Is(err, errUnsupported) {
				t.Fatalf("error = %v, want errUnsupported", err)
			}
		})
	}
}

func TestPreallocateGrowNeverShrinks(t *testing.T) {
	b := newSmokeBackend()
	if _, err := b.Create("big", 0644, false); err != nil {
		t.Fatal(err)
	}
	if _, err := b.WriteFile("big", 0, make([]byte, 1000)); err != nil {
		t.Fatal(err)
	}
	if _, err := b.Preallocate("big", 0, 10); err != nil {
		t.Fatal(err)
	}
	info, err := b.Stat("big")
	if err != nil {
		t.Fatal(err)
	}
	if info.Length != 1000 {
		t.Fatalf("length after preallocate = %d, want 1000", info.Length)
	}
	if _, err := b.Preallocate("big", 2000, 48); err != nil {
		t.Fatal(err)
	}
	info, err = b.Stat("big")
	if err != nil {
		t.Fatal(err)
	}
	if info.Length != 2048 {
		t.Fatalf("length after growing preallocate = %d, want 2048", info.Length)
	}
}

func TestItemIDForPathStable(t *testing.T) {
	v := newNinepVolume(newSmokeBackend(), false)
	if got := v.idForPath("", nodeInfo{}); got != fskit.FSItemIDRootDirectory {
		t.Fatalf("idForPath(\"\") = %d, want root", got)
	}
	a := v.idForPath("dir/a", nodeInfo{})
	if a2 := v.idForPath("dir/a", nodeInfo{}); a2 != a {
		t.Fatalf("idForPath not stable: %d then %d", a, a2)
	}
	if b := v.idForPath("dir/b", nodeInfo{}); b == a {
		t.Fatalf("distinct paths share id %d", a)
	}
}

func TestMovePaths(t *testing.T) {
	v := newNinepVolume(newSmokeBackend(), false)
	dir := v.idForPath("dir", nodeInfo{})
	child := v.idForPath("dir/child", nodeInfo{})
	other := v.idForPath("other", nodeInfo{})
	v.movePaths("dir", "renamed")
	if got := v.idForPath("renamed", nodeInfo{}); got != dir {
		t.Fatalf("renamed dir id = %d, want %d", got, dir)
	}
	if got := v.idForPath("renamed/child", nodeInfo{}); got != child {
		t.Fatalf("renamed child id = %d, want %d", got, child)
	}
	if got := v.idForPath("other", nodeInfo{}); got != other {
		t.Fatalf("unrelated path id changed: %d, want %d", got, other)
	}
	if got := v.idForPath("dir", nodeInfo{}); got == dir {
		t.Fatalf("old path kept id %d after rename", dir)
	}
}

// TestPersistentItemIDsComeFromQIDPaths checks that a volume mounted with
// persistent IDs derives them from the server's QID paths rather than from
// the allocation counter. Nothing else can survive a remount, and the
// difference is invisible within a single mount, so it is worth asserting
// directly.
func TestPersistentItemIDsComeFromQIDPaths(t *testing.T) {
	v := newNinepVolume(newSmokeBackend(), true)
	if got := v.idForPath("", nodeInfo{QIDPath: 99}); got != fskit.FSItemIDRootDirectory {
		t.Fatalf("root id = %d, want root regardless of QID path", got)
	}
	if got := v.idForPath("dir/a", nodeInfo{QIDPath: 4242}); got != 4242 {
		t.Fatalf("idForPath(dir/a) = %d, want the QID path 4242", got)
	}
	// The ID follows the file, not the name: the same QID path under a
	// different name is the same file, so it keeps its ID.
	if got := v.idForPath("dir/renamed", nodeInfo{QIDPath: 4242}); got != 4242 {
		t.Fatalf("id after rename = %d, want 4242", got)
	}
	// A server that reports no QID path leaves nothing to be persistent
	// about; fall back to the counter rather than collapsing every such
	// file onto one ID.
	first := v.idForPath("dir/b", nodeInfo{})
	if second := v.idForPath("dir/c", nodeInfo{}); second == first {
		t.Fatalf("paths without QID paths share id %d", first)
	}
}

// TestPersistentItemIDsAvoidReservedValues checks that a QID path colliding
// with FSItemIDInvalid, FSItemIDParentOfRoot, or FSItemIDRootDirectory is
// folded somewhere harmless instead of being handed to FSKit as-is.
func TestPersistentItemIDsAvoidReservedValues(t *testing.T) {
	for _, qidPath := range []uint64{0, 1, 2} {
		got := persistentItemID(qidPath)
		switch got {
		case fskit.FSItemIDInvalid, fskit.FSItemIDParentOfRoot, fskit.FSItemIDRootDirectory:
			t.Errorf("persistentItemID(%d) = %d, a reserved id", qidPath, got)
		}
	}
	if a, b := persistentItemID(0), persistentItemID(1); a == b {
		t.Errorf("distinct reserved QID paths collapsed onto %d", a)
	}
	if got := persistentItemID(3); got != 3 {
		t.Errorf("persistentItemID(3) = %d, want 3 unchanged", got)
	}
}

func TestFSConfigForURL(t *testing.T) {
	tests := []struct {
		name string
		raw  string
		want fsConfig
	}{
		{
			name: "ninep default port",
			raw:  "ninep://localhost/share",
			want: fsConfig{dialect: "9p2000", network: "tcp", addr: "localhost:5640", aname: "share"},
		},
		{
			name: "persistent ids opt-in",
			raw:  "ninep://localhost/share?persistentids=1",
			want: fsConfig{dialect: "9p2000", network: "tcp", addr: "localhost:5640", aname: "share", persistentIDs: true},
		},
		{
			name: "tcp port dialect and aname",
			raw:  "tcp://127.0.0.1:17000/?dialect=9p2000l&aname=srv",
			want: fsConfig{dialect: "9p2000l", network: "tcp", addr: "127.0.0.1:17000", aname: "srv"},
		},
		{
			name: "unix socket",
			raw:  "unix:///tmp/9p.sock?dialect=9p2000l",
			want: fsConfig{dialect: "9p2000l", network: "unix", addr: "/tmp/9p.sock"},
		},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got, err := fsConfigForURL(fsConfig{dialect: "9p2000", network: "tcp", addr: "127.0.0.1:5640"}, tt.raw)
			if err != nil {
				t.Fatal(err)
			}
			if got != tt.want {
				t.Fatalf("fsConfigForURL(%q) = %+v, want %+v", tt.raw, got, tt.want)
			}
		})
	}
}
