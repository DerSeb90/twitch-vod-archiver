// Package recorder watches channels via Helix and records live streams with
// streamlink (video) and an anonymous IRC connection (chat).
//
// A recording ("session") is keyed by channel. If the stream drops and comes
// back within OFFLINE_GRACE (same Twitch stream id), streamlink is simply
// restarted into a new part; the finalizer stitches parts together.
//
// Recordings can be paused manually (the part so far becomes watchable),
// resumed (appends a new part to the same VOD) or finished early.
package recorder

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"os"
	"path"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"github.com/derseb90/twitch-vod-archiver/server/internal/chat"
	"github.com/derseb90/twitch-vod-archiver/server/internal/config"
	"github.com/derseb90/twitch-vod-archiver/server/internal/store"
	"github.com/derseb90/twitch-vod-archiver/server/internal/twitch"
	"github.com/derseb90/twitch-vod-archiver/server/internal/util"
)

// Enqueuer receives VODs that are ready to be finalized.
type Enqueuer interface{ Enqueue(vodID string) }

type Manager struct {
	cfg *config.Config
	st  *store.Store
	tw  *twitch.Client
	fin Enqueuer
	log *slog.Logger

	mu       sync.Mutex
	sessions map[string]*session  // channel id -> active recording
	orphans  map[string]store.Vod // channel id -> vod left in "recording" by a previous run
	lastWarn map[string]time.Time // rate-limit for capacity warnings
	skip     map[string]string    // channel id -> stream id that was finished manually
	wake     chan struct{}
	wg       sync.WaitGroup

	adMu   sync.Mutex
	adFree AdFree
}

type session struct {
	channel store.Channel
	vod     store.Vod
	dir     string

	chatCancel context.CancelFunc
	chatDone   chan struct{}
	chat       *chat.Recorder

	nextPart  int
	proc      *process
	paused    bool // stopped manually, not restarted until resumed
	exitAt    time.Time
	failures  int
	lastLive  time.Time
	startedAt time.Time

	title, category, categoryID string
	viewers                     int
	thumbnail                   string
}

func New(cfg *config.Config, st *store.Store, tw *twitch.Client, fin Enqueuer, log *slog.Logger) *Manager {
	return &Manager{
		cfg: cfg, st: st, tw: tw, fin: fin, log: log.With("component", "recorder"),
		sessions: map[string]*session{},
		orphans:  map[string]store.Vod{},
		lastWarn: map[string]time.Time{},
		skip:     map[string]string{},
		wake:     make(chan struct{}, 1),
	}
}

func (m *Manager) Wake() {
	select {
	case m.wake <- struct{}{}:
	default:
	}
}

// Run blocks until ctx is done. On shutdown running recordings are stopped
// but left in status "recording" so the next start can resume them.
func (m *Manager) Run(ctx context.Context) error {
	if err := os.MkdirAll(m.cfg.RecordingsDir, 0o755); err != nil {
		return err
	}
	if err := m.recover(ctx); err != nil {
		return err
	}
	m.seedChannels(ctx)
	m.checkUserToken(ctx)

	refresh := time.NewTicker(12 * time.Hour)
	defer refresh.Stop()
	tokenTick := time.NewTicker(tokenCheckInterval)
	defer tokenTick.Stop()
	tick := time.NewTicker(m.cfg.PollInterval)
	defer tick.Stop()
	m.poll(ctx)
	for {
		select {
		case <-ctx.Done():
			m.shutdown()
			return nil
		case <-tick.C:
			m.poll(ctx)
		case <-m.wake:
			m.poll(ctx)
		case <-refresh.C:
			m.refreshChannels(ctx)
		case <-tokenTick.C:
			m.checkUserToken(ctx)
		}
	}
}

func (m *Manager) recover(ctx context.Context) error {
	vods, err := m.st.VodsByStatus(ctx, store.StatusRecording)
	if err != nil {
		return err
	}
	for _, v := range vods {
		m.orphans[v.ChannelID] = v
		m.log.Info("found unfinished recording", "vod", v.ID)
	}
	processing, err := m.st.VodsByStatus(ctx, store.StatusProcessing)
	if err != nil {
		return err
	}
	for _, v := range processing {
		m.fin.Enqueue(v.ID)
	}
	return nil
}

func (m *Manager) seedChannels(ctx context.Context) {
	for _, login := range m.cfg.SeedChannels {
		if _, err := m.st.Channel(ctx, login); err == nil {
			continue
		}
		if _, err := m.AddChannel(ctx, login); err != nil {
			m.log.Error("seed channel", "login", login, "err", err)
		}
	}
}

// AddChannel resolves a login via Helix, stores it and caches the avatar.
func (m *Manager) AddChannel(ctx context.Context, login string) (store.Channel, error) {
	login = strings.ToLower(strings.TrimSpace(strings.TrimPrefix(login, "@")))
	if i := strings.LastIndex(login, "twitch.tv/"); i >= 0 {
		login = strings.Trim(login[i+len("twitch.tv/"):], "/")
	}
	if login == "" {
		return store.Channel{}, errors.New("empty login")
	}
	users, err := m.tw.UsersByLogin(ctx, []string{login})
	if err != nil {
		return store.Channel{}, err
	}
	if len(users) == 0 {
		return store.Channel{}, fmt.Errorf("twitch user %q not found", login)
	}
	ch := m.channelFromUser(ctx, users[0])
	ch.Enabled = true
	if err := m.st.UpsertChannel(ctx, ch); err != nil {
		return store.Channel{}, err
	}
	m.log.Info("channel added", "login", ch.Login)
	m.Wake()
	return m.st.Channel(ctx, ch.ID)
}

// channelFromUser maps a Helix user and caches logo (highest available
// resolution) and offline banner locally, so they stay available and fast.
func (m *Manager) channelFromUser(ctx context.Context, u twitch.User) store.Channel {
	ch := store.Channel{ID: u.ID, Login: u.Login, DisplayName: u.DisplayName, Description: u.Description,
		AvatarURL: u.ProfileImageURL, BannerURL: u.OfflineImageURL}
	if u.ProfileImageURL != "" {
		// Twitch serves profile images in several sizes; try the 600px variant first.
		candidates := []string{u.ProfileImageURL}
		if hi := strings.Replace(u.ProfileImageURL, "300x300", "600x600", 1); hi != u.ProfileImageURL {
			candidates = append([]string{hi}, candidates...)
		}
		ch.AvatarFile = m.cacheImage(ctx, candidates, u.ID+"-avatar")
	}
	if u.OfflineImageURL != "" {
		ch.BannerFile = m.cacheImage(ctx, []string{u.OfflineImageURL}, u.ID+"-banner")
	}
	return ch
}

func (m *Manager) cacheImage(ctx context.Context, urls []string, base string) string {
	dir := filepath.Join(m.cfg.DataDir, "avatars")
	_ = os.MkdirAll(dir, 0o755)
	for _, u := range urls {
		b, err := m.tw.Download(ctx, u)
		if err != nil || len(b) == 0 {
			continue
		}
		ext := strings.ToLower(path.Ext(u))
		if ext == "" || len(ext) > 5 {
			ext = ".png"
		}
		name := base + ext
		if err := os.WriteFile(filepath.Join(dir, name), b, 0o644); err == nil {
			return name
		}
	}
	return ""
}

func (m *Manager) refreshChannels(ctx context.Context) {
	chs, err := m.st.Channels(ctx)
	if err != nil || len(chs) == 0 {
		return
	}
	ids := make([]string, 0, len(chs))
	enabled := map[string]bool{}
	for _, c := range chs {
		ids = append(ids, c.ID)
		enabled[c.ID] = c.Enabled
	}
	users, err := m.tw.UsersByID(ctx, ids)
	if err != nil {
		m.log.Warn("refresh channels", "err", err)
		return
	}
	for _, u := range users {
		ch := m.channelFromUser(ctx, u)
		ch.Enabled = enabled[u.ID]
		_ = m.st.UpsertChannel(ctx, ch)
	}
}

func (m *Manager) poll(ctx context.Context) {
	chs, err := m.st.Channels(ctx)
	if err != nil {
		m.log.Error("load channels", "err", err)
		return
	}
	var ids []string
	byID := map[string]store.Channel{}
	for _, c := range chs {
		byID[c.ID] = c
		if c.Enabled {
			ids = append(ids, c.ID)
		}
	}
	m.mu.Lock()
	for id := range m.orphans {
		if _, ok := byID[id]; ok && !contains(ids, id) {
			ids = append(ids, id) // still check disabled channels with an unfinished recording
		}
	}
	m.mu.Unlock()

	streams := map[string]twitch.Stream{}
	if len(ids) > 0 {
		pctx, cancel := context.WithTimeout(ctx, 20*time.Second)
		streams, err = m.tw.LiveStreams(pctx, ids)
		cancel()
		if err != nil {
			m.log.Warn("poll streams", "err", err)
			return
		}
	}

	m.mu.Lock()
	defer m.mu.Unlock()
	now := time.Now()

	// orphans from a previous run: resume if the same broadcast is still live, else finalize
	for chID, v := range m.orphans {
		s, live := streams[chID]
		delete(m.orphans, chID)
		if live && s.ID == v.StreamID && m.sessions[chID] == nil {
			if ch, ok := byID[chID]; ok {
				m.resumeSession(ctx, ch, v, s)
				continue
			}
		}
		m.endVod(ctx, v.ID, now)
	}

	for _, ch := range chs {
		s, live := streams[ch.ID]
		sess := m.sessions[ch.ID]
		if !live {
			if sess != nil && sess.proc == nil && (now.Sub(sess.lastLive) > m.cfg.OfflineGrace || m.skip[ch.ID] == sess.vod.StreamID) {
				m.endSession(ctx, sess)
			}
			if m.sessions[ch.ID] == nil {
				delete(m.skip, ch.ID)
			}
			continue
		}
		_ = m.st.TouchChannelLive(ctx, ch.ID)
		if sess != nil && sess.proc == nil && (sess.vod.StreamID != s.ID || m.skip[ch.ID] == sess.vod.StreamID) {
			// a new broadcast started before the grace period ended, or the
			// recording was finished manually: close it
			m.endSession(ctx, sess)
			sess = nil
		}
		if sess == nil {
			if !ch.Enabled || m.skip[ch.ID] == s.ID {
				continue
			}
			if len(m.sessions) >= m.cfg.MaxConcurrent {
				m.warnOnce(ch.ID, "max concurrent recordings reached, skipping", "channel", ch.Login, "max", m.cfg.MaxConcurrent)
				continue
			}
			if free, _ := util.FreeBytes(m.cfg.RecordingsDir); free > 0 && float64(free) < m.cfg.MinFreeGB*(1<<30) {
				m.warnOnce(ch.ID, "not enough free local disk, skipping", "channel", ch.Login, "freeGB", free>>30)
				continue
			}
			var err error
			sess, err = m.startSession(ctx, ch, s)
			if err != nil {
				m.log.Error("start recording", "channel", ch.Login, "err", err)
				continue
			}
		}
		sess.lastLive = now
		m.updateMeta(ctx, sess, s)
		if sess.proc == nil && !sess.paused && now.Sub(sess.exitAt) >= m.backoff(sess) {
			m.startPart(sess)
		}
	}

	// sessions whose channel vanished from the list (deleted)
	for chID, sess := range m.sessions {
		if _, ok := byID[chID]; !ok && sess.proc == nil {
			m.endSession(ctx, sess)
		}
	}
}

func (m *Manager) backoff(s *session) time.Duration {
	if s.exitAt.IsZero() {
		return 0
	}
	d := 5 * time.Second << min(s.failures, 5)
	return min(d, 2*time.Minute)
}

func (m *Manager) warnOnce(key, msg string, args ...any) {
	if time.Since(m.lastWarn[key]) < 10*time.Minute {
		return
	}
	m.lastWarn[key] = time.Now()
	m.log.Warn(msg, args...)
}

func (m *Manager) startSession(ctx context.Context, ch store.Channel, s twitch.Stream) (*session, error) {
	v := store.Vod{
		ID:         util.NewID(),
		ChannelID:  ch.ID,
		StreamID:   s.ID,
		Title:      s.Title,
		Category:   s.GameName,
		CategoryID: s.GameID,
		StartedAt:  time.Now().UnixMilli(),
		Status:     store.StatusRecording,
	}
	dir := filepath.Join(m.cfg.RecordingsDir, v.ID)
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return nil, err
	}
	if err := m.st.CreateVod(ctx, v); err != nil {
		return nil, err
	}
	_ = m.st.AddChapter(ctx, v.ID, store.Chapter{At: v.StartedAt, Title: s.Title, Category: s.GameName, CategoryID: s.GameID, BoxArt: m.tw.BoxArt(ctx, s.GameID)})
	sess := &session{channel: ch, vod: v, dir: dir, startedAt: time.Now(), title: s.Title, category: s.GameName, categoryID: s.GameID}
	m.sessions[ch.ID] = sess
	m.startChat(sess)
	m.fetchAssets(sess)
	m.log.Info("recording started", "channel", ch.Login, "vod", v.ID, "title", s.Title)
	return sess, nil
}

func (m *Manager) resumeSession(ctx context.Context, ch store.Channel, v store.Vod, s twitch.Stream) {
	parts, _ := m.st.Parts(ctx, v.ID)
	next := 0
	if len(parts) > 0 {
		next = parts[len(parts)-1].Idx + 1
	}
	dir := filepath.Join(m.cfg.RecordingsDir, v.ID)
	_ = os.MkdirAll(dir, 0o755)
	sess := &session{channel: ch, vod: v, dir: dir, nextPart: next, startedAt: time.UnixMilli(v.StartedAt),
		title: v.Title, category: v.Category, categoryID: v.CategoryID, lastLive: time.Now()}
	m.sessions[ch.ID] = sess
	m.startChat(sess)
	if _, err := os.Stat(filepath.Join(dir, "badges.json")); err != nil {
		m.fetchAssets(sess)
	}
	m.updateMeta(ctx, sess, s)
	m.startPart(sess)
	m.log.Info("recording resumed", "channel", ch.Login, "vod", v.ID, "part", next)
}

func (m *Manager) startChat(sess *session) {
	cctx, cancel := context.WithCancel(context.Background())
	sess.chatCancel = cancel
	sess.chatDone = make(chan struct{})
	sess.chat = chat.NewRecorder(sess.channel.Login, filepath.Join(sess.dir, "chat.ndjson"), m.log)
	m.wg.Add(1)
	go func() {
		defer m.wg.Done()
		defer close(sess.chatDone)
		sess.chat.Run(cctx)
	}()
}

// fetchAssets snapshots badges and third-party emotes at recording time, so the
// replay later shows exactly the emotes that existed during the stream.
func (m *Manager) fetchAssets(sess *session) {
	m.wg.Add(1)
	go func() {
		defer m.wg.Done()
		ctx, cancel := context.WithTimeout(context.Background(), time.Minute)
		defer cancel()
		if badges, err := m.tw.Badges(ctx, sess.channel.ID); err == nil {
			writeJSON(filepath.Join(sess.dir, "badges.json"), badges)
		} else {
			m.log.Warn("fetch badges", "err", err)
		}
		emotes := map[string]string{}
		if m.cfg.ThirdPartyEmotes {
			emotes = m.tw.ThirdPartyEmotes(ctx, sess.channel.ID)
		}
		writeJSON(filepath.Join(sess.dir, "emotes.json"), emotes)
	}()
}

func (m *Manager) updateMeta(ctx context.Context, sess *session, s twitch.Stream) {
	sess.viewers = s.ViewerCount
	sess.thumbnail = strings.NewReplacer("{width}", "1280", "{height}", "720").Replace(s.ThumbnailURL)
	if s.Title != sess.title || s.GameID != sess.categoryID {
		sess.title, sess.category, sess.categoryID = s.Title, s.GameName, s.GameID
		_ = m.st.AddChapter(ctx, sess.vod.ID, store.Chapter{At: time.Now().UnixMilli(), Title: s.Title, Category: s.GameName, CategoryID: s.GameID, BoxArt: m.tw.BoxArt(ctx, s.GameID)})
		m.log.Info("stream metadata changed", "channel", sess.channel.Login, "title", s.Title, "category", s.GameName)
	}
	_ = m.st.UpdateVodMeta(ctx, sess.vod.ID, s.Title, s.GameName, s.GameID, s.ViewerCount)
}

func (m *Manager) startPart(sess *session) {
	idx := sess.nextPart
	sess.nextPart++
	file := fmt.Sprintf("part-%03d", idx)
	part := store.Part{VodID: sess.vod.ID, Idx: idx, File: file, StartedAt: time.Now().UnixMilli()}
	if err := m.st.AddPart(context.Background(), part); err != nil {
		m.log.Error("add part", "err", err)
		return
	}
	onFirstData := func(t time.Time) {
		// precise part start as soon as data flows (chat sync while live)
		_ = m.st.UpdatePart(context.Background(), store.Part{VodID: part.VodID, Idx: part.Idx, StartedAt: t.UnixMilli()})
	}
	p, err := startRecording(m.cfg, m.userToken(), sess.channel.Login, filepath.Join(sess.dir, file), m.log.With("channel", sess.channel.Login, "part", idx), onFirstData)
	if err != nil {
		m.log.Error("start streamlink", "err", err)
		sess.exitAt = time.Now()
		sess.failures++
		return
	}
	sess.proc = p
	m.wg.Add(1)
	go func() {
		defer m.wg.Done()
		<-p.done
		ended := time.Now()
		m.mu.Lock()
		defer m.mu.Unlock()
		part.EndedAt = ended.UnixMilli()
		if !p.firstData.IsZero() {
			part.StartedAt = p.firstData.UnixMilli()
		}
		_ = m.st.UpdatePart(context.Background(), part)
		sess.proc = nil
		sess.exitAt = ended
		if p.firstData.IsZero() || ended.Sub(p.firstData) < time.Minute {
			sess.failures++
		} else {
			sess.failures = 0
		}
		if p.firstData.IsZero() {
			_ = os.RemoveAll(filepath.Join(sess.dir, file))
		}
		m.log.Info("recorder exited", "channel", sess.channel.Login, "part", idx, "err", p.err, "ranFor", ended.Sub(p.started).Round(time.Second))
		m.Wake()
		time.AfterFunc(m.backoff(sess)+time.Second, m.Wake)
	}()
}

func (m *Manager) endSession(ctx context.Context, sess *session) {
	delete(m.sessions, sess.channel.ID)
	sess.chatCancel()
	endedAt := sess.lastLive
	if sess.exitAt.After(endedAt) {
		endedAt = sess.exitAt
	}
	m.log.Info("recording finished", "channel", sess.channel.Login, "vod", sess.vod.ID, "duration", time.Since(sess.startedAt).Round(time.Second))
	done := sess.chatDone
	id := sess.vod.ID
	_ = m.st.SetVodEnded(ctx, id, endedAt.UnixMilli())
	_ = m.st.SetVodStatus(ctx, id, store.StatusProcessing, "")
	go func() {
		<-done // chat file must be flushed before the finalizer reads it
		m.fin.Enqueue(id)
	}()
}

func (m *Manager) endVod(ctx context.Context, id string, at time.Time) {
	_ = m.st.SetVodEnded(ctx, id, at.UnixMilli())
	_ = m.st.SetVodStatus(ctx, id, store.StatusProcessing, "")
	m.fin.Enqueue(id)
}

func (m *Manager) shutdown() {
	m.mu.Lock()
	for _, s := range m.sessions {
		if s.proc != nil {
			s.proc.stop()
		}
		s.chatCancel()
	}
	m.mu.Unlock()
	done := make(chan struct{})
	go func() { m.wg.Wait(); close(done) }()
	select {
	case <-done:
	case <-time.After(25 * time.Second):
		m.log.Warn("shutdown timed out waiting for recorders")
	}
}

// Live describes a currently running recording for the API.
type Live struct {
	VodID       string `json:"vodId"`
	ChannelID   string `json:"channelId"`
	Login       string `json:"login"`
	DisplayName string `json:"displayName"`
	Title       string `json:"title"`
	Category    string `json:"category"`
	StartedAt   int64  `json:"startedAt"`
	Viewers     int    `json:"viewers"`
	Thumbnail   string `json:"thumbnail"`
	ChatCount   int64  `json:"chatCount"`
	Recording   bool   `json:"recording"` // false while paused or waiting for a reconnect
	Paused      bool   `json:"paused"`
	Parts       int    `json:"parts"`
}

func (m *Manager) Live() []Live {
	m.mu.Lock()
	defer m.mu.Unlock()
	out := make([]Live, 0, len(m.sessions))
	for _, s := range m.sessions {
		out = append(out, Live{
			VodID: s.vod.ID, ChannelID: s.channel.ID, Login: s.channel.Login, DisplayName: s.channel.DisplayName,
			Title: s.title, Category: s.category, StartedAt: s.startedAt.UnixMilli(), Viewers: s.viewers,
			Thumbnail: s.thumbnail, ChatCount: s.chat.Count(), Recording: s.proc != nil, Paused: s.paused, Parts: s.nextPart,
		})
	}
	return out
}

// IsRecording reports whether a VOD belongs to an active session.
func (m *Manager) IsRecording(vodID string) bool {
	active, _ := m.VodState(vodID)
	return active
}

// VodState reports whether a VOD belongs to an active session and whether
// that session is paused (then its video is complete for now).
func (m *Manager) VodState(vodID string) (active, paused bool) {
	m.mu.Lock()
	defer m.mu.Unlock()
	for _, s := range m.sessions {
		if s.vod.ID == vodID {
			return true, s.paused
		}
	}
	return false, false
}

var ErrNoSession = errors.New("no active recording for this channel")

// Pause stops the running recording of a channel. The video recorded so far
// can be watched right away. While the channel stays live, Resume appends
// to the same VOD; if the channel goes offline, the VOD is finalized.
func (m *Manager) Pause(channelID string) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	s := m.sessions[channelID]
	if s == nil {
		return ErrNoSession
	}
	s.paused = true
	if s.proc != nil {
		s.proc.stop()
	}
	m.log.Info("recording paused", "channel", s.channel.Login, "vod", s.vod.ID)
	return nil
}

func (m *Manager) Resume(channelID string) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	s := m.sessions[channelID]
	if s == nil {
		return ErrNoSession
	}
	s.paused = false
	s.failures = 0
	s.exitAt = time.Time{}
	m.log.Info("recording resumed by user", "channel", s.channel.Login, "vod", s.vod.ID)
	m.Wake()
	return nil
}

// Finish ends a recording now; the rest of this broadcast is not recorded.
func (m *Manager) Finish(channelID string) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	s := m.sessions[channelID]
	if s == nil {
		return ErrNoSession
	}
	m.skip[channelID] = s.vod.StreamID
	s.paused = true
	if s.proc != nil {
		s.proc.stop()
	} else {
		m.endSession(context.Background(), s)
	}
	m.log.Info("recording finished by user", "channel", s.channel.Login, "vod", s.vod.ID)
	return nil
}

func writeJSON(p string, v any) {
	b, err := json.Marshal(v)
	if err == nil {
		_ = os.WriteFile(p, b, 0o644)
	}
}

func contains(s []string, v string) bool {
	for _, x := range s {
		if x == v {
			return true
		}
	}
	return false
}
