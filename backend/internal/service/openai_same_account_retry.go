package service

import "net/http"

// shouldRetryOpenAIOnSameAccount preserves the caller's existing retry policy
// and additionally retries OAuth-like OpenAI 429 responses on the same account.
func shouldRetryOpenAIOnSameAccount(account *Account, statusCode int, configuredRetryable bool) bool {
	if configuredRetryable {
		return true
	}
	return account != nil &&
		account.IsOpenAI() &&
		account.IsOAuth() &&
		statusCode == http.StatusTooManyRequests
}
