package gemini

import (
	"context"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestAnalyzeCombinesStreamFragments(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/v1/projects/p/locations/global/collections/default_collection/engines/e/assistants/default_assistant:streamAssist" {
			t.Errorf("path = %s", r.URL.Path)
		}
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`[
			{"answer":{"state":"IN_PROGRESS","replies":[{"groundedContent":{"content":{"text":"first "}}}]}},
			{"answer":{"state":"SUCCEEDED","replies":[{"groundedContent":{"content":{"text":"second"}}}]}}
		]`))
	}))
	defer server.Close()
	c := New(server.Client(), "projects/p/locations/global/collections/default_collection/engines/e/assistants/default_assistant")
	c.baseURL = server.URL
	got, err := c.Analyze(context.Background(), "prompt")
	if err != nil {
		t.Fatal(err)
	}
	if got != "first second" {
		t.Fatalf("answer = %q", got)
	}
}

func TestAnalyzeReportsUpstreamError(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		http.Error(w, "denied", http.StatusForbidden)
	}))
	defer server.Close()
	c := New(server.Client(), "projects/p/locations/global/collections/c/engines/e/assistants/a")
	c.baseURL = server.URL
	_, err := c.Analyze(context.Background(), "prompt")
	if err == nil || !strings.Contains(err.Error(), "403") {
		t.Fatalf("error = %v", err)
	}
}
