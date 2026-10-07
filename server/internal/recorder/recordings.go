package recorder

import (
	"context"
	"errors"
	"time"
)

// Recording describes a currently running recording for the API.
type Recording struct {
	VodID       string `json:"vodId"`
	ChannelID   string `json:"channelId"`
	Login       string `json:"login"`
	DisplayName string `json:"displayName"`
	Title       string `json:"title"`
	Category    string `json:"category"`
	StartedAt   int64  `json:"startedAt"`
	Viewers     int    `json:"viewers"`
	Thumbnail   string `json:"thumbnail"`
	ChatCount   int64  `json:"chatCount"`
	Recording   bool   `json:"recording"` // false while paused or waiting for a reconnect
	Paused      bool   `json:"paused"`
	Parts       int    `json:"parts"`
}

func (m *Manager) Recordings() []Recording {
	m.mu.Lock()
	defer m.mu.Unlock()
	out := make([]Recording, 0, len(m.sessions))
	for _, s := range m.sessions {
		out = append(out, Recording{
			VodID: s.vod.ID, ChannelID: s.channel.ID, Login: s.channel.Login, DisplayName: s.channel.DisplayName,
			Title: s.title, Category: s.category, StartedAt: s.startedAt.UnixMilli(), Viewers: s.viewers,
			Thumbnail: s.thumbnail, ChatCount: s.chat.Count(), Recording: s.proc != nil, Paused: s.paused, Parts: s.nextPart,
		})
	}
	return out
}

// IsRecording reports whether a VOD belongs to an active session (paused
// ones included).
func (m *Manager) IsRecording(vodID string) bool {
	m.mu.Lock()
	defer m.mu.Unlock()
	for _, s := range m.sessions {
		if s.vod.ID == vodID {
			return true
		}
	}
	return false
}

var ErrNoSession = errors.New("no active recording for this channel")

// Pause stops the running recording of a channel. While the channel stays
// live, Resume appends to the same VOD; if the channel goes offline, the VOD
// is finalized.
func (m *Manager) Pause(channelID string) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	s := m.sessions[channelID]
	if s == nil {
		return ErrNoSession
	}
	s.paused = true
	if s.proc != nil {
		s.proc.stop()
	}
	m.log.Info("recording paused", "channel", s.channel.Login, "vod", s.vod.ID)
	return nil
}

func (m *Manager) Resume(channelID string) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	s := m.sessions[channelID]
	if s == nil {
		return ErrNoSession
	}
	s.paused = false
	s.failures = 0
	s.exitAt = time.Time{}
	m.log.Info("recording resumed by user", "channel", s.channel.Login, "vod", s.vod.ID)
	m.Wake()
	return nil
}

// Finish ends a recording now; the rest of this broadcast is not recorded.
func (m *Manager) Finish(channelID string) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	s := m.sessions[channelID]
	if s == nil {
		return ErrNoSession
	}
	m.skip[channelID] = s.vod.StreamID
	s.paused = true
	if s.proc != nil {
		s.proc.stop()
	} else {
		m.endSession(context.Background(), s)
	}
	m.log.Info("recording finished by user", "channel", s.channel.Login, "vod", s.vod.ID)
	return nil
}
