package finalize

import (
	"testing"

	"github.com/derseb90/twitch-vod-archiver/server/internal/store"
)

func TestMapTime(t *testing.T) {
	parts := []partInfo{
		{Part: store.Part{StartedAt: 1000}, durMs: 10_000}, // 1000..11000
		{Part: store.Part{StartedAt: 20_000}, durMs: 5_000}, // gap 11000..20000
	}
	cases := map[int64]int64{
		0:      0,      // before start
		1000:   0,
		5000:   4000,
		15_000: 10_000, // inside gap -> start of part 2
		21_000: 11_000,
		99_000: 15_000, // after end -> clamp
	}
	for ts, want := range cases {
		if got := mapTime(parts, ts); got != want {
			t.Errorf("mapTime(%d) = %d, want %d", ts, got, want)
		}
	}
}

func TestParseEmotes(t *testing.T) {
	got := parseEmotes("1902:6-10/25:0-4,12-16")
	if len(got) != 3 || got[0][0] != "25" || got[0][1] != 0 || got[1][0] != "1902" || got[2][1] != 12 {
		t.Fatalf("unexpected %v", got)
	}
	if parseEmotes("") != nil {
		t.Fatal("empty tag should give nil")
	}
}

func TestWasBanned(t *testing.T) {
	if !wasBanned([]int64{10_000}, 5_000) {
		t.Error("message before ban should be hidden")
	}
	if wasBanned([]int64{10_000}, 20_000) {
		t.Error("message after ban must stay")
	}
}
