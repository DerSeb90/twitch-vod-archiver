package recorder

import (
	"bufio"
	"io"
	"log/slog"
	"os"
	"os/exec"
	"strings"
	"sync"
	"time"

	"github.com/derseb90/twitch-vod-archiver/server/internal/config"
)

type process struct {
	cmd       *exec.Cmd
	started   time.Time
	firstData time.Time // when the first bytes hit the disk (used to sync chat)
	done      chan struct{}
	err       error
	stopOnce  sync.Once
}

// startStreamlink records the best available quality straight into an MPEG-TS
// file. TS is used on purpose: it stays playable even if the process or the
// server dies mid-stream (an unfinished MP4 would be unreadable).
func startStreamlink(cfg *config.Config, userToken, login, out string, log *slog.Logger) (*process, error) {
	args := []string{
		"--loglevel", "info",
		"--force",
		"--stream-segment-threads", "3",
		"--stream-timeout", "90",
		"--retry-open", "3",
		"--hls-live-edge", "4",
		"-o", out,
	}
	if userToken != "" {
		args = append(args, "--twitch-api-header", "Authorization=OAuth "+userToken)
	}
	args = append(args, cfg.StreamlinkArgs...)
	args = append(args, "https://twitch.tv/"+login, cfg.Quality)

	cmd := exec.Command(cfg.StreamlinkPath, args...)
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		return nil, err
	}
	cmd.Stderr = cmd.Stdout
	if err := cmd.Start(); err != nil {
		return nil, err
	}
	p := &process{cmd: cmd, started: time.Now(), done: make(chan struct{})}

	go pipeLog(stdout, log)

	// detect the moment the first data is written
	stopWatch := make(chan struct{})
	watchDone := make(chan struct{})
	go func() {
		defer close(watchDone)
		t := time.NewTicker(250 * time.Millisecond)
		defer t.Stop()
		for {
			select {
			case <-stopWatch:
				return
			case <-t.C:
				if fi, err := os.Stat(out); err == nil && fi.Size() > 0 {
					p.firstData = time.Now()
					return
				}
			}
		}
	}()

	go func() {
		p.err = cmd.Wait()
		close(stopWatch)
		<-watchDone
		if p.firstData.IsZero() {
			if fi, err := os.Stat(out); err == nil && fi.Size() > 0 {
				p.firstData = p.started // tiny part, best effort
			}
		}
		close(p.done)
	}()
	return p, nil
}

// stop asks streamlink to finish writing and exit; kills it after 15s.
func (p *process) stop() {
	p.stopOnce.Do(func() {
		if err := p.cmd.Process.Signal(os.Interrupt); err != nil {
			_ = p.cmd.Process.Kill()
			return
		}
		go func() {
			select {
			case <-p.done:
			case <-time.After(15 * time.Second):
				_ = p.cmd.Process.Kill()
			}
		}()
	})
}

func pipeLog(r io.Reader, log *slog.Logger) {
	sc := bufio.NewScanner(r)
	for sc.Scan() {
		line := strings.TrimSpace(sc.Text())
		if line == "" {
			continue
		}
		switch {
		case strings.Contains(line, "error:"), strings.Contains(line, "[error]"):
			log.Warn("streamlink", "msg", line)
		case strings.Contains(line, "[warning]"):
			log.Info("streamlink", "msg", line)
		default:
			log.Debug("streamlink", "msg", line)
		}
	}
}
