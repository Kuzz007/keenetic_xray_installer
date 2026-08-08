package main

func updateAgent() (bool, string) {
	manifest, artifact, err := fetchAgentChannel("latest")
	if err != nil {
		return false, "safe latest agent update check failed: " + err.Error()
	}
	return scheduleAgentRelease("latest", manifest.Version, artifact.SHA256)
}
