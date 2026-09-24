// Package twitch talks to the official Helix API using an app access token
// (client credentials flow) plus a few public third-party emote APIs.
package twitch

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strings"
	"sync"
	"time"
)

type Client struct {
	clientID, clientSecret string
	http                   *http.Client

	mu        sync.Mutex
	token     string
	expiresAt time.Time

	gamesMu sync.Mutex
	games   map[string]string // game id -> box art url
}

func New(clientID, clientSecret string) *Client {
	return &Client{
		clientID:     clientID,
		clientSecret: clientSecret,
		http:         &http.Client{Timeout: 20 * time.Second},
		games:        map[string]string{},
	}
}

type User struct {
	ID              string `json:"id"`
	Login           string `json:"login"`
	DisplayName     string `json:"display_name"`
	Description     string `json:"description"`
	ProfileImageURL string `json:"profile_image_url"`
	OfflineImageURL string `json:"offline_image_url"`
}

type Stream struct {
	ID           string    `json:"id"`
	UserID       string    `json:"user_id"`
	UserLogin    string    `json:"user_login"`
	UserName     string    `json:"user_name"`
	GameID       string    `json:"game_id"`
	GameName     string    `json:"game_name"`
	Type         string    `json:"type"`
	Title        string    `json:"title"`
	ViewerCount  int       `json:"viewer_count"`
	StartedAt    time.Time `json:"started_at"`
	ThumbnailURL string    `json:"thumbnail_url"`
}

func (c *Client) accessToken(ctx context.Context, force bool) (string, error) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if !force && c.token != "" && time.Now().Before(c.expiresAt) {
		return c.token, nil
	}
	form := url.Values{
		"client_id":     {c.clientID},
		"client_secret": {c.clientSecret},
		"grant_type":    {"client_credentials"},
	}
	req, _ := http.NewRequestWithContext(ctx, http.MethodPost, "https://id.twitch.tv/oauth2/token", strings.NewReader(form.Encode()))
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	resp, err := c.http.Do(req)
	if err != nil {
		return "", err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		b, _ := io.ReadAll(io.LimitReader(resp.Body, 512))
		return "", fmt.Errorf("twitch token: %s: %s", resp.Status, b)
	}
	var t struct {
		AccessToken string `json:"access_token"`
		ExpiresIn   int    `json:"expires_in"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&t); err != nil {
		return "", err
	}
	c.token = t.AccessToken
	c.expiresAt = time.Now().Add(time.Duration(t.ExpiresIn)*time.Second - 10*time.Minute)
	return c.token, nil
}

func (c *Client) helix(ctx context.Context, path string, q url.Values, out any) error {
	for attempt := 0; attempt < 2; attempt++ {
		tok, err := c.accessToken(ctx, attempt > 0)
		if err != nil {
			return err
		}
		req, _ := http.NewRequestWithContext(ctx, http.MethodGet, "https://api.twitch.tv/helix/"+path+"?"+q.Encode(), nil)
		req.Header.Set("Client-Id", c.clientID)
		req.Header.Set("Authorization", "Bearer "+tok)
		resp, err := c.http.Do(req)
		if err != nil {
			return err
		}
		if resp.StatusCode == http.StatusUnauthorized && attempt == 0 {
			resp.Body.Close()
			continue
		}
		defer resp.Body.Close()
		if resp.StatusCode != http.StatusOK {
			b, _ := io.ReadAll(io.LimitReader(resp.Body, 512))
			return fmt.Errorf("helix %s: %s: %s", path, resp.Status, b)
		}
		return json.NewDecoder(resp.Body).Decode(out)
	}
	return fmt.Errorf("helix %s: unauthorized", path)
}

func (c *Client) UsersByLogin(ctx context.Context, logins []string) ([]User, error) {
	var all []User
	for _, batch := range chunks(logins, 100) {
		q := url.Values{}
		for _, l := range batch {
			q.Add("login", strings.ToLower(l))
		}
		var r struct{ Data []User }
		if err := c.helix(ctx, "users", q, &r); err != nil {
			return nil, err
		}
		all = append(all, r.Data...)
	}
	return all, nil
}

func (c *Client) UsersByID(ctx context.Context, ids []string) ([]User, error) {
	var all []User
	for _, batch := range chunks(ids, 100) {
		q := url.Values{}
		for _, id := range batch {
			q.Add("id", id)
		}
		var r struct{ Data []User }
		if err := c.helix(ctx, "users", q, &r); err != nil {
			return nil, err
		}
		all = append(all, r.Data...)
	}
	return all, nil
}

// LiveStreams returns live streams keyed by user id.
func (c *Client) LiveStreams(ctx context.Context, userIDs []string) (map[string]Stream, error) {
	out := map[string]Stream{}
	for _, batch := range chunks(userIDs, 100) {
		q := url.Values{"type": {"live"}, "first": {"100"}}
		for _, id := range batch {
			q.Add("user_id", id)
		}
		var r struct{ Data []Stream }
		if err := c.helix(ctx, "streams", q, &r); err != nil {
			return nil, err
		}
		for _, s := range r.Data {
			if s.Type == "live" {
				out[s.UserID] = s
			}
		}
	}
	return out, nil
}

// BoxArt returns a box art URL (285x380) for a game id, cached in memory.
func (c *Client) BoxArt(ctx context.Context, gameID string) string {
	if gameID == "" {
		return ""
	}
	c.gamesMu.Lock()
	if u, ok := c.games[gameID]; ok {
		c.gamesMu.Unlock()
		return u
	}
	c.gamesMu.Unlock()
	var r struct {
		Data []struct {
			BoxArtURL string `json:"box_art_url"`
		}
	}
	if err := c.helix(ctx, "games", url.Values{"id": {gameID}}, &r); err != nil || len(r.Data) == 0 {
		return ""
	}
	u := strings.NewReplacer("{width}", "285", "{height}", "380").Replace(r.Data[0].BoxArtURL)
	c.gamesMu.Lock()
	c.games[gameID] = u
	c.gamesMu.Unlock()
	return u
}

// Badges returns "set/version" -> image url for global plus channel badges.
func (c *Client) Badges(ctx context.Context, broadcasterID string) (map[string]string, error) {
	type badgeResp struct {
		Data []struct {
			SetID    string `json:"set_id"`
			Versions []struct {
				ID       string `json:"id"`
				Image2x  string `json:"image_url_2x"`
				Image1x  string `json:"image_url_1x"`
				ImageURL string `json:"image_url_4x"`
			} `json:"versions"`
		}
	}
	out := map[string]string{}
	add := func(r badgeResp) {
		for _, set := range r.Data {
			for _, v := range set.Versions {
				out[set.SetID+"/"+v.ID] = v.Image2x
			}
		}
	}
	var global, channel badgeResp
	if err := c.helix(ctx, "chat/badges/global", url.Values{}, &global); err != nil {
		return nil, err
	}
	add(global)
	if err := c.helix(ctx, "chat/badges", url.Values{"broadcaster_id": {broadcasterID}}, &channel); err == nil {
		add(channel) // channel badges override global ones (custom sub badges)
	}
	return out, nil
}

// Download fetches an arbitrary URL (avatars etc.).
func (c *Client) Download(ctx context.Context, rawURL string) ([]byte, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, rawURL, nil)
	if err != nil {
		return nil, err
	}
	resp, err := c.http.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("download %s: %s", rawURL, resp.Status)
	}
	return io.ReadAll(io.LimitReader(resp.Body, 20<<20))
}

func chunks(in []string, n int) [][]string {
	var out [][]string
	for len(in) > 0 {
		k := min(n, len(in))
		out = append(out, in[:k])
		in = in[k:]
	}
	return out
}
