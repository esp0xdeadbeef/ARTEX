package config

import (
	"fmt"
	"os"
	"strings"
)

// SecretFromEnv resolves a secret from the environment, supporting the
// `<VAR>_FILE` convention used by container runtimes (Docker/Podman secrets,
// Kubernetes secret volumes, systemd LoadCredential=):
//
//  1. If `<VAR>_FILE` is set, the secret is read from that file. The whole file
//     content is used, with one trailing newline stripped (editors and
//     `openssl rand -hex` / `base64` append one). Leading/trailing spaces are
//     kept: they may be part of the secret.
//  2. Otherwise the value of `<VAR>` itself is returned (trimmed, as before).
//
// `<VAR>_FILE` takes precedence so a deployment can mount a rotated credential
// without also having to unset the plain variable. An unreadable file is an
// error, never a silent fallback to the environment: that would hide a broken
// mount and may quietly use a stale key. A file with empty content is also an
// error.
//
// Callers must treat the result as a secret: it is never logged.
func SecretFromEnv(varName string) (value, source string, err error) {
	if path := strings.TrimSpace(os.Getenv(varName + "_FILE")); path != "" {
		b, err := os.ReadFile(path)
		if err != nil {
			return "", "", fmt.Errorf("read %s_FILE %s: %w", varName, path, err)
		}
		v := strings.TrimSuffix(strings.ReplaceAll(string(b), "\r\n", "\n"), "\n")
		if strings.TrimSpace(v) == "" {
			return "", "", fmt.Errorf("%s_FILE %s is empty", varName, path)
		}
		return v, "file " + varName + "_FILE=" + path, nil
	}
	return strings.TrimSpace(os.Getenv(varName)), "environment variable " + varName, nil
}
