// Package config loads all runtime settings from environment variables.
// Nothing secret is ever hard-coded; see deploy/.env.example.
package config

import (
	"errors"
	"fmt"
	"net/url"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"
)

type Config struct {
	HTTPAddr string
	AppName  string

	DataDir       string // SQLite database (local disk)
	RecordingsDir string // temporary .ts parts + raw chat (local disk)
	ArchiveDir    string // finished VODs (Storage Box via SMB)
	WebDir        string // Flutter web build

	TwitchClientID     string
	TwitchClientSecret string
	TwitchUserOAuth    string // optional: OAuth token of a Turbo/sub account -> no ads

	SeedChannels []string

	MaxConcurrent   int
	PollInterval    time.Duration
	OfflineGrace    time.Duration
	Quality         string
	StreamlinkPath  string
	StreamlinkArgs  []string
	FFmpegPath      string
	FFprobePath     string
	FinalizeWorkers int
	MinFreeGB       float64

	ChatChunk          time.Duration
	StoryboardInterval time.Duration
	ThirdPartyEmotes   bool
	ChatHistory        bool

	AdminToken string
	// CORSOrigins may call mutating endpoints from another origin (e.g. the
	// Flutter dev server); everything else is limited to the server's own origin.
	CORSOrigins []string
	LogLevel    string
	LogFormat   string
}

func Load() (*Config, error) {
	c := &Config{
		HTTPAddr:           env("HTTP_ADDR", ":8080"),
		AppName:            env("APP_NAME", "Rewind"),
		DataDir:            env("DATA_DIR", "/data"),
		RecordingsDir:      env("RECORDINGS_DIR", "/recordings"),
		ArchiveDir:         env("ARCHIVE_DIR", "/archive"),
		WebDir:             env("WEB_DIR", "/app/web"),
		TwitchClientID:     os.Getenv("TWITCH_CLIENT_ID"),
		TwitchClientSecret: os.Getenv("TWITCH_CLIENT_SECRET"),
		TwitchUserOAuth:    strings.TrimPrefix(os.Getenv("TWITCH_USER_OAUTH"), "oauth:"),
		SeedChannels:       list(os.Getenv("CHANNELS")),
		Quality:            env("QUALITY", "best"),
		StreamlinkPath:     env("STREAMLINK_PATH", "streamlink"),
		StreamlinkArgs:     strings.Fields(os.Getenv("STREAMLINK_ARGS")),
		FFmpegPath:         env("FFMPEG_PATH", "ffmpeg"),
		FFprobePath:        env("FFPROBE_PATH", "ffprobe"),
		AdminToken:         os.Getenv("ADMIN_TOKEN"),
		LogLevel:           env("LOG_LEVEL", "info"),
		LogFormat:          env("LOG_FORMAT", "text"),
	}
	var errs []error
	c.MaxConcurrent = intEnv("MAX_CONCURRENT", 3, &errs)
	c.FinalizeWorkers = intEnv("FINALIZE_WORKERS", 1, &errs)
	c.PollInterval = durEnv("POLL_INTERVAL", 30*time.Second, &errs)
	c.OfflineGrace = durEnv("OFFLINE_GRACE", 10*time.Minute, &errs)
	c.ChatChunk = durEnv("CHAT_CHUNK", 5*time.Minute, &errs)
	c.StoryboardInterval = durEnv("STORYBOARD_INTERVAL", 20*time.Second, &errs)
	c.ThirdPartyEmotes = boolEnv("THIRD_PARTY_EMOTES", true, &errs)
	c.ChatHistory = boolEnv("CHAT_HISTORY", true, &errs)
	if v := os.Getenv("MIN_FREE_GB"); v != "" {
		f, err := strconv.ParseFloat(v, 64)
		if err != nil {
			errs = append(errs, fmt.Errorf("MIN_FREE_GB: %w", err))
		}
		c.MinFreeGB = f
	} else {
		c.MinFreeGB = 15
	}

	for _, o := range strings.Split(os.Getenv("CORS_ORIGINS"), ",") {
		if o = strings.TrimSpace(o); o == "" {
			continue
		}
		u, err := url.Parse(o)
		if err != nil || (u.Scheme != "http" && u.Scheme != "https") || u.Host == "" || strings.Trim(u.Path, "/") != "" || u.RawQuery != "" {
			errs = append(errs, fmt.Errorf("CORS_ORIGINS: %q is not an origin like http://localhost:5173", o))
			continue
		}
		c.CORSOrigins = append(c.CORSOrigins, strings.ToLower(u.Scheme+"://"+u.Host))
	}

	// the finalizer deletes leftovers in RECORDINGS_DIR, the API serves all of ARCHIVE_DIR
	dirs := [][2]string{{"DATA_DIR", c.DataDir}, {"RECORDINGS_DIR", c.RecordingsDir}, {"ARCHIVE_DIR", c.ArchiveDir}}
	for i, a := range dirs {
		for _, b := range dirs[i+1:] {
			if overlaps(a[1], b[1]) {
				errs = append(errs, fmt.Errorf("%s (%s) and %s (%s) must be separate folders, neither inside the other", a[0], a[1], b[0], b[1]))
			}
		}
	}

	if c.TwitchClientID == "" || c.TwitchClientSecret == "" {
		errs = append(errs, errors.New("TWITCH_CLIENT_ID and TWITCH_CLIENT_SECRET are required (https://dev.twitch.tv/console/apps)"))
	}
	if c.MaxConcurrent < 1 {
		errs = append(errs, errors.New("MAX_CONCURRENT must be >= 1"))
	}
	if c.FinalizeWorkers < 1 {
		c.FinalizeWorkers = 1
	}
	if c.PollInterval < 10*time.Second {
		c.PollInterval = 10 * time.Second
	}
	if c.ChatChunk < time.Minute {
		c.ChatChunk = time.Minute
	}
	return c, errors.Join(errs...)
}

// overlaps reports whether a and b are the same directory or one contains the other.
func overlaps(a, b string) bool {
	a, errA := filepath.Abs(a)
	b, errB := filepath.Abs(b)
	if errA != nil || errB != nil {
		return false
	}
	within := func(dir, p string) bool {
		rel, err := filepath.Rel(dir, p)
		return err == nil && (rel == "." || filepath.IsLocal(rel))
	}
	return within(a, b) || within(b, a)
}

func env(key, def string) string {
	if v, ok := os.LookupEnv(key); ok && strings.TrimSpace(v) != "" {
		return strings.TrimSpace(v)
	}
	return def
}

func list(v string) []string {
	var out []string
	for _, s := range strings.FieldsFunc(v, func(r rune) bool { return r == ',' || r == ' ' || r == ';' }) {
		if s = strings.ToLower(strings.TrimSpace(s)); s != "" {
			out = append(out, s)
		}
	}
	return out
}

func intEnv(key string, def int, errs *[]error) int {
	v := os.Getenv(key)
	if v == "" {
		return def
	}
	n, err := strconv.Atoi(v)
	if err != nil {
		*errs = append(*errs, fmt.Errorf("%s: %w", key, err))
		return def
	}
	return n
}

func durEnv(key string, def time.Duration, errs *[]error) time.Duration {
	v := os.Getenv(key)
	if v == "" {
		return def
	}
	d, err := time.ParseDuration(v)
	if err != nil {
		*errs = append(*errs, fmt.Errorf("%s: %w", key, err))
		return def
	}
	return d
}

func boolEnv(key string, def bool, errs *[]error) bool {
	v := os.Getenv(key)
	if v == "" {
		return def
	}
	b, err := strconv.ParseBool(v)
	if err != nil {
		*errs = append(*errs, fmt.Errorf("%s: %w", key, err))
		return def
	}
	return b
}
