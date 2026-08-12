package main

import "testing"

func TestActionMutatesXray(t *testing.T) {
	mutating := []string{
		"switch_primary", "switch_backup", "set_primary_source", "set_backup_source",
		"update_subscription", "recover_run", "mux_enable", "mux_disable", "mux_snapshot", "mux_rollback",
	}
	for _, action := range mutating {
		if !actionMutatesXray(action) {
			t.Fatalf("action %q must be blocked while AWG owns Xray", action)
		}
	}
	for _, action := range []string{"status", "source_status", "doctor", "recover_status", "mux_status", "agent_update_check"} {
		if actionMutatesXray(action) {
			t.Fatalf("read-only action %q must remain available", action)
		}
	}
}
