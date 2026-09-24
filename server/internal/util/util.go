// Package util holds small helpers shared across packages.
package util

import (
	"crypto/rand"
	"encoding/base32"
	"encoding/binary"
	"strings"
	"time"
)

var enc = base32.NewEncoding("0123456789abcdefghjkmnpqrstvwxyz").WithPadding(base32.NoPadding)

// NewID returns a short, time-sortable, url-safe id (Crockford-style base32).
func NewID() string {
	var b [16]byte
	binary.BigEndian.PutUint64(b[:8], uint64(time.Now().UnixMilli()))
	_, _ = rand.Read(b[8:])
	// drop the two always-zero leading bytes of the timestamp
	return strings.ToLower(enc.EncodeToString(b[2:12]))
}
