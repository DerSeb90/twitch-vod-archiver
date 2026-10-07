package api

import (
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"testing"

	"github.com/derseb90/twitch-vod-archiver/server/internal/config"
)

func TestMiddlewareCrossOrigin(t *testing.T) {
	cfg := &config.Config{CORSOrigins: []string{"http://localhost:5173"}}
	s := New(cfg, nil, nil, nil, slog.New(slog.NewTextHandler(io.Discard, nil)), "test")
	reached := false
	h := s.middleware(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		reached = true
		w.WriteHeader(http.StatusNoContent)
	}))
	do := func(method string, hdr map[string]string) *httptest.ResponseRecorder {
		t.Helper()
		reached = false
		r := httptest.NewRequest(method, "http://10.8.0.1:8080/api/channels/1", nil)
		for k, v := range hdr {
			r.Header.Set(k, v)
		}
		w := httptest.NewRecorder()
		h.ServeHTTP(w, r)
		return w
	}

	cases := []struct {
		name   string
		method string
		hdr    map[string]string
		pass   bool
		acao   string
	}{
		{"native app", "DELETE", nil, true, ""},
		{"same origin (fetch metadata)", "DELETE", map[string]string{"Origin": "http://10.8.0.1:8080", "Sec-Fetch-Site": "same-origin"}, true, ""},
		{"same origin (old browser)", "DELETE", map[string]string{"Origin": "http://10.8.0.1:8080"}, true, ""},
		{"foreign page", "DELETE", map[string]string{"Origin": "https://evil.example", "Sec-Fetch-Site": "cross-site"}, false, ""},
		{"foreign page (old browser)", "POST", map[string]string{"Origin": "https://evil.example"}, false, ""},
		{"other port on the same host", "PATCH", map[string]string{"Origin": "http://10.8.0.1:9999", "Sec-Fetch-Site": "same-site"}, false, ""},
		{"CORS_ORIGINS", "DELETE", map[string]string{"Origin": "http://localhost:5173", "Sec-Fetch-Site": "cross-site"}, true, "http://localhost:5173"},
		{"read from anywhere", "GET", map[string]string{"Origin": "https://evil.example", "Sec-Fetch-Site": "cross-site"}, true, "*"},
	}
	for _, c := range cases {
		w := do(c.method, c.hdr)
		if reached != c.pass {
			t.Errorf("%s: reached handler = %v, want %v (status %d)", c.name, reached, c.pass, w.Code)
		}
		if !c.pass && w.Code != http.StatusForbidden {
			t.Errorf("%s: status %d, want 403", c.name, w.Code)
		}
		if got := w.Header().Get("Access-Control-Allow-Origin"); got != c.acao {
			t.Errorf("%s: Access-Control-Allow-Origin %q, want %q", c.name, got, c.acao)
		}
	}

	// preflights succeed only for allowed origins
	w := do("OPTIONS", map[string]string{"Origin": "https://evil.example", "Access-Control-Request-Method": "DELETE"})
	if reached || w.Header().Get("Access-Control-Allow-Origin") != "" || w.Header().Get("Access-Control-Allow-Methods") != "" {
		t.Errorf("foreign preflight allowed: %v", w.Header())
	}
	w = do("OPTIONS", map[string]string{"Origin": "http://localhost:5173", "Access-Control-Request-Method": "DELETE"})
	if reached || w.Code != http.StatusNoContent || w.Header().Get("Access-Control-Allow-Origin") != "http://localhost:5173" || w.Header().Get("Access-Control-Allow-Methods") == "" {
		t.Errorf("allowed preflight: %d %v", w.Code, w.Header())
	}
}

func TestFileHandlerStaysInRoot(t *testing.T) {
	dir := t.TempDir()
	root := filepath.Join(dir, "archive")
	os.MkdirAll(filepath.Join(root, "chan", ".hidden"), 0o755)
	os.WriteFile(filepath.Join(root, "chan", "video.mp4"), []byte("video"), 0o644)
	os.WriteFile(filepath.Join(root, "chan", ".hidden", "x"), []byte("x"), 0o644)
	os.WriteFile(filepath.Join(dir, "secret.txt"), []byte("secret"), 0o644)
	h := http.StripPrefix("/media/", fileHandler(root, true))
	get := func(target string) int {
		w := httptest.NewRecorder()
		h.ServeHTTP(w, httptest.NewRequest("GET", target, nil))
		return w.Code
	}
	if c := get("/media/chan/video.mp4"); c != http.StatusOK {
		t.Fatalf("regular file: %d", c)
	}
	for _, target := range []string{
		"/media/chan%5c..%5c..%5csecret.txt", // backslash separators (Windows)
		"/media/..%5csecret.txt",
		"/media/%5c%5c..%5csecret.txt",
		"/media/../secret.txt",
		"/media/chan/.hidden/x",
		"/media/chan",
	} {
		if c := get(target); c != http.StatusNotFound {
			t.Errorf("%s: %d, want 404", target, c)
		}
	}
}
