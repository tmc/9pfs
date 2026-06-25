//go:build darwin && cshared && !ninepfs_stubgo

package main

/*
#include <stdint.h>
#include <stdlib.h>
*/
import "C"

import (
	"errors"
	"fmt"
	"os"
	"os/signal"
	"syscall"
	"unsafe"

	"github.com/tmc/apple/objc"
	"github.com/tmc/apple/x/fskitbridge"
)

func init() {
	ch := make(chan os.Signal, 1)
	signal.Notify(ch, syscall.SIGQUIT)
	go func() {
		for sig := range ch {
			extensionLog("caught signal " + sig.String())
		}
	}()
}

// ninepExtension hosts the bridge server inside the FSKit extension. It owns
// the c-archive lifecycle (lazy retryable init, last-error, reply fallback,
// panic recovery); the exported entry points below are one-line wrappers,
// since a c-archive cannot re-export Go functions from an imported package.
var ninepExtension = fskitbridge.NewExtension(ninepShims, newNinepServer)

// newNinepServer builds the bridge server against the Swift-provided
// NinePFileSystem class. It is retried on every Init until the class is
// registered, so a call that races extension startup does not poison the
// process.
func newNinepServer() (*fskitbridge.Server, error) {
	cls := objc.GetClass("NinePFileSystem")
	if cls == 0 {
		return nil, errors.New("swift shim did not register NinePFileSystem")
	}
	var srv *fskitbridge.Server
	var err error
	objc.AutoreleasePool(func() {
		srv, err = ensureServer(cls, &ninepFileSystem{config: defaultFSConfigFromEnv()})
	})
	if err != nil {
		extensionLog("register bridge: " + err.Error())
	}
	return srv, err
}

//export NinePFSInit
func NinePFSInit() C.int {
	if ninepExtension.Init() != nil {
		return -1
	}
	return 0
}

//export NinePFSNewFileSystem
func NinePFSNewFileSystem() unsafe.Pointer {
	// An objc.ID is an object pointer; reinterpret rather than convert
	// through uintptr, which vet rejects.
	fs := ninepExtension.NewFileSystem()
	return *(*unsafe.Pointer)(unsafe.Pointer(&fs))
}

//export NinePFSConfigureFileSystem
func NinePFSConfigureFileSystem(raw unsafe.Pointer) C.int {
	extensionLog("configure file system begin")
	if ninepExtension.Init() != nil {
		extensionLog("configure file system: init failed")
		return -1
	}
	if raw == nil {
		extensionLog("configure file system: nil object")
		return -1
	}
	extensionLog("configure file system ok")
	return 0
}

//export NinePFSProbeResource
func NinePFSProbeResource(self, resource, reply unsafe.Pointer) {
	ninepExtension.ProbeResource(objc.ID(uintptr(self)), objc.ID(uintptr(resource)), objc.ID(uintptr(reply)))
}

//export NinePFSLoadResource
func NinePFSLoadResource(self, resource, options, reply unsafe.Pointer) {
	ninepExtension.LoadResource(objc.ID(uintptr(self)), objc.ID(uintptr(resource)), objc.ID(uintptr(options)), objc.ID(uintptr(reply)))
}

//export NinePFSUnloadResource
func NinePFSUnloadResource(self, resource, options, reply unsafe.Pointer) {
	ninepExtension.UnloadResource(objc.ID(uintptr(self)), objc.ID(uintptr(resource)), objc.ID(uintptr(options)), objc.ID(uintptr(reply)))
}

//export NinePFSLastError
func NinePFSLastError() *C.char {
	err := ninepExtension.LastError()
	if err == nil {
		return nil
	}
	return C.CString(err.Error())
}

func extensionLog(msg string) {
	nativeExtensionLog(msg)
	if os.Getenv("NINEPFS_DEBUG") != "" {
		fmt.Fprintln(os.Stderr, "9pfs: "+msg)
	}
}
