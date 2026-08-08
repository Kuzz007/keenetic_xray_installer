package routerbundle

import (
	"archive/tar"
	"compress/gzip"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestBuildOpenAndInstall(t *testing.T) {
	t.Parallel()
	temp := t.TempDir()
	sourceOne := writeTestFile(t, temp, "resolver", "new resolver")
	sourceTwo := writeTestFile(t, temp, "agent", "new agent")
	manifest, inputs := testManifest(t, []testInput{
		{source: sourceOne, archive: "files/000-resolver", target: "/opt/bin/xray-failover-go", policy: "replace"},
		{source: sourceTwo, archive: "files/001-agent", target: "/opt/bin/xray-go-agent", policy: "preserve"},
	})
	bundlePath := buildTestBundle(t, temp, manifest, inputs)

	bundle, err := Open(bundlePath)
	if err != nil {
		t.Fatal(err)
	}
	if bundle.Manifest.Edition != "minimal" || len(bundle.Manifest.Files) != 2 {
		t.Fatalf("unexpected manifest: %+v", bundle.Manifest)
	}

	root := filepath.Join(temp, "root")
	writeTestFile(t, filepath.Join(root, "opt", "bin"), "xray-failover-go", "old resolver")
	writeTestFile(t, filepath.Join(root, "opt", "bin"), "xray-go-agent", "running agent")
	writeTestFile(t, filepath.Join(root, "opt", "etc", "xray"), "config.json", "user config")
	result, err := bundle.Install(root)
	if err != nil {
		t.Fatal(err)
	}
	if len(result.Installed) != 1 || len(result.Preserved) != 1 {
		t.Fatalf("unexpected result: %+v", result)
	}
	assertTestFile(t, filepath.Join(root, "opt", "bin", "xray-failover-go"), "new resolver")
	assertTestFile(t, filepath.Join(root, "opt", "bin", "xray-go-agent"), "running agent")
	assertTestFile(t, filepath.Join(root, "opt", "etc", "xray", "config.json"), "user config")
}

func TestOpenRejectsCorruptPayload(t *testing.T) {
	t.Parallel()
	temp := t.TempDir()
	source := writeTestFile(t, temp, "source", "payload")
	manifest, inputs := testManifest(t, []testInput{{source: source, archive: "files/000-source", target: "/opt/bin/source", policy: "replace"}})
	bundlePath := buildTestBundle(t, temp, manifest, inputs)
	data, err := os.ReadFile(bundlePath)
	if err != nil {
		t.Fatal(err)
	}
	data[len(data)-footerSize-1] ^= 0xff
	if err := os.WriteFile(bundlePath, data, 0755); err != nil {
		t.Fatal(err)
	}
	if _, err := Open(bundlePath); err == nil || !strings.Contains(err.Error(), "SHA256 mismatch") {
		t.Fatalf("Open() error = %v, want SHA256 mismatch", err)
	}
}

func TestOpenRejectsTraversalArchiveEntry(t *testing.T) {
	t.Parallel()
	temp := t.TempDir()
	manifest, _ := testManifest(t, []testInput{{source: "unused", archive: "files/000-source", target: "/opt/bin/source", policy: "replace", content: "payload"}})
	bundlePath := filepath.Join(temp, "malicious.run")
	writeRawBundle(t, bundlePath, manifest, []rawEntry{
		{name: "files/000-source", mode: 0755, data: []byte("payload")},
		{name: "../escape", mode: 0755, data: []byte("bad")},
	})
	if _, err := Open(bundlePath); err == nil || !strings.Contains(err.Error(), "unsafe archive entry") {
		t.Fatalf("Open() error = %v, want unsafe archive entry", err)
	}
}

func TestInstallRollsBackEarlierFiles(t *testing.T) {
	t.Parallel()
	temp := t.TempDir()
	first := writeTestFile(t, temp, "first-source", "new first")
	second := writeTestFile(t, temp, "second-source", "new second")
	manifest, inputs := testManifest(t, []testInput{
		{source: first, archive: "files/000-first", target: "/opt/bin/first", policy: "replace"},
		{source: second, archive: "files/001-second", target: "/opt/bin/blocked/second", policy: "replace"},
	})
	bundlePath := buildTestBundle(t, temp, manifest, inputs)
	bundle, err := Open(bundlePath)
	if err != nil {
		t.Fatal(err)
	}

	root := filepath.Join(temp, "root")
	writeTestFile(t, filepath.Join(root, "opt", "bin"), "first", "old first")
	writeTestFile(t, filepath.Join(root, "opt", "bin"), "blocked", "not a directory")
	if _, err := bundle.Install(root); err == nil {
		t.Fatal("Install() succeeded, want failure")
	}
	assertTestFile(t, filepath.Join(root, "opt", "bin", "first"), "old first")
}

func TestValidateManifestRejectsUnsafeTargetAndPolicy(t *testing.T) {
	t.Parallel()
	manifest, _ := testManifest(t, []testInput{{source: "unused", archive: "files/000-source", target: "/opt/bin/source", policy: "replace", content: "payload"}})
	manifest.Files[0].TargetPath = "/etc/passwd"
	if err := ValidateManifest(manifest); err == nil {
		t.Fatal("ValidateManifest() accepted target outside /opt")
	}
	manifest.Files[0].TargetPath = "/opt/bin/source"
	manifest.Files[0].Policy = "overwrite-always"
	if err := ValidateManifest(manifest); err == nil {
		t.Fatal("ValidateManifest() accepted unknown policy")
	}
}

type testInput struct {
	source  string
	archive string
	target  string
	policy  string
	content string
}

func testManifest(t *testing.T, testFiles []testInput) (Manifest, []Input) {
	t.Helper()
	manifest := Manifest{
		Schema:      SchemaName,
		Edition:     "minimal",
		Version:     "dev-test",
		Channel:     "dev",
		OS:          "linux",
		Arch:        "arm64",
		PublishedAt: time.Unix(0, 0).UTC().Format(time.RFC3339),
	}
	inputs := make([]Input, 0, len(testFiles))
	for _, item := range testFiles {
		content := item.content
		if content == "" && item.source != "unused" {
			data, err := os.ReadFile(item.source)
			if err != nil {
				t.Fatal(err)
			}
			content = string(data)
		}
		digest := sha256.Sum256([]byte(content))
		file := File{
			ArchivePath: item.archive,
			TargetPath:  item.target,
			Mode:        0755,
			Size:        int64(len(content)),
			SHA256:      hex.EncodeToString(digest[:]),
			Role:        "test",
			Policy:      item.policy,
		}
		manifest.Files = append(manifest.Files, file)
		inputs = append(inputs, Input{File: file, SourcePath: item.source})
	}
	return manifest, inputs
}

func buildTestBundle(t *testing.T, directory string, manifest Manifest, inputs []Input) string {
	t.Helper()
	stub := writeTestFile(t, directory, "stub", "ELF-STUB")
	output := filepath.Join(directory, "bundle.run")
	if err := Build(output, stub, manifest, inputs); err != nil {
		t.Fatal(err)
	}
	return output
}

type rawEntry struct {
	name string
	mode int64
	data []byte
}

func writeRawBundle(t *testing.T, output string, manifest Manifest, entries []rawEntry) {
	t.Helper()
	f, err := os.Create(output)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := f.WriteString("ELF-STUB"); err != nil {
		t.Fatal(err)
	}
	hash := sha256.New()
	gz := gzip.NewWriter(ioMultiWriter{f, hash})
	tw := tar.NewWriter(gz)
	manifestJSON, err := json.Marshal(manifest)
	if err != nil {
		t.Fatal(err)
	}
	if err := writeTarBytes(tw, ManifestName, 0644, manifestJSON); err != nil {
		t.Fatal(err)
	}
	for _, entry := range entries {
		if err := writeTarBytes(tw, entry.name, entry.mode, entry.data); err != nil {
			t.Fatal(err)
		}
	}
	if err := tw.Close(); err != nil {
		t.Fatal(err)
	}
	if err := gz.Close(); err != nil {
		t.Fatal(err)
	}
	end, err := f.Seek(0, 1)
	if err != nil {
		t.Fatal(err)
	}
	payloadSize := end - int64(len("ELF-STUB"))
	if err := writeFooter(f, uint64(payloadSize), hash.Sum(nil)); err != nil {
		t.Fatal(err)
	}
	if err := f.Close(); err != nil {
		t.Fatal(err)
	}
}

type ioMultiWriter struct {
	left  *os.File
	right interface{ Write([]byte) (int, error) }
}

func (writer ioMultiWriter) Write(data []byte) (int, error) {
	if _, err := writer.right.Write(data); err != nil {
		return 0, err
	}
	return writer.left.Write(data)
}

func writeTestFile(t *testing.T, directory, name, content string) string {
	t.Helper()
	if err := os.MkdirAll(directory, 0755); err != nil {
		t.Fatal(err)
	}
	filePath := filepath.Join(directory, name)
	if err := os.WriteFile(filePath, []byte(content), 0755); err != nil {
		t.Fatal(err)
	}
	return filePath
}

func assertTestFile(t *testing.T, filePath, want string) {
	t.Helper()
	data, err := os.ReadFile(filePath)
	if err != nil {
		t.Fatal(err)
	}
	if string(data) != want {
		t.Fatalf("%s = %q, want %q", filePath, data, want)
	}
}
