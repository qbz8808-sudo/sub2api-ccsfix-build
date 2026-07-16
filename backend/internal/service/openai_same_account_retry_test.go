package service

import (
	"net/http"
	"testing"

	"github.com/stretchr/testify/require"
)

func TestShouldRetryOpenAIOnSameAccount(t *testing.T) {
	tests := []struct {
		name                string
		account             *Account
		statusCode          int
		configuredRetryable bool
		expected            bool
	}{
		{
			name:       "oauth_429",
			account:    &Account{Platform: PlatformOpenAI, Type: AccountTypeOAuth},
			statusCode: http.StatusTooManyRequests,
			expected:   true,
		},
		{
			name:       "setup_token_429",
			account:    &Account{Platform: PlatformOpenAI, Type: AccountTypeSetupToken},
			statusCode: http.StatusTooManyRequests,
			expected:   true,
		},
		{
			name:       "oauth_non_429",
			account:    &Account{Platform: PlatformOpenAI, Type: AccountTypeOAuth},
			statusCode: http.StatusServiceUnavailable,
			expected:   false,
		},
		{
			name:                "existing_policy_remains_retryable",
			account:             &Account{Platform: PlatformOpenAI, Type: AccountTypeAPIKey},
			statusCode:          http.StatusServiceUnavailable,
			configuredRetryable: true,
			expected:            true,
		},
		{
			name:       "api_key_429_without_pool_mode",
			account:    &Account{Platform: PlatformOpenAI, Type: AccountTypeAPIKey},
			statusCode: http.StatusTooManyRequests,
			expected:   false,
		},
		{
			name:       "grok_oauth_429",
			account:    &Account{Platform: PlatformGrok, Type: AccountTypeOAuth},
			statusCode: http.StatusTooManyRequests,
			expected:   false,
		},
		{
			name:       "nil_account",
			statusCode: http.StatusTooManyRequests,
			expected:   false,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			require.Equal(t, tt.expected, shouldRetryOpenAIOnSameAccount(tt.account, tt.statusCode, tt.configuredRetryable))
		})
	}
}
