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

const (
	tokenCheckInterval = 6 * time.Hour
	// recordings that fail this often in a row without any data while the
	// token is in use trigger an early check (a dead token makes streamlink
	// fail with 401 right away)
	tokenSuspectFailures = 3
	tokenRecheckMinGap   = 10 * time.Minute
)

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

// recheckUserToken validates the token early because recordings keep failing
// with it. Rate limited; runs in the background and wakes the poll loop so the
// next attempt goes without the token if it turned out to be invalid.
func (m *Manager) recheckUserToken() {
	m.adMu.Lock()
	if time.Since(m.lastRecheck) < tokenRecheckMinGap {
		m.adMu.Unlock()
		return
	}
	m.lastRecheck = time.Now()
	m.adMu.Unlock()
	m.log.Info("recordings keep failing with TWITCH_USER_OAUTH, checking it now")
	m.wg.Add(1)
	go func() {
		defer m.wg.Done()
		m.checkUserToken(context.Background())
		m.Wake()
	}()
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
