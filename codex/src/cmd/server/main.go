package main

import (
	"context"
	"errors"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"grafana-alert-analyzer/internal/app"
	"grafana-alert-analyzer/internal/config"
	"grafana-alert-analyzer/internal/drive"
	"grafana-alert-analyzer/internal/gemini"
	"grafana-alert-analyzer/internal/slack"

	"golang.org/x/oauth2"
	"golang.org/x/oauth2/google"
)

func main() {
	logger := slog.New(slog.NewJSONHandler(os.Stdout, nil))
	cfg, err := config.Load()
	if err != nil {
		logger.Error("invalid configuration", "error", err)
		os.Exit(1)
	}

	ctx := context.Background()
	ts, err := google.DefaultTokenSource(ctx, "https://www.googleapis.com/auth/cloud-platform", "https://www.googleapis.com/auth/drive.file")
	if err != nil {
		logger.Error("initialize Google authentication", "error", err)
		os.Exit(1)
	}
	googleHTTP := oauth2.NewClient(ctx, ts)
	googleHTTP.Timeout = cfg.UpstreamTimeout

	processor := app.NewProcessor(
		gemini.New(googleHTTP, cfg.GeminiAssistant),
		drive.New(googleHTTP, cfg.DriveFolderID),
		slack.New(&http.Client{Timeout: cfg.UpstreamTimeout}, cfg.SlackWebhookURL),
		logger,
	)
	handler := app.NewHandler(processor, cfg.WebhookToken, cfg.MaxBodyBytes, cfg.QueueSize, cfg.Workers, logger)

	server := &http.Server{
		Addr:              ":" + cfg.Port,
		Handler:           handler,
		ReadHeaderTimeout: 5 * time.Second,
		ReadTimeout:       10 * time.Second,
		WriteTimeout:      10 * time.Second,
		IdleTimeout:       60 * time.Second,
	}

	go func() {
		logger.Info("server started", "address", server.Addr)
		if err := server.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
			logger.Error("server failed", "error", err)
			os.Exit(1)
		}
	}()

	sigCtx, stop := signal.NotifyContext(ctx, syscall.SIGINT, syscall.SIGTERM)
	defer stop()
	<-sigCtx.Done()

	shutdownCtx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	if err := server.Shutdown(shutdownCtx); err != nil {
		logger.Error("HTTP shutdown failed", "error", err)
	}
	handler.Shutdown(shutdownCtx)
	logger.Info("server stopped")
}
