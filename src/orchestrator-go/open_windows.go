package main

import (
	"errors"
	"os/exec"
	"path/filepath"
	"strings"
	"syscall"
)

var errCodeNotFound = errors.New("code not found")

func openExplorer(dir string) error {
	cmd := exec.Command("explorer.exe", filepath.Clean(dir))
	if err := cmd.Start(); err != nil {
		return err
	}
	go cmd.Wait()
	return nil
}

// openVSCode starts VS Code via its launcher found on PATH. A .cmd launcher
// runs through the cmd.exe interpreter, so paths with cmd metacharacters are refused.
func openVSCode(dir string) error {
	bin, err := exec.LookPath("code")
	if err != nil {
		return errCodeNotFound
	}
	dir = filepath.Clean(dir)
	var cmd *exec.Cmd
	ext := strings.ToLower(filepath.Ext(bin))
	if ext == ".cmd" || ext == ".bat" {
		if strings.ContainsAny(dir, "\"%^&|<>!") {
			return errors.New("unsafe path")
		}
		cmd = exec.Command("cmd.exe", "/c", bin, dir)
	} else {
		cmd = exec.Command(bin, dir)
	}
	hideWindow(cmd)
	if err := cmd.Start(); err != nil {
		return err
	}
	go cmd.Wait()
	return nil
}

func hideWindow(cmd *exec.Cmd) {
	cmd.SysProcAttr = &syscall.SysProcAttr{HideWindow: true}
}
