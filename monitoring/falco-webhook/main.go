// monitoring/falco-webhook/main.go
//
// Receives Falco's native HTTP output payload, forwards every alert
// to Loki (label: source=falco), and for severity >= WARNING also
// calls nomad-sentinel over internal HTTP.
//
// Falco's own JSON schema (its native http_output, not falcosidekick's
// richer format) — confirmed structure per Falco's own output
// documentation: output, priority, rule, time, output_fields,
// hostname, source, tags.
//
// NOT VERIFIED: nomad-sentinel's own HTTP API contract — /anomaly
// below and its request body shape are a reasonable assumption, not
// confirmed against nomad-sentinel's actual (not yet written) code.
// Whoever builds that service needs to either match this shape or
// this file needs updating to match whatever nomad-sentinel actually
// expects.
package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"strings"
	"time"
)

// FalcoAlert matches Falco's native HTTP output payload.
type FalcoAlert struct {
	Output       string                 `json:"output"`
	Priority     string                 `json:"priority"`
	Rule         string                 `json:"rule"`
	Time         string                 `json:"time"`
	Source       string                 `json:"source"`
	Hostname     string                 `json:"hostname"`
	Tags         []string               `json:"tags"`
	OutputFields map[string]interface{} `json:"output_fields"`
}

// severityAtLeastWarning mirrors Falco's own priority ordering —
// Emergency is the most severe, Debug the least. Everything from
// Warning up (inclusive) triggers a nomad-sentinel call.
var severityRank = map[string]int{
	"emergency":     0,
	"alert":         1,
	"critical":      2,
	"error":         3,
	"warning":       4,
	"notice":        5,
	"informational": 6,
	"debug":         7,
}

func severityAtLeastWarning(priority string) bool {
	rank, ok := severityRank[strings.ToLower(priority)]
	if !ok {
		// Unknown priority string — fail open (treat as worth
		// escalating) rather than silently drop something Falco
		// considered worth reporting.
		return true
	}
	return rank <= severityRank["warning"]
}

type server struct {
	lokiAddr    string
	aiAgentAddr string
	httpClient  *http.Client
}

func main() {
	port := os.Getenv("PORT")
	if port == "" {
		port = "8080"
	}

	s := &server{
		lokiAddr:    mustEnv("LOKI_ADDR"),
		aiAgentAddr: mustEnv("AI_AGENT_ADDR"),
		httpClient:  &http.Client{Timeout: 5 * time.Second},
	}

	mux := http.NewServeMux()
	mux.HandleFunc("/health", s.handleHealth)
	mux.HandleFunc("/webhook", s.handleWebhook)

	log.Printf("falco-webhook listening on :%s (loki=%s, ai-agent=%s)", port, s.lokiAddr, s.aiAgentAddr)
	if err := http.ListenAndServe(":"+port, mux); err != nil {
		log.Fatalf("server exited: %v", err)
	}
}

func mustEnv(key string) string {
	v := os.Getenv(key)
	if v == "" {
		log.Fatalf("required env var %s is not set", key)
	}
	return v
}

func (s *server) handleHealth(w http.ResponseWriter, r *http.Request) {
	w.WriteHeader(http.StatusOK)
	_, _ = w.Write([]byte("ok"))
}

func (s *server) handleWebhook(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}

	body, err := io.ReadAll(r.Body)
	if err != nil {
		http.Error(w, "failed to read body", http.StatusBadRequest)
		return
	}

	var alert FalcoAlert
	if err := json.Unmarshal(body, &alert); err != nil {
		http.Error(w, "invalid json", http.StatusBadRequest)
		return
	}

	log.Printf("received Falco alert: rule=%q priority=%q", alert.Rule, alert.Priority)

	if err := s.forwardToLoki(alert); err != nil {
		// Loki being down shouldn't stop this from acking Falco or
		// from still escalating to nomad-sentinel — log and continue,
		// same "never let a downstream failure gate the primary
		// function" pattern used elsewhere in this project (e.g.
		// nomad-sentinel's own optional history-database writes).
		log.Printf("WARN: failed to forward alert to Loki: %v", err)
	}

	if severityAtLeastWarning(alert.Priority) {
		if err := s.escalateToNomadSentinel(alert); err != nil {
			log.Printf("WARN: failed to escalate alert to nomad-sentinel: %v", err)
		}
	}

	w.WriteHeader(http.StatusOK)
}

// forwardToLoki pushes the alert to Loki's push API with label
// source=falco, plus priority/rule as additional labels — cardinality
// here is bounded (Falco's own priority enum, and a rule set that
// doesn't change per-request), so this doesn't risk a label
// explosion the way something like alloc_id in a high-cardinality
// label would.
func (s *server) forwardToLoki(alert FalcoAlert) error {
	nowNs := fmt.Sprintf("%d", time.Now().UnixNano())

	payload := map[string]interface{}{
		"streams": []map[string]interface{}{
			{
				"stream": map[string]string{
					"source":   "falco",
					"priority": strings.ToLower(alert.Priority),
					"rule":     alert.Rule,
				},
				"values": [][]string{
					{nowNs, alert.Output},
				},
			},
		},
	}

	body, err := json.Marshal(payload)
	if err != nil {
		return fmt.Errorf("marshal loki payload: %w", err)
	}

	url := fmt.Sprintf("http://%s/loki/api/v1/push", s.lokiAddr)
	req, err := http.NewRequest(http.MethodPost, url, bytes.NewReader(body))
	if err != nil {
		return fmt.Errorf("build loki request: %w", err)
	}
	req.Header.Set("Content-Type", "application/json")

	resp, err := s.httpClient.Do(req)
	if err != nil {
		return fmt.Errorf("loki request failed: %w", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode >= 300 {
		respBody, _ := io.ReadAll(resp.Body)
		return fmt.Errorf("loki returned %d: %s", resp.StatusCode, string(respBody))
	}
	return nil
}

// escalateToNomadSentinel — NOT VERIFIED, see file header comment.
func (s *server) escalateToNomadSentinel(alert FalcoAlert) error {
	body, err := json.Marshal(alert)
	if err != nil {
		return fmt.Errorf("marshal alert: %w", err)
	}

	url := fmt.Sprintf("http://%s/anomaly", s.aiAgentAddr)
	req, err := http.NewRequest(http.MethodPost, url, bytes.NewReader(body))
	if err != nil {
		return fmt.Errorf("build nomad-sentinel request: %w", err)
	}
	req.Header.Set("Content-Type", "application/json")

	resp, err := s.httpClient.Do(req)
	if err != nil {
		return fmt.Errorf("nomad-sentinel request failed: %w", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode >= 300 {
		respBody, _ := io.ReadAll(resp.Body)
		return fmt.Errorf("nomad-sentinel returned %d: %s", resp.StatusCode, string(respBody))
	}
	return nil
}
