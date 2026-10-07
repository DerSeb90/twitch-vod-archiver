package store

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"strings"

	_ "modernc.org/sqlite"
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
	SizeBytes   int64  `json:"sizeBytes"` // finished recordings on the archive
}

const channelCols = `c.id, c.login, c.display_name, c.description, c.avatar_url, c.avatar_file, c.banner_url, c.banner_file, c.enabled, c.created_at, c.last_live_at,
	(SELECT COUNT(*) FROM vods v WHERE v.channel_id = c.id AND v.status = 'ready'),
	(SELECT COALESCE(SUM(duration_ms),0) FROM vods v WHERE v.channel_id = c.id AND v.status = 'ready'),
	(SELECT COALESCE(SUM(size_bytes),0) FROM vods v WHERE v.channel_id = c.id AND v.status = 'ready')`

func scanChannel(sc interface{ Scan(...any) error }) (Channel, error) {
	var c Channel
	var enabled int
	err := sc.Scan(&c.ID, &c.Login, &c.DisplayName, &c.Description, &c.AvatarURL, &c.AvatarFile, &c.BannerURL, &c.BannerFile, &enabled, &c.CreatedAt, &c.LastLiveAt, &c.VodCount, &c.TotalMs, &c.SizeBytes)
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
	return s.changed(err, true)
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
	return s.changed(affected(s.db.ExecContext(ctx, `DELETE FROM channels WHERE id = ?`, id)), true)
}
