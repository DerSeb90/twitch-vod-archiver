package store

import (
	"context"
	"errors"
	"path/filepath"
	"testing"
	"time"
)

func TestProgress(t *testing.T) {
	ctx := context.Background()
	s, err := Open(filepath.Join(t.TempDir(), "t.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	if err := s.UpsertChannel(ctx, Channel{ID: "c1", Login: "c1", DisplayName: "C1"}); err != nil {
		t.Fatal(err)
	}
	for i, id := range []string{"a", "b", "c"} {
		if err := s.CreateVod(ctx, Vod{ID: id, ChannelID: "c1", StartedAt: int64(i), Status: StatusReady}); err != nil {
			t.Fatal(err)
		}
	}
	ids := func(f VodFilter) []string {
		t.Helper()
		vs, total, err := s.Vods(ctx, f)
		if err != nil {
			t.Fatal(err)
		}
		if total != len(vs) {
			t.Fatalf("total %d != %d", total, len(vs))
		}
		out := []string{}
		for _, v := range vs {
			out = append(out, v.ID)
		}
		return out
	}

	if err := s.SetProgress(ctx, "missing", 1, false); !errors.Is(err, ErrNotFound) {
		t.Fatalf("unknown vod: %v", err)
	}
	must := func(err error) {
		t.Helper()
		if err != nil {
			t.Fatal(err)
		}
	}
	must(s.SetProgress(ctx, "a", 60000, false))
	must(s.SetProgress(ctx, "b", 5000, false)) // below MinResumeMs: not "in progress"
	must(s.SetProgress(ctx, "c", 90000, false))
	must(s.SetProgress(ctx, "a", 70000, false)) // most recent

	if got := ids(VodFilter{InProgress: true}); len(got) != 2 || got[0] != "a" || got[1] != "c" {
		t.Fatalf("in progress: %v", got)
	}
	v, err := s.Vod(ctx, "a")
	must(err)
	if v.PositionMs != 70000 || v.Watched || v.ProgressAt == 0 {
		t.Fatalf("vod a: %+v", v)
	}

	must(s.SetProgress(ctx, "c", 123456, true))
	v, _ = s.Vod(ctx, "c")
	if !v.Watched || v.PositionMs != 0 {
		t.Fatalf("watched vod c: %+v", v)
	}
	if got := ids(VodFilter{Unwatched: true}); len(got) != 2 || got[0] != "b" || got[1] != "a" {
		t.Fatalf("unwatched: %v", got)
	}
	if got := ids(VodFilter{InProgress: true}); len(got) != 1 || got[0] != "a" {
		t.Fatalf("in progress after watched: %v", got)
	}

	must(s.ClearProgress(ctx, "c"))
	if got := ids(VodFilter{Unwatched: true}); len(got) != 3 {
		t.Fatalf("after clear: %v", got)
	}

	// progress goes away with the VOD
	must(s.DeleteVod(ctx, "a"))
	if got := ids(VodFilter{InProgress: true}); len(got) != 0 {
		t.Fatalf("after delete: %v", got)
	}
}

func TestChanges(t *testing.T) {
	ctx := context.Background()
	s, err := Open(filepath.Join(t.TempDir(), "t.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	st := s.Changes.Wait(ctx, 0, time.Second) // unknown seq: immediate
	if st.Seq == 0 || st.Vods != st.Seq {
		t.Fatalf("initial state %+v", st)
	}

	// nothing happens: returns after the timeout with the same seq
	t0 := time.Now()
	if got := s.Changes.Wait(ctx, st.Seq, 50*time.Millisecond); got.Seq != st.Seq || time.Since(t0) < 50*time.Millisecond {
		t.Fatalf("idle wait: %+v after %v", got, time.Since(t0))
	}

	// a write wakes a waiting client right away
	done := make(chan ChangeState)
	go func() { done <- s.Changes.Wait(ctx, st.Seq, 10*time.Second) }()
	time.Sleep(20 * time.Millisecond)
	if err := s.UpsertChannel(ctx, Channel{ID: "c1", Login: "c1", DisplayName: "C1"}); err != nil {
		t.Fatal(err)
	}
	select {
	case got := <-done:
		if got.Seq <= st.Seq || got.Vods != got.Seq {
			t.Fatalf("after channel: %+v", got)
		}
		st = got
	case <-time.After(2 * time.Second):
		t.Fatal("waiter not woken")
	}

	// progress changes bump seq but not the VOD lists
	if err := s.CreateVod(ctx, Vod{ID: "a", ChannelID: "c1", Status: StatusReady}); err != nil {
		t.Fatal(err)
	}
	st = s.Changes.Wait(ctx, 0, 0)
	since := st.Now
	if err := s.SetProgress(ctx, "a", 42000, false); err != nil {
		t.Fatal(err)
	}
	got := s.Changes.Wait(ctx, st.Seq, 0)
	if got.Seq != st.Seq+1 || got.Vods != st.Vods {
		t.Fatalf("progress bump: %+v -> %+v", st, got)
	}
	ps, err := s.ProgressSince(ctx, since)
	if err != nil || len(ps) != 1 || ps[0].VodID != "a" || ps[0].PositionMs != 42000 {
		t.Fatalf("progress since: %+v %v", ps, err)
	}

	// unwatching keeps a row, so other clients see it
	if err := s.ClearProgress(ctx, "a"); err != nil {
		t.Fatal(err)
	}
	ps, _ = s.ProgressSince(ctx, since)
	if len(ps) != 1 || ps[0].PositionMs != 0 || ps[0].Watched {
		t.Fatalf("after clear: %+v", ps)
	}
}
