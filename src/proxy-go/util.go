package main

import "os"

func fileExists(path string) bool {
	info, err := os.Stat(path)
	return err == nil && !info.IsDir()
}

func dirExists(path string) bool {
	info, err := os.Stat(path)
	return err == nil && info.IsDir()
}

// safePrefix returns the first 6 chars of a string (for masking API keys in logs).
func safePrefix(s string) string {
	if len(s) > 6 {
		return s[:6]
	}
	return s
}

func boolStr(b bool) string {
	if b {
		return "True"
	}
	return "False"
}
