package finalize

import (
	"compress/gzip"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"

	"github.com/derseb90/twitch-vod-archiver/server/internal/chat"
	"github.com/derseb90/twitch-vod-archiver/server/internal/hls"
)

const activityBucketMs = 30_000

// chat converts the raw ndjson log into time-bucketed gzip chunks and returns
// the number of messages written.
func (f *Finalizer) chat(rawPath string, parts []hls.Part, dir string) (int, error) {
	log := chat.NewLog()
	if err := log.Refresh(rawPath); err != nil {
		return 0, err
	}
	msgs := log.Replay(func(ts int64) (int64, bool) { return hls.Map(parts, ts, hls.MaxChatGap) }, 0, 0)
	return len(msgs), f.writeChunks(dir, msgs, hls.TotalMs(parts))
}

func (f *Finalizer) writeChunks(dir string, msgs []chat.Message, totalMs int64) error {
	chunkMs := f.cfg.ChatChunk.Milliseconds()
	n := int(totalMs/chunkMs) + 1
	buckets := make([][]chat.Message, n)
	activity := make([]int, int(totalMs/activityBucketMs)+1)
	for _, m := range msgs {
		if m.T > totalMs {
			m.T = totalMs // messages after the last frame
		}
		i := min(int(m.T/chunkMs), n-1)
		buckets[i] = append(buckets[i], m)
		activity[min(int(m.T/activityBucketMs), len(activity)-1)]++
	}
	for i, b := range buckets {
		if b == nil {
			b = []chat.Message{}
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
