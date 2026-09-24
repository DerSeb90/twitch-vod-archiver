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
	"io"
	"log/slog"
	"math"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/derseb90/twitch-vod-archiver/server/internal/config"
	"github.com/derseb90/twitch-vod-archiver/server/internal/hls"
	"github.com/derseb90/twitch-vod-archiver/server/internal/store"
)

type Finalizer struct {
	cfg *config.Config
	st  *store.Store
	log *slog.Logger

	q       chan string
	mu      sync.Mutex
	pending map[string]bool
	active  map[string]string // vod id -> current step
}

func New(cfg *config.Config, st *store.Store, log *slog.Logger) *Finalizer {
	return &Finalizer{cfg: cfg, st: st, log: log.With("component", "finalize"),
		q: make(chan string, 256), pending: map[string]bool{}, active: map[string]string{}}
}

func (f *Finalizer) Enqueue(id string) {
	f.mu.Lock()
	if f.pending[id] {
		f.mu.Unlock()
		return
	}
	f.pending[id] = true
	f.mu.Unlock()
	f.q <- id
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
	var wg sync.WaitGroup
	for i := 0; i < f.cfg.FinalizeWorkers; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for {
				select {
				case <-ctx.Done():
					return
				case id := <-f.q:
					start := time.Now()
					err := f.process(ctx, id)
					f.mu.Lock()
					delete(f.pending, id)
					delete(f.active, id)
					f.mu.Unlock()
					if ctx.Err() != nil {
						return // shutting down: vod stays "processing" and is retried on next start
					}
					if err != nil {
						f.log.Error("finalize failed", "vod", id, "err", err)
						_ = f.st.SetVodStatus(context.Background(), id, store.StatusFailed, err.Error())
					} else {
						f.log.Info("finalize done", "vod", id, "took", time.Since(start).Round(time.Second))
					}
				}
			}
		}()
	}
	wg.Wait()
}

func (f *Finalizer) process(ctx context.Context, id string) error {
	vod, err := f.st.Vod(ctx, id)
	if err != nil {
		return err
	}
	ch, err := f.st.Channel(ctx, vod.ChannelID)
	if err != nil {
		return err
	}
	work := filepath.Join(f.cfg.RecordingsDir, vod.ID)

	f.step(id, "probe")
	dbParts, err := f.st.Parts(ctx, id)
	if err != nil {
		return err
	}
	hls.Forget(work)
	parts := hls.Timeline(work, dbParts)
	if len(parts) == 0 {
		f.log.Warn("no usable video, discarding recording", "vod", id)
		_ = os.RemoveAll(work)
		return f.st.DeleteVod(ctx, id)
	}
	totalMs := hls.TotalMs(parts)

	out := filepath.Join(work, "out")
	_ = os.RemoveAll(out)
	if err := os.MkdirAll(filepath.Join(out, "chat"), 0o755); err != nil {
		return err
	}
	concat := filepath.Join(work, "concat.txt")
	var sb strings.Builder
	for _, p := range parts {
		for _, s := range p.Playlist.Segments {
			fmt.Fprintf(&sb, "file '%s'\n", strings.ReplaceAll(filepath.ToSlash(filepath.Join(p.Dir, s.URI)), "'", `'\''`))
		}
	}
	if err := os.WriteFile(concat, []byte(sb.String()), 0o644); err != nil {
		return err
	}

	stream, _ := f.probeVideo(ctx, filepath.Join(parts[0].Dir, parts[0].Playlist.Segments[0].URI))

	// small local artifacts first
	f.step(id, "storyboard")
	storyboard, err := f.storyboard(ctx, concat, totalMs, filepath.Join(out, "storyboard"))
	if err != nil {
		f.log.Warn("storyboard", "vod", id, "err", err)
	}
	f.step(id, "chat")
	chatCount, err := f.chat(filepath.Join(work, "chat.ndjson"), parts, filepath.Join(out, "chat"))
	if err != nil {
		f.log.Warn("chat", "vod", id, "err", err)
	}
	for _, name := range []string{"badges.json", "emotes.json"} {
		if err := copyFile(filepath.Join(work, name), filepath.Join(out, name)); err != nil {
			_ = os.WriteFile(filepath.Join(out, name), []byte("{}"), 0o644)
		}
	}
	chapters, err := f.st.Chapters(ctx, id)
	if err != nil {
		return err
	}
	for i := range chapters {
		chapters[i].OffsetMs, _ = hls.Map(parts, chapters[i].At, math.MaxInt64)
		chapters[i].OffsetMs = min(chapters[i].OffsetMs, totalMs)
	}

	// stage on the share, then atomically move into place
	relDir := filepath.ToSlash(filepath.Join(safeName(ch.Login), time.UnixMilli(vod.StartedAt).Format("2006-01-02")+"_"+vod.ID))
	staging := filepath.Join(f.cfg.ArchiveDir, ".incoming", vod.ID)
	_ = os.RemoveAll(staging)
	if err := os.MkdirAll(staging, 0o755); err != nil {
		return fmt.Errorf("archive not writable: %w", err)
	}

	f.step(id, "remux")
	video := filepath.Join(staging, "video.mp4")
	if err := f.remux(ctx, concat, stream.codec, video); err != nil {
		return err
	}
	final, err := f.probeVideo(ctx, video)
	if err != nil {
		return fmt.Errorf("probe output: %w", err)
	}
	if final.durMs > 0 && final.durMs < totalMs*9/10 {
		return fmt.Errorf("output too short: %dms of %dms", final.durMs, totalMs)
	}
	if fi, err := os.Stat(video); err == nil {
		vod.SizeBytes = fi.Size()
	}

	f.step(id, "thumbnail")
	if err := f.thumbnail(ctx, video, final.durMs, filepath.Join(out, "thumb.jpg")); err != nil {
		f.log.Warn("thumbnail", "vod", id, "err", err)
	}

	f.step(id, "upload")
	if err := copyTree(out, staging); err != nil {
		return fmt.Errorf("copy artifacts: %w", err)
	}

	vod.Dir = relDir
	vod.DurationMs = final.durMs
	if vod.DurationMs == 0 {
		vod.DurationMs = totalMs
	}
	vod.Width, vod.Height, vod.FPS, vod.VideoCodec = final.width, final.height, final.fps, final.codec
	vod.ChatCount = chatCount
	vod.ChatChunkMs = f.cfg.ChatChunk.Milliseconds()
	vod.Storyboard = storyboard
	if vod.EndedAt == 0 {
		last := parts[len(parts)-1]
		vod.EndedAt = last.Start + last.DurMs
	}
	info := map[string]any{"vod": vod, "channel": ch, "chapters": chapters, "version": 1}
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
	if err := f.st.FinishVod(ctx, vod, chapters); err != nil {
		return err
	}
	hls.Forget(work)
	return os.RemoveAll(work)
}

// ---------- ffmpeg helpers ----------

func (f *Finalizer) run(ctx context.Context, name string, args ...string) ([]byte, error) {
	cmd := exec.CommandContext(ctx, name, args...)
	var stderr strings.Builder
	cmd.Stderr = &stderr
	b, err := cmd.Output()
	if err != nil {
		msg := stderr.String()
		if len(msg) > 800 {
			msg = msg[len(msg)-800:]
		}
		return b, fmt.Errorf("%s: %w: %s", filepath.Base(name), err, strings.TrimSpace(msg))
	}
	return b, nil
}

type videoInfo struct {
	codec         string
	width, height int
	fps           float64
	durMs         int64
}

func (f *Finalizer) probeVideo(ctx context.Context, file string) (videoInfo, error) {
	b, err := f.run(ctx, f.cfg.FFprobePath, "-v", "error", "-select_streams", "v:0",
		"-show_entries", "stream=codec_name,width,height,avg_frame_rate:format=duration", "-of", "json", file)
	if err != nil {
		return videoInfo{}, err
	}
	var r struct {
		Streams []struct {
			CodecName string `json:"codec_name"`
			Width     int    `json:"width"`
			Height    int    `json:"height"`
			FrameRate string `json:"avg_frame_rate"`
		} `json:"streams"`
		Format struct {
			Duration string `json:"duration"`
		} `json:"format"`
	}
	if err := json.Unmarshal(b, &r); err != nil {
		return videoInfo{}, err
	}
	var vi videoInfo
	if len(r.Streams) > 0 {
		s := r.Streams[0]
		vi.codec, vi.width, vi.height = s.CodecName, s.Width, s.Height
		if n, d, ok := strings.Cut(s.FrameRate, "/"); ok {
			nf, _ := strconv.ParseFloat(n, 64)
			df, _ := strconv.ParseFloat(d, 64)
			if df > 0 {
				vi.fps = math.Round(nf/df*100) / 100
			}
		}
	}
	if d, err := strconv.ParseFloat(r.Format.Duration, 64); err == nil {
		vi.durMs = int64(d * 1000)
	}
	return vi, nil
}

func (f *Finalizer) remux(ctx context.Context, concat, codec, out string) error {
	args := []string{"-hide_banner", "-nostdin", "-loglevel", "error", "-y",
		"-fflags", "+genpts+discardcorrupt", "-f", "concat", "-safe", "0", "-i", concat,
		"-map", "0:v:0", "-map", "0:a:0?", "-c", "copy", "-bsf:a", "aac_adtstoasc",
		"-avoid_negative_ts", "make_zero"}
	if codec == "hevc" {
		args = append(args, "-tag:v", "hvc1") // required for Apple players
	}
	args = append(args, "-f", "mp4", out)
	_, err := f.run(ctx, f.cfg.FFmpegPath, args...)
	return err
}

// thumbnail grabs a poster frame from the finished MP4 (seeking there is
// exact, unlike inside single live segments).
func (f *Finalizer) thumbnail(ctx context.Context, video string, totalMs int64, out string) error {
	target := totalMs * 3 / 10
	if target > 20*60*1000 && totalMs > 60*60*1000 {
		target = 20 * 60 * 1000 // skip "starting soon" screens but stay early
	}
	var err error
	for _, at := range []int64{target, totalMs / 10, 0} { // fall back to earlier frames
		_, err = f.run(ctx, f.cfg.FFmpegPath, "-hide_banner", "-nostdin", "-loglevel", "error", "-y",
			"-ss", fmt.Sprintf("%.3f", float64(at)/1000), "-i", video, "-frames:v", "1", "-update", "1",
			"-vf", "scale='min(1920,iw)':-2", "-q:v", "2", out)
		if err == nil {
			if fi, serr := os.Stat(out); serr == nil && fi.Size() > 0 {
				return nil
			}
			err = errors.New("empty thumbnail")
		}
	}
	return err
}

const (
	sbCols, sbRows = 10, 10
	sbW, sbH       = 256, 144
)

func (f *Finalizer) storyboard(ctx context.Context, concat string, totalMs int64, dir string) (store.Storyboard, error) {
	interval := f.cfg.StoryboardInterval
	if interval <= 0 {
		return store.Storyboard{}, nil
	}
	// keep sheet count bounded for very long streams
	if n := totalMs / interval.Milliseconds(); n > 3000 {
		interval = time.Duration(totalMs/3000) * time.Millisecond
	}
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return store.Storyboard{}, err
	}
	vf := fmt.Sprintf("fps=1000/%d,scale=%d:%d:force_original_aspect_ratio=decrease,pad=%d:%d:(ow-iw)/2:(oh-ih)/2,tile=%dx%d",
		interval.Milliseconds(), sbW, sbH, sbW, sbH, sbCols, sbRows)
	_, err := f.run(ctx, f.cfg.FFmpegPath, "-hide_banner", "-nostdin", "-loglevel", "error", "-y",
		"-skip_frame", "nokey", "-f", "concat", "-safe", "0", "-i", concat,
		"-an", "-sn", "-dn", "-vf", vf, "-fps_mode", "vfr", "-q:v", "6", "-start_number", "0",
		filepath.Join(dir, "%03d.jpg"))
	if err != nil {
		return store.Storyboard{}, err
	}
	sheets, _ := filepath.Glob(filepath.Join(dir, "*.jpg"))
	count := int(math.Ceil(float64(totalMs) / float64(interval.Milliseconds())))
	return store.Storyboard{IntervalMs: interval.Milliseconds(), Cols: sbCols, Rows: sbRows, TileW: sbW, TileH: sbH,
		Count: min(count, len(sheets)*sbCols*sbRows), Sheets: len(sheets)}, nil
}

// ---------- file helpers ----------

func copyFile(src, dst string) error {
	in, err := os.Open(src)
	if err != nil {
		return err
	}
	defer in.Close()
	out, err := os.Create(dst)
	if err != nil {
		return err
	}
	if _, err := io.Copy(out, in); err != nil {
		out.Close()
		return err
	}
	return out.Close()
}

func copyTree(src, dst string) error {
	return filepath.WalkDir(src, func(p string, d os.DirEntry, err error) error {
		if err != nil {
			return err
		}
		rel, _ := filepath.Rel(src, p)
		target := filepath.Join(dst, rel)
		if d.IsDir() {
			return os.MkdirAll(target, 0o755)
		}
		return copyFile(p, target)
	})
}

func safeName(s string) string {
	s = strings.Map(func(r rune) rune {
		if r >= 'a' && r <= 'z' || r >= '0' && r <= '9' || r == '_' || r == '-' {
			return r
		}
		return '_'
	}, strings.ToLower(s))
	if s == "" {
		s = "unknown"
	}
	return s
}
