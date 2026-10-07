package chat

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
)

func TestParseEmotes(t *testing.T) {
	got := ParseEmotes("1902:6-10/25:0-4,12-16")
	if len(got) != 3 || got[0][0] != "25" || got[0][1] != 0 || got[1][0] != "1902" || got[2][1] != 12 {
		t.Fatalf("unexpected %v", got)
	}
	if ParseEmotes("") != nil {
		t.Fatal("empty tag should give nil")
	}
}

func TestLogReplay(t *testing.T) {
	p := filepath.Join(t.TempDir(), "chat.ndjson")
	f, _ := os.Create(p)
	enc := json.NewEncoder(f)
	enc.Encode(Event{TS: 1000, Kind: "msg", ID: "a", Login: "u1", Name: "U1", Text: "hi"})
	enc.Encode(Event{TS: 2000, Kind: "msg", ID: "b", Login: "u2", Name: "U2", Text: "gone"})
	enc.Encode(Event{TS: 3000, Kind: "del", ID: "b"})
	enc.Encode(Event{TS: 9000, Kind: "ban", Login: "u5"})
	enc.Encode(Event{TS: 8000, Kind: "msg", Login: "u5", Name: "U5", Text: "banned"})
	enc.Encode(Event{TS: 4000, Kind: "msg", Login: "u3", Name: "U3", Text: "late"})
	f.WriteString(`{"ts":5000,"k":"msg","u":"u4","n":"U4","m":"cut off`) // recorder stopped mid-write
	f.Close()

	l, err := ReadLog(p)
	if err != nil {
		t.Fatal(err)
	}
	got := l.Replay(func(ts int64) (int64, bool) { return ts, true })
	if len(got) != 2 || got[0].Name != "U1" || got[1].Text != "late" {
		t.Fatalf("replay: %+v", got)
	}
	if got := l.Replay(func(ts int64) (int64, bool) { return ts, ts < 2000 }); len(got) != 1 {
		t.Fatalf("mapper drops: %+v", got)
	}
	if l, err := ReadLog(filepath.Join(t.TempDir(), "missing.ndjson")); err != nil || len(l.Replay(func(ts int64) (int64, bool) { return ts, true })) != 0 {
		t.Fatalf("missing log: %v", err)
	}
}
