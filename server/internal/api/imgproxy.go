package api

import (
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"time"
)

// Emotes and badges are loaded through the server:
//   - some CDNs (e.g. BTTV) send no CORS headers, which breaks the web app
//   - cached copies keep the chat replay intact after an emote got deleted
//
// Only well-known emote/badge hosts are allowed, so this is no open proxy.
var imgHosts = map[string]bool{
	"static-cdn.jtvnw.net": true, // Twitch emotes, badges, box art
	"cdn.betterttv.net":    true,
	"cdn.7tv.app":          true,
	"cdn.frankerfacez.com": true,
}

var imgClient = &http.Client{Timeout: 20 * time.Second}

func (s *Server) imageProxy(w http.ResponseWriter, r *http.Request) {
	raw := r.URL.Query().Get("u")
	u, err := url.Parse(raw)
	if err != nil || u.Scheme != "https" || !imgHosts[u.Hostname()] || strings.Contains(u.Path, "/previews-ttv/") {
		http.Error(w, "host not allowed", http.StatusBadRequest)
		return
	}
	sum := sha256.Sum256([]byte(u.String()))
	key := hex.EncodeToString(sum[:])
	dir := filepath.Join(s.cfg.DataDir, "imgcache", key[:2])
	file := filepath.Join(dir, key)

	b, err := os.ReadFile(file)
	if err != nil {
		b, err = fetchImage(u.String())
		if err != nil {
			http.Error(w, err.Error(), http.StatusBadGateway)
			return
		}
		if os.MkdirAll(dir, 0o755) == nil {
			tmp := file + ".tmp"
			if os.WriteFile(tmp, b, 0o644) == nil {
				_ = os.Rename(tmp, file)
			}
		}
	}
	w.Header().Set("Content-Type", http.DetectContentType(b))
	w.Header().Set("Cache-Control", "public, max-age=31536000, immutable")
	_, _ = w.Write(b)
}

func fetchImage(u string) ([]byte, error) {
	resp, err := imgClient.Get(u)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("upstream: %s", resp.Status)
	}
	b, err := io.ReadAll(io.LimitReader(resp.Body, 8<<20))
	if err != nil {
		return nil, err
	}
	if !strings.HasPrefix(http.DetectContentType(b), "image/") {
		return nil, fmt.Errorf("upstream did not return an image")
	}
	return b, nil
}
