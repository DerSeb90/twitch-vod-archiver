// Package hls reads the HLS playlists written during recording and maps
// wall-clock timestamps onto the (possibly multi-part) video timeline.
//
// Layout of a recording on local disk:
//
//	<RECORDINGS_DIR>/<vod>/part-000/index.m3u8 + seg-00000.ts ...
//	<RECORDINGS_DIR>/<vod>/part-001/...        (after a reconnect / resume)
package hls

import (
	"bufio"
	"errors"
	"fmt"
	"io/fs"
	"math"
	"os"
	"path/filepath"
	"strconv"
	"strings"

	"github.com/derseb90/twitch-vod-archiver/server/internal/store"
)

type Segment struct {
	URI string  // file name relative to the playlist
	Dur float64 // seconds
}

type Playlist struct {
	Segments []Segment
}

func (p Playlist) DurationMs() int64 {
	var d float64
	for _, s := range p.Segments {
		d += s.Dur
	}
	return int64(math.Round(d * 1000))
}

// Parse reads a media playlist.
func Parse(path string) (Playlist, error) {
	f, err := os.Open(path)
	if err != nil {
		return Playlist{}, err
	}
	defer f.Close()
	var pl Playlist
	var dur float64
	sc := bufio.NewScanner(f)
	for sc.Scan() {
		line := strings.TrimSpace(sc.Text())
		switch {
		case strings.HasPrefix(line, "#EXTINF:"):
			v, _, _ := strings.Cut(strings.TrimPrefix(line, "#EXTINF:"), ",")
			dur, _ = strconv.ParseFloat(v, 64)
		case line != "" && !strings.HasPrefix(line, "#"):
			pl.Segments = append(pl.Segments, Segment{URI: line, Dur: dur})
			dur = 0
		}
	}
	if err := sc.Err(); err != nil {
		return Playlist{}, err
	}
	return pl, nil
}

// Part is one continuous piece of a recording.
type Part struct {
	Dir      string // absolute directory of the part
	Name     string // e.g. "part-000"
	Start    int64  // unix ms of the first received byte
	DurMs    int64
	Playlist Playlist
}

// liveEdgeMs is how far behind the live edge streamlink starts
// (--hls-live-edge 4 x 2 s Twitch segments). That much video arrives in the
// first moment, so the first frame of a part was live this long before the
// first byte reached us.
const liveEdgeMs = 8000

// Timeline loads all usable parts of a recording in order. Part.Start is the
// wall-clock time the part's first frame was live on Twitch, which lines the
// video up with the (real-time) chat.
//
// Parts without a playlist or without segments (the recorder got no data)
// are skipped. Any other read error is returned: the video is there but
// can't be read right now, so it must not be treated as empty.
func Timeline(workDir string, parts []store.Part) ([]Part, error) {
	var out []Part
	for _, p := range parts {
		dir := filepath.Join(workDir, p.File)
		pl, err := Parse(filepath.Join(dir, "index.m3u8"))
		if errors.Is(err, fs.ErrNotExist) {
			continue
		}
		if err != nil {
			return nil, fmt.Errorf("%s: %w", p.File, err)
		}
		if len(pl.Segments) == 0 {
			continue
		}
		dur := pl.DurationMs()
		backlog := int64(liveEdgeMs)
		if p.EndedAt > p.StartedAt {
			// finished part: recorded video minus wall-clock runtime = initial backlog
			backlog = min(max(dur-(p.EndedAt-p.StartedAt), 0), 20_000)
		}
		out = append(out, Part{Dir: dir, Name: p.File, Start: p.StartedAt - backlog, DurMs: dur, Playlist: pl})
	}
	return out, nil
}

func TotalMs(parts []Part) int64 {
	var t int64
	for _, p := range parts {
		t += p.DurMs
	}
	return t
}

// MaxChatGap: chat written while nothing was recorded for longer than this
// (e.g. a manually paused recording) is dropped instead of being piled up
// at the resume point. Short reconnect gaps collapse onto the next part.
const MaxChatGap = 60_000

// Map converts a wall-clock timestamp to a video offset. Timestamps inside
// gaps longer than maxGap report ok=false. Timestamps after the end of the
// timeline are extrapolated (callers clamp them to the end of the video).
func Map(parts []Part, ts, maxGap int64) (offset int64, ok bool) {
	var cum, prevEnd int64
	for i, p := range parts {
		if ts < p.Start {
			if i == 0 {
				return 0, true // chat before the recording (history) shows at the start
			}
			return cum, p.Start-prevEnd <= maxGap
		}
		if ts < p.Start+p.DurMs {
			return cum + ts - p.Start, true
		}
		prevEnd = p.Start + p.DurMs
		cum += p.DurMs
	}
	return cum + ts - prevEnd, true
}

// ChapterOffsets sets the video position of each chapter (stream start or
// title/category change), clamped to the end of the video.
func ChapterOffsets(parts []Part, chapters []store.Chapter) {
	total := TotalMs(parts)
	for i := range chapters {
		off, _ := Map(parts, chapters[i].At, math.MaxInt64)
		chapters[i].OffsetMs = min(off, total)
	}
}
