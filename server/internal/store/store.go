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
	"strings"
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

type Channel struct {
	ID          string `json:"id"`
	Login       string `json:"login"`
	DisplayName string `json:"displayName"`
	Description string `json:"description"`
	AvatarURL   string `json:"-"`
	AvatarFile  string `json:"-"`
	BannerURL   string `json:"-"`
	BannerFile  string `json:"-"`
	Enabled     bool   `json:"enabled"`
	CreatedAt   int64  `json:"createdAt"`
	LastLiveAt  int64  `json:"lastLiveAt"`
	VodCount    int    `json:"vodCount"`
	TotalMs     int64  `json:"totalMs"`
}

type Vod struct {
	ID          string  `json:"id"`
	ChannelID   string  `json:"channelId"`
	StreamID    string  `json:"streamId"`
	Title       string  `json:"title"`
	Category    string  `json:"category"`
	CategoryID  string  `json:"categoryId"`
	StartedAt   int64   `json:"startedAt"`
	EndedAt     int64   `json:"endedAt"`
	DurationMs  int64   `json:"durationMs"`
	Status      string  `json:"status"`
	Dir         string  `json:"-"`
	SizeBytes   int64   `json:"sizeBytes"`
	Width       int     `json:"width"`
	Height      int     `json:"height"`
	FPS         float64 `json:"fps"`
	VideoCodec  string  `json:"videoCodec"`
	ChatCount   int     `json:"chatCount"`
	ChatChunkMs int64   `json:"chatChunkMs"`
	PeakViewers int     `json:"peakViewers"`
	Error       string  `json:"error,omitempty"`
	CreatedAt   int64   `json:"createdAt"`

	Storyboard Storyboard `json:"storyboard"`
}

type Storyboard struct {
	IntervalMs int64 `json:"intervalMs"`
	Cols       int   `json:"cols"`
	Rows       int   `json:"rows"`
	TileW      int   `json:"tileW"`
	TileH      int   `json:"tileH"`
	Count      int   `json:"count"` // number of tiles overall
	Sheets     int   `json:"sheets"`
}

type Part struct {
	VodID     string
	Idx       int
	File      string
	StartedAt int64
	EndedAt   int64
}

type Chapter struct {
	At         int64  `json:"-"`
	OffsetMs   int64  `json:"offsetMs"`
	Title      string `json:"title"`
	Category   string `json:"category"`
	CategoryID string `json:"categoryId"`
	BoxArt     string `json:"boxArt"`
}

type Store struct{ db *sql.DB }

func Open(path string) (*Store, error) {
	dsn := "file:" + path + "?_pragma=journal_mode(WAL)&_pragma=busy_timeout(10000)&_pragma=foreign_keys(ON)&_pragma=synchronous(NORMAL)"
	db, err := sql.Open("sqlite", dsn)
	if err != nil {
		return nil, err
	}
	db.SetMaxOpenConns(4)
	s := &Store{db: db}
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
`)
	return err
}

func now() int64 { return time.Now().UnixMilli() }

// ---------- channels ----------

const channelCols = `c.id, c.login, c.display_name, c.description, c.avatar_url, c.avatar_file, c.banner_url, c.banner_file, c.enabled, c.created_at, c.last_live_at,
	(SELECT COUNT(*) FROM vods v WHERE v.channel_id = c.id AND v.status = 'ready'),
	(SELECT COALESCE(SUM(duration_ms),0) FROM vods v WHERE v.channel_id = c.id AND v.status = 'ready')`

func scanChannel(sc interface{ Scan(...any) error }) (Channel, error) {
	var c Channel
	var enabled int
	err := sc.Scan(&c.ID, &c.Login, &c.DisplayName, &c.Description, &c.AvatarURL, &c.AvatarFile, &c.BannerURL, &c.BannerFile, &enabled, &c.CreatedAt, &c.LastLiveAt, &c.VodCount, &c.TotalMs)
	c.Enabled = enabled == 1
	return c, err
}

func (s *Store) Channels(ctx context.Context) ([]Channel, error) {
	rows, err := s.db.QueryContext(ctx, `SELECT `+channelCols+` FROM channels c ORDER BY c.last_live_at DESC, c.display_name COLLATE NOCASE`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []Channel{}
	for rows.Next() {
		c, err := scanChannel(rows)
		if err != nil {
			return nil, err
		}
		out = append(out, c)
	}
	return out, rows.Err()
}

func (s *Store) Channel(ctx context.Context, idOrLogin string) (Channel, error) {
	c, err := scanChannel(s.db.QueryRowContext(ctx, `SELECT `+channelCols+` FROM channels c WHERE c.id = ? OR c.login = ?`, idOrLogin, strings.ToLower(idOrLogin)))
	if errors.Is(err, sql.ErrNoRows) {
		return c, ErrNotFound
	}
	return c, err
}

func (s *Store) UpsertChannel(ctx context.Context, c Channel) error {
	_, err := s.db.ExecContext(ctx, `
INSERT INTO channels (id, login, display_name, description, avatar_url, avatar_file, banner_url, banner_file, enabled, created_at)
VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
ON CONFLICT(id) DO UPDATE SET login = excluded.login, display_name = excluded.display_name,
	description = excluded.description, avatar_url = excluded.avatar_url, banner_url = excluded.banner_url,
	avatar_file = CASE WHEN excluded.avatar_file != '' THEN excluded.avatar_file ELSE channels.avatar_file END,
	banner_file = CASE WHEN excluded.banner_file != '' OR excluded.banner_url = '' THEN excluded.banner_file ELSE channels.banner_file END`,
		c.ID, strings.ToLower(c.Login), c.DisplayName, c.Description, c.AvatarURL, c.AvatarFile, c.BannerURL, c.BannerFile, boolInt(c.Enabled), now())
	return err
}

func (s *Store) SetChannelEnabled(ctx context.Context, id string, enabled bool) error {
	return affected(s.db.ExecContext(ctx, `UPDATE channels SET enabled = ? WHERE id = ?`, boolInt(enabled), id))
}

func (s *Store) TouchChannelLive(ctx context.Context, id string) error {
	_, err := s.db.ExecContext(ctx, `UPDATE channels SET last_live_at = ? WHERE id = ?`, now(), id)
	return err
}

// DeleteChannel removes a channel only if it owns no VODs (purge them first).
func (s *Store) DeleteChannel(ctx context.Context, id string) error {
	var n int
	if err := s.db.QueryRowContext(ctx, `SELECT COUNT(*) FROM vods WHERE channel_id = ?`, id).Scan(&n); err != nil {
		return err
	}
	if n > 0 {
		return fmt.Errorf("channel still has %d vods", n)
	}
	return affected(s.db.ExecContext(ctx, `DELETE FROM channels WHERE id = ?`, id))
}

// ---------- vods ----------

const vodCols = `id, channel_id, stream_id, title, category, category_id, started_at, ended_at, duration_ms, status, dir,
	size_bytes, width, height, fps, video_codec, chat_count, chat_chunk_ms,
	sb_interval_ms, sb_cols, sb_rows, sb_w, sb_h, sb_count, sb_sheets, peak_viewers, error, created_at`

func scanVod(sc interface{ Scan(...any) error }) (Vod, error) {
	var v Vod
	sb := &v.Storyboard
	err := sc.Scan(&v.ID, &v.ChannelID, &v.StreamID, &v.Title, &v.Category, &v.CategoryID, &v.StartedAt, &v.EndedAt, &v.DurationMs,
		&v.Status, &v.Dir, &v.SizeBytes, &v.Width, &v.Height, &v.FPS, &v.VideoCodec, &v.ChatCount, &v.ChatChunkMs,
		&sb.IntervalMs, &sb.Cols, &sb.Rows, &sb.TileW, &sb.TileH, &sb.Count, &sb.Sheets, &v.PeakViewers, &v.Error, &v.CreatedAt)
	return v, err
}

func (s *Store) CreateVod(ctx context.Context, v Vod) error {
	_, err := s.db.ExecContext(ctx, `INSERT INTO vods (id, channel_id, stream_id, title, category, category_id, started_at, status, created_at)
VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)`, v.ID, v.ChannelID, v.StreamID, v.Title, v.Category, v.CategoryID, v.StartedAt, v.Status, now())
	return err
}

func (s *Store) Vod(ctx context.Context, id string) (Vod, error) {
	v, err := scanVod(s.db.QueryRowContext(ctx, `SELECT `+vodCols+` FROM vods WHERE id = ?`, id))
	if errors.Is(err, sql.ErrNoRows) {
		return v, ErrNotFound
	}
	return v, err
}

type VodFilter struct {
	ChannelID string
	IDs       []string
	Query     string
	Statuses  []string
	Limit     int
	Offset    int
}

func (s *Store) Vods(ctx context.Context, f VodFilter) ([]Vod, int, error) {
	var where []string
	var args []any
	if f.ChannelID != "" {
		where = append(where, "channel_id = ?")
		args = append(args, f.ChannelID)
	}
	if len(f.IDs) > 0 {
		where = append(where, "id IN (?"+strings.Repeat(",?", len(f.IDs)-1)+")")
		for _, id := range f.IDs {
			args = append(args, id)
		}
	}
	if len(f.Statuses) > 0 {
		where = append(where, "status IN (?"+strings.Repeat(",?", len(f.Statuses)-1)+")")
		for _, st := range f.Statuses {
			args = append(args, st)
		}
	}
	if q := strings.TrimSpace(f.Query); q != "" {
		where = append(where, "(title LIKE ? OR category LIKE ? OR channel_id IN (SELECT id FROM channels WHERE login LIKE ? OR display_name LIKE ?))")
		like := "%" + q + "%"
		args = append(args, like, like, like, like)
	}
	cond := ""
	if len(where) > 0 {
		cond = " WHERE " + strings.Join(where, " AND ")
	}
	var total int
	if err := s.db.QueryRowContext(ctx, `SELECT COUNT(*) FROM vods`+cond, args...).Scan(&total); err != nil {
		return nil, 0, err
	}
	if f.Limit <= 0 || f.Limit > 200 {
		f.Limit = 48
	}
	rows, err := s.db.QueryContext(ctx, `SELECT `+vodCols+` FROM vods`+cond+` ORDER BY started_at DESC LIMIT ? OFFSET ?`, append(args, f.Limit, f.Offset)...)
	if err != nil {
		return nil, 0, err
	}
	defer rows.Close()
	out := []Vod{}
	for rows.Next() {
		v, err := scanVod(rows)
		if err != nil {
			return nil, 0, err
		}
		out = append(out, v)
	}
	return out, total, rows.Err()
}

func (s *Store) VodsByStatus(ctx context.Context, statuses ...string) ([]Vod, error) {
	v, _, err := s.Vods(ctx, VodFilter{Statuses: statuses, Limit: 200})
	return v, err
}

func (s *Store) UpdateVodMeta(ctx context.Context, id, title, category, categoryID string, viewers int) error {
	_, err := s.db.ExecContext(ctx, `UPDATE vods SET title = ?, category = ?, category_id = ?, peak_viewers = MAX(peak_viewers, ?) WHERE id = ?`,
		title, category, categoryID, viewers, id)
	return err
}

func (s *Store) SetVodStatus(ctx context.Context, id, status, errMsg string) error {
	_, err := s.db.ExecContext(ctx, `UPDATE vods SET status = ?, error = ? WHERE id = ?`, status, errMsg, id)
	return err
}

func (s *Store) SetVodEnded(ctx context.Context, id string, endedAt int64) error {
	_, err := s.db.ExecContext(ctx, `UPDATE vods SET ended_at = ? WHERE id = ?`, endedAt, id)
	return err
}

// FinishVod stores everything the finalizer computed and marks the VOD ready.
func (s *Store) FinishVod(ctx context.Context, v Vod, chapters []Chapter) error {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	sb := v.Storyboard
	if _, err := tx.ExecContext(ctx, `UPDATE vods SET status = ?, dir = ?, duration_ms = ?, size_bytes = ?, width = ?, height = ?, fps = ?,
	video_codec = ?, chat_count = ?, chat_chunk_ms = ?, sb_interval_ms = ?, sb_cols = ?, sb_rows = ?, sb_w = ?, sb_h = ?, sb_count = ?, sb_sheets = ?,
	ended_at = ?, error = '' WHERE id = ?`,
		StatusReady, v.Dir, v.DurationMs, v.SizeBytes, v.Width, v.Height, v.FPS, v.VideoCodec, v.ChatCount, v.ChatChunkMs,
		sb.IntervalMs, sb.Cols, sb.Rows, sb.TileW, sb.TileH, sb.Count, sb.Sheets, v.EndedAt, v.ID); err != nil {
		return err
	}
	for _, c := range chapters {
		if _, err := tx.ExecContext(ctx, `UPDATE chapters SET offset_ms = ? WHERE vod_id = ? AND at = ?`, c.OffsetMs, v.ID, c.At); err != nil {
			return err
		}
	}
	if _, err := tx.ExecContext(ctx, `DELETE FROM parts WHERE vod_id = ?`, v.ID); err != nil {
		return err
	}
	return tx.Commit()
}

func (s *Store) DeleteVod(ctx context.Context, id string) error {
	return affected(s.db.ExecContext(ctx, `DELETE FROM vods WHERE id = ?`, id))
}

// ---------- parts ----------

func (s *Store) AddPart(ctx context.Context, p Part) error {
	_, err := s.db.ExecContext(ctx, `INSERT INTO parts (vod_id, idx, file, started_at) VALUES (?, ?, ?, ?)`, p.VodID, p.Idx, p.File, p.StartedAt)
	return err
}

func (s *Store) UpdatePart(ctx context.Context, p Part) error {
	_, err := s.db.ExecContext(ctx, `UPDATE parts SET started_at = ?, ended_at = ? WHERE vod_id = ? AND idx = ?`, p.StartedAt, p.EndedAt, p.VodID, p.Idx)
	return err
}

func (s *Store) Parts(ctx context.Context, vodID string) ([]Part, error) {
	rows, err := s.db.QueryContext(ctx, `SELECT vod_id, idx, file, started_at, ended_at FROM parts WHERE vod_id = ? ORDER BY idx`, vodID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []Part
	for rows.Next() {
		var p Part
		if err := rows.Scan(&p.VodID, &p.Idx, &p.File, &p.StartedAt, &p.EndedAt); err != nil {
			return nil, err
		}
		out = append(out, p)
	}
	return out, rows.Err()
}

// ---------- chapters ----------

func (s *Store) AddChapter(ctx context.Context, vodID string, c Chapter) error {
	_, err := s.db.ExecContext(ctx, `INSERT INTO chapters (vod_id, at, title, category, category_id, box_art) VALUES (?, ?, ?, ?, ?, ?)`,
		vodID, c.At, c.Title, c.Category, c.CategoryID, c.BoxArt)
	return err
}

func (s *Store) Chapters(ctx context.Context, vodID string) ([]Chapter, error) {
	rows, err := s.db.QueryContext(ctx, `SELECT at, offset_ms, title, category, category_id, box_art FROM chapters WHERE vod_id = ? ORDER BY at`, vodID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []Chapter{}
	for rows.Next() {
		var c Chapter
		if err := rows.Scan(&c.At, &c.OffsetMs, &c.Title, &c.Category, &c.CategoryID, &c.BoxArt); err != nil {
			return nil, err
		}
		out = append(out, c)
	}
	return out, rows.Err()
}

// ---------- stats ----------

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
