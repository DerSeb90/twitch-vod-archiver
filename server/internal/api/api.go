// Package api serves the JSON API, the archived media and the Flutter web app.
// There is intentionally no user login: the service is meant to sit behind a
// VPN. Mutating endpoints can optionally be protected with ADMIN_TOKEN, and
// browsers may only call them from the server's own origin (or CORS_ORIGINS),
// so a foreign web page opened inside the VPN cannot use them.
package api

import (
	"crypto/subtle"
	"encoding/json"
	"errors"
	"log/slog"
	"net/http"
	"path/filepath"
	"strings"
	"time"

	"github.com/derseb90/twitch-vod-archiver/server/internal/config"
	"github.com/derseb90/twitch-vod-archiver/server/internal/finalize"
	"github.com/derseb90/twitch-vod-archiver/server/internal/recorder"
	"github.com/derseb90/twitch-vod-archiver/server/internal/store"
	"github.com/derseb90/twitch-vod-archiver/server/internal/util"
)

type Server struct {
	cfg     *config.Config
	st      *store.Store
	rec     *recorder.Manager
	fin     *finalize.Finalizer
	log     *slog.Logger
	version string

	csrf    *http.CrossOriginProtection
	origins map[string]bool // CORS_ORIGINS
}

func New(cfg *config.Config, st *store.Store, rec *recorder.Manager, fin *finalize.Finalizer, log *slog.Logger, version string) *Server {
	s := &Server{cfg: cfg, st: st, rec: rec, fin: fin, log: log.With("component", "api"), version: version,
		csrf: http.NewCrossOriginProtection(), origins: map[string]bool{}}
	for _, o := range cfg.CORSOrigins {
		if err := s.csrf.AddTrustedOrigin(o); err != nil {
			s.log.Warn("ignoring CORS origin", "origin", o, "err", err)
			continue
		}
		s.origins[o] = true
	}
	return s
}

func (s *Server) Handler() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /api/health", func(w http.ResponseWriter, r *http.Request) {
		writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
	})
	mux.HandleFunc("GET /api/info", s.info)
	mux.HandleFunc("POST /api/auth", s.admin(func(w http.ResponseWriter, r *http.Request) { writeJSON(w, http.StatusOK, map[string]bool{"ok": true}) }))

	mux.HandleFunc("GET /api/channels", s.listChannels)
	mux.HandleFunc("GET /api/channels/{id}", s.getChannel)
	mux.HandleFunc("POST /api/channels", s.admin(s.addChannel))
	mux.HandleFunc("PATCH /api/channels/{id}", s.admin(s.patchChannel))
	mux.HandleFunc("DELETE /api/channels/{id}", s.admin(s.deleteChannel))

	mux.HandleFunc("GET /api/live", s.listRecordings)
	mux.HandleFunc("GET /api/vods", s.listVods)
	mux.HandleFunc("GET /api/vods/{id}", s.getVod)
	mux.HandleFunc("DELETE /api/vods/{id}", s.admin(s.deleteVod))
	mux.HandleFunc("POST /api/vods/{id}/retry", s.admin(s.retryVod))
	// Watch progress is part of viewing: no admin token (single user behind the VPN).
	mux.HandleFunc("PUT /api/vods/{id}/progress", s.putProgress)
	mux.HandleFunc("DELETE /api/vods/{id}/progress", s.deleteProgress)
	mux.HandleFunc("GET /api/progress", s.progressSince)
	mux.HandleFunc("GET /api/changes", s.changes)

	mux.HandleFunc("POST /api/recordings/{channel}/pause", s.admin(s.recordingControl("pause")))
	mux.HandleFunc("POST /api/recordings/{channel}/resume", s.admin(s.recordingControl("resume")))
	mux.HandleFunc("POST /api/recordings/{channel}/finish", s.admin(s.recordingControl("finish")))

	mux.HandleFunc("GET /img", s.imageProxy)

	mux.Handle("GET /media/", http.StripPrefix("/media/", fileHandler(s.cfg.ArchiveDir, true)))
	mux.Handle("GET /avatars/", http.StripPrefix("/avatars/", fileHandler(filepath.Join(s.cfg.DataDir, "avatars"), false)))
	mux.Handle("GET /", s.spa())
	return s.middleware(mux)
}

// middleware sets CORS headers and refuses cross-origin writes. Reads stay
// open to every origin (media, JSON); writes and preflights only succeed
// from the server's own origin or one listed in CORS_ORIGINS. Native apps
// send no Origin / Sec-Fetch-Site header and are not affected.
func (s *Server) middleware(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		h := w.Header()
		h.Set("X-Content-Type-Options", "nosniff")
		origin := r.Header.Get("Origin")
		if len(s.origins) > 0 {
			h.Add("Vary", "Origin")
		}
		switch {
		case origin != "" && s.origins[origin]:
			h.Set("Access-Control-Allow-Origin", origin)
			h.Set("Access-Control-Allow-Headers", "Authorization, Content-Type, Range")
			h.Set("Access-Control-Allow-Methods", "GET, POST, PUT, PATCH, DELETE, OPTIONS")
			h.Set("Access-Control-Expose-Headers", "Content-Length, Content-Range, Accept-Ranges")
		case r.Method == http.MethodGet || r.Method == http.MethodHead:
			h.Set("Access-Control-Allow-Origin", "*")
			h.Set("Access-Control-Expose-Headers", "Content-Length, Content-Range, Accept-Ranges")
		}
		if r.Method == http.MethodOptions {
			w.WriteHeader(http.StatusNoContent) // without allow headers the browser refuses the actual request
			return
		}
		if err := s.csrf.Check(r); err != nil {
			s.log.Warn("cross-origin request refused", "method", r.Method, "path", r.URL.Path, "origin", origin)
			writeErr(w, http.StatusForbidden, errors.New("cross-origin request refused (add the origin to CORS_ORIGINS to allow it)"))
			return
		}
		start := time.Now()
		next.ServeHTTP(w, r)
		if strings.HasPrefix(r.URL.Path, "/api/") {
			s.log.Debug("request", "method", r.Method, "path", r.URL.Path, "took", time.Since(start))
		}
	})
}

func (s *Server) admin(next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if s.cfg.AdminToken != "" {
			tok := strings.TrimPrefix(r.Header.Get("Authorization"), "Bearer ")
			if subtle.ConstantTimeCompare([]byte(tok), []byte(s.cfg.AdminToken)) != 1 {
				writeErr(w, http.StatusUnauthorized, errors.New("admin token required"))
				return
			}
		}
		next(w, r)
	}
}

func (s *Server) info(w http.ResponseWriter, r *http.Request) {
	stats, err := s.st.Stats(r.Context())
	if err != nil {
		writeErr(w, http.StatusInternalServerError, err)
		return
	}
	lf, lt := util.FreeBytes(s.cfg.RecordingsDir)
	af, at := util.FreeBytes(s.cfg.ArchiveDir)
	writeJSON(w, http.StatusOK, map[string]any{
		"appName":       s.cfg.AppName,
		"version":       s.version,
		"adminRequired": s.cfg.AdminToken != "",
		"maxConcurrent": s.cfg.MaxConcurrent,
		"recording":     len(s.rec.Recordings()),
		"adFree":        s.rec.AdFree(),
		"processing":    s.fin.Active(),
		"stats":         stats,
		"disk": map[string]uint64{
			"localFree": lf, "localTotal": lt, "archiveFree": af, "archiveTotal": at,
		},
	})
}

func writeJSON(w http.ResponseWriter, code int, v any) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.Header().Set("Cache-Control", "no-store")
	w.WriteHeader(code)
	enc := json.NewEncoder(w)
	enc.SetEscapeHTML(false)
	_ = enc.Encode(v)
}

func writeErr(w http.ResponseWriter, code int, err error) {
	writeJSON(w, code, map[string]string{"error": err.Error()})
}

func statusFor(err error) int {
	if errors.Is(err, store.ErrNotFound) {
		return http.StatusNotFound
	}
	return http.StatusInternalServerError
}
