package twitch

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"sync"
)

// ThirdPartyEmotes fetches global and channel emotes from 7TV, BTTV and FFZ.
// The result maps emote code -> image url. Failures of single providers are
// ignored: a missing provider must never break a recording.
func (c *Client) ThirdPartyEmotes(ctx context.Context, twitchUserID string) map[string]string {
	type src struct {
		prio int
		m    map[string]string
	}
	var (
		mu      sync.Mutex
		results []src
		wg      sync.WaitGroup
	)
	run := func(prio int, fn func() (map[string]string, error)) {
		wg.Add(1)
		go func() {
			defer wg.Done()
			m, err := fn()
			if err != nil || len(m) == 0 {
				return
			}
			mu.Lock()
			results = append(results, src{prio, m})
			mu.Unlock()
		}()
	}
	// lower prio is applied first, higher prio overrides (channel > global, 7TV > BTTV > FFZ)
	run(0, c.ffzGlobal)
	run(1, c.bttvGlobal)
	run(2, c.sevenTVGlobal)
	run(3, func() (map[string]string, error) { return c.ffzChannel(twitchUserID) })
	run(4, func() (map[string]string, error) { return c.bttvChannel(twitchUserID) })
	run(5, func() (map[string]string, error) { return c.sevenTVChannel(twitchUserID) })
	wg.Wait()

	out := map[string]string{}
	for p := 0; p <= 5; p++ {
		for _, r := range results {
			if r.prio == p {
				for k, v := range r.m {
					out[k] = v
				}
			}
		}
	}
	return out
}

func (c *Client) getJSON(url string, out any) error {
	resp, err := c.http.Get(url)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("%s: %s", url, resp.Status)
	}
	return json.NewDecoder(resp.Body).Decode(out)
}

type sevenTVSet struct {
	Emotes []struct {
		ID   string `json:"id"`
		Name string `json:"name"`
	} `json:"emotes"`
}

func sevenTVMap(s sevenTVSet) map[string]string {
	m := map[string]string{}
	for _, e := range s.Emotes {
		m[e.Name] = "https://cdn.7tv.app/emote/" + e.ID + "/2x.webp"
	}
	return m
}

func (c *Client) sevenTVGlobal() (map[string]string, error) {
	var s sevenTVSet
	if err := c.getJSON("https://7tv.io/v3/emote-sets/global", &s); err != nil {
		return nil, err
	}
	return sevenTVMap(s), nil
}

func (c *Client) sevenTVChannel(id string) (map[string]string, error) {
	var r struct {
		EmoteSet sevenTVSet `json:"emote_set"`
	}
	if err := c.getJSON("https://7tv.io/v3/users/twitch/"+id, &r); err != nil {
		return nil, err
	}
	return sevenTVMap(r.EmoteSet), nil
}

type bttvEmote struct {
	ID   string `json:"id"`
	Code string `json:"code"`
}

func bttvMap(list ...[]bttvEmote) map[string]string {
	m := map[string]string{}
	for _, l := range list {
		for _, e := range l {
			m[e.Code] = "https://cdn.betterttv.net/emote/" + e.ID + "/2x"
		}
	}
	return m
}

func (c *Client) bttvGlobal() (map[string]string, error) {
	var l []bttvEmote
	if err := c.getJSON("https://api.betterttv.net/3/cached/emotes/global", &l); err != nil {
		return nil, err
	}
	return bttvMap(l), nil
}

func (c *Client) bttvChannel(id string) (map[string]string, error) {
	var r struct {
		ChannelEmotes []bttvEmote `json:"channelEmotes"`
		SharedEmotes  []bttvEmote `json:"sharedEmotes"`
	}
	if err := c.getJSON("https://api.betterttv.net/3/cached/users/twitch/"+id, &r); err != nil {
		return nil, err
	}
	return bttvMap(r.ChannelEmotes, r.SharedEmotes), nil
}

type ffzSets struct {
	DefaultSets []int `json:"default_sets"`
	Sets        map[string]struct {
		Emoticons []struct {
			Name string            `json:"name"`
			URLs map[string]string `json:"urls"`
		} `json:"emoticons"`
	} `json:"sets"`
}

func ffzMap(r ffzSets) map[string]string {
	m := map[string]string{}
	for _, set := range r.Sets {
		for _, e := range set.Emoticons {
			u := e.URLs["2"]
			if u == "" {
				u = e.URLs["1"]
			}
			if u != "" {
				m[e.Name] = u
			}
		}
	}
	return m
}

func (c *Client) ffzGlobal() (map[string]string, error) {
	var r ffzSets
	if err := c.getJSON("https://api.frankerfacez.com/v1/set/global", &r); err != nil {
		return nil, err
	}
	return ffzMap(r), nil
}

func (c *Client) ffzChannel(id string) (map[string]string, error) {
	var r ffzSets
	if err := c.getJSON("https://api.frankerfacez.com/v1/room/id/"+id, &r); err != nil {
		return nil, err
	}
	return ffzMap(r), nil
}
