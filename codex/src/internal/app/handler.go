package app

import (
	"context"
	"crypto/subtle"
	"encoding/json"
	"errors"
	"io"
	"log/slog"
	"net/http"
	"strings"
	"sync"

	"grafana-alert-analyzer/internal/model"
)

type job struct{ alert model.GrafanaWebhook }

type Handler struct {
	mux       *http.ServeMux
	processor *Processor
	token     string
	maxBody   int64
	queue     chan job
	wg        sync.WaitGroup
	logger    *slog.Logger
}

func NewHandler(processor *Processor, token string, maxBody int64, queueSize, workers int, logger *slog.Logger) *Handler {
	h := &Handler{processor: processor, token: token, maxBody: maxBody, queue: make(chan job, queueSize), logger: logger, mux: http.NewServeMux()}
	h.mux.HandleFunc("GET /healthz", h.health)
	h.mux.HandleFunc("POST /webhook/grafana", h.webhook)
	for range workers {
		h.wg.Add(1)
		go h.worker()
	}
	return h
}

func (h *Handler) ServeHTTP(w http.ResponseWriter, r *http.Request) { h.mux.ServeHTTP(w, r) }

func (h *Handler) health(w http.ResponseWriter, _ *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	_, _ = w.Write([]byte(`{"status":"ok"}`))
}

func (h *Handler) webhook(w http.ResponseWriter, r *http.Request) {
	if !h.authorized(r.Header.Get("Authorization")) {
		writeError(w, http.StatusUnauthorized, "unauthorized")
		return
	}
	r.Body = http.MaxBytesReader(w, r.Body, h.maxBody)
	dec := json.NewDecoder(r.Body)
	var payload model.GrafanaWebhook
	if err := dec.Decode(&payload); err != nil {
		var maxErr *http.MaxBytesError
		if errors.As(err, &maxErr) {
			writeError(w, http.StatusRequestEntityTooLarge, "payload too large")
			return
		}
		writeError(w, http.StatusBadRequest, "invalid JSON")
		return
	}
	if err := ensureEOF(dec); err != nil {
		writeError(w, http.StatusBadRequest, "request must contain one JSON object")
		return
	}
	if len(payload.Alerts) == 0 {
		writeError(w, http.StatusBadRequest, "alerts must not be empty")
		return
	}
	select {
	case h.queue <- job{alert: payload}:
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusAccepted)
		_, _ = w.Write([]byte(`{"status":"accepted"}`))
	default:
		writeError(w, http.StatusServiceUnavailable, "processing queue is full")
	}
}

func (h *Handler) authorized(header string) bool {
	provided := strings.TrimPrefix(header, "Bearer ")
	return len(provided) == len(h.token) && subtle.ConstantTimeCompare([]byte(provided), []byte(h.token)) == 1
}

func (h *Handler) worker() {
	defer h.wg.Done()
	for j := range h.queue {
		if err := h.processor.Process(context.Background(), j.alert); err != nil {
			h.logger.Error("process alert", "error", err, "group_key", j.alert.GroupKey)
		}
	}
}

func (h *Handler) Shutdown(ctx context.Context) {
	close(h.queue)
	done := make(chan struct{})
	go func() { h.wg.Wait(); close(done) }()
	select {
	case <-done:
	case <-ctx.Done():
		h.logger.Warn("worker shutdown timed out")
	}
}

func ensureEOF(dec *json.Decoder) error {
	var extra any
	err := dec.Decode(&extra)
	if err == nil {
		return errors.New("extra JSON value")
	}
	if errors.Is(err, io.EOF) {
		return nil
	}
	return err
}

func writeError(w http.ResponseWriter, status int, message string) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(map[string]string{"error": message})
}
