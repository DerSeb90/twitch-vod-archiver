package config

import (
	"strings"
	"testing"
)

func TestLoad(t *testing.T) {
	t.Setenv("TWITCH_CLIENT_ID", "id")
	t.Setenv("TWITCH_CLIENT_SECRET", "secret")
	t.Setenv("DATA_DIR", "/srv/rewind/data")
	t.Setenv("RECORDINGS_DIR", "/srv/rewind/recordings")
	t.Setenv("ARCHIVE_DIR", "/mnt/archive")
	t.Setenv("CORS_ORIGINS", "http://localhost:5173, HTTPS://Example.org/")
	c, err := Load()
	if err != nil {
		t.Fatal(err)
	}
	if len(c.CORSOrigins) != 2 || c.CORSOrigins[0] != "http://localhost:5173" || c.CORSOrigins[1] != "https://example.org" {
		t.Fatalf("origins %q", c.CORSOrigins)
	}

	for _, raw := range []string{"abc123", " abc123\r", `"abc123"`, "'oauth:abc123' ", "oauth:abc123"} {
		t.Setenv("TWITCH_USER_OAUTH", raw)
		if c, err := Load(); err != nil || c.TwitchUserOAuth != "abc123" {
			t.Errorf("token %q -> %q, %v", raw, c.TwitchUserOAuth, err)
		}
	}
	t.Setenv("TWITCH_USER_OAUTH", "")

	t.Setenv("CORS_ORIGINS", "localhost:5173")
	if _, err := Load(); err == nil || !strings.Contains(err.Error(), "CORS_ORIGINS") {
		t.Fatalf("origin without scheme: %v", err)
	}
	t.Setenv("CORS_ORIGINS", "")

	for _, dirs := range [][3]string{
		{"/data", "/data", "/archive"},             // same folder
		{"/data", "/data/recordings", "/archive"},  // nested
		{"/srv/x/data", "/recordings", "/srv/x"},   // archive contains data
		{"/data", "/recordings/./", "/recordings"}, // same after cleaning
	} {
		t.Setenv("DATA_DIR", dirs[0])
		t.Setenv("RECORDINGS_DIR", dirs[1])
		t.Setenv("ARCHIVE_DIR", dirs[2])
		if _, err := Load(); err == nil || !strings.Contains(err.Error(), "separate folders") {
			t.Errorf("%v: %v", dirs, err)
		}
	}
	t.Setenv("DATA_DIR", "/data")
	t.Setenv("RECORDINGS_DIR", "/recordings")
	t.Setenv("ARCHIVE_DIR", "/recordings-archive") // shared prefix only
	if _, err := Load(); err != nil {
		t.Fatal(err)
	}
}
