package routerbundle

import (
	"archive/tar"
	"compress/gzip"
	"crypto/sha256"
	"encoding/binary"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path"
	"path/filepath"
	"sort"
	"strings"
	"time"
)

const (
	SchemaName        = "keenetic-vpn.router-bundle.v1"
	ManifestName      = "bundle-manifest.json"
	footerSize        = 64
	maxManifestSize   = 1 << 20
	maxBundleFileSize = 128 << 20
	maxBundleFiles    = 256
	maxInstalledSize  = 256 << 20
)

var footerMagic = [16]byte{'K', 'V', 'P', 'N', 'B', 'U', 'N', 'D', 'L', 'E', 'v', '1'}

type Manifest struct {
	Schema      string `json:"schema"`
	Edition     string `json:"edition"`
	Version     string `json:"version"`
	Channel     string `json:"channel"`
	Commit      string `json:"commit,omitempty"`
	OS          string `json:"os"`
	Arch        string `json:"arch"`
	PublishedAt string `json:"published_at"`
	Files       []File `json:"files"`
}

type File struct {
	ArchivePath string `json:"archive_path"`
	TargetPath  string `json:"target_path"`
	Mode        uint32 `json:"mode"`
	Size        int64  `json:"size"`
	SHA256      string `json:"sha256"`
	Role        string `json:"role"`
	Policy      string `json:"policy"`
}

type Bundle struct {
	Path          string
	Manifest      Manifest
	payloadOffset int64
	payloadSize   int64
}

type Input struct {
	File       File
	SourcePath string
}

type InstallResult struct {
	Installed []string
	Preserved []string
}

type footer struct {
	PayloadSize uint64
	SHA256      [32]byte
}

func Open(filePath string) (*Bundle, error) {
	f, err := os.Open(filePath)
	if err != nil {
		return nil, err
	}
	defer f.Close()

	info, err := f.Stat()
	if err != nil {
		return nil, err
	}
	parsed, err := readFooter(f, info.Size())
	if err != nil {
		return nil, err
	}
	if parsed.PayloadSize == 0 || parsed.PayloadSize > uint64(info.Size()-footerSize) {
		return nil, errors.New("invalid bundle payload bounds")
	}
	payloadSize := int64(parsed.PayloadSize)
	payloadOffset := info.Size() - footerSize - payloadSize

	hash := sha256.New()
	if _, err := io.Copy(hash, io.NewSectionReader(f, payloadOffset, payloadSize)); err != nil {
		return nil, fmt.Errorf("hash payload: %w", err)
	}
	if !equalHash(hash.Sum(nil), parsed.SHA256[:]) {
		return nil, errors.New("bundle payload SHA256 mismatch")
	}

	bundle := &Bundle{Path: filePath, payloadOffset: payloadOffset, payloadSize: payloadSize}
	manifest, err := bundle.scan(nil)
	if err != nil {
		return nil, err
	}
	bundle.Manifest = manifest
	return bundle, nil
}

func Build(outputPath, stubPath string, manifest Manifest, inputs []Input) error {
	if len(inputs) != len(manifest.Files) {
		return fmt.Errorf("manifest has %d files but builder received %d inputs", len(manifest.Files), len(inputs))
	}
	if err := ValidateManifest(manifest); err != nil {
		return err
	}

	byArchive := make(map[string]Input, len(inputs))
	for _, input := range inputs {
		if _, exists := byArchive[input.File.ArchivePath]; exists {
			return fmt.Errorf("duplicate input archive path %q", input.File.ArchivePath)
		}
		byArchive[input.File.ArchivePath] = input
	}
	for _, file := range manifest.Files {
		input, ok := byArchive[file.ArchivePath]
		if !ok {
			return fmt.Errorf("missing input for %q", file.ArchivePath)
		}
		if input.File != file {
			return fmt.Errorf("input metadata differs from manifest for %q", file.ArchivePath)
		}
	}

	if err := os.MkdirAll(filepath.Dir(outputPath), 0755); err != nil {
		return err
	}
	tmp, err := os.CreateTemp(filepath.Dir(outputPath), ".router-bundle-*")
	if err != nil {
		return err
	}
	tmpPath := tmp.Name()
	defer os.Remove(tmpPath)

	stub, err := os.Open(stubPath)
	if err != nil {
		tmp.Close()
		return err
	}
	if _, err := io.Copy(tmp, stub); err != nil {
		stub.Close()
		tmp.Close()
		return err
	}
	if err := stub.Close(); err != nil {
		tmp.Close()
		return err
	}
	payloadOffset, err := tmp.Seek(0, io.SeekCurrent)
	if err != nil {
		tmp.Close()
		return err
	}

	hash := sha256.New()
	gz := gzip.NewWriter(io.MultiWriter(tmp, hash))
	gz.Name = ""
	gz.Comment = ""
	gz.ModTime = time.Unix(0, 0).UTC()
	tw := tar.NewWriter(gz)
	manifestJSON, err := json.MarshalIndent(manifest, "", "  ")
	if err != nil {
		tmp.Close()
		return err
	}
	manifestJSON = append(manifestJSON, '\n')
	if err := writeTarBytes(tw, ManifestName, 0644, manifestJSON); err != nil {
		tmp.Close()
		return err
	}

	files := append([]File(nil), manifest.Files...)
	sort.Slice(files, func(i, j int) bool { return files[i].ArchivePath < files[j].ArchivePath })
	for _, file := range files {
		input := byArchive[file.ArchivePath]
		if err := writeTarFile(tw, file, input.SourcePath); err != nil {
			tmp.Close()
			return err
		}
	}
	if err := tw.Close(); err != nil {
		tmp.Close()
		return err
	}
	if err := gz.Close(); err != nil {
		tmp.Close()
		return err
	}
	payloadEnd, err := tmp.Seek(0, io.SeekCurrent)
	if err != nil {
		tmp.Close()
		return err
	}
	payloadSize := payloadEnd - payloadOffset
	if err := writeFooter(tmp, uint64(payloadSize), hash.Sum(nil)); err != nil {
		tmp.Close()
		return err
	}
	if err := tmp.Chmod(0755); err != nil {
		tmp.Close()
		return err
	}
	if err := tmp.Sync(); err != nil {
		tmp.Close()
		return err
	}
	if err := tmp.Close(); err != nil {
		return err
	}
	if err := os.Rename(tmpPath, outputPath); err != nil {
		if removeErr := os.Remove(outputPath); removeErr != nil && !errors.Is(removeErr, os.ErrNotExist) {
			return err
		}
		if err := os.Rename(tmpPath, outputPath); err != nil {
			return err
		}
	}
	_, err = Open(outputPath)
	return err
}

func ValidateManifest(manifest Manifest) error {
	if manifest.Schema != SchemaName {
		return fmt.Errorf("unsupported manifest schema %q", manifest.Schema)
	}
	if manifest.Edition != "full" && manifest.Edition != "minimal" {
		return fmt.Errorf("unsupported edition %q", manifest.Edition)
	}
	if strings.TrimSpace(manifest.Version) == "" {
		return errors.New("manifest version is empty")
	}
	if strings.TrimSpace(manifest.Channel) == "" {
		return errors.New("manifest channel is empty")
	}
	if manifest.OS != "linux" {
		return fmt.Errorf("unsupported operating system %q", manifest.OS)
	}
	if manifest.Arch != "arm64" && manifest.Arch != "mipsle" {
		return fmt.Errorf("unsupported router architecture %q", manifest.Arch)
	}
	if _, err := time.Parse(time.RFC3339, manifest.PublishedAt); err != nil {
		return fmt.Errorf("invalid published_at: %w", err)
	}
	if len(manifest.Files) == 0 {
		return errors.New("manifest contains no files")
	}
	if len(manifest.Files) > maxBundleFiles {
		return fmt.Errorf("manifest contains too many files: %d", len(manifest.Files))
	}

	archives := make(map[string]struct{}, len(manifest.Files))
	targets := make(map[string]struct{}, len(manifest.Files))
	var totalSize int64
	for _, file := range manifest.Files {
		if !safeArchivePath(file.ArchivePath) || file.ArchivePath == ManifestName {
			return fmt.Errorf("unsafe archive path %q", file.ArchivePath)
		}
		if _, exists := archives[file.ArchivePath]; exists {
			return fmt.Errorf("duplicate archive path %q", file.ArchivePath)
		}
		archives[file.ArchivePath] = struct{}{}
		if !strings.HasPrefix(file.TargetPath, "/opt/") || path.Clean(file.TargetPath) != file.TargetPath {
			return fmt.Errorf("unsafe target path %q", file.TargetPath)
		}
		if _, exists := targets[file.TargetPath]; exists {
			return fmt.Errorf("duplicate target path %q", file.TargetPath)
		}
		targets[file.TargetPath] = struct{}{}
		if file.Mode == 0 || file.Mode > 0777 {
			return fmt.Errorf("invalid mode %#o for %q", file.Mode, file.TargetPath)
		}
		if file.Size < 0 || file.Size > maxBundleFileSize {
			return fmt.Errorf("invalid size %d for %q", file.Size, file.TargetPath)
		}
		totalSize += file.Size
		if totalSize > maxInstalledSize {
			return fmt.Errorf("manifest payload exceeds %d bytes", maxInstalledSize)
		}
		decoded, err := hex.DecodeString(file.SHA256)
		if err != nil || len(decoded) != sha256.Size {
			return fmt.Errorf("invalid SHA256 for %q", file.TargetPath)
		}
		if strings.TrimSpace(file.Role) == "" {
			return fmt.Errorf("empty role for %q", file.TargetPath)
		}
		if file.Policy != "replace" && file.Policy != "preserve" {
			return fmt.Errorf("invalid policy %q for %q", file.Policy, file.TargetPath)
		}
	}
	return nil
}

func (bundle *Bundle) Verify() error {
	_, err := bundle.scan(nil)
	return err
}

func (bundle *Bundle) Install(root string) (InstallResult, error) {
	var result InstallResult
	root, err := filepath.Abs(root)
	if err != nil {
		return result, err
	}
	if err := os.MkdirAll(filepath.Join(root, "opt", "tmp"), 0755); err != nil {
		return result, fmt.Errorf("create staging parent: %w", err)
	}
	stage, err := os.MkdirTemp(filepath.Join(root, "opt", "tmp"), ".keenetic-vpn-install-")
	if err != nil {
		return result, fmt.Errorf("create staging directory: %w", err)
	}
	defer os.RemoveAll(stage)

	staged := make(map[string]string, len(bundle.Manifest.Files))
	_, err = bundle.scan(func(file File, reader io.Reader) error {
		stagedPath := filepath.Join(stage, "payload", filepath.FromSlash(file.ArchivePath))
		if err := os.MkdirAll(filepath.Dir(stagedPath), 0755); err != nil {
			return err
		}
		out, err := os.OpenFile(stagedPath, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0600)
		if err != nil {
			return err
		}
		_, copyErr := io.Copy(out, reader)
		closeErr := out.Close()
		if copyErr != nil {
			return copyErr
		}
		if closeErr != nil {
			return closeErr
		}
		staged[file.ArchivePath] = stagedPath
		return nil
	})
	if err != nil {
		return result, fmt.Errorf("extract verified payload: %w", err)
	}

	type appliedFile struct {
		target    string
		backup    string
		hadBackup bool
	}
	applied := make([]appliedFile, 0, len(bundle.Manifest.Files))
	rollback := func() {
		for i := len(applied) - 1; i >= 0; i-- {
			item := applied[i]
			_ = os.Remove(item.target)
			if item.hadBackup {
				_ = os.Rename(item.backup, item.target)
			}
		}
	}

	transactionID := fmt.Sprintf("%d", time.Now().UnixNano())
	for _, file := range bundle.Manifest.Files {
		target, err := resolveTarget(root, file.TargetPath)
		if err != nil {
			rollback()
			return result, err
		}
		targetInfo, targetErr := os.Lstat(target)
		if targetErr == nil && !targetInfo.Mode().IsRegular() {
			rollback()
			return result, fmt.Errorf("refusing to replace non-regular target %q", file.TargetPath)
		}
		if targetErr != nil && !errors.Is(targetErr, os.ErrNotExist) {
			rollback()
			return result, targetErr
		}
		if file.Policy == "preserve" {
			if targetErr == nil {
				result.Preserved = append(result.Preserved, file.TargetPath)
				continue
			}
		}
		if err := os.MkdirAll(filepath.Dir(target), 0755); err != nil {
			rollback()
			return result, err
		}
		if err := ensureWithinRoot(root, filepath.Dir(target)); err != nil {
			rollback()
			return result, err
		}

		newPath := filepath.Join(filepath.Dir(target), "."+filepath.Base(target)+".kvpn-new-"+transactionID)
		backupPath := filepath.Join(filepath.Dir(target), "."+filepath.Base(target)+".kvpn-old-"+transactionID)
		if err := copyFile(staged[file.ArchivePath], newPath, os.FileMode(file.Mode)); err != nil {
			rollback()
			return result, err
		}

		hadBackup := false
		if _, err := os.Lstat(target); err == nil {
			if err := os.Rename(target, backupPath); err != nil {
				_ = os.Remove(newPath)
				rollback()
				return result, err
			}
			hadBackup = true
		} else if !errors.Is(err, os.ErrNotExist) {
			_ = os.Remove(newPath)
			rollback()
			return result, err
		}
		if err := os.Rename(newPath, target); err != nil {
			if hadBackup {
				_ = os.Rename(backupPath, target)
			}
			_ = os.Remove(newPath)
			rollback()
			return result, err
		}
		applied = append(applied, appliedFile{target: target, backup: backupPath, hadBackup: hadBackup})
		result.Installed = append(result.Installed, file.TargetPath)
	}
	for _, item := range applied {
		if item.hadBackup {
			_ = os.Remove(item.backup)
		}
	}
	return result, nil
}

func (bundle *Bundle) scan(consume func(File, io.Reader) error) (Manifest, error) {
	f, err := os.Open(bundle.Path)
	if err != nil {
		return Manifest{}, err
	}
	defer f.Close()
	gz, err := gzip.NewReader(io.NewSectionReader(f, bundle.payloadOffset, bundle.payloadSize))
	if err != nil {
		return Manifest{}, fmt.Errorf("open bundle payload: %w", err)
	}
	defer gz.Close()
	tr := tar.NewReader(gz)

	header, err := tr.Next()
	if err != nil {
		return Manifest{}, fmt.Errorf("read manifest header: %w", err)
	}
	if header.Name != ManifestName || !header.FileInfo().Mode().IsRegular() {
		return Manifest{}, errors.New("bundle manifest must be the first regular archive entry")
	}
	if header.Size < 0 || header.Size > maxManifestSize {
		return Manifest{}, errors.New("bundle manifest is too large")
	}
	manifestBytes, err := io.ReadAll(io.LimitReader(tr, maxManifestSize+1))
	if err != nil {
		return Manifest{}, err
	}
	var manifest Manifest
	decoder := json.NewDecoder(strings.NewReader(string(manifestBytes)))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&manifest); err != nil {
		return Manifest{}, fmt.Errorf("decode bundle manifest: %w", err)
	}
	var trailing any
	if err := decoder.Decode(&trailing); !errors.Is(err, io.EOF) {
		if err == nil {
			return Manifest{}, errors.New("bundle manifest contains trailing JSON")
		}
		return Manifest{}, fmt.Errorf("decode trailing bundle manifest data: %w", err)
	}
	if err := ValidateManifest(manifest); err != nil {
		return Manifest{}, err
	}

	expected := make(map[string]File, len(manifest.Files))
	seen := make(map[string]struct{}, len(manifest.Files))
	for _, file := range manifest.Files {
		expected[file.ArchivePath] = file
	}
	for {
		header, err = tr.Next()
		if errors.Is(err, io.EOF) {
			break
		}
		if err != nil {
			return Manifest{}, fmt.Errorf("read archive: %w", err)
		}
		if !safeArchivePath(header.Name) || !header.FileInfo().Mode().IsRegular() {
			return Manifest{}, fmt.Errorf("unsafe archive entry %q", header.Name)
		}
		file, ok := expected[header.Name]
		if !ok {
			return Manifest{}, fmt.Errorf("unexpected archive entry %q", header.Name)
		}
		if _, duplicate := seen[header.Name]; duplicate {
			return Manifest{}, fmt.Errorf("duplicate archive entry %q", header.Name)
		}
		seen[header.Name] = struct{}{}
		if header.Size != file.Size {
			return Manifest{}, fmt.Errorf("size mismatch for %q", header.Name)
		}
		if uint32(header.Mode)&0777 != file.Mode {
			return Manifest{}, fmt.Errorf("mode mismatch for %q", header.Name)
		}
		hash := sha256.New()
		reader := io.TeeReader(tr, hash)
		if consume != nil {
			if err := consume(file, reader); err != nil {
				return Manifest{}, fmt.Errorf("consume %q: %w", header.Name, err)
			}
		}
		if _, err := io.Copy(io.Discard, reader); err != nil {
			return Manifest{}, err
		}
		if hex.EncodeToString(hash.Sum(nil)) != strings.ToLower(file.SHA256) {
			return Manifest{}, fmt.Errorf("file SHA256 mismatch for %q", header.Name)
		}
	}
	if len(seen) != len(expected) {
		return Manifest{}, fmt.Errorf("bundle is missing %d file(s)", len(expected)-len(seen))
	}
	return manifest, nil
}

func readFooter(reader io.ReaderAt, size int64) (footer, error) {
	var parsed footer
	if size < footerSize {
		return parsed, errors.New("file is too small to be a router bundle")
	}
	buf := make([]byte, footerSize)
	if _, err := reader.ReadAt(buf, size-footerSize); err != nil {
		return parsed, err
	}
	if string(buf[:16]) != string(footerMagic[:]) {
		return parsed, errors.New("router bundle footer not found")
	}
	parsed.PayloadSize = binary.LittleEndian.Uint64(buf[16:24])
	copy(parsed.SHA256[:], buf[24:56])
	for _, value := range buf[56:] {
		if value != 0 {
			return footer{}, errors.New("router bundle footer reserved bytes are not zero")
		}
	}
	return parsed, nil
}

func writeFooter(writer io.Writer, payloadSize uint64, digest []byte) error {
	if len(digest) != sha256.Size {
		return errors.New("invalid payload digest size")
	}
	buf := make([]byte, footerSize)
	copy(buf[:16], footerMagic[:])
	binary.LittleEndian.PutUint64(buf[16:24], payloadSize)
	copy(buf[24:56], digest)
	_, err := writer.Write(buf)
	return err
}

func writeTarBytes(tw *tar.Writer, name string, mode int64, data []byte) error {
	header := &tar.Header{Name: name, Mode: mode, Size: int64(len(data)), ModTime: time.Unix(0, 0).UTC(), Typeflag: tar.TypeReg}
	if err := tw.WriteHeader(header); err != nil {
		return err
	}
	_, err := tw.Write(data)
	return err
}

func writeTarFile(tw *tar.Writer, file File, sourcePath string) error {
	source, err := os.Open(sourcePath)
	if err != nil {
		return fmt.Errorf("open %q: %w", sourcePath, err)
	}
	defer source.Close()
	header := &tar.Header{Name: file.ArchivePath, Mode: int64(file.Mode), Size: file.Size, ModTime: time.Unix(0, 0).UTC(), Typeflag: tar.TypeReg}
	if err := tw.WriteHeader(header); err != nil {
		return err
	}
	written, err := io.Copy(tw, source)
	if err != nil {
		return err
	}
	if written != file.Size {
		return fmt.Errorf("source size changed while packing %q", sourcePath)
	}
	return nil
}

func safeArchivePath(name string) bool {
	return name != "" && !strings.Contains(name, "\\") && !strings.HasPrefix(name, "/") && path.Clean(name) == name && name != "." && !strings.HasPrefix(name, "../")
}

func resolveTarget(root, target string) (string, error) {
	if !strings.HasPrefix(target, "/opt/") || path.Clean(target) != target {
		return "", fmt.Errorf("unsafe target path %q", target)
	}
	resolved := filepath.Join(root, filepath.FromSlash(strings.TrimPrefix(target, "/")))
	if err := ensureLexicallyWithinRoot(root, resolved); err != nil {
		return "", err
	}
	return resolved, nil
}

func ensureLexicallyWithinRoot(root, candidate string) error {
	relative, err := filepath.Rel(root, candidate)
	if err != nil {
		return err
	}
	if relative == ".." || strings.HasPrefix(relative, ".."+string(filepath.Separator)) {
		return fmt.Errorf("path %q escapes install root", candidate)
	}
	return nil
}

func ensureWithinRoot(root, directory string) error {
	realRoot, err := filepath.EvalSymlinks(root)
	if err != nil {
		return err
	}
	realDirectory, err := filepath.EvalSymlinks(directory)
	if err != nil {
		return err
	}
	return ensureLexicallyWithinRoot(realRoot, realDirectory)
}

func copyFile(sourcePath, targetPath string, mode os.FileMode) error {
	source, err := os.Open(sourcePath)
	if err != nil {
		return err
	}
	defer source.Close()
	target, err := os.OpenFile(targetPath, os.O_CREATE|os.O_EXCL|os.O_WRONLY, mode)
	if err != nil {
		return err
	}
	_, copyErr := io.Copy(target, source)
	syncErr := target.Sync()
	closeErr := target.Close()
	if copyErr != nil {
		_ = os.Remove(targetPath)
		return copyErr
	}
	if syncErr != nil {
		_ = os.Remove(targetPath)
		return syncErr
	}
	if closeErr != nil {
		_ = os.Remove(targetPath)
		return closeErr
	}
	return nil
}

func equalHash(left, right []byte) bool {
	if len(left) != len(right) {
		return false
	}
	var difference byte
	for i := range left {
		difference |= left[i] ^ right[i]
	}
	return difference == 0
}
