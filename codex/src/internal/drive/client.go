package drive

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"mime/multipart"
	"net/http"
	"net/textproto"
	"net/url"
	"strings"
)

type File struct{ ID, Name, WebViewLink string }

type Client struct {
	httpClient *http.Client
	folderID   string
	baseURL    string
}

func New(httpClient *http.Client, folderID string) *Client {
	return &Client{httpClient: httpClient, folderID: folderID, baseURL: "https://www.googleapis.com"}
}

func (c *Client) UploadMarkdown(ctx context.Context, name string, content []byte) (File, error) {
	var body bytes.Buffer
	w := multipart.NewWriter(&body)
	metadataHeader := textproto.MIMEHeader{}
	metadataHeader.Set("Content-Type", "application/json; charset=UTF-8")
	part, err := w.CreatePart(metadataHeader)
	if err != nil {
		return File{}, err
	}
	metadata := map[string]any{"name": name, "mimeType": "text/markdown", "parents": []string{c.folderID}}
	if err := json.NewEncoder(part).Encode(metadata); err != nil {
		return File{}, err
	}
	contentHeader := textproto.MIMEHeader{}
	contentHeader.Set("Content-Type", "text/markdown; charset=UTF-8")
	part, err = w.CreatePart(contentHeader)
	if err != nil {
		return File{}, err
	}
	if _, err := part.Write(content); err != nil {
		return File{}, err
	}
	if err := w.Close(); err != nil {
		return File{}, err
	}

	endpoint := strings.TrimRight(c.baseURL, "/") + "/upload/drive/v3/files?uploadType=multipart&fields=id,name,webViewLink&supportsAllDrives=true"
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, endpoint, &body)
	if err != nil {
		return File{}, fmt.Errorf("create Drive request: %w", err)
	}
	req.Header.Set("Content-Type", w.FormDataContentType())
	resp, err := c.httpClient.Do(req)
	if err != nil {
		return File{}, fmt.Errorf("upload to Drive: %w", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		b, _ := io.ReadAll(io.LimitReader(resp.Body, 8192))
		return File{}, fmt.Errorf("Drive returned %s: %s", resp.Status, strings.TrimSpace(string(b)))
	}
	var result struct {
		ID          string `json:"id"`
		Name        string `json:"name"`
		WebViewLink string `json:"webViewLink"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&result); err != nil {
		return File{}, fmt.Errorf("decode Drive response: %w", err)
	}
	if result.ID == "" {
		return File{}, fmt.Errorf("Drive returned no file ID")
	}
	link := result.WebViewLink
	if link == "" {
		link = "https://drive.google.com/open?id=" + url.QueryEscape(result.ID)
	}
	return File{ID: result.ID, Name: result.Name, WebViewLink: link}, nil
}
