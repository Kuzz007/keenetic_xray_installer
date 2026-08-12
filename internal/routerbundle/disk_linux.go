//go:build linux

package routerbundle

import (
	"errors"
	"syscall"
)

func availableInstallBytes(path string) (uint64, bool, error) {
	var stat syscall.Statfs_t
	if err := syscall.Statfs(path, &stat); err != nil {
		return 0, true, err
	}
	blockSize := uint64(stat.Bsize)
	availableBlocks := stat.Bavail
	if blockSize != 0 && availableBlocks > ^uint64(0)/blockSize {
		return 0, true, errors.New("available filesystem size overflows uint64")
	}
	return availableBlocks * blockSize, true, nil
}
