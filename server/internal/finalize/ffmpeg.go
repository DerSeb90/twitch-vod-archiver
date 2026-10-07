package finalize

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"math"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	"github.com/derseb90/twitch-vod-archiver/server/internal/store"
)

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
	// index (moov) at the start: players can begin right away instead of
	// first fetching the end of a multi-GB file
	args = append(args, "-movflags", "+faststart", "-f", "mp4", out)
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
