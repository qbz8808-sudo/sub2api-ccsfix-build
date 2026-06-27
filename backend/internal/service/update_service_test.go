//go:build unit

package service

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/stretchr/testify/require"
)

type updateServiceCacheStub struct {
	data string
}

func (s *updateServiceCacheStub) GetUpdateInfo(context.Context) (string, error) {
	if s.data == "" {
		return "", errors.New("cache miss")
	}
	return s.data, nil
}

func (s *updateServiceCacheStub) SetUpdateInfo(_ context.Context, data string, _ time.Duration) error {
	s.data = data
	return nil
}

type updateServiceGitHubClientStub struct {
	release *GitHubRelease
}

func (s *updateServiceGitHubClientStub) FetchLatestRelease(context.Context, string) (*GitHubRelease, error) {
	return s.release, nil
}

func (s *updateServiceGitHubClientStub) DownloadFile(context.Context, string, string, int64) error {
	panic("DownloadFile should not be called when no update is available")
}

func (s *updateServiceGitHubClientStub) FetchChecksumFile(context.Context, string) ([]byte, error) {
	panic("FetchChecksumFile should not be called when no update is available")
}

func TestUpdateServicePerformUpdateNoUpdateReturnsSentinel(t *testing.T) {
	svc := NewUpdateService(
		&updateServiceCacheStub{},
		&updateServiceGitHubClientStub{
			release: &GitHubRelease{
				TagName: "v0.1.132",
				Name:    "v0.1.132",
			},
		},
		"0.1.132",
		"release",
	)

	result, err := svc.PerformUpdate(context.Background())

	require.Nil(t, result)
	require.Error(t, err)
	require.True(t, errors.Is(err, ErrNoUpdateAvailable))
	require.ErrorIs(t, err, ErrNoUpdateAvailable)
}

func TestUpdateServicePerformUpdateDispatchesGitHubActionsWhenConfigured(t *testing.T) {
	var gotPath string
	var gotPayload struct {
		Ref    string            `json:"ref"`
		Inputs map[string]string `json:"inputs"`
	}
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		gotPath = r.URL.Path
		require.Equal(t, http.MethodPost, r.Method)
		require.Equal(t, "Bearer test-token", r.Header.Get("Authorization"))
		require.NoError(t, json.NewDecoder(r.Body).Decode(&gotPayload))
		w.WriteHeader(http.StatusNoContent)
	}))
	t.Cleanup(server.Close)

	t.Setenv(customUpdateModeEnv, customUpdateModeActions)
	t.Setenv(customUpdateGitHubToken, "test-token")
	t.Setenv(customUpdateGitHubRepo, "owner/repo")
	t.Setenv(customUpdateGitHubWorkflow, "build.yml")
	t.Setenv(customUpdateGitHubRef, "main")
	t.Setenv(customUpdateGitHubAPIURL, server.URL)
	t.Setenv(customUpdateGHCRImage, "ghcr.io/owner/repo:latest")
	t.Setenv(customUpdateInputsJSON, `{"version":"{{latestVersion}}","image":"{{image}}"}`)

	svc := NewUpdateService(
		&updateServiceCacheStub{},
		&updateServiceGitHubClientStub{
			release: &GitHubRelease{
				TagName: "v0.1.139",
				Name:    "v0.1.139",
			},
		},
		"0.1.138",
		"release",
	)

	result, err := svc.PerformUpdate(context.Background())

	require.NoError(t, err)
	require.NotNil(t, result)
	require.False(t, result.NeedRestart)
	require.True(t, result.WorkflowDispatched)
	require.Equal(t, customUpdateModeActions, result.Mode)
	require.Equal(t, "owner/repo", result.Repository)
	require.Equal(t, "build.yml", result.Workflow)
	require.Equal(t, "/repos/owner/repo/actions/workflows/build.yml/dispatches", gotPath)
	require.Equal(t, "main", gotPayload.Ref)
	require.Equal(t, map[string]string{
		"version": "0.1.139",
		"image":   "ghcr.io/owner/repo:latest",
	}, gotPayload.Inputs)
}
