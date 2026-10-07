package recorder

import (
	"bufio"
	"io"
	"log/slog"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"github.com/derseb90/twitch-vod-archiver/server/internal/config"
)

type process struct {
	sl, ff    *exec.Cmd
	started   time.Time
	firstData time.Time // when the first bytes arrived (used to sync chat)
	done      chan struct{}
	err       error
	stopOnce  sync.Once
}

// startRecording pipes `streamlink --stdout` into ffmpeg, which cuts the
// stream (no re-encode) into 4 s MPEG-TS segments plus an HLS playlist in dir.
// Segments are crash safe: whatever arrived before a crash or disconnect is
// kept and finalized later.
//
// The pipe runs through Go so the arrival of the first byte can be stamped
// precisely; onFirstData is called once with that time.
func startRecording(cfg *config.Config, userToken, login, dir string, log *slog.Logger, onFirstData func(time.Time)) (*process, error) {
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return nil, err
	}
	slArgs := []string{
		"--loglevel", "info",
		"--stream-segment-threads", "3",
		"--stream-timeout", "90",
		"--retry-open", "3",
		"--hls-live-edge", "4",
		"--stdout",
	}
	if userToken != "" {
		slArgs = append(slArgs, "--twitch-api-header", "Authorization=OAuth "+userToken)
	}
	slArgs = append(slArgs, cfg.StreamlinkArgs...)
	slArgs = append(slArgs, "https://twitch.tv/"+login, cfg.Quality)

	ffArgs := []string{
		"-hide_banner", "-loglevel", "warning",
		"-fflags", "+genpts+discardcorrupt",
		"-i", "pipe:0",
		"-map", "0:v:0?", "-map", "0:a:0?", "-c", "copy",
		"-f", "hls",
		"-hls_time", "4",
		"-hls_list_size", "0",
		"-hls_playlist_type", "event",
		"-hls_flags", "independent_segments+temp_file",
		"-hls_segment_filename", filepath.Join(dir, "seg-%05d.ts"),
		filepath.Join(dir, "index.m3u8"),
	}

	// ffmpeg first: streamlink's pipes are only created once it runs (a
	// failed Start closes the pipes of its own command, nothing else)
	ff := exec.Command(cfg.FFmpegPath, ffArgs...)
	ffIn, err := ff.StdinPipe()
	if err != nil {
		return nil, err
	}
	ffStderr, err := ff.StderrPipe()
	if err == nil {
		err = ff.Start()
	}
	if err != nil {
		_ = ffIn.Close()
		return nil, err
	}
	sl := exec.Command(cfg.StreamlinkPath, slArgs...)
	slOut, err := sl.StdoutPipe()
	var slStderr io.ReadCloser
	if err == nil {
		slStderr, err = sl.StderrPipe()
	}
	if err == nil {
		err = sl.Start()
	}
	if err != nil {
		_ = ffIn.Close() // EOF lets ffmpeg exit
		_ = ff.Wait()
		return nil, err
	}
	p := &process{sl: sl, ff: ff, started: time.Now(), done: make(chan struct{})}
	var logs sync.WaitGroup
	logs.Add(2)
	go func() { defer logs.Done(); pipeLog(slStderr, log, "streamlink") }()
	go func() { defer logs.Done(); pipeLog(ffStderr, log, "ffmpeg") }()

	copied := make(chan struct{})
	go func() {
		defer close(copied)
		defer ffIn.Close() // EOF lets ffmpeg finish the playlist cleanly
		buf := make([]byte, 256<<10)
		first := true
		for {
			n, rerr := slOut.Read(buf)
			if n > 0 {
				if first {
					first = false
					p.firstData = time.Now()
					if onFirstData != nil {
						onFirstData(p.firstData)
					}
				}
				if _, werr := ffIn.Write(buf[:n]); werr != nil {
					_ = sl.Process.Kill() // ffmpeg died: stop streamlink as well
					_, _ = io.Copy(io.Discard, slOut)
					return
				}
			}
			if rerr != nil {
				return
			}
		}
	}()

	go func() {
		<-copied
		// Wait closes the stderr pipes: read them to the end first so the last
		// (usually most telling) lines are logged. Bounded, in case a child
		// process keeps a pipe open.
		logged := make(chan struct{})
		go func() { logs.Wait(); close(logged) }()
		select {
		case <-logged:
		case <-time.After(10 * time.Second):
		}
		slErr := sl.Wait()
		ffErr := ff.Wait()
		if slErr != nil {
			p.err = slErr
		} else {
			p.err = ffErr
		}
		close(p.done)
	}()
	return p, nil
}

// stop asks streamlink to exit; ffmpeg then sees EOF and closes the playlist.
// Both are killed if they don't exit within 15 s.
func (p *process) stop() {
	p.stopOnce.Do(func() {
		if err := p.sl.Process.Signal(os.Interrupt); err != nil {
			_ = p.sl.Process.Kill() // Windows cannot send SIGINT to child processes
		}
		go func() {
			select {
			case <-p.done:
			case <-time.After(15 * time.Second):
				_ = p.sl.Process.Kill()
				_ = p.ff.Process.Kill()
			}
		}()
	})
}

func pipeLog(r io.Reader, log *slog.Logger, name string) {
	sc := bufio.NewScanner(r)
	for sc.Scan() {
		line := strings.TrimSpace(sc.Text())
		if line == "" {
			continue
		}
		lower := strings.ToLower(line)
		switch {
		case strings.Contains(lower, "error"):
			log.Warn(name, "msg", line)
		case strings.Contains(lower, "warning"):
			log.Info(name, "msg", line)
		default:
			log.Debug(name, "msg", line)
		}
	}
}
