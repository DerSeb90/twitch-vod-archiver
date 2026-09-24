package chat

import "testing"

func TestParse(t *testing.T) {
	m := parse(`@badges=subscriber/12,premium/1;color=#FF0000;display-name=Foo\sBar;emotes=25:0-4;id=abc :foo!foo@foo.tmi.twitch.tv PRIVMSG #chan :Kappa hello`)
	if m.command != "PRIVMSG" || m.nick() != "foo" || m.trailing != "Kappa hello" {
		t.Fatalf("bad parse: %+v", m)
	}
	if m.tags["display-name"] != "Foo Bar" || m.tags["badges"] != "subscriber/12,premium/1" {
		t.Fatalf("bad tags: %v", m.tags)
	}
	if p := parse("PING :tmi.twitch.tv"); p.command != "PING" || p.trailing != "tmi.twitch.tv" {
		t.Fatalf("bad ping: %+v", p)
	}
}
