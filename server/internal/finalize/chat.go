package finalize

import (
	"bufio"
	"compress/gzip"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"

	"github.com/derseb90/twitch-vod-archiver/server/internal/chat"
)

// ChatMessage is the replay format served to clients.
type ChatMessage struct {
	T      int64      `json:"t"` // offset in video (ms)
	Name   string     `json:"n"`
	Color  string     `json:"c,omitempty"`
	Badges []string   `json:"b,omitempty"`
	Text   string     `json:"m"`
	Emotes [][3]any   `json:"e,omitempty"` // [emoteId, startRune, endRune]
	System string     `json:"s,omitempty"`
	Action bool       `json:"a,omitempty"`
	Reply  string     `json:"r,omitempty"`
}

const activityBucketMs = 30_000

// chat converts the raw ndjson log into time-bucketed gzip chunks and returns
// the number of messages written.
func (f *Finalizer) chat(rawPath string, parts []partInfo, dir string) (int, error) {
	file, err := os.Open(rawPath)
	if err != nil {
		if os.IsNotExist(err) {
			return 0, f.writeChunks(dir, nil, parts)
		}
		return 0, err
	}
	defer file.Close()

	var events []chat.Event
	deleted := map[string]bool{}
	bans := map[string][]int64{}
	sc := bufio.NewScanner(file)
	sc.Buffer(make([]byte, 64<<10), 1<<20)
	for sc.Scan() {
		var ev chat.Event
		if json.Unmarshal(sc.Bytes(), &ev) != nil {
			continue // tolerate a truncated last line after a crash
		}
		switch ev.Kind {
		case "del":
			deleted[ev.ID] = true
		case "ban":
			bans[ev.Login] = append(bans[ev.Login], ev.TS)
		default:
			events = append(events, ev)
		}
	}
	if err := sc.Err(); err != nil {
		return 0, err
	}

	msgs := make([]ChatMessage, 0, len(events))
	for _, ev := range events {
		if ev.ID != "" && deleted[ev.ID] {
			continue
		}
		if wasBanned(bans[strings.ToLower(ev.Login)], ev.TS) {
			continue
		}
		m := ChatMessage{
			T:      mapTime(parts, ev.TS),
			Name:   ev.Name,
			Color:  ev.Color,
			Text:   ev.Text,
			System: ev.System,
			Action: ev.Action,
			Reply:  ev.ReplyTo,
			Emotes: parseEmotes(ev.Emotes),
		}
		if ev.Badges != "" {
			m.Badges = strings.Split(ev.Badges, ",")
		}
		msgs = append(msgs, m)
	}
	sort.SliceStable(msgs, func(i, j int) bool { return msgs[i].T < msgs[j].T })
	return len(msgs), f.writeChunks(dir, msgs, parts)
}

// a timeout/ban hides the user's messages from the ten minutes before it
func wasBanned(banTimes []int64, ts int64) bool {
	for _, b := range banTimes {
		if b >= ts && b-ts < 10*60*1000 {
			return true
		}
	}
	return false
}

func (f *Finalizer) writeChunks(dir string, msgs []ChatMessage, parts []partInfo) error {
	chunkMs := f.cfg.ChatChunk.Milliseconds()
	var totalMs int64
	for _, p := range parts {
		totalMs += p.durMs
	}
	n := int(totalMs/chunkMs) + 1
	buckets := make([][]ChatMessage, n)
	activity := make([]int, int(totalMs/activityBucketMs)+1)
	for _, m := range msgs {
		i := min(int(m.T/chunkMs), n-1)
		buckets[i] = append(buckets[i], m)
		activity[min(int(m.T/activityBucketMs), len(activity)-1)]++
	}
	for i, b := range buckets {
		if b == nil {
			b = []ChatMessage{}
		}
		if err := writeGzipJSON(filepath.Join(dir, fmt.Sprintf("%04d.json.gz", i)), b); err != nil {
			return err
		}
	}
	a, _ := json.Marshal(map[string]any{"bucketMs": activityBucketMs, "counts": activity})
	return os.WriteFile(filepath.Join(dir, "activity.json"), a, 0o644)
}

func writeGzipJSON(p string, v any) error {
	f, err := os.Create(p)
	if err != nil {
		return err
	}
	zw, _ := gzip.NewWriterLevel(f, gzip.BestCompression)
	enc := json.NewEncoder(zw)
	enc.SetEscapeHTML(false)
	if err := enc.Encode(v); err != nil {
		f.Close()
		return err
	}
	if err := zw.Close(); err != nil {
		f.Close()
		return err
	}
	return f.Close()
}

// parseEmotes parses the IRC emotes tag: "25:0-4,12-16/1902:6-10".
// Positions are unicode code point indices (inclusive end).
func parseEmotes(tag string) [][3]any {
	if tag == "" {
		return nil
	}
	var out [][3]any
	for _, group := range strings.Split(tag, "/") {
		id, ranges, ok := strings.Cut(group, ":")
		if !ok {
			continue
		}
		for _, r := range strings.Split(ranges, ",") {
			a, b, ok := strings.Cut(r, "-")
			if !ok {
				continue
			}
			s, err1 := strconv.Atoi(a)
			e, err2 := strconv.Atoi(b)
			if err1 == nil && err2 == nil {
				out = append(out, [3]any{id, s, e})
			}
		}
	}
	sort.Slice(out, func(i, j int) bool { return out[i][1].(int) < out[j][1].(int) })
	return out
}
