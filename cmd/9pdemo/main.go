// Command 9pdemo serves a small 9P2000.L file system on the loopback so that
// the mount example has something to mount.
//
// It exports a temporary directory holding a few sample files, prints the
// mount command for that address, and removes the directory when it stops:
//
//	9pdemo
//	mkdir -p ~/9pfs
//	/sbin/mount -F -t 9pfs 'ninep://127.0.0.1:5640?dialect=9p2000l&persistentids=1' ~/9pfs
//
// The exported files are writable, so a mount can be exercised rather than
// only listed. The mount command asks for persistent object IDs because this
// server derives its QID paths from the underlying files, so they identify a
// file across a remount; document versioning needs that.
//
// Pass -root to export a directory of your own instead; that directory is
// left alone on exit. The listener is bound to the loopback and -addr cannot
// move it off: this serves an unauthenticated file system.
package main

import (
	"flag"
	"fmt"
	"log"
	"net"
	"os"
	"os/signal"
	"path/filepath"
	"strings"
	"syscall"

	"github.com/hugelgupf/p9/fsimpl/localfs"
	"github.com/hugelgupf/p9/p9"
)

var (
	addr = flag.String("addr", "127.0.0.1:5640", "loopback address to listen on")
	root = flag.String("root", "", "directory to export (default: a temporary one holding sample files)")
)

// sample is the demo tree, laid out so that a mount shows a file to read, a
// file to write, and a subdirectory to descend into.
var sample = map[string]string{
	"README": `This directory is served over 9P2000.L by 9pdemo.

If you can read this through a mount, the whole path works: the FSKit
extension loaded, it dialed the server, and it read a file back.

The files here are writable. Edit one, or create a new one, and it changes
on the server side too. Everything is removed when 9pdemo stops.
`,
	"hello.txt":         "hello from 9pdemo\n",
	"notes/scratch.txt": "Write to this file to exercise the write path.\n",
}

func main() {
	log.SetFlags(0)
	log.SetPrefix("9pdemo: ")
	flag.Parse()

	// Refuse anything but the loopback. A demo file system with no
	// authentication has no business being reachable from the network.
	host, _, err := net.SplitHostPort(*addr)
	if err != nil {
		log.Fatalf("bad -addr %q: %v", *addr, err)
	}
	if ip := net.ParseIP(host); ip == nil || !ip.IsLoopback() {
		log.Fatalf("bad -addr %q: the host must be a loopback address", *addr)
	}

	dir := *root
	if dir == "" {
		dir, err = os.MkdirTemp("", "9pdemo")
		if err != nil {
			log.Fatalf("create export directory: %v", err)
		}
		defer os.RemoveAll(dir)
		if err := writeSample(dir); err != nil {
			log.Fatalf("write sample files: %v", err)
		}
	}

	ln, err := net.Listen("tcp", *addr)
	if err != nil {
		log.Fatalf("listen: %v", err)
	}

	fmt.Print(instructions(dir, ln.Addr().String()))

	// Serve blocks, so the interrupt handler closes the listener to unblock
	// it and lets the deferred cleanup above run.
	stop := make(chan os.Signal, 1)
	signal.Notify(stop, os.Interrupt, syscall.SIGTERM)
	go func() {
		<-stop
		fmt.Println()
		ln.Close()
	}()

	// Serve returns the listener's error once it is closed; that is the
	// expected way to stop, not a failure.
	p9.NewServer(localfs.Attacher(dir)).Serve(ln)
}

func writeSample(dir string) error {
	for name, content := range sample {
		path := filepath.Join(dir, name)
		if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
			return err
		}
		if err := os.WriteFile(path, []byte(content), 0o644); err != nil {
			return err
		}
	}
	return nil
}

// instructions describes what to do with the running server. The mount point
// has to exist first: mounting onto a missing directory fails with the
// unhelpful "invalid file system".
func instructions(dir, addr string) string {
	var b strings.Builder
	fmt.Fprintf(&b, "serving %s on %s (9P2000.L)\n\n", dir, addr)
	fmt.Fprintf(&b, "Mount it:\n\n")
	fmt.Fprintf(&b, "    mkdir -p ~/9pfs\n")
	fmt.Fprintf(&b, "    /sbin/mount -F -t 9pfs 'ninep://%s?dialect=9p2000l&persistentids=1' ~/9pfs\n\n", addr)
	fmt.Fprintf(&b, "Unmount it:\n\n    umount ~/9pfs\n\n")
	fmt.Fprintf(&b, "Press Ctrl-C to stop.\n\n")
	return b.String()
}
