// Package util holds small helpers shared across packages.
package util

import (
	"crypto/rand"
	"encoding/base32"
	"encoding/binary"
	"io/fs"
	"path/filepath"
	"strings"
	"time"
)

const idAlphabet = "0123456789abcdefghjkmnpqrstvwxyz"

var enc = base32.NewEncoding(idAlphabet).WithPadding(base32.NoPadding)

// NewID returns a short, time-sortable, url-safe id (Crockford-style base32).
func NewID() string {
	var b [16]byte
	binary.BigEndian.PutUint64(b[:8], uint64(time.Now().UnixMilli()))
	_, _ = rand.Read(b[8:])
	// drop the two always-zero leading bytes of the timestamp
	return strings.ToLower(enc.EncodeToString(b[2:12]))
}

// IsID reports whether s has the form of an id made by NewID.
func IsID(s string) bool {
	if len(s) != 16 {
		return false
	}
	for _, r := range s {
		if !strings.ContainsRune(idAlphabet, r) {
			return false
		}
	}
	return true
}

// DirSize is the total size of all files below dir (0 if it doesn't exist).
func DirSize(dir string) int64 {
	var n int64
	_ = filepath.WalkDir(dir, func(_ string, d fs.DirEntry, err error) error {
		if err == nil && !d.IsDir() {
			if fi, err := d.Info(); err == nil {
				n += fi.Size()
			}
		}
		return nil
	})
	return n
}
