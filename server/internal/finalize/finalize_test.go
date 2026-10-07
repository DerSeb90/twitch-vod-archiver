package finalize

import (
	"context"
	"fmt"
	"io"
	"log/slog"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/derseb90/twitch-vod-archiver/server/internal/config"
	"github.com/derseb90/twitch-vod-archiver/server/internal/store"
)

func TestQueue(t *testing.T) {
	ctx := context.Background()
	root := t.TempDir()
	cfg := &config.Config{RecordingsDir: filepath.Join(root, "recordings"), ArchiveDir: filepath.Join(root, "archive"), FinalizeWorkers: 1}
	st, err := store.Open(filepath.Join(root, "t.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	st.UpsertChannel(ctx, store.Channel{ID: "c1", Login: "c1", DisplayName: "C1"})
	for _, id := range []string{"queued", "broken"} {
		if err := st.CreateVod(ctx, store.Vod{ID: id, ChannelID: "c1", Status: store.StatusProcessing}); err != nil {
			t.Fatal(err)
		}
	}
	f := New(cfg, st, slog.New(slog.NewTextHandler(io.Discard, nil)))

	// enqueueing never blocks, however long the queue gets
	done := make(chan struct{})
	go func() {
		for i := range 1000 {
			f.Enqueue(fmt.Sprintf("x%d", i))
		}
		close(done)
	}()
	select {
	case <-done:
	case <-time.After(5 * time.Second):
		t.Fatal("Enqueue blocked")
	}
	f.queue, f.pending = nil, map[string]bool{}

	// cancelling a queued VOD takes it out and leaves it retryable
	f.Enqueue("queued")
	f.Cancel("queued", time.Second)
	if v, _ := st.Vod(ctx, "queued"); v.Status != store.StatusFailed || len(f.queue) != 0 {
		t.Fatalf("after cancel: status %s, queue %v", v.Status, f.queue)
	}
	f.Enqueue("queued")
	if len(f.queue) != 1 {
		t.Fatalf("re-enqueue after cancel: queue %v", f.queue)
	}
	f.Cancel("queued", time.Second)

	// a failing run marks the VOD failed (and keeps its recording)
	part := filepath.Join(cfg.RecordingsDir, "broken", "part-000")
	os.MkdirAll(part, 0o755)
	os.WriteFile(filepath.Join(part, "index.m3u8"), []byte("#EXTM3U\n"+strings.Repeat("x", 100_000)+"\n"), 0o644)
	st.AddPart(ctx, store.Part{VodID: "broken", Idx: 0, File: "part-000"})
	rctx, cancel := context.WithCancel(ctx)
	defer cancel()
	go f.Run(rctx)
	f.Enqueue("broken")
	for deadline := time.Now().Add(5 * time.Second); ; time.Sleep(20 * time.Millisecond) {
		v, err := st.Vod(ctx, "broken")
		if err != nil {
			t.Fatalf("vod gone: %v", err)
		}
		if v.Status == store.StatusFailed && v.Error != "cancelled" {
			break
		}
		if time.Now().After(deadline) {
			t.Fatalf("status %s (%s), want failed", v.Status, v.Error)
		}
	}
	if _, err := os.Stat(part); err != nil {
		t.Fatal("recording removed after a failed run")
	}
}
