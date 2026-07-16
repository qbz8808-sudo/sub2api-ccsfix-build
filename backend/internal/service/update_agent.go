package service

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"strings"
	"time"
)

const maxUpdateAgentResponseSize = 64 * 1024

type updateAgentInfo struct {
	HasUpdate     bool   `json:"has_update"`
	CurrentImage  string `json:"current_image"`
	LatestImage   string `json:"latest_image"`
	LatestVersion string `json:"latest_version"`
}

// ManagedUpdateStatus is the host updater state exposed to the admin UI.
type ManagedUpdateStatus struct {
	State      string `json:"state"`
	Message    string `json:"message,omitempty"`
	StartedAt  string `json:"started_at,omitempty"`
	FinishedAt string `json:"finished_at,omitempty"`
}

type updateAgent interface {
	Check(ctx context.Context, force bool) (*updateAgentInfo, error)
	Trigger(ctx context.Context) error
	Status(ctx context.Context) (*ManagedUpdateStatus, error)
}

type unixUpdateAgent struct {
	client *http.Client
	token  string
}

func newUpdateAgentFromEnv() updateAgent {
	socketPath := strings.TrimSpace(os.Getenv("UPDATE_AGENT_SOCKET"))
	token := strings.TrimSpace(os.Getenv("UPDATE_AGENT_TOKEN"))
	if socketPath == "" || token == "" {
		return nil
	}

	transport := &http.Transport{
		DialContext: func(ctx context.Context, _, _ string) (net.Conn, error) {
			dialer := net.Dialer{Timeout: 5 * time.Second}
			return dialer.DialContext(ctx, "unix", socketPath)
		},
	}

	return &unixUpdateAgent{
		client: &http.Client{
			Transport: transport,
			Timeout:   5 * time.Minute,
		},
		token: token,
	}
}

func (a *unixUpdateAgent) Check(ctx context.Context, force bool) (*updateAgentInfo, error) {
	path := "http://unix/v1/check"
	if force {
		path += "?force=true"
	}
	request, err := http.NewRequestWithContext(ctx, http.MethodPost, path, nil)
	if err != nil {
		return nil, err
	}

	var info updateAgentInfo
	if err := a.doJSON(request, &info); err != nil {
		return nil, err
	}
	return &info, nil
}

func (a *unixUpdateAgent) Trigger(ctx context.Context) error {
	request, err := http.NewRequestWithContext(ctx, http.MethodPost, "http://unix/v1/update", nil)
	if err != nil {
		return err
	}
	return a.doJSON(request, nil)
}

func (a *unixUpdateAgent) Status(ctx context.Context) (*ManagedUpdateStatus, error) {
	request, err := http.NewRequestWithContext(ctx, http.MethodGet, "http://unix/v1/status", nil)
	if err != nil {
		return nil, err
	}

	var status ManagedUpdateStatus
	if err := a.doJSON(request, &status); err != nil {
		return nil, err
	}
	return &status, nil
}

func (a *unixUpdateAgent) doJSON(request *http.Request, destination any) error {
	request.Header.Set("Authorization", "Bearer "+a.token)
	request.Header.Set("Accept", "application/json")

	response, err := a.client.Do(request)
	if err != nil {
		return err
	}
	defer func() { _ = response.Body.Close() }()

	body, err := io.ReadAll(io.LimitReader(response.Body, maxUpdateAgentResponseSize+1))
	if err != nil {
		return err
	}
	if len(body) > maxUpdateAgentResponseSize {
		return fmt.Errorf("update agent response too large")
	}
	if response.StatusCode < http.StatusOK || response.StatusCode >= http.StatusMultipleChoices {
		return fmt.Errorf("update agent returned %s: %s", response.Status, strings.TrimSpace(string(body)))
	}
	if destination == nil || len(body) == 0 {
		return nil
	}
	if err := json.Unmarshal(body, destination); err != nil {
		return fmt.Errorf("decode update agent response: %w", err)
	}
	return nil
}

func (s *UpdateService) withManagedUpdateInfo(ctx context.Context, info *UpdateInfo, force bool) *UpdateInfo {
	if info == nil || s.updateAgent == nil {
		return info
	}

	info.ManagedUpdate = true
	agentInfo, err := s.updateAgent.Check(ctx, force)
	if err != nil {
		info.HasUpdate = false
		warning := "Managed updater unavailable: " + err.Error()
		if info.Warning == "" {
			info.Warning = warning
		} else {
			info.Warning += "; " + warning
		}
		return info
	}

	info.HasUpdate = agentInfo.HasUpdate
	if agentInfo.LatestVersion != "" {
		info.LatestVersion = agentInfo.LatestVersion
	}
	return info
}

// ManagedUpdateStatus returns the host updater state when managed updates are configured.
func (s *UpdateService) ManagedUpdateStatus(ctx context.Context) (*ManagedUpdateStatus, error) {
	if s.updateAgent == nil {
		return &ManagedUpdateStatus{State: "disabled"}, nil
	}
	return s.updateAgent.Status(ctx)
}
