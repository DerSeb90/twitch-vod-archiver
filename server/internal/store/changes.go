package store

import (
	"context"
	"sync"
	"time"
)

// Changes lets clients wait for writes (long polling), so every open app
// shows new progress or VODs right away instead of after a reload.
type Changes struct {
	mu   sync.Mutex
	seq  int64 // any change
	vods int64 // seq of the last change to the VOD lists (new, finished, deleted)
	wake chan struct{}
}

// ChangeState is what clients compare against their last known state.
type ChangeState struct {
	Seq  int64 `json:"seq"`
	Vods int64 `json:"vods"`
	Now  int64 `json:"now"` // server clock, for ProgressSince
}

func newChanges() *Changes {
	// start from the clock so a restarted server never repeats an old seq
	seq := time.Now().UnixMilli()
	return &Changes{seq: seq, vods: seq, wake: make(chan struct{})}
}

func (c *Changes) bump(vods bool) {
	c.mu.Lock()
	c.seq++
	if vods {
		c.vods = c.seq
	}
	close(c.wake)
	c.wake = make(chan struct{})
	c.mu.Unlock()
}

func (c *Changes) state() ChangeState {
	c.mu.Lock()
	defer c.mu.Unlock()
	return ChangeState{Seq: c.seq, Vods: c.vods, Now: now()}
}

// Wait returns as soon as the sequence differs from since, or after timeout.
func (c *Changes) Wait(ctx context.Context, since int64, timeout time.Duration) ChangeState {
	c.mu.Lock()
	seq, wake := c.seq, c.wake
	c.mu.Unlock()
	if seq != since {
		return c.state()
	}
	t := time.NewTimer(timeout)
	defer t.Stop()
	select {
	case <-wake:
	case <-t.C:
	case <-ctx.Done():
	}
	return c.state()
}
