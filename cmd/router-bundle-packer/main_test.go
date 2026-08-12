package main

import (
	"path/filepath"
	"testing"
)

func TestResolveSourceBuildArtifact(t *testing.T) {
	binaryDir := t.TempDir()
	got, err := resolveSource("@BUILD/awg-runtime-provenance.txt", t.TempDir(), binaryDir)
	if err != nil {
		t.Fatal(err)
	}
	want := filepath.Join(binaryDir, "awg-runtime-provenance.txt")
	if got != want {
		t.Fatalf("resolved path = %q, want %q", got, want)
	}
	for _, source := range []string{"@BUILD/", "@BUILD/../secret", `@BUILD/dir\secret`} {
		if _, err := resolveSource(source, t.TempDir(), binaryDir); err == nil {
			t.Fatalf("unsafe build source %q was accepted", source)
		}
	}
}
