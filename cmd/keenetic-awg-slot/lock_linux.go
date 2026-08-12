//go:build linux

package main

import (
	"errors"
	"os"
	"syscall"
)

func acquireLock(opts options) (func(), error) {
	if err := ensurePrivateDir(opts.dir); err != nil {
		return nil, err
	}
	file, err := os.OpenFile(opts.dir+"/.lock", os.O_CREATE|os.O_RDWR, 0600)
	if err != nil {
		return nil, err
	}
	if err := syscall.Flock(int(file.Fd()), syscall.LOCK_EX|syscall.LOCK_NB); err != nil {
		_ = file.Close()
		return nil, errors.New("another AWG slot operation is already running")
	}
	return func() {
		_ = syscall.Flock(int(file.Fd()), syscall.LOCK_UN)
		_ = file.Close()
	}, nil
}
