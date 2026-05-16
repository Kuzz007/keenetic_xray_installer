package main

import "strings"

func forceResultNotification(commandID string) bool {
	commandID = strings.TrimSpace(commandID)
	return commandID == "agent_start" ||
		commandID == "slot_change" ||
		strings.HasPrefix(commandID, "manual_test")
}
