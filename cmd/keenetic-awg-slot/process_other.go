//go:build !linux

package main

import "os/exec"

func detachProcess(_ *exec.Cmd) {}
