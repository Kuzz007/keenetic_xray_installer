package main

import (
	"crypto/sha256"
	"encoding/hex"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/Kuzz007/keenetic_xray_installer/internal/routerbundle"
)

func TestRunBundleCommands(t *testing.T) {
	temp := t.TempDir()
	stub := filepath.Join(temp, "stub")
	source := filepath.Join(temp, "helper")
	if err := os.WriteFile(stub, []byte("test stub"), 0755); err != nil {
		t.Fatal(err)
	}
	content := []byte("#!/bin/sh\necho ok\n")
	if err := os.WriteFile(source, content, 0755); err != nil {
		t.Fatal(err)
	}
	digest := sha256.Sum256(content)
	file := routerbundle.File{
		ArchivePath: "files/000-helper",
		TargetPath:  "/opt/bin/test-helper",
		Mode:        0755,
		Size:        int64(len(content)),
		SHA256:      hex.EncodeToString(digest[:]),
		Role:        "test-helper",
		Policy:      "replace",
	}
	manifest := routerbundle.Manifest{
		Schema:      routerbundle.SchemaName,
		Edition:     "minimal",
		Version:     "dev-test",
		Channel:     "dev",
		OS:          "linux",
		Arch:        "arm64",
		PublishedAt: time.Unix(0, 0).UTC().Format(time.RFC3339),
		Files:       []routerbundle.File{file},
	}
	bundlePath := filepath.Join(temp, "bundle.run")
	if err := routerbundle.Build(bundlePath, stub, manifest, []routerbundle.Input{{File: file, SourcePath: source}}); err != nil {
		t.Fatal(err)
	}

	for _, args := range [][]string{
		{"info", "--bundle", bundlePath},
		{"verify", "--bundle", bundlePath},
		{"list", "--bundle", bundlePath},
		{"plan", "--bundle", bundlePath, "--allow-arch-mismatch"},
	} {
		if err := run(args); err != nil {
			t.Fatalf("run(%q): %v", args, err)
		}
	}
	if err := run([]string{"install", "--bundle", bundlePath, "--root", filepath.Join(temp, "root"), "--allow-arch-mismatch"}); err == nil {
		t.Fatal("install without --yes succeeded")
	}
	root := filepath.Join(temp, "root")
	if err := run([]string{"install", "--bundle", bundlePath, "--root", root, "--allow-arch-mismatch", "--yes"}); err != nil {
		t.Fatal(err)
	}
	installed, err := os.ReadFile(filepath.Join(root, "opt", "bin", "test-helper"))
	if err != nil {
		t.Fatal(err)
	}
	if string(installed) != string(content) {
		t.Fatalf("installed content = %q, want %q", installed, content)
	}
}
