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

func TestToEventHistoryLine(t *testing.T) {
	// format delivered by the recent-messages service
	line := `@badges=partner/1;color=#FF0000;display-name=Torkie;emotes=;id=259f;tmi-sent-ts=1790239335195;historical=1 :torkie!torkie@torkie.tmi.twitch.tv PRIVMSG #summit1g :that hunter was npc`
	ev, ok := toEvent(parse(line), 1790239335195)
	if !ok || ev.Kind != "msg" || ev.Name != "Torkie" || ev.Text != "that hunter was npc" || ev.Badges != "partner/1" {
		t.Fatalf("unexpected %+v", ev)
	}
	if _, ok := toEvent(parse("PING :tmi.twitch.tv"), 0); ok {
		t.Fatal("PING must not become an event")
	}
}
