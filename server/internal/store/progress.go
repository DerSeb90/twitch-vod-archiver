package store

import (
	"context"

	_ "modernc.org/sqlite"
)

// SetProgress stores the playback position of a VOD. watched marks it as
// seen completely (the position is then reset so a rewatch starts at 0).
func (s *Store) SetProgress(ctx context.Context, vodID string, positionMs int64, watched bool) error {
	if watched {
		positionMs = 0
	}
	w := 0
	if watched {
		w = 1
	}
	return s.changed(affected(s.db.ExecContext(ctx, `INSERT INTO progress (vod_id, position_ms, watched, updated_at)
SELECT id, ?, ?, ? FROM vods WHERE id = ?
ON CONFLICT(vod_id) DO UPDATE SET position_ms = excluded.position_ms, watched = excluded.watched, updated_at = excluded.updated_at`,
		max(positionMs, 0), w, now(), vodID)), false)
}

// ClearProgress marks a VOD as unwatched. The row stays (position 0) so
// other clients learn about it through ProgressSince.
func (s *Store) ClearProgress(ctx context.Context, vodID string) error {
	return s.SetProgress(ctx, vodID, 0, false)
}

type Progress struct {
	VodID      string `json:"vodId"`
	PositionMs int64  `json:"positionMs"`
	Watched    bool   `json:"watched"`
	UpdatedAt  int64  `json:"updatedAt"`
}

// ProgressSince returns progress written at or after since (server clock,
// ms; inclusive, so writes within the same millisecond are not lost).
func (s *Store) ProgressSince(ctx context.Context, since int64) ([]Progress, error) {
	rows, err := s.db.QueryContext(ctx, `SELECT vod_id, position_ms, watched, updated_at FROM progress WHERE updated_at >= ? ORDER BY updated_at LIMIT 500`, since)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []Progress{}
	for rows.Next() {
		var p Progress
		var w int
		if err := rows.Scan(&p.VodID, &p.PositionMs, &w, &p.UpdatedAt); err != nil {
			return nil, err
		}
		p.Watched = w == 1
		out = append(out, p)
	}
	return out, rows.Err()
}
