// Package store persists channels, VODs, recording parts and chapters in SQLite.
// The database lives on local disk (never on the SMB share: SQLite locking over
// CIFS is unreliable). Every finished VOD additionally gets an info.json next to
// the video on the Storage Box so metadata is never only in one place.
package store

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"time"

	_ "modernc.org/sqlite"
)

var ErrNotFound = errors.New("not found")

const (
	StatusRecording  = "recording"
	StatusProcessing = "processing"
	StatusReady      = "ready"
	StatusFailed     = "failed"
)

type Store struct {
	db *sql.DB
	// Changes wakes long-polling clients after writes they display.
	Changes *Changes
}

// changed signals a successful write to waiting clients.
func (s *Store) changed(err error, vods bool) error {
	if err == nil {
		s.Changes.bump(vods)
	}
	return err
}

func Open(path string) (*Store, error) {
	dsn := "file:" + path + "?_pragma=journal_mode(WAL)&_pragma=busy_timeout(10000)&_pragma=foreign_keys(ON)&_pragma=synchronous(NORMAL)"
	db, err := sql.Open("sqlite", dsn)
	if err != nil {
		return nil, err
	}
	db.SetMaxOpenConns(4)
	s := &Store{db: db, Changes: newChanges()}
	if err := s.migrate(); err != nil {
		db.Close()
		return nil, fmt.Errorf("migrate: %w", err)
	}
	return s, nil
}

func (s *Store) Close() error { return s.db.Close() }

func (s *Store) migrate() error {
	_, err := s.db.Exec(`
CREATE TABLE IF NOT EXISTS channels (
	id TEXT PRIMARY KEY,
	login TEXT NOT NULL UNIQUE,
	display_name TEXT NOT NULL,
	description TEXT NOT NULL DEFAULT '',
	avatar_url TEXT NOT NULL DEFAULT '',
	avatar_file TEXT NOT NULL DEFAULT '',
	banner_url TEXT NOT NULL DEFAULT '',
	banner_file TEXT NOT NULL DEFAULT '',
	enabled INTEGER NOT NULL DEFAULT 1,
	created_at INTEGER NOT NULL,
	last_live_at INTEGER NOT NULL DEFAULT 0
);
CREATE TABLE IF NOT EXISTS vods (
	id TEXT PRIMARY KEY,
	channel_id TEXT NOT NULL REFERENCES channels(id),
	stream_id TEXT NOT NULL DEFAULT '',
	title TEXT NOT NULL DEFAULT '',
	category TEXT NOT NULL DEFAULT '',
	category_id TEXT NOT NULL DEFAULT '',
	started_at INTEGER NOT NULL,
	ended_at INTEGER NOT NULL DEFAULT 0,
	duration_ms INTEGER NOT NULL DEFAULT 0,
	status TEXT NOT NULL,
	dir TEXT NOT NULL DEFAULT '',
	size_bytes INTEGER NOT NULL DEFAULT 0,
	width INTEGER NOT NULL DEFAULT 0,
	height INTEGER NOT NULL DEFAULT 0,
	fps REAL NOT NULL DEFAULT 0,
	video_codec TEXT NOT NULL DEFAULT '',
	chat_count INTEGER NOT NULL DEFAULT 0,
	chat_chunk_ms INTEGER NOT NULL DEFAULT 0,
	sb_interval_ms INTEGER NOT NULL DEFAULT 0,
	sb_cols INTEGER NOT NULL DEFAULT 0,
	sb_rows INTEGER NOT NULL DEFAULT 0,
	sb_w INTEGER NOT NULL DEFAULT 0,
	sb_h INTEGER NOT NULL DEFAULT 0,
	sb_count INTEGER NOT NULL DEFAULT 0,
	sb_sheets INTEGER NOT NULL DEFAULT 0,
	peak_viewers INTEGER NOT NULL DEFAULT 0,
	error TEXT NOT NULL DEFAULT '',
	created_at INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS vods_channel_started ON vods(channel_id, started_at DESC);
CREATE INDEX IF NOT EXISTS vods_started ON vods(started_at DESC);
CREATE TABLE IF NOT EXISTS parts (
	vod_id TEXT NOT NULL REFERENCES vods(id) ON DELETE CASCADE,
	idx INTEGER NOT NULL,
	file TEXT NOT NULL,
	started_at INTEGER NOT NULL,
	ended_at INTEGER NOT NULL DEFAULT 0,
	PRIMARY KEY (vod_id, idx)
);
CREATE TABLE IF NOT EXISTS chapters (
	vod_id TEXT NOT NULL REFERENCES vods(id) ON DELETE CASCADE,
	at INTEGER NOT NULL,
	offset_ms INTEGER NOT NULL DEFAULT 0,
	title TEXT NOT NULL DEFAULT '',
	category TEXT NOT NULL DEFAULT '',
	category_id TEXT NOT NULL DEFAULT '',
	box_art TEXT NOT NULL DEFAULT ''
);
CREATE INDEX IF NOT EXISTS chapters_vod ON chapters(vod_id, at);
CREATE TABLE IF NOT EXISTS progress (
	vod_id TEXT PRIMARY KEY REFERENCES vods(id) ON DELETE CASCADE,
	position_ms INTEGER NOT NULL DEFAULT 0,
	watched INTEGER NOT NULL DEFAULT 0,
	updated_at INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS progress_updated ON progress(updated_at DESC);
`)
	return err
}

func now() int64 { return time.Now().UnixMilli() }

type Stats struct {
	Channels   int   `json:"channels"`
	Vods       int   `json:"vods"`
	TotalMs    int64 `json:"totalMs"`
	TotalBytes int64 `json:"totalBytes"`
	ChatCount  int64 `json:"chatCount"`
}

func (s *Store) Stats(ctx context.Context) (Stats, error) {
	var st Stats
	err := s.db.QueryRowContext(ctx, `SELECT (SELECT COUNT(*) FROM channels), COUNT(*), COALESCE(SUM(duration_ms),0), COALESCE(SUM(size_bytes),0), COALESCE(SUM(chat_count),0)
FROM vods WHERE status = 'ready'`).Scan(&st.Channels, &st.Vods, &st.TotalMs, &st.TotalBytes, &st.ChatCount)
	return st, err
}

func boolInt(b bool) int {
	if b {
		return 1
	}
	return 0
}

func affected(res sql.Result, err error) error {
	if err != nil {
		return err
	}
	n, err := res.RowsAffected()
	if err != nil {
		return err
	}
	if n == 0 {
		return ErrNotFound
	}
	return nil
}
