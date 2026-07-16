package main

import (
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"sync"
	"time"
)

type replicaQuota struct {
	Observed int `json:"observed"`
	Pending  int `json:"pending"`
}

type quotaCluster struct {
	mu        sync.Mutex
	quota     int
	committed int
	replicas  []replicaQuota
}

type consumeResult struct {
	ReplicaID int `json:"replica_id"`
	Status    int `json:"status"`
	Observed  int `json:"observed"`
	Pending   int `json:"pending"`
	Committed int `json:"committed"`
}

type probeRound struct {
	Round       int             `json:"round"`
	StartedAt   time.Time       `json:"started_at"`
	Successes   int             `json:"successes"`
	RateLimited int             `json:"rate_limited"`
	Results     []consumeResult `json:"results"`
}

type fixtureReport struct {
	Quota          int          `json:"quota"`
	ReplicaCount   int          `json:"replica_count"`
	Attempts       int          `json:"attempts_per_round"`
	SyncIntervalMS int64        `json:"sync_interval_ms"`
	Rounds         []probeRound `json:"rounds"`
	FinalCommitted int          `json:"final_committed"`
	AcceptedOver   int          `json:"accepted_over_quota"`
}

func newQuotaCluster(quota, replicaCount int) *quotaCluster {
	return &quotaCluster{
		quota:    quota,
		replicas: make([]replicaQuota, replicaCount),
	}
}

func (c *quotaCluster) consume(replicaID int) consumeResult {
	c.mu.Lock()
	defer c.mu.Unlock()

	replica := &c.replicas[replicaID]
	result := consumeResult{
		ReplicaID: replicaID,
		Observed:  replica.Observed,
		Pending:   replica.Pending,
		Committed: c.committed,
	}
	if replica.Observed+replica.Pending >= c.quota {
		result.Status = http.StatusTooManyRequests
		return result
	}

	replica.Pending++
	result.Status = http.StatusOK
	result.Pending = replica.Pending
	return result
}

func (c *quotaCluster) synchronize() {
	c.mu.Lock()
	defer c.mu.Unlock()

	for i := range c.replicas {
		c.committed += c.replicas[i].Pending
		c.replicas[i].Pending = 0
	}
	for i := range c.replicas {
		c.replicas[i].Observed = c.committed
	}
}

func (c *quotaCluster) committedUsage() int {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.committed
}

func startReplicaServers(cluster *quotaCluster) []*httptest.Server {
	servers := make([]*httptest.Server, len(cluster.replicas))
	for replicaID := range cluster.replicas {
		id := replicaID
		servers[id] = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
			result := cluster.consume(id)
			w.Header().Set("Content-Type", "application/json")
			w.WriteHeader(result.Status)
			_ = json.NewEncoder(w).Encode(result)
		}))
	}
	return servers
}

func closeReplicaServers(servers []*httptest.Server) {
	for _, server := range servers {
		server.Close()
	}
}

func startSynchronizer(ctx context.Context, cluster *quotaCluster, interval time.Duration) {
	ticker := time.NewTicker(interval)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			cluster.synchronize()
		}
	}
}

func runFanout(ctx context.Context, client *http.Client, servers []*httptest.Server, attempts, round int) probeRound {
	results := make([]consumeResult, attempts)
	start := make(chan struct{})
	var wg sync.WaitGroup

	for i := 0; i < attempts; i++ {
		wg.Add(1)
		go func(attempt int) {
			defer wg.Done()
			<-start

			replicaID := attempt % len(servers)
			req, err := http.NewRequestWithContext(ctx, http.MethodPost, servers[replicaID].URL, nil)
			if err != nil {
				results[attempt] = consumeResult{ReplicaID: replicaID, Status: http.StatusInternalServerError}
				return
			}
			resp, err := client.Do(req)
			if err != nil {
				results[attempt] = consumeResult{ReplicaID: replicaID, Status: http.StatusBadGateway}
				return
			}
			defer func() { _ = resp.Body.Close() }()

			var result consumeResult
			if err := json.NewDecoder(io.LimitReader(resp.Body, 16<<10)).Decode(&result); err != nil {
				result = consumeResult{ReplicaID: replicaID, Status: resp.StatusCode}
			}
			results[attempt] = result
		}(i)
	}

	startedAt := time.Now().UTC()
	close(start)
	wg.Wait()

	probe := probeRound{Round: round, StartedAt: startedAt, Results: results}
	for _, result := range results {
		switch result.Status {
		case http.StatusOK:
			probe.Successes++
		case http.StatusTooManyRequests:
			probe.RateLimited++
		}
	}
	return probe
}

func executeFixture(ctx context.Context, quota, replicaCount, attempts, rounds int, syncInterval, roundGap time.Duration) fixtureReport {
	cluster := newQuotaCluster(quota, replicaCount)
	servers := startReplicaServers(cluster)
	defer closeReplicaServers(servers)

	syncCtx, cancelSync := context.WithCancel(ctx)
	defer cancelSync()
	go startSynchronizer(syncCtx, cluster, syncInterval)

	report := fixtureReport{
		Quota:          quota,
		ReplicaCount:   replicaCount,
		Attempts:       attempts,
		SyncIntervalMS: syncInterval.Milliseconds(),
		Rounds:         make([]probeRound, 0, rounds),
	}
	client := &http.Client{Timeout: 2 * time.Second}
	for round := 1; round <= rounds; round++ {
		report.Rounds = append(report.Rounds, runFanout(ctx, client, servers, attempts, round))
		if round < rounds {
			select {
			case <-ctx.Done():
				round = rounds
			case <-time.After(roundGap):
			}
		}
	}

	cancelSync()
	cluster.synchronize()
	report.FinalCommitted = cluster.committedUsage()
	if report.FinalCommitted > quota {
		report.AcceptedOver = report.FinalCommitted - quota
	}
	return report
}

func main() {
	quota := flag.Int("quota", 1, "quota shared by the local fixture")
	replicas := flag.Int("replicas", 4, "number of local replicas")
	attempts := flag.Int("attempts", 4, "parallel attempts per round")
	rounds := flag.Int("rounds", 2, "probe rounds")
	syncInterval := flag.Duration("sync-interval", 500*time.Millisecond, "replica aggregation interval")
	roundGap := flag.Duration("round-gap", 650*time.Millisecond, "delay between probe rounds")
	flag.Parse()

	if *quota < 1 || *replicas < 1 || *attempts < 1 || *rounds < 1 || *syncInterval <= 0 || *roundGap < 0 {
		fmt.Fprintln(os.Stderr, "all counts and sync-interval must be positive; round-gap must be non-negative")
		os.Exit(2)
	}

	report := executeFixture(context.Background(), *quota, *replicas, *attempts, *rounds, *syncInterval, *roundGap)
	encoder := json.NewEncoder(os.Stdout)
	encoder.SetIndent("", "  ")
	if err := encoder.Encode(report); err != nil {
		fmt.Fprintf(os.Stderr, "encode report: %v\n", err)
		os.Exit(1)
	}
}
