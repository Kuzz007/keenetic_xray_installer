package main

import (
	"fmt"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"
)

type doctorBatch struct {
	CommandID string
	Expected  map[string]string
	Results   map[string]doctorBatchResult
	CreatedAt time.Time
	Sent      bool
}

type doctorBatchResult struct {
	RouterID string
	Name     string
	OK       bool
	Status   string
}

var doctorBatchState = struct {
	sync.Mutex
	batches map[string]*doctorBatch
}{batches: map[string]*doctorBatch{}}

func rememberDoctorBatch(commandID string, expected map[string]string) {
	if commandID == "" || len(expected) == 0 {
		return
	}
	doctorBatchState.Lock()
	defer doctorBatchState.Unlock()
	for id, b := range doctorBatchState.batches {
		if time.Since(b.CreatedAt) > 2*time.Hour {
			delete(doctorBatchState.batches, id)
		}
	}
	doctorBatchState.batches[commandID] = &doctorBatch{CommandID: commandID, Expected: expected, Results: map[string]doctorBatchResult{}, CreatedAt: time.Now()}
}

func (s *Server) recordDoctorAllResult(routerName string, res Result) (string, bool) {
	if !strings.HasPrefix(res.CommandID, "doctor_all-") {
		return "", false
	}
	doctorBatchState.Lock()
	defer doctorBatchState.Unlock()
	b := doctorBatchState.batches[res.CommandID]
	if b == nil || b.Sent {
		return "", false
	}
	name := strings.TrimSpace(routerName)
	if name == "" {
		name = res.RouterID
	}
	b.Results[res.RouterID] = doctorBatchResult{RouterID: res.RouterID, Name: name, OK: res.OK, Status: doctorResultStatus(res)}
	if len(b.Results) < len(b.Expected) {
		return "", false
	}
	b.Sent = true
	return formatDoctorBatchSummary(b), true
}

func doctorResultStatus(res Result) string {
	if !res.OK {
		return "FAIL"
	}
	out := strings.ToUpper(res.Output)
	if strings.Contains(out, "[FAIL]") || nonzeroCounter(out, "FAIL") {
		return "FAIL"
	}
	if strings.Contains(out, "[WARN]") || nonzeroCounter(out, "WARN") {
		return "WARN"
	}
	return "OK"
}

func nonzeroCounter(out, name string) bool {
	idx := strings.Index(out, name+"=")
	if idx < 0 {
		return false
	}
	start := idx + len(name) + 1
	end := start
	for end < len(out) && out[end] >= '0' && out[end] <= '9' {
		end++
	}
	if end == start {
		return false
	}
	n, err := strconv.Atoi(out[start:end])
	return err == nil && n > 0
}

func formatDoctorBatchSummary(b *doctorBatch) string {
	ids := make([]string, 0, len(b.Expected))
	for id := range b.Expected {
		ids = append(ids, id)
	}
	sort.Strings(ids)
	okCount, warnCount, failCount := 0, 0, 0
	lines := []string{}
	for _, id := range ids {
		name := b.Expected[id]
		if strings.TrimSpace(name) == "" {
			name = id
		}
		r, got := b.Results[id]
		status := "NO RESULT"
		icon := "⚫"
		if got {
			status = r.Status
			switch status {
			case "OK":
				icon = "✅"
				okCount++
			case "WARN":
				icon = "⚠️"
				warnCount++
			default:
				icon = "❌"
				failCount++
			}
		} else {
			failCount++
		}
		lines = append(lines, fmt.Sprintf("%s %s: %s", icon, name, status))
	}
	return fmt.Sprintf("🩺 Диагностика всех завершена\n\n✅ OK: %d\n⚠️ WARN: %d\n❌ FAIL: %d\n\n%s", okCount, warnCount, failCount, strings.Join(lines, "\n"))
}
