package main

import (
	"context"
	"net/http"
	"testing"
	"time"

	"github.com/stretchr/testify/require"
)

func TestFanoutCapturesPreAggregationWindow(t *testing.T) {
	cluster := newQuotaCluster(1, 4)
	servers := startReplicaServers(cluster)
	defer closeReplicaServers(servers)

	probe := runFanout(context.Background(), &http.Client{Timeout: time.Second}, servers, 4, 1)
	require.Equal(t, 4, probe.Successes)
	require.Zero(t, probe.RateLimited)

	cluster.synchronize()
	require.Equal(t, 4, cluster.committedUsage())

	converged := runFanout(context.Background(), &http.Client{Timeout: time.Second}, servers, 4, 2)
	require.Zero(t, converged.Successes)
	require.Equal(t, 4, converged.RateLimited)
}

func TestSingleReplicaEnforcesLocalQuotaBeforeAggregation(t *testing.T) {
	cluster := newQuotaCluster(2, 1)
	servers := startReplicaServers(cluster)
	defer closeReplicaServers(servers)

	probe := runFanout(context.Background(), &http.Client{Timeout: time.Second}, servers, 5, 1)
	require.Equal(t, 2, probe.Successes)
	require.Equal(t, 3, probe.RateLimited)

	cluster.synchronize()
	require.Equal(t, 2, cluster.committedUsage())
}

func TestExecuteFixtureReportsAcceptedOverQuota(t *testing.T) {
	report := executeFixture(context.Background(), 1, 3, 3, 1, time.Hour, 0)

	require.Len(t, report.Rounds, 1)
	require.Equal(t, 3, report.Rounds[0].Successes)
	require.Equal(t, 3, report.FinalCommitted)
	require.Equal(t, 2, report.AcceptedOver)
}
