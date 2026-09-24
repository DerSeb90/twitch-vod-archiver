//go:build live

package chat

import (
	"context"
	"log/slog"
	"os"
	"path/filepath"
	"testing"
	"time"
)

// LIVE_CHANNEL=somechannel go test -tags live -v -run TestLiveChat ./internal/chat/
func TestLiveChat(t *testing.T) {
	channel := os.Getenv("LIVE_CHANNEL")
	if channel == "" {
		t.Skip("LIVE_CHANNEL not set")
	}
	p := filepath.Join(t.TempDir(), "chat.ndjson")
	r := NewRecorder(channel, p, slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelDebug})))
	r.History = true
	ctx, cancel := context.WithTimeout(context.Background(), 25*time.Second)
	defer cancel()
	r.Run(ctx)
	b, _ := os.ReadFile(p)
	t.Logf("%d messages, %d bytes", r.Count(), len(b))
	if len(b) > 0 {
		end := min(len(b), 400)
		t.Logf("sample: %s", b[:end])
	}
	if r.Count() == 0 {
		t.Error("no chat messages received")
	}
}
