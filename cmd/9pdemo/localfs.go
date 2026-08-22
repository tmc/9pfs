package main

import (
	"os"
	"path/filepath"

	"github.com/hugelgupf/p9/fsimpl/localfs"
	"github.com/hugelgupf/p9/p9"
)

// demoAttacher adds the permission change missing from localfs. The release
// build patches localfs itself, but an ordinary "go run ./cmd/9pdemo" uses the
// unpatched module named by go.mod.
type demoAttacher struct {
	root string
	p9.Attacher
}

func newDemoAttacher(root string) p9.Attacher {
	if root == "" {
		root = "/"
	}
	return &demoAttacher{root: root, Attacher: localfs.Attacher(root)}
}

func (a *demoAttacher) Attach() (p9.File, error) {
	file, err := a.Attacher.Attach()
	if err != nil {
		return nil, err
	}
	return &demoFile{File: file, path: a.root}, nil
}

// demoFile tracks the local path corresponding to a localfs file so it can
// apply a 9P2000.L permission change with chmod.
type demoFile struct {
	p9.File
	path string
}

func (f *demoFile) Walk(names []string) ([]p9.QID, p9.File, error) {
	qids, file, err := f.File.Walk(names)
	if file != nil {
		parts := append([]string{f.path}, names...)
		file = &demoFile{File: file, path: filepath.Join(parts...)}
	}
	return qids, file, err
}

func (f *demoFile) WalkGetAttr(names []string) ([]p9.QID, p9.File, p9.AttrMask, p9.Attr, error) {
	qids, file, valid, attr, err := f.File.WalkGetAttr(names)
	if file != nil {
		parts := append([]string{f.path}, names...)
		file = &demoFile{File: file, path: filepath.Join(parts...)}
	}
	return qids, file, valid, attr, err
}

func (f *demoFile) Create(name string, flags p9.OpenFlags, permissions p9.FileMode, uid p9.UID, gid p9.GID) (p9.File, p9.QID, uint32, error) {
	file, qid, iounit, err := f.File.Create(name, flags, permissions, uid, gid)
	if file != nil {
		file = &demoFile{File: file, path: filepath.Join(f.path, name)}
	}
	return file, qid, iounit, err
}

func (f *demoFile) SetAttr(valid p9.SetAttrMask, attr p9.SetAttr) error {
	rest := valid
	rest.Permissions = false
	if !rest.Empty() {
		if err := f.File.SetAttr(rest, attr); err != nil {
			return err
		}
	}
	if !valid.Permissions {
		return nil
	}
	return os.Chmod(f.path, os.FileMode(attr.Permissions.Permissions()))
}

func (f *demoFile) Link(target p9.File, newName string) error {
	return f.File.Link(unwrapDemoFile(target), newName)
}

func (f *demoFile) Rename(newDir p9.File, newName string) error {
	return f.File.Rename(unwrapDemoFile(newDir), newName)
}

func (f *demoFile) RenameAt(oldName string, newDir p9.File, newName string) error {
	return f.File.RenameAt(oldName, unwrapDemoFile(newDir), newName)
}

func (f *demoFile) Renamed(newDir p9.File, newName string) {
	if dir, ok := newDir.(*demoFile); ok {
		f.path = filepath.Join(dir.path, newName)
	}
	f.File.Renamed(unwrapDemoFile(newDir), newName)
}

func unwrapDemoFile(file p9.File) p9.File {
	if file, ok := file.(*demoFile); ok {
		return file.File
	}
	return file
}
