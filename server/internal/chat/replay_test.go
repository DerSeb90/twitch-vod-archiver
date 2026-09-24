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

func TestLogIncrementalReplay(t *testing.T) {
	p := filepath.Join(t.TempDir(), "chat.ndjson")
	f, _ := os.Create(p)
	enc := json.NewEncoder(f)
	enc.Encode(Event{TS: 1000, Kind: "msg", ID: "a", Login: "u1", Name: "U1", Text: "hi"})
	enc.Encode(Event{TS: 2000, Kind: "msg", ID: "b", Login: "u2", Name: "U2", Text: "gone"})
	enc.Encode(Event{TS: 3000, Kind: "del", ID: "b"})
	f.WriteString(`{"ts":4000,"k":"msg","u":"u3","n":"U3","m":"partial`) // line still being written
	f.Close()

	l := NewLog()
	identity := func(ts int64) (int64, bool) { return ts, true }
	if err := l.Refresh(p); err != nil {
		t.Fatal(err)
	}
	if got := l.Replay(identity, 0, 0); len(got) != 1 || got[0].Name != "U1" {
		t.Fatalf("first replay: %+v", got)
	}
	f, _ = os.OpenFile(p, os.O_APPEND|os.O_WRONLY, 0)
	f.WriteString("\"}\n")
	json.NewEncoder(f).Encode(Event{TS: 9000, Kind: "ban", Login: "u5"})
	json.NewEncoder(f).Encode(Event{TS: 8000, Kind: "msg", Login: "u5", Name: "U5", Text: "banned"})
	f.Close()
	l.Refresh(p)
	got := l.Replay(identity, 0, 0)
	if len(got) != 2 || got[1].Text != "partial" {
		t.Fatalf("after refresh: %+v", got)
	}
	if w := l.Replay(identity, 1500, 5000); len(w) != 1 || w[0].T != 4000 {
		t.Fatalf("window: %+v", w)
	}
}
