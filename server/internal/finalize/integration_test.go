//go:build integration

// Runs the full finalize pipeline against synthetic recordings.
// Needs ffmpeg/ffprobe in PATH:  go test -tags integration ./internal/finalize/
package finalize

import (
	"compress/gzip"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log/slog"
	"os"
	"os/exec"
	"path/filepath"
	"testing"
	"time"

	"github.com/derseb90/twitch-vod-archiver/server/internal/chat"
	"github.com/derseb90/twitch-vod-archiver/server/internal/config"
	"github.com/derseb90/twitch-vod-archiver/server/internal/store"
)

func TestFinalizePipeline(t *testing.T) {
	if _, err := exec.LookPath("ffmpeg"); err != nil {
		t.Skip("ffmpeg not installed")
	}
	root := t.TempDir()
	if d := os.Getenv("KEEP_DIR"); d != "" {
		root = d // keep the generated archive, e.g. as demo data for UI work
	}
	cfg := &config.Config{
		DataDir: filepath.Join(root, "data"), RecordingsDir: filepath.Join(root, "recordings"), ArchiveDir: filepath.Join(root, "archive"),
		FFmpegPath: "ffmpeg", FFprobePath: "ffprobe", ChatChunk: time.Minute, StoryboardInterval: 5 * time.Second, FinalizeWorkers: 1,
	}
	for _, d := range []string{cfg.DataDir, cfg.RecordingsDir, cfg.ArchiveDir} {
		os.MkdirAll(d, 0o755)
	}
	st, err := store.Open(filepath.Join(cfg.DataDir, "archive.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	ctx := context.Background()
	if err := st.UpsertChannel(ctx, store.Channel{ID: "1", Login: "tester", DisplayName: "Tester", Enabled: true}); err != nil {
		t.Fatal(err)
	}
	start := time.Now().Add(-10 * time.Minute).UnixMilli()
	vod := store.Vod{ID: "vod1", ChannelID: "1", StreamID: "s1", Title: "Test", StartedAt: start, Status: store.StatusProcessing}
	if err := st.CreateVod(ctx, vod); err != nil {
		t.Fatal(err)
	}
	work := filepath.Join(cfg.RecordingsDir, vod.ID)
	os.MkdirAll(work, 0o755)

	// two 70s parts with a 30s gap between them (simulated reconnect)
	parts := []struct{ start, dur int64 }{{start, 70_000}, {start + 100_000, 70_000}}
	for i, p := range parts {
		file := fmt.Sprintf("part-%03d.ts", i)
		cmd := exec.Command("ffmpeg", "-hide_banner", "-loglevel", "error", "-f", "lavfi", "-i", "testsrc2=size=640x360:rate=30",
			"-f", "lavfi", "-i", "sine=frequency=440", "-t", fmt.Sprint(p.dur/1000), "-c:v", "libx264", "-preset", "ultrafast", "-g", "60",
			"-c:a", "aac", "-f", "mpegts", filepath.Join(work, file))
		if out, err := cmd.CombinedOutput(); err != nil {
			t.Fatalf("gen part: %v %s", err, out)
		}
		st.AddPart(ctx, store.Part{VodID: vod.ID, Idx: i, File: file, StartedAt: p.start})
		st.UpdatePart(ctx, store.Part{VodID: vod.ID, Idx: i, StartedAt: p.start, EndedAt: p.start + p.dur})
	}
	st.AddChapter(ctx, vod.ID, store.Chapter{At: start, Title: "Start", Category: "Just Chatting"})
	st.AddChapter(ctx, vod.ID, store.Chapter{At: start + 110_000, Title: "Game", Category: "Minecraft"})

	f, _ := os.Create(filepath.Join(work, "chat.ndjson"))
	enc := json.NewEncoder(f)
	enc.Encode(chat.Event{TS: start + 1000, Kind: "msg", ID: "a", Login: "u1", Name: "U1", Text: "Kappa hi", Emotes: "25:0-4"})
	enc.Encode(chat.Event{TS: start + 2000, Kind: "msg", ID: "b", Login: "u2", Name: "U2", Text: "deleted"})
	enc.Encode(chat.Event{TS: start + 3000, Kind: "del", ID: "b"})
	enc.Encode(chat.Event{TS: start + 80_000, Kind: "msg", ID: "c", Login: "u3", Name: "U3", Text: "in gap"})
	enc.Encode(chat.Event{TS: start + 110_000, Kind: "msg", ID: "d", Login: "u4", Name: "U4", Text: "part two"})
	f.Close()

	fin := New(cfg, st, slog.New(slog.NewTextHandler(io.Discard, nil)))
	if err := fin.process(ctx, vod.ID); err != nil {
		t.Fatal(err)
	}
	got, err := st.Vod(ctx, vod.ID)
	if err != nil {
		t.Fatal(err)
	}
	if got.Status != store.StatusReady {
		t.Fatalf("status %s", got.Status)
	}
	if got.DurationMs < 138_000 || got.DurationMs > 142_000 {
		t.Errorf("duration %d, want ~140000", got.DurationMs)
	}
	if got.ChatCount != 3 {
		t.Errorf("chat count %d, want 3 (one deleted)", got.ChatCount)
	}
	if got.Storyboard.Sheets < 1 || got.Width != 640 {
		t.Errorf("storyboard %+v width %d", got.Storyboard, got.Width)
	}
	dir := filepath.Join(cfg.ArchiveDir, filepath.FromSlash(got.Dir))
	for _, name := range []string{"video.mp4", "thumb.jpg", "storyboard/000.jpg", "chat/0000.json.gz", "chat/0002.json.gz", "chat/activity.json", "info.json", "emotes.json"} {
		if _, err := os.Stat(filepath.Join(dir, name)); err != nil {
			t.Errorf("missing %s", name)
		}
	}
	// message in the gap maps to the start of part two (70s) -> chunk 1
	msgs := readChunk(t, filepath.Join(dir, "chat/0001.json.gz"))
	near := func(a, b int64) bool { return a-b < 500 && b-a < 500 } // TS durations carry a few ms of padding
	if len(msgs) != 2 || !near(msgs[0].T, 70_000) || !near(msgs[1].T, 80_000) {
		t.Errorf("chunk 1: %+v", msgs)
	}
	chs, _ := st.Chapters(ctx, vod.ID)
	if len(chs) != 2 || !near(chs[1].OffsetMs, 80_000) {
		t.Errorf("chapters %+v", chs)
	}
	if _, err := os.Stat(work); !os.IsNotExist(err) {
		t.Error("work dir not cleaned up")
	}
}

func readChunk(t *testing.T, p string) []ChatMessage {
	f, err := os.Open(p)
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()
	zr, err := gzip.NewReader(f)
	if err != nil {
		t.Fatal(err)
	}
	var out []ChatMessage
	if err := json.NewDecoder(zr).Decode(&out); err != nil {
		t.Fatal(err)
	}
	return out
}
