package twitch

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
)

// ErrInvalidToken means Twitch rejected the token (logged out, password
// changed, revoked...). Network problems are reported as other errors.
var ErrInvalidToken = errors.New("token invalid or expired")

type TokenInfo struct {
	Login     string `json:"login"`
	UserID    string `json:"user_id"`
	ExpiresIn int    `json:"expires_in"` // seconds, 0 = no fixed expiry
}

// ValidateUserToken checks a user OAuth token (e.g. the twitch.tv "auth-token"
// cookie used for ad-free recordings).
func (c *Client) ValidateUserToken(ctx context.Context, token string) (TokenInfo, error) {
	req, _ := http.NewRequestWithContext(ctx, http.MethodGet, "https://id.twitch.tv/oauth2/validate", nil)
	req.Header.Set("Authorization", "OAuth "+token)
	resp, err := c.http.Do(req)
	if err != nil {
		return TokenInfo{}, err
	}
	defer resp.Body.Close()
	switch resp.StatusCode {
	case http.StatusOK:
		var ti TokenInfo
		err := json.NewDecoder(resp.Body).Decode(&ti)
		return ti, err
	case http.StatusUnauthorized:
		return TokenInfo{}, ErrInvalidToken
	default:
		return TokenInfo{}, fmt.Errorf("validate token: %s", resp.Status)
	}
}
