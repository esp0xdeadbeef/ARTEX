package config

import (
	"os"
	"path/filepath"
	"testing"
)

func TestSecretFromEnv(t *testing.T) {
	dir := t.TempDir()
	write := func(name, content string) string {
		p := filepath.Join(dir, name)
		if err := os.WriteFile(p, []byte(content), 0o600); err != nil {
			t.Fatal(err)
		}
		return p
	}

	t.Run("plain variable when no _FILE", func(t *testing.T) {
		t.Setenv("ARTEX_TEST_KEY", "  sk-env  ")
		t.Setenv("ARTEX_TEST_KEY_FILE", "")
		v, src, err := SecretFromEnv("ARTEX_TEST_KEY")
		if err != nil || v != "sk-env" || src != "environment variable ARTEX_TEST_KEY" {
			t.Fatalf("got %q %q %v", v, src, err)
		}
	})

	t.Run("file wins and strips one newline", func(t *testing.T) {
		p := write("key", "sk-file\n")
		t.Setenv("ARTEX_TEST_KEY", "sk-env")
		t.Setenv("ARTEX_TEST_KEY_FILE", p)
		v, src, err := SecretFromEnv("ARTEX_TEST_KEY")
		if err != nil || v != "sk-file" {
			t.Fatalf("got %q %q %v", v, src, err)
		}
		if src != "file ARTEX_TEST_KEY_FILE="+p {
			t.Fatalf("source = %q", src)
		}
	})

	t.Run("CRLF and no trailing newline", func(t *testing.T) {
		p := write("key-crlf", "sk-crlf\r\n")
		t.Setenv("ARTEX_TEST_KEY_FILE", p)
		if v, _, err := SecretFromEnv("ARTEX_TEST_KEY"); err != nil || v != "sk-crlf" {
			t.Fatalf("got %q %v", v, err)
		}
		p2 := write("key-bare", "sk-bare")
		t.Setenv("ARTEX_TEST_KEY_FILE", p2)
		if v, _, err := SecretFromEnv("ARTEX_TEST_KEY"); err != nil || v != "sk-bare" {
			t.Fatalf("got %q %v", v, err)
		}
	})

	t.Run("empty file is an error", func(t *testing.T) {
		p := write("empty", "\n")
		t.Setenv("ARTEX_TEST_KEY", "sk-env")
		t.Setenv("ARTEX_TEST_KEY_FILE", p)
		if _, _, err := SecretFromEnv("ARTEX_TEST_KEY"); err == nil {
			t.Fatal("expected an error for an empty file")
		}
	})

	t.Run("missing file is an error, not a fallback", func(t *testing.T) {
		t.Setenv("ARTEX_TEST_KEY", "sk-env")
		t.Setenv("ARTEX_TEST_KEY_FILE", filepath.Join(dir, "does-not-exist"))
		if _, _, err := SecretFromEnv("ARTEX_TEST_KEY"); err == nil {
			t.Fatal("expected an error for a missing file")
		}
	})
}
