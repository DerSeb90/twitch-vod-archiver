package api

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"os"
	"path/filepath"
	"time"

	"github.com/derseb90/twitch-vod-archiver/server/internal/recorder"
	"github.com/derseb90/twitch-vod-archiver/server/internal/store"
	"github.com/derseb90/twitch-vod-archiver/server/internal/util"
)

type channelView struct {
	store.Channel
	Avatar string `json:"avatar"`
	Banner string `json:"banner"`
	Live   bool   `json:"live"` // being recorded right now
	// running / not yet finalized recordings on the local disk (channel list only)
	LocalBytes int64 `json:"localBytes,omitempty"`
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

// recordingSet returns the channels being recorded and the running
// recordings by VOD id.
func (s *Server) recordingSet() (map[string]bool, map[string]recorder.Recording) {
	set := map[string]bool{}
	byVod := map[string]recorder.Recording{}
	for _, l := range s.rec.Recordings() {
		set[l.ChannelID] = true
		byVod[l.VodID] = l
	}
	return set, byVod
}

func (s *Server) listChannels(w http.ResponseWriter, r *http.Request) {
	chs, err := s.st.Channels(r.Context())
	if err != nil {
		writeErr(w, http.StatusInternalServerError, err)
		return
	}
	live, _ := s.recordingSet()
	// local recording folders are named after their VOD
	local := map[string]int64{}
	if entries, err := os.ReadDir(s.cfg.RecordingsDir); err == nil {
		for _, e := range entries {
			if v, err := s.st.Vod(r.Context(), e.Name()); err == nil && e.IsDir() {
				local[v.ChannelID] += util.DirSize(filepath.Join(s.cfg.RecordingsDir, e.Name()))
			}
		}
	}
	out := make([]channelView, 0, len(chs))
	for _, c := range chs {
		cv := s.channelView(c, live)
		cv.LocalBytes = local[c.ID]
		out = append(out, cv)
	}
	writeJSON(w, http.StatusOK, out)
}

func (s *Server) getChannel(w http.ResponseWriter, r *http.Request) {
	c, err := s.st.Channel(r.Context(), r.PathValue("id"))
	if err != nil {
		writeErr(w, statusFor(err), err)
		return
	}
	live, _ := s.recordingSet()
	writeJSON(w, http.StatusOK, s.channelView(c, live))
}

func (s *Server) addChannel(w http.ResponseWriter, r *http.Request) {
	var body struct {
		Login string `json:"login"`
	}
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 4096)).Decode(&body); err != nil {
		writeErr(w, http.StatusBadRequest, err)
		return
	}
	ctx, cancel := context.WithTimeout(r.Context(), 30*time.Second)
	defer cancel()
	c, err := s.rec.AddChannel(ctx, body.Login)
	if err != nil {
		writeErr(w, http.StatusBadRequest, err)
		return
	}
	writeJSON(w, http.StatusCreated, s.channelView(c, nil))
}

func (s *Server) patchChannel(w http.ResponseWriter, r *http.Request) {
	var body struct {
		Enabled *bool `json:"enabled"`
	}
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 4096)).Decode(&body); err != nil {
		writeErr(w, http.StatusBadRequest, err)
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
		for _, l := range s.rec.Recordings() {
			if l.ChannelID == id {
				writeErr(w, http.StatusConflict, errors.New("channel is recording right now - pause it and wait until the recording is finished"))
				return
			}
		}
		for {
			vods, _, err := s.st.Vods(r.Context(), store.VodFilter{ChannelID: id, Limit: 200})
			if err != nil {
				writeErr(w, http.StatusInternalServerError, err)
				return
			}
			if len(vods) == 0 {
				break
			}
			for _, v := range vods {
				if err := s.stopProcessing(v.ID); err != nil {
					writeErr(w, http.StatusConflict, err)
					return
				}
				if err := s.removeVod(r.Context(), v); err != nil {
					writeErr(w, http.StatusInternalServerError, err)
					return
				}
			}
		}
	}
	if err := s.st.DeleteChannel(r.Context(), id); err != nil {
		code := statusFor(err)
		if code == http.StatusInternalServerError {
			code = http.StatusConflict
		}
		writeErr(w, code, err)
		return
	}
	s.rec.Wake()
	w.WriteHeader(http.StatusNoContent)
}

// listRecordings lists the recordings running right now.
func (s *Server) listRecordings(w http.ResponseWriter, r *http.Request) {
	recs := s.rec.Recordings()
	chs, _ := s.st.Channels(r.Context())
	set, _ := s.recordingSet()
	byID := map[string]channelView{}
	for _, c := range chs {
		byID[c.ID] = s.channelView(c, set)
	}
	type recordingView struct {
		recorder.Recording
		Channel channelView `json:"channel"`
	}
	out := make([]recordingView, 0, len(recs))
	for _, l := range recs {
		out = append(out, recordingView{Recording: l, Channel: byID[l.ChannelID]})
	}
	writeJSON(w, http.StatusOK, out)
}

// recordingControl pauses, resumes or finishes the running recording of a
// channel.
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
			writeErr(w, http.StatusInternalServerError, err)
			return
		}
		w.WriteHeader(http.StatusNoContent)
	}
}
