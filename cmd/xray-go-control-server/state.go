package main

import (
	"encoding/json"
	"fmt"
	"log"
	"os"
)

// RouterState is the subset of Router that changes on every command/result
// instead of every admin edit, so it's persisted separately from Config:
// persistConfigLocked would otherwise rewrite the whole .conf file (and its
// timestamped backups) on every queued command, coupling infrequent
// identity edits to high-frequency runtime churn. LastSeen/Status are
// intentionally excluded - they're only ever meaningful as of the last
// poll, so restoring a stale value after a restart would misrepresent a
// router as recently online right up until its next real poll corrects it.
type RouterState struct {
	Queue                 []Command `json:"queue,omitempty"`
	Results               []Result  `json:"results,omitempty"`
	RequestedAgentChannel string    `json:"requested_agent_channel,omitempty"`
}

// loadStateLocked restores each router's Queue/Results from cfg.StateFile.
// Called once at startup, before any goroutine can reach s.mu.
func (s *Server) loadStateLocked() {
	data, err := os.ReadFile(s.cfg.StateFile)
	if err != nil {
		return
	}
	if len(data) == 0 {
		return
	}
	var state map[string]RouterState
	if err := json.Unmarshal(data, &state); err != nil {
		log.Printf("state: failed to parse %s: %v", s.cfg.StateFile, err)
		return
	}
	for id, st := range state {
		if rt := s.cfg.Routers[id]; rt != nil {
			rt.Queue = st.Queue
			rt.Results = st.Results
			rt.RequestedAgentChannel = st.RequestedAgentChannel
		}
	}
}

// persistStateLocked writes every router's Queue/Results to cfg.StateFile,
// atomically (write to a temp file, then rename). Called after every
// enqueue/dequeue/result-append so a restart never silently drops a command
// that was already accepted or a result the router already reported.
// Caller must hold s.mu. Failures are logged, not fatal: the in-memory
// state (and the HTTP response already sent for it) stays authoritative
// for this process's lifetime either way.
func (s *Server) persistStateLocked() {
	state := make(map[string]RouterState, len(s.cfg.Routers))
	for id, rt := range s.cfg.Routers {
		if len(rt.Queue) == 0 && len(rt.Results) == 0 && rt.RequestedAgentChannel == "" {
			continue
		}
		state[id] = RouterState{
			Queue:                 rt.Queue,
			Results:               rt.Results,
			RequestedAgentChannel: rt.RequestedAgentChannel,
		}
	}
	data, err := json.MarshalIndent(state, "", "  ")
	if err != nil {
		log.Printf("state: marshal failed: %v", err)
		return
	}
	tmp := fmt.Sprintf("%s.%d.tmp", s.cfg.StateFile, os.Getpid())
	if err := os.WriteFile(tmp, data, 0600); err != nil {
		log.Printf("state: write failed: %v", err)
		return
	}
	if err := os.Rename(tmp, s.cfg.StateFile); err != nil {
		log.Printf("state: rename failed: %v", err)
		_ = os.Remove(tmp)
	}
}
