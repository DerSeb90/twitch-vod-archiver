// Package finalize turns a finished recording (local HLS parts + raw chat)
// into an archived VOD on the Storage Box:
//
//	<ARCHIVE_DIR>/<login>/<yyyy-mm-dd>_<vodid>/
//	  video.mp4            remuxed, no re-encode
//	  thumb.jpg            poster frame
//	  storyboard/NNN.jpg   seek preview sprite sheets
//	  chat/NNNN.json.gz    chat replay, one file per CHAT_CHUNK
//	  chat/activity.json   messages per bucket (chat heat map)
//	  badges.json, emotes.json, info.json
//
// Heavy reads (storyboard, thumbnail) happen on the local disk; only the
// final MP4 is written once, directly to the share.
package finalize

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"sync"
	"time"

	"github.com/derseb90/twitch-vod-archiver/server/internal/config"
	"github.com/derseb90/twitch-vod-archiver/server/internal/hls"
	"github.com/derseb90/twitch-vod-archiver/server/internal/store"
	"github.com/derseb90/twitch-vod-archiver/server/internal/util"
)

type Finalizer struct {
	cfg *config.Config
	st  *store.Store
	log *slog.Logger

	mu      sync.Mutex
	queue   []string
	wake    chan struct{}
	pending map[string]bool   // queued or running
	active  map[string]string // vod id -> current step
	cancels map[string]context.CancelFunc
}

func New(cfg *config.Config, st *store.Store, log *slog.Logger) *Finalizer {
	return &Finalizer{cfg: cfg, st: st, log: log.With("component", "finalize"),
		wake: make(chan struct{}, 1), pending: map[string]bool{}, active: map[string]string{},
		cancels: map[string]context.CancelFunc{}}
}

// Enqueue queues a VOD for processing. It never blocks, callers may hold
// their own locks.
func (f *Finalizer) Enqueue(id string) {
	f.mu.Lock()
	defer f.mu.Unlock()
	if f.pending[id] {
		return
	}
	f.pending[id] = true
	f.queue = append(f.queue, id)
	f.signal()
}

// signal wakes a waiting worker; f.mu must be held.
func (f *Finalizer) signal() {
	select {
	case f.wake <- struct{}{}:
	default:
	}
}

// next takes the oldest queued VOD and registers it as running.
func (f *Finalizer) next(ctx context.Context) (string, context.Context, bool) {
	f.mu.Lock()
	defer f.mu.Unlock()
	if len(f.queue) == 0 {
		return "", nil, false
	}
	id := f.queue[0]
	f.queue = f.queue[1:]
	if len(f.queue) > 0 {
		f.signal() // more work for another worker
	}
	job, cancel := context.WithCancel(ctx)
	f.cancels[id] = cancel
	return id, job, true
}

// Cancel stops the processing of a VOD (running or queued) and waits up to
// timeout until it has let go of its files. The VOD is marked failed, so it
// can be retried if it is not deleted afterwards.
func (f *Finalizer) Cancel(id string, timeout time.Duration) {
	f.mu.Lock()
	if i := slices.Index(f.queue, id); i >= 0 {
		f.queue = slices.Delete(f.queue, i, i+1)
		delete(f.pending, id)
		f.mu.Unlock()
		_ = f.st.SetVodStatus(context.Background(), id, store.StatusFailed, "cancelled")
		return
	}
	if c := f.cancels[id]; c != nil {
		c()
	}
	f.mu.Unlock()
	for deadline := time.Now().Add(timeout); time.Now().Before(deadline); time.Sleep(200 * time.Millisecond) {
		if _, busy := f.Active()[id]; !busy {
			return
		}
	}
}

// cleanup removes what an interrupted run left behind: staging copies on the
// archive (.incoming/<vod>) of VODs that are no longer being processed, and
// local recording folders of VODs that no longer exist. Folders not named
// like a VOD are never touched.
func (f *Finalizer) cleanup(ctx context.Context) {
	var freed int64
	remove := func(dir string) {
		freed += util.DirSize(dir)
		_ = os.RemoveAll(dir)
		f.log.Info("removed leftover", "dir", dir)
	}
	incoming := filepath.Join(f.cfg.ArchiveDir, ".incoming")
	if entries, err := os.ReadDir(incoming); err == nil {
		for _, e := range entries {
			if v, err := f.st.Vod(ctx, e.Name()); err != nil || v.Status != store.StatusProcessing {
				remove(filepath.Join(incoming, e.Name()))
			}
		}
	}
	if entries, err := os.ReadDir(f.cfg.RecordingsDir); err == nil {
		for _, e := range entries {
			if !e.IsDir() || !util.IsID(e.Name()) {
				continue
			}
			if _, err := f.st.Vod(ctx, e.Name()); errors.Is(err, store.ErrNotFound) {
				remove(filepath.Join(f.cfg.RecordingsDir, e.Name()))
			}
		}
	}
	if freed > 0 {
		f.log.Info("cleanup done", "freedMB", freed>>20)
	}
}

// Active returns vod id -> current processing step.
func (f *Finalizer) Active() map[string]string {
	f.mu.Lock()
	defer f.mu.Unlock()
	out := make(map[string]string, len(f.active))
	for k, v := range f.active {
		out[k] = v
	}
	return out
}

func (f *Finalizer) step(id, s string) {
	f.mu.Lock()
	f.active[id] = s
	f.mu.Unlock()
	f.log.Info("finalize", "vod", id, "step", s)
}

func (f *Finalizer) Run(ctx context.Context) {
	f.cleanup(ctx)
	var wg sync.WaitGroup
	for i := 0; i < f.cfg.FinalizeWorkers; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for ctx.Err() == nil {
				id, job, ok := f.next(ctx)
				if !ok {
					select {
					case <-ctx.Done():
					case <-f.wake:
					}
					continue
				}
				start := time.Now()
				err := f.process(job, id)
				cancelled := job.Err() != nil // before releasing the job context below
				f.mu.Lock()
				f.cancels[id]()
				delete(f.pending, id)
				delete(f.active, id)
				delete(f.cancels, id)
				f.mu.Unlock()
				if ctx.Err() != nil {
					return // shutting down: vod stays "processing" and is retried on next start
				}
				switch {
				case cancelled:
					f.log.Info("finalize cancelled", "vod", id) // usually deleted by the user
					_ = f.st.SetVodStatus(context.Background(), id, store.StatusFailed, "cancelled")
				case err != nil:
					f.log.Error("finalize failed", "vod", id, "err", err)
					_ = f.st.SetVodStatus(context.Background(), id, store.StatusFailed, err.Error())
				default:
					f.log.Info("finalize done", "vod", id, "took", time.Since(start).Round(time.Second))
				}
			}
		}()
	}
	wg.Wait()
}

// task is one VOD being processed; the steps of process fill it in.
type task struct {
	vod      store.Vod
	ch       store.Channel
	work     string // local recording folder
	out      string // artifacts built locally, copied next to the video at the end
	concat   string // ffmpeg concat list over all segments
	parts    []hls.Part
	totalMs  int64
	codec    string // of the recorded video
	chapters []store.Chapter
}

func (f *Finalizer) process(ctx context.Context, id string) error {
	t, err := f.load(ctx, id)
	if err != nil || t == nil {
		return err // no task: nothing usable was recorded, the VOD is gone
	}
	if err := f.prepare(ctx, t); err != nil {
		return err
	}
	// stage on the share, then atomically move into place
	staging := filepath.Join(f.cfg.ArchiveDir, ".incoming", t.vod.ID)
	_ = os.RemoveAll(staging)
	if err := os.MkdirAll(staging, 0o755); err != nil {
		return fmt.Errorf("archive not writable: %w", err)
	}
	if err := f.archiveVideo(ctx, t, staging); err != nil {
		return err
	}
	return f.publish(ctx, t, staging)
}

// load reads the VOD and its recorded parts. A recording without any usable
// video is discarded (nil task).
func (f *Finalizer) load(ctx context.Context, id string) (*task, error) {
	vod, err := f.st.Vod(ctx, id)
	if err != nil {
		return nil, err
	}
	ch, err := f.st.Channel(ctx, vod.ChannelID)
	if err != nil {
		return nil, err
	}
	t := &task{vod: vod, ch: ch, work: filepath.Join(f.cfg.RecordingsDir, vod.ID)}

	f.step(id, "probe")
	dbParts, err := f.st.Parts(ctx, id)
	if err != nil {
		return nil, err
	}
	if t.parts, err = hls.Timeline(t.work, dbParts); err != nil {
		return nil, fmt.Errorf("read recording: %w", err)
	}
	if len(t.parts) == 0 {
		f.log.Warn("no usable video, discarding recording", "vod", id)
		_ = os.RemoveAll(t.work)
		return nil, f.st.DeleteVod(ctx, id)
	}
	t.totalMs = hls.TotalMs(t.parts)
	return t, nil
}

// prepare builds the small artifacts on the local disk first: concat list,
// storyboard, chat chunks, badge/emote snapshots and chapter offsets.
func (f *Finalizer) prepare(ctx context.Context, t *task) error {
	id := t.vod.ID
	t.out = filepath.Join(t.work, "out")
	_ = os.RemoveAll(t.out)
	if err := os.MkdirAll(filepath.Join(t.out, "chat"), 0o755); err != nil {
		return err
	}
	t.concat = filepath.Join(t.work, "concat.txt")
	var sb strings.Builder
	for _, p := range t.parts {
		for _, s := range p.Playlist.Segments {
			fmt.Fprintf(&sb, "file '%s'\n", strings.ReplaceAll(filepath.ToSlash(filepath.Join(p.Dir, s.URI)), "'", `'\''`))
		}
	}
	if err := os.WriteFile(t.concat, []byte(sb.String()), 0o644); err != nil {
		return err
	}

	stream, _ := f.probeVideo(ctx, filepath.Join(t.parts[0].Dir, t.parts[0].Playlist.Segments[0].URI))
	t.codec = stream.codec

	f.step(id, "storyboard")
	var err error
	if t.vod.Storyboard, err = f.storyboard(ctx, t.concat, t.totalMs, filepath.Join(t.out, "storyboard")); err != nil {
		f.log.Warn("storyboard", "vod", id, "err", err)
	}
	f.step(id, "chat")
	if t.vod.ChatCount, err = f.chat(filepath.Join(t.work, "chat.ndjson"), t.parts, filepath.Join(t.out, "chat")); err != nil {
		// fail (retryable) instead of archiving without chat: the raw log
		// lives in the work dir, which is deleted once the VOD is ready
		return fmt.Errorf("chat: %w", err)
	}
	for _, name := range []string{"badges.json", "emotes.json"} {
		if err := copyFile(filepath.Join(t.work, name), filepath.Join(t.out, name)); err != nil {
			_ = os.WriteFile(filepath.Join(t.out, name), []byte("{}"), 0o644)
		}
	}
	if t.chapters, err = f.st.Chapters(ctx, id); err != nil {
		return err
	}
	hls.ChapterOffsets(t.parts, t.chapters)
	return nil
}

// archiveVideo remuxes the recording into staging on the archive and grabs
// the poster frame from the result.
func (f *Finalizer) archiveVideo(ctx context.Context, t *task, staging string) error {
	id := t.vod.ID
	f.step(id, "remux")
	video := filepath.Join(staging, "video.mp4")
	if err := f.remux(ctx, t.concat, t.codec, video); err != nil {
		return err
	}
	final, err := f.probeVideo(ctx, video)
	if err != nil {
		return fmt.Errorf("probe output: %w", err)
	}
	if final.durMs > 0 && final.durMs < t.totalMs*9/10 {
		return fmt.Errorf("output too short: %dms of %dms", final.durMs, t.totalMs)
	}
	if fi, err := os.Stat(video); err == nil {
		t.vod.SizeBytes = fi.Size()
	}

	f.step(id, "thumbnail")
	if err := f.thumbnail(ctx, video, final.durMs, filepath.Join(t.out, "thumb.jpg")); err != nil {
		f.log.Warn("thumbnail", "vod", id, "err", err)
	}

	t.vod.DurationMs = final.durMs
	if t.vod.DurationMs == 0 {
		t.vod.DurationMs = t.totalMs
	}
	t.vod.Width, t.vod.Height, t.vod.FPS, t.vod.VideoCodec = final.width, final.height, final.fps, final.codec
	return nil
}

// publish copies the artifacts next to the video, moves the folder into
// place, marks the VOD ready and frees the local disk.
func (f *Finalizer) publish(ctx context.Context, t *task, staging string) error {
	f.step(t.vod.ID, "upload")
	if err := copyTree(t.out, staging); err != nil {
		return fmt.Errorf("copy artifacts: %w", err)
	}

	relDir := filepath.ToSlash(filepath.Join(safeName(t.ch.Login), time.UnixMilli(t.vod.StartedAt).Format("2006-01-02")+"_"+t.vod.ID))
	t.vod.Dir = relDir
	t.vod.ChatChunkMs = f.cfg.ChatChunk.Milliseconds()
	if t.vod.EndedAt == 0 {
		last := t.parts[len(t.parts)-1]
		t.vod.EndedAt = last.Start + last.DurMs
	}
	info := map[string]any{"vod": t.vod, "channel": t.ch, "chapters": t.chapters, "version": 1}
	if b, err := json.MarshalIndent(info, "", "  "); err == nil {
		_ = os.WriteFile(filepath.Join(staging, "info.json"), b, 0o644)
	}

	dest := filepath.Join(f.cfg.ArchiveDir, filepath.FromSlash(relDir))
	if err := os.MkdirAll(filepath.Dir(dest), 0o755); err != nil {
		return err
	}
	_ = os.RemoveAll(dest)
	if err := os.Rename(staging, dest); err != nil {
		return fmt.Errorf("move into archive: %w", err)
	}
	if err := f.st.FinishVod(ctx, t.vod, t.chapters); err != nil {
		// not marked ready (cancelled, or deleted meanwhile): no folder on the
		// archive that nothing points to; a retry moves it into place again
		_ = os.RemoveAll(dest)
		if errors.Is(err, store.ErrNotFound) {
			_ = os.RemoveAll(t.work)
		}
		return err
	}
	return os.RemoveAll(t.work)
}
