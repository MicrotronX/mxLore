package main

import (
	"crypto/rand"
	"fmt"
	"net/http"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"sync"
)

var (
	deviceIDOnce  sync.Once
	deviceIDValue string
)

// deviceIDDir returns the per-user, per-machine directory for device.id.
// Windows uses LOCALAPPDATA like the Delphi proxy, so both ports on one
// machine share the same id. Not next to the INI: a copied proxy folder must
// not carry the device id to another machine (Spec#17110).
func deviceIDDir() (string, error) {
	if runtime.GOOS == "windows" {
		if d := os.Getenv("LOCALAPPDATA"); d != "" {
			return filepath.Join(d, "mxLore"), nil
		}
	}
	d, err := os.UserConfigDir()
	if err != nil {
		return "", err
	}
	return filepath.Join(d, "mxLore"), nil
}

func newUUID() (string, error) {
	b := make([]byte, 16)
	if _, err := rand.Read(b); err != nil {
		return "", err
	}
	b[6] = (b[6] & 0x0f) | 0x40
	b[8] = (b[8] & 0x3f) | 0x80
	return fmt.Sprintf("%x-%x-%x-%x-%x", b[0:4], b[4:6], b[6:8], b[8:10], b[10:16]), nil
}

func loadDeviceID() (string, error) {
	dir, err := deviceIDDir()
	if err != nil {
		return "", err
	}
	file := filepath.Join(dir, "device.id")
	if _, err := os.Stat(file); os.IsNotExist(err) {
		if err := os.MkdirAll(dir, 0o700); err != nil {
			return "", err
		}
		id, err := newUUID()
		if err != nil {
			return "", err
		}
		// Temp file + hard link: the link fails when a parallel proxy created
		// device.id first, and both then read the winner.
		tmp := fmt.Sprintf("%s.%d.tmp", file, os.Getpid())
		if err := os.WriteFile(tmp, []byte(id), 0o600); err != nil {
			return "", err
		}
		_ = os.Link(tmp, file)
		_ = os.Remove(tmp)
	}
	data, err := os.ReadFile(file)
	if err != nil {
		return "", err
	}
	return strings.TrimSpace(string(data)), nil
}

// deviceID returns the cached device id; "" when it could not be loaded or
// created — the header is then omitted, like an old proxy.
func deviceID() string {
	deviceIDOnce.Do(func() {
		id, err := loadDeviceID()
		if err != nil {
			logMsg("WARN: device id unavailable: " + err.Error())
			return
		}
		deviceIDValue = id
	})
	return deviceIDValue
}

// setIdentityHeaders adds X-Device-Id and X-Proxy-Version to a request.
func setIdentityHeaders(req *http.Request) {
	if id := deviceID(); id != "" {
		req.Header.Set("X-Device-Id", id)
	}
	req.Header.Set("X-Proxy-Version", proxyVersion)
}
