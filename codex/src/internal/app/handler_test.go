package app

import (
	"context"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"grafana-alert-analyzer/internal/drive"
)

type fakeAnalyzer struct{ prompt chan string }

func (f *fakeAnalyzer) Analyze(_ context.Context, prompt string) (string, error) {
	f.prompt <- prompt
	return "## 現状把握\nok\n## 原因調査\nx\n## 解決策提案\ny\n## 確認方法\nz", nil
}

type fakeUploader struct{}

func (fakeUploader) UploadMarkdown(context.Context, string, []byte) (drive.File, error) {
	return drive.File{ID: "file-1", WebViewLink: "https://drive.example/file-1"}, nil
}

type fakeNotifier struct{}

func (fakeNotifier) Notify(context.Context, string) error { return nil }

func TestWebhookAcceptedAndProcessed(t *testing.T) {
	a := &fakeAnalyzer{prompt: make(chan string, 1)}
	logger := slog.New(slog.NewTextHandler(io.Discard, nil))
	p := NewProcessor(a, fakeUploader{}, fakeNotifier{}, logger)
	h := NewHandler(p, "secret", 4096, 1, 1, logger)
	t.Cleanup(func() {
		ctx, cancel := context.WithTimeout(context.Background(), time.Second)
		defer cancel()
		h.Shutdown(ctx)
	})

	body := `{"receiver":"ops","status":"firing","title":"High error rate","alerts":[{"status":"firing","labels":{"service":"api"}}]}`
	req := httptest.NewRequest(http.MethodPost, "/webhook/grafana", strings.NewReader(body))
	req.Header.Set("Authorization", "Bearer secret")
	w := httptest.NewRecorder()
	h.ServeHTTP(w, req)
	if w.Code != http.StatusAccepted {
		t.Fatalf("status = %d, body = %s", w.Code, w.Body.String())
	}
	select {
	case prompt := <-a.prompt:
		for _, heading := range []string{"## 現状把握", "## 原因調査", "## 解決策提案", "## 確認方法"} {
			if !strings.Contains(prompt, heading) {
				t.Errorf("prompt does not contain %q", heading)
			}
		}
		if !strings.Contains(prompt, `"service": "api"`) {
			t.Error("prompt does not contain alert payload")
		}
	case <-time.After(time.Second):
		t.Fatal("alert was not processed")
	}
}

func TestWebhookRejectsUnauthorized(t *testing.T) {
	logger := slog.New(slog.NewTextHandler(io.Discard, nil))
	p := NewProcessor(&fakeAnalyzer{prompt: make(chan string, 1)}, fakeUploader{}, fakeNotifier{}, logger)
	h := NewHandler(p, "secret", 4096, 1, 1, logger)
	t.Cleanup(func() { h.Shutdown(context.Background()) })
	req := httptest.NewRequest(http.MethodPost, "/webhook/grafana", strings.NewReader(`{"alerts":[{}]}`))
	w := httptest.NewRecorder()
	h.ServeHTTP(w, req)
	if w.Code != http.StatusUnauthorized {
		t.Fatalf("status = %d", w.Code)
	}
}

func TestWebhookRejectsEmptyAlerts(t *testing.T) {
	logger := slog.New(slog.NewTextHandler(io.Discard, nil))
	p := NewProcessor(&fakeAnalyzer{prompt: make(chan string, 1)}, fakeUploader{}, fakeNotifier{}, logger)
	h := NewHandler(p, "secret", 4096, 1, 1, logger)
	t.Cleanup(func() { h.Shutdown(context.Background()) })
	req := httptest.NewRequest(http.MethodPost, "/webhook/grafana", strings.NewReader(`{"alerts":[]}`))
	req.Header.Set("Authorization", "Bearer secret")
	w := httptest.NewRecorder()
	h.ServeHTTP(w, req)
	if w.Code != http.StatusBadRequest {
		t.Fatalf("status = %d", w.Code)
	}
}
