package api

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	"github.com/derseb90/twitch-vod-archiver/server/internal/recorder"
	"github.com/derseb90/twitch-vod-archiver/server/internal/store"
)

type vodView struct {
	store.Vod
	Channel    *channelView    `json:"channel,omitempty"`
	Video      string          `json:"video,omitempty"`
	Thumbnail  string          `json:"thumbnail,omitempty"`
	Base       string          `json:"base,omitempty"` // prefix for chat/, storyboard/, badges.json, emotes.json
	Chapters   []store.Chapter `json:"chapters,omitempty"`
	Processing string          `json:"processing,omitempty"`
}

func (s *Server) vodView(v store.Vod, ch *channelView, byVod map[string]recorder.Recording, active map[string]string) vodView {
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
	f.Unwatched = q.Get("unwatched") == "1"
	f.InProgress = q.Get("inProgress") == "1"
	switch q.Get("status") {
	case "all":
	case "":
		f.Statuses = []string{store.StatusReady}
	default:
		f.Statuses = strings.Split(q.Get("status"), ",")
	}
	vods, total, err := s.st.Vods(r.Context(), f)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, err)
		return
	}
	chs, _ := s.st.Channels(r.Context())
	live, byVod := s.recordingSet()
	byID := map[string]*channelView{}
	for _, c := range chs {
		cv := s.channelView(c, live)
		byID[c.ID] = &cv
	}
	active := s.fin.Active()
	items := make([]vodView, 0, len(vods))
	for _, v := range vods {
		items = append(items, s.vodView(v, byID[v.ChannelID], byVod, active))
	}
	writeJSON(w, http.StatusOK, map[string]any{"items": items, "total": total})
}

func (s *Server) getVod(w http.ResponseWriter, r *http.Request) {
	v, err := s.st.Vod(r.Context(), r.PathValue("id"))
	if err != nil {
		writeErr(w, statusFor(err), err)
		return
	}
	live, byVod := s.recordingSet()
	var chv *channelView
	if c, err := s.st.Channel(r.Context(), v.ChannelID); err == nil {
		cv := s.channelView(c, live)
		chv = &cv
	}
	vv := s.vodView(v, chv, byVod, s.fin.Active())
	vv.Chapters, _ = s.st.Chapters(r.Context(), v.ID)
	writeJSON(w, http.StatusOK, vv)
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
	if err := s.stopProcessing(id); err != nil {
		writeErr(w, http.StatusConflict, err)
		return
	}
	if err := s.removeVod(r.Context(), v); err != nil {
		writeErr(w, statusFor(err), err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

// stopProcessing cancels the post-processing of a VOD that is about to be
// deleted (e.g. restarted after an update), so it can't write the VOD back
// into the archive afterwards.
func (s *Server) stopProcessing(id string) error {
	s.fin.Cancel(id, time.Minute)
	if _, busy := s.fin.Active()[id]; busy {
		return errors.New("processing could not be stopped, try again")
	}
	return nil
}

func (s *Server) removeVod(ctx context.Context, v store.Vod) error {
	if v.Dir != "" {
		if err := os.RemoveAll(filepath.Join(s.cfg.ArchiveDir, filepath.FromSlash(v.Dir))); err != nil {
			return err
		}
	}
	_ = os.RemoveAll(filepath.Join(s.cfg.RecordingsDir, v.ID))
	_ = os.RemoveAll(filepath.Join(s.cfg.ArchiveDir, ".incoming", v.ID))
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

func (s *Server) putProgress(w http.ResponseWriter, r *http.Request) {
	var body struct {
		PositionMs int64 `json:"positionMs"`
		Watched    bool  `json:"watched"`
	}
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 1024)).Decode(&body); err != nil {
		writeErr(w, http.StatusBadRequest, err)
		return
	}
	if err := s.st.SetProgress(r.Context(), r.PathValue("id"), body.PositionMs, body.Watched); err != nil {
		writeErr(w, statusFor(err), err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

// progressSince lists progress written since ?since= (server ms), so apps
// can update what they show without reloading.
func (s *Server) progressSince(w http.ResponseWriter, r *http.Request) {
	since, _ := strconv.ParseInt(r.URL.Query().Get("since"), 10, 64)
	p, err := s.st.ProgressSince(r.Context(), since)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, err)
		return
	}
	writeJSON(w, http.StatusOK, p)
}

// changes is a long poll: it answers once something changed after ?since=
// (the seq of the previous answer) or after 25 s.
func (s *Server) changes(w http.ResponseWriter, r *http.Request) {
	since, _ := strconv.ParseInt(r.URL.Query().Get("since"), 10, 64)
	writeJSON(w, http.StatusOK, s.st.Changes.Wait(r.Context(), since, 25*time.Second))
}

func (s *Server) deleteProgress(w http.ResponseWriter, r *http.Request) {
	if err := s.st.ClearProgress(r.Context(), r.PathValue("id")); err != nil {
		writeErr(w, statusFor(err), err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}
