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
	"fmt"
	"math"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/derseb90/twitch-vod-archiver/server/internal/store"
)

type Segment struct {
	URI string  // file name relative to the playlist
	Dur float64 // seconds
}

type Playlist struct {
	Segments []Segment
	Ended    bool
}

func (p Playlist) DurationMs() int64 {
	var d float64
	for _, s := range p.Segments {
		d += s.Dur
	}
	return int64(math.Round(d * 1000))
}

type cached struct {
	mod  time.Time
	size int64
	pl   Playlist
}

var (
	cacheMu sync.Mutex
	cache   = map[string]cached{}
)

// Parse reads a media playlist. Results are cached by mtime/size because the
// API re-reads growing playlists on every request.
func Parse(path string) (Playlist, error) {
	fi, err := os.Stat(path)
	if err != nil {
		return Playlist{}, err
	}
	cacheMu.Lock()
	if c, ok := cache[path]; ok && c.mod.Equal(fi.ModTime()) && c.size == fi.Size() {
		cacheMu.Unlock()
		return c.pl, nil
	}
	cacheMu.Unlock()

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
		case line == "#EXT-X-ENDLIST":
			pl.Ended = true
		case line != "" && !strings.HasPrefix(line, "#"):
			pl.Segments = append(pl.Segments, Segment{URI: line, Dur: dur})
			dur = 0
		}
	}
	if err := sc.Err(); err != nil {
		return Playlist{}, err
	}
	cacheMu.Lock()
	cache[path] = cached{fi.ModTime(), fi.Size(), pl}
	cacheMu.Unlock()
	return pl, nil
}

// Forget drops cached playlists below dir (after a recording was finalized).
func Forget(dir string) {
	cacheMu.Lock()
	defer cacheMu.Unlock()
	for k := range cache {
		if strings.HasPrefix(k, dir) {
			delete(cache, k)
		}
	}
}

// Part is one continuous piece of a recording.
type Part struct {
	Dir      string // absolute directory of the part
	Name     string // e.g. "part-000"
	Start    int64  // unix ms of the first received byte
	DurMs    int64
	Playlist Playlist
}

// LiveEdgeMs is how far behind the live edge streamlink starts
// (--hls-live-edge 4 x 2 s Twitch segments). That much video arrives in the
// first moment, so the first frame of a part was live this long before the
// first byte reached us.
const LiveEdgeMs = 8000

// Timeline loads all usable parts of a recording in order. Part.Start is the
// wall-clock time the part's first frame was live on Twitch, which lines the
// video up with the (real-time) chat.
func Timeline(workDir string, parts []store.Part) []Part {
	var out []Part
	for _, p := range parts {
		dir := filepath.Join(workDir, p.File)
		pl, err := Parse(filepath.Join(dir, "index.m3u8"))
		if err != nil || len(pl.Segments) == 0 {
			continue
		}
		dur := pl.DurationMs()
		backlog := int64(LiveEdgeMs)
		if p.EndedAt > p.StartedAt {
			// finished part: recorded video minus wall-clock runtime = initial backlog
			backlog = min(max(dur-(p.EndedAt-p.StartedAt), 0), 20_000)
		}
		out = append(out, Part{Dir: dir, Name: p.File, Start: p.StartedAt - backlog, DurMs: dur, Playlist: pl})
	}
	return out
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
// timeline are extrapolated (needed while the recording is still growing).
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

// Combined builds one EVENT playlist over all parts (discontinuity between
// parts) so players can watch live and seek back to the very beginning.
func Combined(parts []Part, ended bool) string {
	target := 1.0
	for _, p := range parts {
		for _, s := range p.Playlist.Segments {
			target = math.Max(target, s.Dur)
		}
	}
	var b strings.Builder
	fmt.Fprintf(&b, "#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-PLAYLIST-TYPE:EVENT\n#EXT-X-TARGETDURATION:%d\n#EXT-X-MEDIA-SEQUENCE:0\n#EXT-X-INDEPENDENT-SEGMENTS\n", int(math.Ceil(target)))
	for i, p := range parts {
		if i > 0 {
			b.WriteString("#EXT-X-DISCONTINUITY\n")
		}
		for _, s := range p.Playlist.Segments {
			fmt.Fprintf(&b, "#EXTINF:%.3f,\n%s/%s\n", s.Dur, p.Name, s.URI)
		}
	}
	if ended {
		b.WriteString("#EXT-X-ENDLIST\n")
	}
	return b.String()
}
