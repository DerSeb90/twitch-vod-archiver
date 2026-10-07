package store

import (
	"context"
	"database/sql"
	"errors"
	"strings"

	_ "modernc.org/sqlite"
)

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

	// Watch progress (single user, shared by all devices).
	PositionMs int64 `json:"positionMs"`
	Watched    bool  `json:"watched"`
	ProgressAt int64 `json:"progressAt,omitempty"`

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

const vodCols = `id, channel_id, stream_id, title, category, category_id, started_at, ended_at, duration_ms, status, dir,
	size_bytes, width, height, fps, video_codec, chat_count, chat_chunk_ms,
	sb_interval_ms, sb_cols, sb_rows, sb_w, sb_h, sb_count, sb_sheets, peak_viewers, error, created_at,
	COALESCE(position_ms, 0), COALESCE(watched, 0), COALESCE(updated_at, 0)`

// vodFrom joins the watch progress; its column names don't clash with vods.
const vodFrom = ` FROM vods LEFT JOIN progress ON progress.vod_id = vods.id`

func scanVod(sc interface{ Scan(...any) error }) (Vod, error) {
	var v Vod
	var watched int
	sb := &v.Storyboard
	err := sc.Scan(&v.ID, &v.ChannelID, &v.StreamID, &v.Title, &v.Category, &v.CategoryID, &v.StartedAt, &v.EndedAt, &v.DurationMs,
		&v.Status, &v.Dir, &v.SizeBytes, &v.Width, &v.Height, &v.FPS, &v.VideoCodec, &v.ChatCount, &v.ChatChunkMs,
		&sb.IntervalMs, &sb.Cols, &sb.Rows, &sb.TileW, &sb.TileH, &sb.Count, &sb.Sheets, &v.PeakViewers, &v.Error, &v.CreatedAt,
		&v.PositionMs, &watched, &v.ProgressAt)
	v.Watched = watched == 1
	return v, err
}

func (s *Store) CreateVod(ctx context.Context, v Vod) error {
	_, err := s.db.ExecContext(ctx, `INSERT INTO vods (id, channel_id, stream_id, title, category, category_id, started_at, status, created_at)
VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)`, v.ID, v.ChannelID, v.StreamID, v.Title, v.Category, v.CategoryID, v.StartedAt, v.Status, now())
	return s.changed(err, true)
}

func (s *Store) Vod(ctx context.Context, id string) (Vod, error) {
	v, err := scanVod(s.db.QueryRowContext(ctx, `SELECT `+vodCols+vodFrom+` WHERE id = ?`, id))
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
	// Unwatched hides VODs marked as watched.
	Unwatched bool
	// InProgress returns only started, unfinished VODs, most recently watched first.
	InProgress bool
	Limit      int
	Offset     int
	all        bool // no limit (internal use only, Limit comes from clients)
}

// MinResumeMs is the position from which a VOD counts as "started".
const MinResumeMs = 10000

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
	if f.Unwatched || f.InProgress {
		where = append(where, "COALESCE(watched, 0) = 0")
	}
	order := "started_at DESC"
	if f.InProgress {
		where = append(where, "position_ms >= ?")
		args = append(args, MinResumeMs)
		order = "updated_at DESC"
	}
	cond := ""
	if len(where) > 0 {
		cond = " WHERE " + strings.Join(where, " AND ")
	}
	var total int
	if err := s.db.QueryRowContext(ctx, `SELECT COUNT(*)`+vodFrom+cond, args...).Scan(&total); err != nil {
		return nil, 0, err
	}
	switch {
	case f.all:
		f.Limit = -1 // SQLite: no limit
	case f.Limit <= 0 || f.Limit > 200:
		f.Limit = 48
	}
	rows, err := s.db.QueryContext(ctx, `SELECT `+vodCols+vodFrom+cond+` ORDER BY `+order+` LIMIT ? OFFSET ?`, append(args, f.Limit, f.Offset)...)
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

// ChannelVods is the newest part of one channel's VODs.
type ChannelVods struct {
	ChannelID string
	Vods      []Vod
	Total     int // all matching VODs of the channel, not just Vods
}

// LatestPerChannel returns the newest finished VODs of every channel that has
// any, at most limit each (unwatched ones only if asked). Channels come in
// the order of their newest such VOD.
func (s *Store) LatestPerChannel(ctx context.Context, limit int, unwatched bool) ([]ChannelVods, error) {
	cond := "status = ?"
	if unwatched {
		cond += " AND COALESCE(watched, 0) = 0"
	}
	rows, err := s.db.QueryContext(ctx, `WITH ranked AS (
	SELECT vods.id AS rid,
		ROW_NUMBER() OVER (PARTITION BY channel_id ORDER BY started_at DESC, vods.id) AS rn,
		COUNT(*) OVER (PARTITION BY channel_id) AS n,
		MAX(started_at) OVER (PARTITION BY channel_id) AS newest`+vodFrom+` WHERE `+cond+`
)
SELECT `+vodCols+`, ranked.n`+vodFrom+` JOIN ranked ON ranked.rid = vods.id
WHERE ranked.rn <= ? ORDER BY ranked.newest DESC, channel_id, ranked.rn`, StatusReady, limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []ChannelVods{}
	for rows.Next() {
		var n int
		v, err := scanVod(withExtra{rows, []any{&n}})
		if err != nil {
			return nil, err
		}
		if len(out) == 0 || out[len(out)-1].ChannelID != v.ChannelID {
			out = append(out, ChannelVods{ChannelID: v.ChannelID, Total: n})
		}
		last := &out[len(out)-1]
		last.Vods = append(last.Vods, v)
	}
	return out, rows.Err()
}

// withExtra scans additional trailing columns into extra.
type withExtra struct {
	rows  *sql.Rows
	extra []any
}

func (w withExtra) Scan(dest ...any) error { return w.rows.Scan(append(dest, w.extra...)...) }

// VodsByStatus returns all VODs with one of the statuses (no paging).
func (s *Store) VodsByStatus(ctx context.Context, statuses ...string) ([]Vod, error) {
	v, _, err := s.Vods(ctx, VodFilter{Statuses: statuses, all: true})
	return v, err
}

func (s *Store) UpdateVodMeta(ctx context.Context, id, title, category, categoryID string, viewers int) error {
	_, err := s.db.ExecContext(ctx, `UPDATE vods SET title = ?, category = ?, category_id = ?, peak_viewers = MAX(peak_viewers, ?) WHERE id = ?`,
		title, category, categoryID, viewers, id)
	return err
}

func (s *Store) SetVodStatus(ctx context.Context, id, status, errMsg string) error {
	_, err := s.db.ExecContext(ctx, `UPDATE vods SET status = ?, error = ? WHERE id = ?`, status, errMsg, id)
	return s.changed(err, true)
}

// SetVodStream records the Twitch stream a VOD continues with (a new
// broadcast within the grace period), so a restart can resume it.
func (s *Store) SetVodStream(ctx context.Context, id, streamID string) error {
	return affected(s.db.ExecContext(ctx, `UPDATE vods SET stream_id = ? WHERE id = ?`, streamID, id))
}

func (s *Store) SetVodEnded(ctx context.Context, id string, endedAt int64) error {
	_, err := s.db.ExecContext(ctx, `UPDATE vods SET ended_at = ? WHERE id = ?`, endedAt, id)
	return err
}

// FinishVod stores everything the finalizer computed and marks the VOD ready.
// It returns ErrNotFound if the VOD no longer exists.
func (s *Store) FinishVod(ctx context.Context, v Vod, chapters []Chapter) error {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	sb := v.Storyboard
	if err := affected(tx.ExecContext(ctx, `UPDATE vods SET status = ?, dir = ?, duration_ms = ?, size_bytes = ?, width = ?, height = ?, fps = ?,
	video_codec = ?, chat_count = ?, chat_chunk_ms = ?, sb_interval_ms = ?, sb_cols = ?, sb_rows = ?, sb_w = ?, sb_h = ?, sb_count = ?, sb_sheets = ?,
	ended_at = ?, error = '' WHERE id = ?`,
		StatusReady, v.Dir, v.DurationMs, v.SizeBytes, v.Width, v.Height, v.FPS, v.VideoCodec, v.ChatCount, v.ChatChunkMs,
		sb.IntervalMs, sb.Cols, sb.Rows, sb.TileW, sb.TileH, sb.Count, sb.Sheets, v.EndedAt, v.ID)); err != nil {
		return err // ErrNotFound: deleted while it was being processed
	}
	for _, c := range chapters {
		if _, err := tx.ExecContext(ctx, `UPDATE chapters SET offset_ms = ? WHERE vod_id = ? AND at = ?`, c.OffsetMs, v.ID, c.At); err != nil {
			return err
		}
	}
	if _, err := tx.ExecContext(ctx, `DELETE FROM parts WHERE vod_id = ?`, v.ID); err != nil {
		return err
	}
	return s.changed(tx.Commit(), true)
}

func (s *Store) DeleteVod(ctx context.Context, id string) error {
	return s.changed(affected(s.db.ExecContext(ctx, `DELETE FROM vods WHERE id = ?`, id)), true)
}

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
