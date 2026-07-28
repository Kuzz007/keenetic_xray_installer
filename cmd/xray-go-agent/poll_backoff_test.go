package main

import (
	"testing"
	"time"
)

func TestPollBackoff(t *testing.T) {
	interval := 5 * time.Second
	cases := []struct {
		consecutiveFailures int
		want                time.Duration
	}{
		{0, 5 * time.Second},
		{1, 10 * time.Second},
		{2, 20 * time.Second},
		{3, 40 * time.Second},
		{4, 40 * time.Second},  // capped
		{50, 40 * time.Second}, // still capped
	}
	for _, c := range cases {
		if got := pollBackoff(interval, c.consecutiveFailures); got != c.want {
			t.Errorf("pollBackoff(%v, %d) = %v, want %v", interval, c.consecutiveFailures, got, c.want)
		}
	}
}
