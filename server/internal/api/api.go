// Package api serves the JSON API, the archived media and the Flutter web app.
// There is intentionally no user login: the service is meant to sit behind a
// VPN. Mutating endpoints can optionally be protected with ADMIN_TOKEN.
package api

import (
	"context"
	"crypto/subtle"
	"encoding/json"
	"errors"
	"log/slog"
	"mime"
	"net/http"
	"net/url"
	"os"
	"path"
	"path/filepath"
	"strconv"
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
	chats   liveChats
}

func New(cfg *config.Config, st *store.Store, rec *recorder.Manager, fin *finalize.Finalizer, log *slog.Logger, version string) *Server {
	return &Server{cfg: cfg, st: st, rec: rec, fin: fin, log: log.With("component", "api"), version: version}
}

func (s *Server) Handler() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /api/health", func(w http.ResponseWriter, r *http.Request) { writeJSON(w, 200, map[string]string{"status": "ok"}) })
	mux.HandleFunc("GET /api/info", s.info)
	mux.HandleFunc("POST /api/auth", s.admin(func(w http.ResponseWriter, r *http.Request) { writeJSON(w, 200, map[string]bool{"ok": true}) }))

	mux.HandleFunc("GET /api/channels", s.listChannels)
	mux.HandleFunc("GET /api/channels/{id}", s.getChannel)
	mux.HandleFunc("POST /api/channels", s.admin(s.addChannel))
	mux.HandleFunc("PATCH /api/channels/{id}", s.admin(s.patchChannel))
	mux.HandleFunc("DELETE /api/channels/{id}", s.admin(s.deleteChannel))

	mux.HandleFunc("GET /api/live", s.live)
	mux.HandleFunc("GET /api/vods", s.listVods)
	mux.HandleFunc("GET /api/vods/{id}", s.getVod)
	mux.HandleFunc("DELETE /api/vods/{id}", s.admin(s.deleteVod))
	mux.HandleFunc("POST /api/vods/{id}/retry", s.admin(s.retryVod))

	mux.HandleFunc("POST /api/recordings/{channel}/pause", s.admin(s.recordingControl("pause")))
	mux.HandleFunc("POST /api/recordings/{channel}/resume", s.admin(s.recordingControl("resume")))
	mux.HandleFunc("POST /api/recordings/{channel}/finish", s.admin(s.recordingControl("finish")))

	mux.HandleFunc("GET /live/{id}/index.m3u8", s.livePlaylist)
	mux.HandleFunc("GET /live/{id}/{file}", s.liveAsset)
	mux.HandleFunc("GET /live/{id}/chat/{file}", s.liveChat)
	mux.HandleFunc("GET /live/{id}/{part}/{seg}", s.liveSegment)

	mux.HandleFunc("GET /img", s.imageProxy)

	mux.Handle("GET /media/", http.StripPrefix("/media/", fileHandler(s.cfg.ArchiveDir, true)))
	mux.Handle("GET /avatars/", http.StripPrefix("/avatars/", fileHandler(filepath.Join(s.cfg.DataDir, "avatars"), false)))
	mux.Handle("GET /", s.spa())
	return s.middleware(mux)
}

func (s *Server) middleware(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		h := w.Header()
		h.Set("Access-Control-Allow-Origin", "*")
		h.Set("Access-Control-Allow-Headers", "Authorization, Content-Type, Range")
		h.Set("Access-Control-Allow-Methods", "GET, POST, PATCH, DELETE, OPTIONS")
		h.Set("Access-Control-Expose-Headers", "Content-Length, Content-Range, Accept-Ranges")
		h.Set("X-Content-Type-Options", "nosniff")
		if r.Method == http.MethodOptions {
			w.WriteHeader(http.StatusNoContent)
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

// ---------- views ----------

type channelView struct {
	store.Channel
	Avatar string `json:"avatar"`
	Banner string `json:"banner"`
	Live   bool   `json:"live"`
}

type vodView struct {
	store.Vod
	Channel    *channelView    `json:"channel,omitempty"`
	Video      string          `json:"video,omitempty"`
	Thumbnail  string          `json:"thumbnail,omitempty"`
	Base       string          `json:"base,omitempty"` // prefix for chat/, storyboard/, badges.json, emotes.json
	Chapters   []store.Chapter `json:"chapters,omitempty"`
	Processing string          `json:"processing,omitempty"`
	Live       bool            `json:"live,omitempty"` // served as HLS from local disk (recording / not yet finalized)
	Paused     bool            `json:"paused,omitempty"`
}

func (s *Server) channelView(c store.Channel, live map[string]bool) channelView {
	v := channelView{Channel: c, Live: live[c.ID]}
	if c.AvatarFile != "" {
		v.Avatar = "/avatars/" + c.AvatarFile
	} else {
		v.Avatar = c.AvatarURL
	}
	if c.BannerFile != "" {
		v.Banner = "/avatars/" + c.BannerFile
	} else {
		v.Banner = c.BannerURL
	}
	return v
}

func (s *Server) liveSet() (map[string]bool, map[string]recorder.Live) {
	set := map[string]bool{}
	byVod := map[string]recorder.Live{}
	for _, l := range s.rec.Live() {
		set[l.ChannelID] = true
		byVod[l.VodID] = l
	}
	return set, byVod
}

func (s *Server) vodView(v store.Vod, ch *channelView, byVod map[string]recorder.Live, active map[string]string) vodView {
	vv := vodView{Vod: v, Channel: ch}
	if v.Status == store.StatusReady && v.Dir != "" {
		vv.Base = "/media/" + escapePath(v.Dir) + "/"
		vv.Video = vv.Base + "video.mp4"
		vv.Thumbnail = vv.Base + "thumb.jpg"
	} else if l, ok := byVod[v.ID]; ok {
		vv.Thumbnail = l.Thumbnail
		vv.DurationMs = time.Since(time.UnixMilli(l.StartedAt)).Milliseconds()
		vv.ChatCount = int(l.ChatCount)
	}
	vv.Processing = active[v.ID]
	return vv
}

// ---------- handlers ----------

func (s *Server) info(w http.ResponseWriter, r *http.Request) {
	stats, err := s.st.Stats(r.Context())
	if err != nil {
		writeErr(w, 500, err)
		return
	}
	lf, lt := util.FreeBytes(s.cfg.RecordingsDir)
	af, at := util.FreeBytes(s.cfg.ArchiveDir)
	writeJSON(w, 200, map[string]any{
		"appName":       s.cfg.AppName,
		"version":       s.version,
		"adminRequired": s.cfg.AdminToken != "",
		"maxConcurrent": s.cfg.MaxConcurrent,
		"recording":     len(s.rec.Live()),
		"adFree":        s.rec.AdFree(),
		"processing":    s.fin.Active(),
		"stats":         stats,
		"disk": map[string]uint64{
			"localFree": lf, "localTotal": lt, "archiveFree": af, "archiveTotal": at,
		},
	})
}

func (s *Server) listChannels(w http.ResponseWriter, r *http.Request) {
	chs, err := s.st.Channels(r.Context())
	if err != nil {
		writeErr(w, 500, err)
		return
	}
	live, _ := s.liveSet()
	out := make([]channelView, 0, len(chs))
	for _, c := range chs {
		out = append(out, s.channelView(c, live))
	}
	writeJSON(w, 200, out)
}

func (s *Server) getChannel(w http.ResponseWriter, r *http.Request) {
	c, err := s.st.Channel(r.Context(), r.PathValue("id"))
	if err != nil {
		writeErr(w, statusFor(err), err)
		return
	}
	live, _ := s.liveSet()
	writeJSON(w, 200, s.channelView(c, live))
}

func (s *Server) addChannel(w http.ResponseWriter, r *http.Request) {
	var body struct {
		Login string `json:"login"`
	}
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 4096)).Decode(&body); err != nil {
		writeErr(w, 400, err)
		return
	}
	ctx, cancel := context.WithTimeout(r.Context(), 30*time.Second)
	defer cancel()
	c, err := s.rec.AddChannel(ctx, body.Login)
	if err != nil {
		writeErr(w, 400, err)
		return
	}
	writeJSON(w, 201, s.channelView(c, nil))
}

func (s *Server) patchChannel(w http.ResponseWriter, r *http.Request) {
	var body struct {
		Enabled *bool `json:"enabled"`
	}
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 4096)).Decode(&body); err != nil {
		writeErr(w, 400, err)
		return
	}
	if body.Enabled != nil {
		if err := s.st.SetChannelEnabled(r.Context(), r.PathValue("id"), *body.Enabled); err != nil {
			writeErr(w, statusFor(err), err)
			return
		}
		s.rec.Wake()
	}
	s.getChannel(w, r)
}

// deleteChannel removes a channel. With ?purge=1 all of its VODs (files on
// the Storage Box included) are deleted as well.
func (s *Server) deleteChannel(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	if r.URL.Query().Get("purge") == "1" {
		for _, l := range s.rec.Live() {
			if l.ChannelID == id {
				writeErr(w, http.StatusConflict, errors.New("channel is recording right now - pause it and wait until the recording is finished"))
				return
			}
		}
		for {
			vods, _, err := s.st.Vods(r.Context(), store.VodFilter{ChannelID: id, Limit: 200})
			if err != nil {
				writeErr(w, 500, err)
				return
			}
			if len(vods) == 0 {
				break
			}
			for _, v := range vods {
				if err := s.removeVod(r.Context(), v); err != nil {
					writeErr(w, 500, err)
					return
				}
			}
		}
	}
	if err := s.st.DeleteChannel(r.Context(), id); err != nil {
		code := statusFor(err)
		if code == 500 {
			code = http.StatusConflict
		}
		writeErr(w, code, err)
		return
	}
	s.rec.Wake()
	w.WriteHeader(http.StatusNoContent)
}

func (s *Server) live(w http.ResponseWriter, r *http.Request) {
	live := s.rec.Live()
	chs, _ := s.st.Channels(r.Context())
	set, _ := s.liveSet()
	byID := map[string]channelView{}
	for _, c := range chs {
		byID[c.ID] = s.channelView(c, set)
	}
	type liveView struct {
		recorder.Live
		Channel channelView `json:"channel"`
	}
	out := make([]liveView, 0, len(live))
	for _, l := range live {
		out = append(out, liveView{Live: l, Channel: byID[l.ChannelID]})
	}
	writeJSON(w, 200, out)
}

func (s *Server) listVods(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query()
	f := store.VodFilter{Query: q.Get("q")}
	f.Limit, _ = strconv.Atoi(q.Get("limit"))
	f.Offset, _ = strconv.Atoi(q.Get("offset"))
	if ids := q.Get("ids"); ids != "" {
		f.IDs = strings.Split(ids, ",")
		if len(f.IDs) > 100 {
			f.IDs = f.IDs[:100]
		}
	}
	if c := q.Get("channel"); c != "" {
		ch, err := s.st.Channel(r.Context(), c)
		if err != nil {
			writeErr(w, statusFor(err), err)
			return
		}
		f.ChannelID = ch.ID
	}
	switch q.Get("status") {
	case "all":
	case "":
		f.Statuses = []string{store.StatusReady}
	default:
		f.Statuses = strings.Split(q.Get("status"), ",")
	}
	vods, total, err := s.st.Vods(r.Context(), f)
	if err != nil {
		writeErr(w, 500, err)
		return
	}
	chs, _ := s.st.Channels(r.Context())
	live, byVod := s.liveSet()
	byID := map[string]*channelView{}
	for _, c := range chs {
		cv := s.channelView(c, live)
		byID[c.ID] = &cv
	}
	active := s.fin.Active()
	items := make([]vodView, 0, len(vods))
	for _, v := range vods {
		vv := s.vodView(v, byID[v.ChannelID], byVod, active)
		if v.Status != store.StatusReady {
			s.applyLive(r.Context(), &vv)
		}
		items = append(items, vv)
	}
	writeJSON(w, 200, map[string]any{"items": items, "total": total})
}

func (s *Server) getVod(w http.ResponseWriter, r *http.Request) {
	v, err := s.st.Vod(r.Context(), r.PathValue("id"))
	if err != nil {
		writeErr(w, statusFor(err), err)
		return
	}
	live, byVod := s.liveSet()
	var chv *channelView
	if c, err := s.st.Channel(r.Context(), v.ChannelID); err == nil {
		cv := s.channelView(c, live)
		chv = &cv
	}
	vv := s.vodView(v, chv, byVod, s.fin.Active())
	vv.Chapters, _ = s.st.Chapters(r.Context(), v.ID)
	if v.Status != store.StatusReady {
		s.applyLive(r.Context(), &vv)
	}
	writeJSON(w, 200, vv)
}

func (s *Server) deleteVod(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	v, err := s.st.Vod(r.Context(), id)
	if err != nil {
		writeErr(w, statusFor(err), err)
		return
	}
	if s.rec.IsRecording(id) {
		writeErr(w, http.StatusConflict, errors.New("vod is still recording"))
		return
	}
	if _, busy := s.fin.Active()[id]; busy {
		writeErr(w, http.StatusConflict, errors.New("vod is being processed"))
		return
	}
	if err := s.removeVod(r.Context(), v); err != nil {
		writeErr(w, statusFor(err), err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func (s *Server) removeVod(ctx context.Context, v store.Vod) error {
	if v.Dir != "" {
		if err := os.RemoveAll(filepath.Join(s.cfg.ArchiveDir, filepath.FromSlash(v.Dir))); err != nil {
			return err
		}
	}
	_ = os.RemoveAll(filepath.Join(s.cfg.RecordingsDir, v.ID))
	if err := s.st.DeleteVod(ctx, v.ID); err != nil {
		return err
	}
	s.log.Info("vod deleted", "vod", v.ID, "title", v.Title)
	return nil
}

func (s *Server) retryVod(w http.ResponseWriter, r *http.Request) {
	v, err := s.st.Vod(r.Context(), r.PathValue("id"))
	if err != nil {
		writeErr(w, statusFor(err), err)
		return
	}
	if v.Status != store.StatusFailed {
		writeErr(w, http.StatusConflict, errors.New("only failed vods can be retried"))
		return
	}
	_ = s.st.SetVodStatus(r.Context(), v.ID, store.StatusProcessing, "")
	s.fin.Enqueue(v.ID)
	w.WriteHeader(http.StatusAccepted)
}

// ---------- static files ----------

// fileHandler serves files (with Range support) from root. Hidden paths and
// directory listings are refused. Pre-compressed chat chunks (*.json.gz) are
// served with Content-Encoding so clients decompress transparently.
func fileHandler(root string, immutable bool) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		rel := path.Clean("/" + r.URL.Path)
		for _, seg := range strings.Split(rel, "/") {
			if strings.HasPrefix(seg, ".") {
				http.NotFound(w, r)
				return
			}
		}
		p := filepath.Join(root, filepath.FromSlash(rel))
		f, err := os.Open(p)
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
		rel := path.Clean("/" + r.URL.Path)
		if strings.HasPrefix(rel, "/api/") {
			http.NotFound(w, r)
			return
		}
		p := filepath.Join(s.cfg.WebDir, filepath.FromSlash(rel))
		if fi, err := os.Stat(p); err != nil || fi.IsDir() {
			p = filepath.Join(s.cfg.WebDir, "index.html")
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

// ---------- helpers ----------

func escapePath(p string) string {
	segs := strings.Split(p, "/")
	for i, s := range segs {
		segs[i] = url.PathEscape(s)
	}
	return strings.Join(segs, "/")
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
