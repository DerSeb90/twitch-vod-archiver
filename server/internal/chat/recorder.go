// Package chat records Twitch chat anonymously via IRC (no account needed)
// and writes every event as one JSON line with a wall-clock timestamp.
// The finalizer later maps those timestamps onto the video timeline.
package chat

import (
	"bufio"
	"context"
	"crypto/tls"
	"encoding/json"
	"fmt"
	"log/slog"
	"math/rand/v2"
	"net"
	"os"
	"strings"
	"sync/atomic"
	"time"
)

// Event is the raw on-disk format (one per line in chat.ndjson).
type Event struct {
	TS       int64  `json:"ts"`           // unix ms
	Kind     string `json:"k"`            // msg | sub | del | ban
	ID       string `json:"id,omitempty"` // message id (msg) or target id (del)
	Login    string `json:"u,omitempty"`
	Name     string `json:"n,omitempty"`
	Color    string `json:"c,omitempty"`
	Badges   string `json:"b,omitempty"`
	Text     string `json:"m,omitempty"`
	Emotes   string `json:"e,omitempty"`
	System   string `json:"s,omitempty"`
	Action   bool   `json:"a,omitempty"` // /me
	ReplyTo  string `json:"r,omitempty"` // display name of replied-to user
	BanUntil int64  `json:"bu,omitempty"`
}

type Recorder struct {
	channel string
	path    string
	log     *slog.Logger
	count   atomic.Int64
}

func NewRecorder(channel, path string, log *slog.Logger) *Recorder {
	return &Recorder{channel: strings.ToLower(channel), path: path, log: log.With("chat", channel)}
}

func (r *Recorder) Count() int64 { return r.count.Load() }

// Run blocks until ctx is cancelled, reconnecting with backoff on errors.
func (r *Recorder) Run(ctx context.Context) {
	f, err := os.OpenFile(r.path, os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0o644)
	if err != nil {
		r.log.Error("open chat file", "err", err)
		return
	}
	defer f.Close()
	w := bufio.NewWriterSize(f, 64<<10)
	defer w.Flush()
	enc := json.NewEncoder(w)
	enc.SetEscapeHTML(false)

	// flush periodically so a crash loses at most a few seconds of chat
	flushTick := time.NewTicker(5 * time.Second)
	defer flushTick.Stop()
	events := make(chan Event, 1024)
	go func() {
		backoff := time.Second
		for ctx.Err() == nil {
			start := time.Now()
			err := r.session(ctx, events)
			if ctx.Err() != nil {
				return
			}
			if time.Since(start) > time.Minute {
				backoff = time.Second
			}
			r.log.Warn("chat disconnected, reconnecting", "err", err, "in", backoff)
			select {
			case <-ctx.Done():
				return
			case <-time.After(backoff):
			}
			backoff = min(backoff*2, 30*time.Second)
		}
	}()
	for {
		select {
		case <-ctx.Done():
			// drain what is buffered
			for {
				select {
				case ev := <-events:
					_ = enc.Encode(ev)
				default:
					return
				}
			}
		case ev := <-events:
			if err := enc.Encode(ev); err != nil {
				r.log.Error("write chat", "err", err)
			}
			if ev.Kind == "msg" || ev.Kind == "sub" {
				r.count.Add(1)
			}
		case <-flushTick.C:
			_ = w.Flush()
		}
	}
}

func (r *Recorder) session(ctx context.Context, out chan<- Event) error {
	d := &net.Dialer{Timeout: 15 * time.Second, KeepAlive: 30 * time.Second}
	conn, err := tls.DialWithDialer(d, "tcp", "irc.chat.twitch.tv:6697", &tls.Config{ServerName: "irc.chat.twitch.tv"})
	if err != nil {
		return err
	}
	defer conn.Close()
	go func() { <-ctx.Done(); conn.Close() }()

	nick := fmt.Sprintf("justinfan%d", 10000+rand.IntN(80000))
	fmt.Fprintf(conn, "CAP REQ :twitch.tv/tags twitch.tv/commands\r\nPASS SCHMOOPIIE\r\nNICK %s\r\nJOIN #%s\r\n", nick, r.channel)
	r.log.Debug("chat connected")

	sc := bufio.NewScanner(conn)
	sc.Buffer(make([]byte, 64<<10), 1<<20)
	for {
		_ = conn.SetReadDeadline(time.Now().Add(6 * time.Minute)) // server pings every ~5 min
		if !sc.Scan() {
			if err := sc.Err(); err != nil {
				return err
			}
			return fmt.Errorf("connection closed")
		}
		line := sc.Text()
		msg := parse(line)
		switch msg.command {
		case "PING":
			fmt.Fprintf(conn, "PONG :%s\r\n", msg.trailing)
		case "RECONNECT":
			return fmt.Errorf("server requested reconnect")
		case "PRIVMSG":
			ev := Event{
				TS:     time.Now().UnixMilli(),
				Kind:   "msg",
				ID:     msg.tags["id"],
				Login:  msg.nick(),
				Name:   msg.tags["display-name"],
				Color:  msg.tags["color"],
				Badges: msg.tags["badges"],
				Emotes: msg.tags["emotes"],
				Text:   msg.trailing,
			}
			if strings.HasPrefix(ev.Text, "\x01ACTION ") {
				ev.Text = strings.TrimSuffix(strings.TrimPrefix(ev.Text, "\x01ACTION "), "\x01")
				ev.Action = true
			}
			if rp := msg.tags["reply-parent-display-name"]; rp != "" {
				ev.ReplyTo = rp
				// Twitch prefixes replies with "@name "; emote indices include it, so keep text untouched.
			}
			if ev.Name == "" {
				ev.Name = ev.Login
			}
			out <- ev
		case "USERNOTICE":
			out <- Event{
				TS:     time.Now().UnixMilli(),
				Kind:   "sub",
				ID:     msg.tags["id"],
				Login:  msg.tags["login"],
				Name:   msg.tags["display-name"],
				Color:  msg.tags["color"],
				Badges: msg.tags["badges"],
				Emotes: msg.tags["emotes"],
				Text:   msg.trailing,
				System: msg.tags["system-msg"],
			}
		case "CLEARMSG":
			out <- Event{TS: time.Now().UnixMilli(), Kind: "del", ID: msg.tags["target-msg-id"]}
		case "CLEARCHAT":
			if msg.trailing != "" { // timeout/ban of a single user; full clears are ignored
				out <- Event{TS: time.Now().UnixMilli(), Kind: "ban", Login: strings.ToLower(msg.trailing)}
			}
		}
	}
}

// Timestamps use our own clock on purpose: it is the same clock the video
// parts are stamped with (tmi-sent-ts can drift from it by seconds).

type ircMessage struct {
	tags     map[string]string
	prefix   string
	command  string
	params   []string
	trailing string
}

func (m ircMessage) nick() string {
	if i := strings.IndexByte(m.prefix, '!'); i > 0 {
		return m.prefix[:i]
	}
	return m.prefix
}

func parse(line string) ircMessage {
	var m ircMessage
	if strings.HasPrefix(line, "@") {
		sp := strings.IndexByte(line, ' ')
		if sp < 0 {
			return m
		}
		m.tags = parseTags(line[1:sp])
		line = line[sp+1:]
	}
	if strings.HasPrefix(line, ":") {
		sp := strings.IndexByte(line, ' ')
		if sp < 0 {
			return m
		}
		m.prefix = line[1:sp]
		line = line[sp+1:]
	}
	if i := strings.Index(line, " :"); i >= 0 {
		m.trailing = line[i+2:]
		line = line[:i]
	}
	parts := strings.Fields(line)
	if len(parts) > 0 {
		m.command = parts[0]
		m.params = parts[1:]
	}
	if m.tags == nil {
		m.tags = map[string]string{}
	}
	return m
}

var tagUnescape = strings.NewReplacer(`\s`, " ", `\:`, ";", `\\`, `\`, `\r`, "\r", `\n`, "\n")

func parseTags(s string) map[string]string {
	tags := make(map[string]string, 16)
	for _, kv := range strings.Split(s, ";") {
		k, v, _ := strings.Cut(kv, "=")
		tags[k] = tagUnescape.Replace(v)
	}
	return tags
}
