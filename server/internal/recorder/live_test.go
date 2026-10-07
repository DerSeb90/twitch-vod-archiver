//go:build live

// Records a real Twitch channel for a few seconds (no credentials needed):
//
//	LIVE_CHANNEL=somechannel go test -tags live -v ./internal/recorder/
//
// Needs streamlink + ffmpeg (STREAMLINK_PATH / FFMPEG_PATH or in PATH).
package recorder

import (
	"context"
	"io"
	"log/slog"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/derseb90/twitch-vod-archiver/server/internal/chat"
	"github.com/derseb90/twitch-vod-archiver/server/internal/config"
	"github.com/derseb90/twitch-vod-archiver/server/internal/hls"
)

func TestLiveRecording(t *testing.T) {
	channel := os.Getenv("LIVE_CHANNEL")
	if channel == "" {
		t.Skip("LIVE_CHANNEL not set")
	}
	cfg := &config.Config{StreamlinkPath: envOr("STREAMLINK_PATH", "streamlink"), FFmpegPath: envOr("FFMPEG_PATH", "ffmpeg"), Quality: "best"}
	dir := t.TempDir()
	log := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelInfo}))

	ctx, cancel := context.WithCancel(context.Background())
	chatRec := chat.NewRecorder(channel, filepath.Join(dir, "chat.ndjson"), slog.New(slog.NewTextHandler(io.Discard, nil)))
	chatDone := make(chan struct{})
	go func() { chatRec.Run(ctx); close(chatDone) }()

	var first time.Time
	p, err := startRecording(cfg, "", channel, filepath.Join(dir, "part-000"), log, func(ts time.Time) { first = ts })
	if err != nil {
		t.Fatal(err)
	}
	time.Sleep(30 * time.Second)

	// while running: playlist grows
	pl, err := hls.Parse(filepath.Join(dir, "part-000", "index.m3u8"))
	if err != nil || len(pl.Segments) < 3 {
		t.Fatalf("live playlist: %+v err=%v", pl, err)
	}
	t.Logf("while live: %d segments, %d ms, first data after %v", len(pl.Segments), pl.DurationMs(), first.Sub(p.started))

	p.stop()
	select {
	case <-p.done:
	case <-time.After(30 * time.Second):
		t.Fatal("recorder did not stop")
	}
	cancel()
	<-chatDone

	pl, _ = hls.Parse(filepath.Join(dir, "part-000", "index.m3u8"))
	if b, _ := os.ReadFile(filepath.Join(dir, "part-000", "index.m3u8")); !strings.Contains(string(b), "#EXT-X-ENDLIST") {
		t.Error("playlist not closed after stop")
	}
	t.Logf("after stop: %d segments, %d ms, exit=%v, chat messages=%d", len(pl.Segments), pl.DurationMs(), p.err, chatRec.Count())
	for _, s := range pl.Segments {
		if fi, err := os.Stat(filepath.Join(dir, "part-000", s.URI)); err != nil || fi.Size() == 0 {
			t.Errorf("segment %s missing/empty", s.URI)
		}
	}
	if first.IsZero() {
		t.Error("first data time not recorded")
	}
}

func envOr(k, d string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return d
}
