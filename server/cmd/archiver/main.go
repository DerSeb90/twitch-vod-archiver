// Command archiver records Twitch live streams (video + chat) and serves them.
package main

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"path/filepath"
	"strings"
	"sync"
	"syscall"
	"time"

	"github.com/derseb90/twitch-vod-archiver/server/internal/api"
	"github.com/derseb90/twitch-vod-archiver/server/internal/config"
	"github.com/derseb90/twitch-vod-archiver/server/internal/finalize"
	"github.com/derseb90/twitch-vod-archiver/server/internal/recorder"
	"github.com/derseb90/twitch-vod-archiver/server/internal/store"
	"github.com/derseb90/twitch-vod-archiver/server/internal/twitch"
)

var version = "dev"

func main() {
	if err := run(); err != nil {
		fmt.Fprintln(os.Stderr, "fatal:", err)
		os.Exit(1)
	}
}

func run() error {
	cfg, err := config.Load()
	if err != nil {
		return err
	}
	log := newLogger(cfg)
	log.Info("starting", "version", version, "maxConcurrent", cfg.MaxConcurrent, "archive", cfg.ArchiveDir, "recordings", cfg.RecordingsDir)

	for _, d := range []string{cfg.DataDir, cfg.RecordingsDir, cfg.ArchiveDir} {
		if err := os.MkdirAll(d, 0o755); err != nil {
			return fmt.Errorf("create %s: %w", d, err)
		}
	}
	if err := checkWritable(cfg.ArchiveDir); err != nil {
		log.Error("archive dir is not writable - is the Storage Box mounted?", "dir", cfg.ArchiveDir, "err", err)
	}

	st, err := store.Open(filepath.Join(cfg.DataDir, "archive.db"))
	if err != nil {
		return err
	}
	defer st.Close()

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	tw := twitch.New(cfg.TwitchClientID, cfg.TwitchClientSecret)
	fin := finalize.New(cfg, st, log)
	rec := recorder.New(cfg, st, tw, fin, log)
	srv := &http.Server{
		Addr:              cfg.HTTPAddr,
		Handler:           api.New(cfg, st, rec, fin, log, version).Handler(),
		ReadHeaderTimeout: 10 * time.Second,
		IdleTimeout:       2 * time.Minute,
	}

	var wg sync.WaitGroup
	errc := make(chan error, 3)
	wg.Add(3)
	go func() { defer wg.Done(); fin.Run(ctx) }()
	go func() {
		defer wg.Done()
		if err := rec.Run(ctx); err != nil {
			errc <- fmt.Errorf("recorder: %w", err)
		}
	}()
	go func() {
		defer wg.Done()
		log.Info("http listening", "addr", cfg.HTTPAddr)
		if err := srv.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
			errc <- fmt.Errorf("http: %w", err)
		}
	}()

	select {
	case <-ctx.Done():
	case err = <-errc:
		stop()
	}
	log.Info("shutting down")
	sctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	_ = srv.Shutdown(sctx)
	cancel()
	wg.Wait()
	return err
}

func newLogger(cfg *config.Config) *slog.Logger {
	var lvl slog.Level
	_ = lvl.UnmarshalText([]byte(strings.ToUpper(cfg.LogLevel)))
	opts := &slog.HandlerOptions{Level: lvl}
	if cfg.LogFormat == "json" {
		return slog.New(slog.NewJSONHandler(os.Stdout, opts))
	}
	return slog.New(slog.NewTextHandler(os.Stdout, opts))
}

func checkWritable(dir string) error {
	p := filepath.Join(dir, ".write-test")
	if err := os.WriteFile(p, []byte("ok"), 0o644); err != nil {
		return err
	}
	return os.Remove(p)
}
