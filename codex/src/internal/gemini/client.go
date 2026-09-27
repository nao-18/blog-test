package gemini

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strings"
)

type Client struct {
	httpClient *http.Client
	assistant  string
	baseURL    string
}

func New(httpClient *http.Client, assistant string) *Client {
	return &Client{httpClient: httpClient, assistant: assistant, baseURL: "https://discoveryengine.googleapis.com"}
}

func (c *Client) Analyze(ctx context.Context, prompt string) (string, error) {
	payload := map[string]any{"query": map[string]string{"text": prompt}}
	body, err := json.Marshal(payload)
	if err != nil {
		return "", fmt.Errorf("encode Gemini request: %w", err)
	}
	endpoint := strings.TrimRight(c.baseURL, "/") + "/v1/" + escapeResourceName(c.assistant) + ":streamAssist"
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, endpoint, bytes.NewReader(body))
	if err != nil {
		return "", fmt.Errorf("create Gemini request: %w", err)
	}
	req.Header.Set("Content-Type", "application/json")
	resp, err := c.httpClient.Do(req)
	if err != nil {
		return "", fmt.Errorf("call Gemini Enterprise: %w", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		b, _ := io.ReadAll(io.LimitReader(resp.Body, 8192))
		return "", fmt.Errorf("Gemini Enterprise returned %s: %s", resp.Status, strings.TrimSpace(string(b)))
	}
	var responses []streamAssistResponse
	if err := json.NewDecoder(resp.Body).Decode(&responses); err != nil {
		return "", fmt.Errorf("decode Gemini response: %w", err)
	}
	var answer strings.Builder
	for _, result := range responses {
		for _, reply := range result.Answer.Replies {
			if !reply.GroundedContent.Content.Thought {
				answer.WriteString(reply.GroundedContent.Content.Text)
			}
		}
	}
	if strings.TrimSpace(answer.String()) == "" {
		return "", fmt.Errorf("Gemini Enterprise returned an empty answer")
	}
	return answer.String(), nil
}

type streamAssistResponse struct {
	Answer struct {
		State   string `json:"state"`
		Replies []struct {
			GroundedContent struct {
				Content struct {
					Text    string `json:"text"`
					Thought bool   `json:"thought"`
				} `json:"content"`
			} `json:"groundedContent"`
		} `json:"replies"`
	} `json:"answer"`
}

func escapeResourceName(name string) string {
	parts := strings.Split(strings.Trim(name, "/"), "/")
	for i := range parts {
		parts[i] = url.PathEscape(parts[i])
	}
	return strings.Join(parts, "/")
}
