package config

import (
	"fmt"
	"os"
	"strconv"
	"strings"
	"time"
)

type Config struct {
	Port            string
	WebhookToken    string
	GeminiAssistant string
	DriveFolderID   string
	SlackWebhookURL string
	MaxBodyBytes    int64
	QueueSize       int
	Workers         int
	UpstreamTimeout time.Duration
}

func Load() (Config, error) {
	c := Config{
		Port:            value("PORT", "8080"),
		WebhookToken:    strings.TrimSpace(os.Getenv("WEBHOOK_TOKEN")),
		GeminiAssistant: strings.TrimSpace(os.Getenv("GEMINI_ASSISTANT")),
		DriveFolderID:   strings.TrimSpace(os.Getenv("GOOGLE_DRIVE_FOLDER_ID")),
		SlackWebhookURL: strings.TrimSpace(os.Getenv("SLACK_WEBHOOK_URL")),
		MaxBodyBytes:    1 << 20,
		QueueSize:       100,
		Workers:         2,
		UpstreamTimeout: 2 * time.Minute,
	}
	var err error
	if c.MaxBodyBytes, err = int64Value("MAX_BODY_BYTES", c.MaxBodyBytes); err != nil {
		return Config{}, err
	}
	if c.QueueSize, err = intValue("QUEUE_SIZE", c.QueueSize); err != nil {
		return Config{}, err
	}
	if c.Workers, err = intValue("WORKERS", c.Workers); err != nil {
		return Config{}, err
	}
	seconds, err := intValue("UPSTREAM_TIMEOUT_SECONDS", int(c.UpstreamTimeout/time.Second))
	if err != nil {
		return Config{}, err
	}
	c.UpstreamTimeout = time.Duration(seconds) * time.Second

	for name, v := range map[string]string{
		"WEBHOOK_TOKEN":          c.WebhookToken,
		"GEMINI_ASSISTANT":       c.GeminiAssistant,
		"GOOGLE_DRIVE_FOLDER_ID": c.DriveFolderID,
		"SLACK_WEBHOOK_URL":      c.SlackWebhookURL,
	} {
		if v == "" {
			return Config{}, fmt.Errorf("%s is required", name)
		}
	}
	if !strings.HasPrefix(c.GeminiAssistant, "projects/") || !strings.Contains(c.GeminiAssistant, "/assistants/") {
		return Config{}, fmt.Errorf("GEMINI_ASSISTANT must be a full assistant resource name")
	}
	if !strings.HasPrefix(c.SlackWebhookURL, "https://hooks.slack.com/") && !strings.HasPrefix(c.SlackWebhookURL, "https://hooks.slack-gov.com/") {
		return Config{}, fmt.Errorf("SLACK_WEBHOOK_URL must be a Slack incoming webhook URL")
	}
	if c.QueueSize < 1 || c.Workers < 1 || c.MaxBodyBytes < 1 || c.UpstreamTimeout <= 0 {
		return Config{}, fmt.Errorf("numeric settings must be positive")
	}
	return c, nil
}

func value(name, fallback string) string {
	if v := strings.TrimSpace(os.Getenv(name)); v != "" {
		return v
	}
	return fallback
}

func intValue(name string, fallback int) (int, error) {
	v := strings.TrimSpace(os.Getenv(name))
	if v == "" {
		return fallback, nil
	}
	n, err := strconv.Atoi(v)
	if err != nil {
		return 0, fmt.Errorf("%s must be an integer: %w", name, err)
	}
	return n, nil
}

func int64Value(name string, fallback int64) (int64, error) {
	v := strings.TrimSpace(os.Getenv(name))
	if v == "" {
		return fallback, nil
	}
	n, err := strconv.ParseInt(v, 10, 64)
	if err != nil {
		return 0, fmt.Errorf("%s must be an integer: %w", name, err)
	}
	return n, nil
}
