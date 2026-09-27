package model

import "time"

// GrafanaWebhook represents the fields sent by Grafana's unified alerting webhook.
// Unknown fields are deliberately accepted so Grafana can add fields compatibly.
type GrafanaWebhook struct {
	Receiver        string  `json:"receiver"`
	Status          string  `json:"status"`
	OrgID           int64   `json:"orgId"`
	Alerts          []Alert `json:"alerts"`
	ExternalURL     string  `json:"externalURL"`
	Version         string  `json:"version"`
	GroupKey        string  `json:"groupKey"`
	TruncatedAlerts int     `json:"truncatedAlerts"`
	Title           string  `json:"title"`
	State           string  `json:"state"`
	Message         string  `json:"message"`
}

type Alert struct {
	Status       string            `json:"status"`
	Labels       map[string]string `json:"labels"`
	Annotations  map[string]string `json:"annotations"`
	StartsAt     time.Time         `json:"startsAt"`
	EndsAt       time.Time         `json:"endsAt"`
	GeneratorURL string            `json:"generatorURL"`
	SilenceURL   string            `json:"silenceURL"`
	DashboardURL string            `json:"dashboardURL"`
	PanelURL     string            `json:"panelURL"`
	Fingerprint  string            `json:"fingerprint"`
	Values       map[string]any    `json:"values"`
	ValueString  string            `json:"valueString"`
}
