package main

import (
	"crypto/sha256"
	"encoding/binary"
	"encoding/hex"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"os"
	"path"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	"github.com/Kuzz007/keenetic_xray_installer/internal/routerbundle"
)

type buildSpec struct {
	Edition string     `json:"edition"`
	Files   []specFile `json:"files"`
}

type specFile struct {
	Source string `json:"source"`
	Target string `json:"target"`
	Mode   string `json:"mode"`
	Role   string `json:"role"`
	Policy string `json:"policy"`
}

func main() {
	if err := run(); err != nil {
		fmt.Fprintln(os.Stderr, "ERROR:", err)
		os.Exit(1)
	}
}

func run() error {
	stub := flag.String("stub", "", "cross-compiled installer stub")
	specPath := flag.String("spec", "", "FULL or MINIMAL JSON file specification")
	sourceRoot := flag.String("source-root", ".", "repository root")
	binaryDir := flag.String("binary-dir", "", "directory containing router binaries")
	output := flag.String("out", "", "output .run file")
	version := flag.String("version", "dev", "bundle version")
	channel := flag.String("channel", "dev", "release channel")
	commit := flag.String("commit", "", "source commit")
	goarch := flag.String("arch", "", "target Go architecture")
	publishedAt := flag.String("published-at", "", "RFC3339 publication time")
	flag.Parse()

	for name, value := range map[string]string{
		"-stub": *stub, "-spec": *specPath, "-binary-dir": *binaryDir, "-out": *output, "-arch": *goarch,
	} {
		if strings.TrimSpace(value) == "" {
			return fmt.Errorf("%s is required", name)
		}
	}
	if *publishedAt == "" {
		*publishedAt = time.Now().UTC().Format(time.RFC3339)
	}

	spec, err := readSpec(*specPath)
	if err != nil {
		return err
	}
	if err := validateELF(*stub, *goarch); err != nil {
		return fmt.Errorf("installer stub: %w", err)
	}
	manifest := routerbundle.Manifest{
		Schema:      routerbundle.SchemaName,
		Edition:     spec.Edition,
		Version:     *version,
		Channel:     *channel,
		Commit:      *commit,
		OS:          "linux",
		Arch:        *goarch,
		PublishedAt: *publishedAt,
	}
	inputs := make([]routerbundle.Input, 0, len(spec.Files))
	for index, item := range spec.Files {
		input, err := makeInput(index, item, *sourceRoot, *binaryDir, *goarch)
		if err != nil {
			return err
		}
		manifest.Files = append(manifest.Files, input.File)
		inputs = append(inputs, input)
	}
	if err := routerbundle.Build(*output, *stub, manifest, inputs); err != nil {
		return err
	}
	fmt.Printf("Built %s %s for linux/%s: %s\n", strings.ToUpper(spec.Edition), *version, *goarch, *output)
	return nil
}

func readSpec(filePath string) (buildSpec, error) {
	var spec buildSpec
	f, err := os.Open(filePath)
	if err != nil {
		return spec, err
	}
	defer f.Close()
	decoder := json.NewDecoder(f)
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&spec); err != nil {
		return spec, fmt.Errorf("decode %s: %w", filePath, err)
	}
	if spec.Edition != "full" && spec.Edition != "minimal" {
		return spec, fmt.Errorf("unsupported spec edition %q", spec.Edition)
	}
	if len(spec.Files) == 0 {
		return spec, fmt.Errorf("spec %s contains no files", filePath)
	}
	return spec, nil
}

func makeInput(index int, item specFile, sourceRoot, binaryDir, goarch string) (routerbundle.Input, error) {
	var input routerbundle.Input
	if item.Source == "" || item.Target == "" {
		return input, fmt.Errorf("spec file %d requires source and target", index)
	}
	mode, err := strconv.ParseUint(item.Mode, 8, 32)
	if err != nil || mode == 0 || mode > 0777 {
		return input, fmt.Errorf("invalid mode %q for %s", item.Mode, item.Target)
	}
	sourcePath, err := resolveSource(item.Source, sourceRoot, binaryDir)
	if err != nil {
		return input, err
	}
	if strings.HasPrefix(item.Source, "@BIN/") {
		if err := validateELF(sourcePath, goarch); err != nil {
			return input, fmt.Errorf("binary %s: %w", item.Source, err)
		}
	}
	info, err := os.Stat(sourcePath)
	if err != nil {
		return input, fmt.Errorf("stat %s: %w", sourcePath, err)
	}
	if !info.Mode().IsRegular() {
		return input, fmt.Errorf("source is not a regular file: %s", sourcePath)
	}
	digest, err := hashFile(sourcePath)
	if err != nil {
		return input, err
	}
	base := path.Base(item.Target)
	archivePath := fmt.Sprintf("files/%03d-%s", index, base)
	policy := item.Policy
	if policy == "" {
		policy = "replace"
	}
	input.File = routerbundle.File{
		ArchivePath: archivePath,
		TargetPath:  item.Target,
		Mode:        uint32(mode),
		Size:        info.Size(),
		SHA256:      digest,
		Role:        item.Role,
		Policy:      policy,
	}
	input.SourcePath = sourcePath
	return input, nil
}

func resolveSource(source, sourceRoot, binaryDir string) (string, error) {
	if strings.HasPrefix(source, "@BIN/") {
		name := strings.TrimPrefix(source, "@BIN/")
		if name == "" || strings.ContainsAny(name, "/\\") {
			return "", fmt.Errorf("unsafe binary source %q", source)
		}
		return filepath.Join(binaryDir, name), nil
	}
	if strings.HasPrefix(source, "@BUILD/") {
		name := strings.TrimPrefix(source, "@BUILD/")
		if name == "" || strings.ContainsAny(name, "/\\") {
			return "", fmt.Errorf("unsafe build source %q", source)
		}
		return filepath.Join(binaryDir, name), nil
	}
	if strings.Contains(source, "\\") || strings.HasPrefix(source, "/") || path.Clean(source) != source || strings.HasPrefix(source, "../") {
		return "", fmt.Errorf("unsafe repository source %q", source)
	}
	return filepath.Join(sourceRoot, filepath.FromSlash(source)), nil
}

func hashFile(filePath string) (string, error) {
	f, err := os.Open(filePath)
	if err != nil {
		return "", err
	}
	defer f.Close()
	hash := sha256.New()
	if _, err := io.Copy(hash, f); err != nil {
		return "", err
	}
	return hex.EncodeToString(hash.Sum(nil)), nil
}

func validateELF(filePath, goarch string) error {
	f, err := os.Open(filePath)
	if err != nil {
		return err
	}
	defer f.Close()
	header := make([]byte, 20)
	if _, err := io.ReadFull(f, header); err != nil {
		return err
	}
	if string(header[:4]) != "\x7fELF" {
		return fmt.Errorf("%s is not an ELF executable", filePath)
	}
	if header[5] != 1 {
		return fmt.Errorf("%s is not little-endian ELF", filePath)
	}
	machine := binary.LittleEndian.Uint16(header[18:20])
	switch goarch {
	case "arm64":
		if header[4] != 2 || machine != 183 {
			return fmt.Errorf("%s is not linux/arm64 ELF", filePath)
		}
	case "mipsle":
		if header[4] != 1 || machine != 8 {
			return fmt.Errorf("%s is not linux/mipsle ELF", filePath)
		}
	default:
		return fmt.Errorf("unsupported architecture %q", goarch)
	}
	return nil
}
