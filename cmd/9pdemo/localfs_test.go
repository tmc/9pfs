package main

import (
	"net"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/hugelgupf/p9/p9"
)

func TestDemoFileSetAttrPermissions(t *testing.T) {
	root := t.TempDir()
	path := filepath.Join(root, "hello.txt")
	if err := os.WriteFile(path, []byte("hello\n"), 0o644); err != nil {
		t.Fatal(err)
	}

	file := walkDemoFile(t, root, "hello.txt")
	defer file.Close()
	if err := file.SetAttr(p9.SetAttrMask{Permissions: true}, p9.SetAttr{Permissions: 0o100600}); err != nil {
		t.Fatalf("SetAttr permissions: %v", err)
	}
	info, err := os.Stat(path)
	if err != nil {
		t.Fatal(err)
	}
	if got := info.Mode().Perm(); got != 0o600 {
		t.Fatalf("mode = %04o, want 0600", got)
	}
}

func TestDemoServerAtomicReplace(t *testing.T) {
	root := t.TempDir()
	if err := os.WriteFile(filepath.Join(root, "hello.txt"), []byte("old\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	stage := "hello.txt.sb-test"

	rootFile := attachDemoServer(t, root)
	if _, err := rootFile.Mkdir(stage, 0o700, p9.NoUID, p9.NoGID); err != nil {
		t.Fatalf("Mkdir staging directory: %v", err)
	}
	creator := walkFrom(t, rootFile, stage)
	replacement, _, _, err := creator.Create("hello.txt", p9.WriteOnly, 0o600, p9.NoUID, p9.NoGID)
	if err != nil {
		creator.Close()
		t.Fatalf("Create replacement: %v", err)
	}
	defer replacement.Close()
	if _, err := replacement.WriteAt([]byte("new contents\n"), 0); err != nil {
		t.Fatalf("Write replacement: %v", err)
	}
	if err := replacement.SetAttr(p9.SetAttrMask{Permissions: true}, p9.SetAttr{Permissions: 0o644}); err != nil {
		t.Fatalf("SetAttr replacement permissions: %v", err)
	}
	stageFile := walkFrom(t, rootFile, stage)
	defer stageFile.Close()
	if err := stageFile.RenameAt("hello.txt", rootFile, "hello.txt"); err != nil {
		t.Fatalf("rename replacement: %v", err)
	}
	if err := replacement.SetAttr(p9.SetAttrMask{Permissions: true}, p9.SetAttr{Permissions: 0o600}); err != nil {
		t.Fatalf("SetAttr renamed replacement permissions: %v", err)
	}

	data, err := os.ReadFile(filepath.Join(root, "hello.txt"))
	if err != nil {
		t.Fatal(err)
	}
	if got, want := string(data), "new contents\n"; got != want {
		t.Fatalf("contents = %q, want %q", got, want)
	}
	info, err := os.Stat(filepath.Join(root, "hello.txt"))
	if err != nil {
		t.Fatal(err)
	}
	if got := info.Mode().Perm(); got != 0o600 {
		t.Fatalf("mode = %04o, want 0600", got)
	}
}

func attachDemoServer(t *testing.T, root string) p9.File {
	t.Helper()
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("Listen: %v", err)
	}
	done := make(chan error, 1)
	go func() {
		done <- p9.NewServer(newDemoAttacher(root)).Serve(listener)
	}()
	t.Cleanup(func() {
		listener.Close()
		select {
		case <-done:
		case <-time.After(5 * time.Second):
			t.Error("server did not stop")
		}
	})

	conn, err := net.Dial("tcp", listener.Addr().String())
	if err != nil {
		t.Fatalf("Dial: %v", err)
	}
	client, err := p9.NewClient(conn)
	if err != nil {
		conn.Close()
		t.Fatalf("NewClient: %v", err)
	}
	t.Cleanup(func() { client.Close() })

	file, err := client.Attach("")
	if err != nil {
		t.Fatalf("Attach: %v", err)
	}
	t.Cleanup(func() { file.Close() })
	return file
}

func walkDemoFile(t *testing.T, root string, names ...string) p9.File {
	t.Helper()
	rootFile := attachDemoFile(t, root)
	t.Cleanup(func() { rootFile.Close() })
	return walkFrom(t, rootFile, names...)
}

func attachDemoFile(t *testing.T, root string) p9.File {
	t.Helper()
	file, err := newDemoAttacher(root).Attach()
	if err != nil {
		t.Fatalf("Attach: %v", err)
	}
	return file
}

func walkFrom(t *testing.T, file p9.File, names ...string) p9.File {
	t.Helper()
	_, walked, err := file.Walk(names)
	if err != nil {
		t.Fatalf("Walk(%q): %v", names, err)
	}
	return walked
}
