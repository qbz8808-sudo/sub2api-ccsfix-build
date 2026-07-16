//go:build unit

package service

import (
	"context"
	"io"
	"net/http"
	"strings"
	"testing"

	"github.com/stretchr/testify/require"
)

type updateAgentRoundTripper func(*http.Request) (*http.Response, error)

func (f updateAgentRoundTripper) RoundTrip(request *http.Request) (*http.Response, error) {
	return f(request)
}

func TestUnixUpdateAgentCheckAuthenticatesAndDecodes(t *testing.T) {
	agent := &unixUpdateAgent{
		token: "test-token",
		client: &http.Client{Transport: updateAgentRoundTripper(func(request *http.Request) (*http.Response, error) {
			require.Equal(t, http.MethodPost, request.Method)
			require.Equal(t, "/v1/check", request.URL.Path)
			require.Equal(t, "true", request.URL.Query().Get("force"))
			require.Equal(t, "Bearer test-token", request.Header.Get("Authorization"))
			return &http.Response{
				StatusCode: http.StatusOK,
				Status:     "200 OK",
				Body: io.NopCloser(strings.NewReader(
					`{"has_update":true,"current_image":"sha256:old","latest_image":"sha256:new","latest_version":"0.1.159-429"}`,
				)),
			}, nil
		})},
	}

	info, err := agent.Check(context.Background(), true)

	require.NoError(t, err)
	require.True(t, info.HasUpdate)
	require.Equal(t, "sha256:old", info.CurrentImage)
	require.Equal(t, "sha256:new", info.LatestImage)
	require.Equal(t, "0.1.159-429", info.LatestVersion)
}

func TestUnixUpdateAgentTriggerRejectsAgentFailure(t *testing.T) {
	agent := &unixUpdateAgent{
		token: "test-token",
		client: &http.Client{Transport: updateAgentRoundTripper(func(request *http.Request) (*http.Response, error) {
			require.Equal(t, "/v1/update", request.URL.Path)
			return &http.Response{
				StatusCode: http.StatusConflict,
				Status:     "409 Conflict",
				Body:       io.NopCloser(strings.NewReader(`{"error":"already running"}`)),
			}, nil
		})},
	}

	err := agent.Trigger(context.Background())

	require.Error(t, err)
	require.Contains(t, err.Error(), "409 Conflict")
}

func TestUnixUpdateAgentStatus(t *testing.T) {
	agent := &unixUpdateAgent{
		token: "test-token",
		client: &http.Client{Transport: updateAgentRoundTripper(func(request *http.Request) (*http.Response, error) {
			require.Equal(t, http.MethodGet, request.Method)
			require.Equal(t, "/v1/status", request.URL.Path)
			return &http.Response{
				StatusCode: http.StatusOK,
				Status:     "200 OK",
				Body:       io.NopCloser(strings.NewReader(`{"state":"running","message":"updating"}`)),
			}, nil
		})},
	}

	status, err := agent.Status(context.Background())

	require.NoError(t, err)
	require.Equal(t, "running", status.State)
	require.Equal(t, "updating", status.Message)
}
