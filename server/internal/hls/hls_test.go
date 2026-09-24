package hls

import (
	"math"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestMap(t *testing.T) {
	parts := []Part{
		{Start: 1000, DurMs: 10_000},   // 1000..11000
		{Start: 20_000, DurMs: 5_000},  // short gap 11000..20000 (9s)
		{Start: 200_000, DurMs: 5_000}, // long gap (pause)
	}
	cases := []struct {
		ts, want int64
		ok       bool
	}{
		{500, 0, true},         // shortly before start
		{5000, 4000, true},     // inside part 1
		{15_000, 10_000, true}, // short gap collapses onto part 2
		{21_000, 11_000, true},
		{100_000, 15_000, false}, // inside the long pause: dropped
		{201_000, 16_000, true},
		{210_000, 25_000, true}, // after the end: extrapolated (live)
	}
	for _, c := range cases {
		got, ok := Map(parts, c.ts, MaxChatGap)
		if got != c.want || ok != c.ok {
			t.Errorf("Map(%d) = %d,%v want %d,%v", c.ts, got, ok, c.want, c.ok)
		}
	}
	if _, ok := Map(parts, 100_000, math.MaxInt64); !ok {
		t.Error("unbounded gap must map")
	}
}

func TestParseAndCombine(t *testing.T) {
	dir := t.TempDir()
	os.WriteFile(filepath.Join(dir, "index.m3u8"), []byte("#EXTM3U\n#EXT-X-TARGETDURATION:4\n#EXTINF:4.000000,\nseg-00000.ts\n#EXTINF:3.500000,\nseg-00001.ts\n"), 0o644)
	pl, err := Parse(filepath.Join(dir, "index.m3u8"))
	if err != nil || len(pl.Segments) != 2 || pl.DurationMs() != 7500 || pl.Ended {
		t.Fatalf("parse: %+v %v", pl, err)
	}
	c := Combined([]Part{{Name: "part-000", Playlist: pl}, {Name: "part-001", Playlist: pl}}, true)
	for _, want := range []string{"#EXT-X-PLAYLIST-TYPE:EVENT", "part-000/seg-00000.ts", "#EXT-X-DISCONTINUITY\n", "part-001/seg-00001.ts", "#EXT-X-ENDLIST"} {
		if !strings.Contains(c, want) {
			t.Errorf("combined playlist misses %q:\n%s", want, c)
		}
	}
}
