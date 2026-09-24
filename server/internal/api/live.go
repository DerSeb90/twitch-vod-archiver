package api

import (
	"context"
	"encoding/json"
	"errors"
	"math"
	"net/http"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"sync"

	"github.com/derseb90/twitch-vod-archiver/server/internal/chat"
	"github.com/derseb90/twitch-vod-archiver/server/internal/hls"
	"github.com/derseb90/twitch-vod-archiver/server/internal/recorder"
	"github.com/derseb90/twitch-vod-archiver/server/internal/store"
)

// Live/DVR playback of recordings that are still on the local disk
// (recording, paused or waiting for post-processing):
//
//	GET /live/{id}/index.m3u8            combined EVENT playlist over all parts
//	GET /live/{id}/part-000/seg-00001.ts segments
//	GET /live/{id}/emotes.json|badges.json
//	GET /live/{id}/chat/0003.json.gz     chat chunk, computed from the growing log
const liveChatChunkMs = 60_000

var (
	rePart = regexp.MustCompile(`^part-\d{3}$`)
	reSeg  = regexp.MustCompile(`^seg-\d{5}\.ts$`)
	reNum  = regexp.MustCompile(`^(\d{1,5})\.json(\.gz)?$`)
)

type liveChats struct {
	mu   sync.Mutex
	logs map[string]*chat.Log
}

func (lc *liveChats) get(vodID string) *chat.Log {
	lc.mu.Lock()
	defer lc.mu.Unlock()
	if lc.logs == nil {
		lc.logs = map[string]*chat.Log{}
	}
	l := lc.logs[vodID]
	if l == nil {
		l = chat.NewLog()
		lc.logs[vodID] = l
	}
	return l
}

func (lc *liveChats) drop(vodID string) {
	lc.mu.Lock()
	delete(lc.logs, vodID)
	lc.mu.Unlock()
}

// liveVod returns the vod and its timeline if it is still served from local disk.
func (s *Server) liveVod(ctx context.Context, id string) (store.Vod, []hls.Part, bool) {
	v, err := s.st.Vod(ctx, id)
	if err != nil || (v.Status != store.StatusRecording && v.Status != store.StatusProcessing) {
		s.chats.drop(id)
		return v, nil, false
	}
	parts, err := s.st.Parts(ctx, id)
	if err != nil {
		return v, nil, false
	}
	tl := hls.Timeline(filepath.Join(s.cfg.RecordingsDir, v.ID), parts)
	return v, tl, len(tl) > 0
}

func (s *Server) livePlaylist(w http.ResponseWriter, r *http.Request) {
	v, tl, ok := s.liveVod(r.Context(), r.PathValue("id"))
	if !ok {
		http.NotFound(w, r)
		return
	}
	active, paused := s.rec.VodState(v.ID)
	ended := !active || paused // complete for now: players treat it as a normal VOD
	w.Header().Set("Content-Type", "application/vnd.apple.mpegurl")
	w.Header().Set("Cache-Control", "no-cache")
	_, _ = w.Write([]byte(hls.Combined(tl, ended)))
}

func (s *Server) liveSegment(w http.ResponseWriter, r *http.Request) {
	part, seg := r.PathValue("part"), r.PathValue("seg")
	if !rePart.MatchString(part) || !reSeg.MatchString(seg) {
		http.NotFound(w, r)
		return
	}
	if _, _, ok := s.liveVod(r.Context(), r.PathValue("id")); !ok {
		http.NotFound(w, r)
		return
	}
	p := filepath.Join(s.cfg.RecordingsDir, r.PathValue("id"), part, seg)
	f, err := os.Open(p)
	if err != nil {
		http.NotFound(w, r)
		return
	}
	defer f.Close()
	fi, _ := f.Stat()
	w.Header().Set("Content-Type", "video/mp2t")
	w.Header().Set("Cache-Control", "public, max-age=86400")
	http.ServeContent(w, r, "", fi.ModTime(), f)
}

func (s *Server) liveAsset(w http.ResponseWriter, r *http.Request) {
	name := r.PathValue("file")
	if name != "emotes.json" && name != "badges.json" {
		http.NotFound(w, r)
		return
	}
	id := r.PathValue("id")
	if _, _, ok := s.liveVod(r.Context(), id); !ok {
		http.NotFound(w, r)
		return
	}
	b, err := os.ReadFile(filepath.Join(s.cfg.RecordingsDir, id, name))
	if err != nil {
		b = []byte("{}") // assets are fetched asynchronously at recording start
	}
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Cache-Control", "no-cache")
	_, _ = w.Write(b)
}

func (s *Server) liveChat(w http.ResponseWriter, r *http.Request) {
	m := reNum.FindStringSubmatch(r.PathValue("file"))
	if m == nil {
		http.NotFound(w, r)
		return
	}
	idx, _ := strconv.Atoi(m[1])
	v, tl, ok := s.liveVod(r.Context(), r.PathValue("id"))
	if !ok {
		http.NotFound(w, r)
		return
	}
	log := s.chats.get(v.ID)
	if err := log.Refresh(filepath.Join(s.cfg.RecordingsDir, v.ID, "chat.ndjson")); err != nil {
		writeErr(w, 500, err)
		return
	}
	from := int64(idx) * liveChatChunkMs
	msgs := log.Replay(func(ts int64) (int64, bool) { return hls.Map(tl, ts, hls.MaxChatGap) }, from, from+liveChatChunkMs)
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Cache-Control", "no-cache")
	enc := json.NewEncoder(w)
	enc.SetEscapeHTML(false)
	_ = enc.Encode(msgs)
}

// applyLive fills playback fields for a vod that is still on local disk.
func (s *Server) applyLive(ctx context.Context, vv *vodView) {
	_, tl, ok := s.liveVod(ctx, vv.ID)
	if !ok {
		return
	}
	vv.Live = true
	vv.Base = "/live/" + vv.ID + "/"
	vv.Video = vv.Base + "index.m3u8"
	vv.DurationMs = hls.TotalMs(tl)
	vv.ChatChunkMs = liveChatChunkMs
	if vv.Chapters != nil {
		for i := range vv.Chapters {
			vv.Chapters[i].OffsetMs, _ = hls.Map(tl, vv.Chapters[i].At, math.MaxInt64)
			vv.Chapters[i].OffsetMs = min(vv.Chapters[i].OffsetMs, vv.DurationMs)
		}
	}
}

// ---------- admin controls ----------

func (s *Server) recordingControl(action string) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		id := r.PathValue("channel")
		var err error
		switch action {
		case "pause":
			err = s.rec.Pause(id)
		case "resume":
			err = s.rec.Resume(id)
		case "finish":
			err = s.rec.Finish(id)
		}
		if errors.Is(err, recorder.ErrNoSession) {
			writeErr(w, http.StatusNotFound, err)
			return
		}
		if err != nil {
			writeErr(w, 500, err)
			return
		}
		w.WriteHeader(http.StatusNoContent)
	}
}
