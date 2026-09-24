package recorder

import (
	"context"
	"errors"
	"time"

	"github.com/derseb90/twitch-vod-archiver/server/internal/twitch"
)

// AdFree reports the state of the optional TWITCH_USER_OAUTH token.
type AdFree struct {
	Configured bool   `json:"configured"`
	Valid      bool   `json:"valid"`
	Login      string `json:"login,omitempty"`
	CheckedAt  int64  `json:"checkedAt,omitempty"`
	Error      string `json:"error,omitempty"`
}

const tokenCheckInterval = 6 * time.Hour

// checkUserToken validates TWITCH_USER_OAUTH. An invalid token is dropped from
// streamlink calls: Twitch answers requests carrying a dead token with 401,
// which would make every recording fail. Without it we still record, only with
// ad breaks cut out.
func (m *Manager) checkUserToken(ctx context.Context) {
	if m.cfg.TwitchUserOAuth == "" {
		return
	}
	cctx, cancel := context.WithTimeout(ctx, 15*time.Second)
	defer cancel()
	ti, err := m.tw.ValidateUserToken(cctx, m.cfg.TwitchUserOAuth)

	m.adMu.Lock()
	defer m.adMu.Unlock()
	was := m.adFree.Valid
	switch {
	case err == nil:
		m.adFree = AdFree{Configured: true, Valid: true, Login: ti.Login, CheckedAt: time.Now().UnixMilli()}
		if !was {
			m.log.Info("ad-free token valid", "login", ti.Login)
		}
	case errors.Is(err, twitch.ErrInvalidToken):
		m.adFree = AdFree{Configured: true, Valid: false, CheckedAt: time.Now().UnixMilli(), Error: err.Error()}
		m.log.Warn("TWITCH_USER_OAUTH is invalid or expired - recording WITHOUT it (ads are cut out). Put a fresh auth-token into .env and restart.")
	default:
		// network trouble: keep the last known state
		m.adFree.Error = err.Error()
		m.log.Warn("could not validate TWITCH_USER_OAUTH", "err", err)
	}
}

// userToken returns the token to hand to streamlink ("" = none).
func (m *Manager) userToken() string {
	m.adMu.Lock()
	defer m.adMu.Unlock()
	if m.cfg.TwitchUserOAuth == "" || (m.adFree.CheckedAt > 0 && !m.adFree.Valid) {
		return ""
	}
	return m.cfg.TwitchUserOAuth
}

func (m *Manager) AdFree() AdFree {
	m.adMu.Lock()
	defer m.adMu.Unlock()
	a := m.adFree
	a.Configured = m.cfg.TwitchUserOAuth != ""
	return a
}
