package util

import "testing"

func TestIsID(t *testing.T) {
	for range 100 {
		if id := NewID(); !IsID(id) {
			t.Fatalf("NewID %q not recognized", id)
		}
	}
	for _, s := range []string{"", "vod1", "avatars", "0123456789abcdei", "0123456789ABCDEF", "0123456789abcdefg"} {
		if IsID(s) {
			t.Errorf("IsID(%q) = true", s)
		}
	}
}
