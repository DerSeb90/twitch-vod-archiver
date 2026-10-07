package chat

import (
	"bufio"
	"encoding/json"
	"os"
	"sort"
	"strconv"
	"strings"
)

// Message is the replay format served to clients.
type Message struct {
	T      int64    `json:"t"` // offset in video (ms)
	Name   string   `json:"n"`
	Color  string   `json:"c,omitempty"`
	Badges []string `json:"b,omitempty"`
	Text   string   `json:"m"`
	Emotes [][3]any `json:"e,omitempty"` // [emoteId, startRune, endRune]
	System string   `json:"s,omitempty"`
	Action bool     `json:"a,omitempty"`
	Reply  string   `json:"r,omitempty"`
}

// Log is a parsed chat.ndjson.
type Log struct {
	events  []Event // msg/sub only, ordered by TS
	deleted map[string]bool
	bans    map[string][]int64
}

// ReadLog parses a raw chat log. A missing file is an empty log, and an
// unfinished last line (recorder stopped mid-write) is ignored.
func ReadLog(path string) (*Log, error) {
	l := &Log{deleted: map[string]bool{}, bans: map[string][]int64{}}
	f, err := os.Open(path)
	if err != nil {
		if os.IsNotExist(err) {
			return l, nil
		}
		return nil, err
	}
	defer f.Close()
	r := bufio.NewReaderSize(f, 256<<10)
	for {
		line, err := r.ReadBytes('\n')
		if err != nil {
			break // EOF or partial line
		}
		var ev Event
		if json.Unmarshal(line, &ev) != nil {
			continue
		}
		switch ev.Kind {
		case "del":
			l.deleted[ev.ID] = true
		case "ban":
			l.bans[ev.Login] = append(l.bans[ev.Login], ev.TS)
		default:
			l.events = append(l.events, ev)
		}
	}
	return l, nil
}

// Replay converts all events to replay messages on the video timeline.
// mapper turns a wall-clock timestamp into a video offset; ok=false drops
// the message.
func (l *Log) Replay(mapper func(ts int64) (int64, bool)) []Message {
	out := []Message{}
	for _, ev := range l.events {
		t, ok := mapper(ev.TS)
		if !ok || (ev.ID != "" && l.deleted[ev.ID]) || wasBanned(l.bans[strings.ToLower(ev.Login)], ev.TS) {
			continue
		}
		out = append(out, toMessage(ev, t))
	}
	sort.SliceStable(out, func(i, j int) bool { return out[i].T < out[j].T })
	return out
}

func toMessage(ev Event, t int64) Message {
	m := Message{T: t, Name: ev.Name, Color: ev.Color, Text: ev.Text, System: ev.System, Action: ev.Action, Reply: ev.ReplyTo, Emotes: ParseEmotes(ev.Emotes)}
	if ev.Badges != "" {
		m.Badges = strings.Split(ev.Badges, ",")
	}
	return m
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

// ParseEmotes parses the IRC emotes tag: "25:0-4,12-16/1902:6-10".
// Positions are unicode code point indices (inclusive end).
func ParseEmotes(tag string) [][3]any {
	if tag == "" {
		return nil
	}
	var out [][3]any
	for group := range strings.SplitSeq(tag, "/") {
		id, ranges, ok := strings.Cut(group, ":")
		if !ok {
			continue
		}
		for r := range strings.SplitSeq(ranges, ",") {
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
