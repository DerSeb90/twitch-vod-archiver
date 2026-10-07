package api

import (
	"mime"
	"net/http"
	"net/url"
	"os"
	"path"
	"path/filepath"
	"strings"
)

// fileHandler serves files (with Range support) from root. Hidden paths and
// directory listings are refused. Pre-compressed chat chunks (*.json.gz) are
// served with Content-Encoding so clients decompress transparently.
func fileHandler(root string, immutable bool) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		rel, ok := localPath(r.URL.Path)
		if !ok {
			http.NotFound(w, r)
			return
		}
		for _, seg := range strings.Split(rel, "/") {
			if strings.HasPrefix(seg, ".") {
				http.NotFound(w, r)
				return
			}
		}
		f, err := os.Open(filepath.Join(root, filepath.FromSlash(rel)))
		if err != nil {
			http.NotFound(w, r)
			return
		}
		defer f.Close()
		fi, err := f.Stat()
		if err != nil || fi.IsDir() {
			http.NotFound(w, r)
			return
		}
		h := w.Header()
		if immutable {
			h.Set("Cache-Control", "public, max-age=31536000, immutable")
		} else {
			h.Set("Cache-Control", "public, max-age=86400")
		}
		name := fi.Name()
		if strings.HasSuffix(name, ".json.gz") {
			h.Set("Content-Type", "application/json")
			h.Set("Content-Encoding", "gzip")
			name = strings.TrimSuffix(name, ".gz")
		}
		http.ServeContent(w, r, name, fi.ModTime(), f)
	})
}

// spa serves the Flutter web build; unknown paths fall back to index.html so
// deep links work. Pre-compressed .gz siblings are used when available.
func (s *Server) spa() http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if strings.HasPrefix(path.Clean("/"+r.URL.Path), "/api/") {
			http.NotFound(w, r)
			return
		}
		p := filepath.Join(s.cfg.WebDir, "index.html")
		if rel, ok := localPath(r.URL.Path); ok {
			if fi, err := os.Stat(filepath.Join(s.cfg.WebDir, filepath.FromSlash(rel))); err == nil && !fi.IsDir() {
				p = filepath.Join(s.cfg.WebDir, filepath.FromSlash(rel))
			}
		}
		w.Header().Set("Cache-Control", "no-cache")
		w.Header().Add("Vary", "Accept-Encoding")
		if strings.Contains(r.Header.Get("Accept-Encoding"), "gzip") {
			if fi, err := os.Stat(p + ".gz"); err == nil && !fi.IsDir() {
				ct := mime.TypeByExtension(filepath.Ext(p))
				if ct == "" {
					ct = "application/octet-stream"
				}
				w.Header().Set("Content-Type", ct)
				w.Header().Set("Content-Encoding", "gzip")
				f, err := os.Open(p + ".gz")
				if err == nil {
					defer f.Close()
					http.ServeContent(w, r, "", fi.ModTime(), f)
					return
				}
			}
		}
		if _, err := os.Stat(p); err != nil {
			http.Error(w, "web app not built (WEB_DIR="+s.cfg.WebDir+")", http.StatusNotFound)
			return
		}
		http.ServeFile(w, r, p)
	})
}

// localPath turns a URL path into a slash-separated path that stays inside
// the directory it is joined to. Backslashes are refused: on Windows they
// are separators, so `a\..\..\x` would otherwise climb out of the root.
func localPath(urlPath string) (string, bool) {
	rel := strings.TrimPrefix(path.Clean("/"+urlPath), "/")
	if rel == "" || strings.ContainsRune(rel, '\\') || !filepath.IsLocal(filepath.FromSlash(rel)) {
		return "", false
	}
	return rel, true
}

func escapePath(p string) string {
	segs := strings.Split(p, "/")
	for i, s := range segs {
		segs[i] = url.PathEscape(s)
	}
	return strings.Join(segs, "/")
}
