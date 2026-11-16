package server

import (
	"testing"

	"github.com/Autumn-27/artex/db"
	"golang.org/x/crypto/bcrypt"
)

const testAdminPassKey = "auth.password_hash"

// TestSeedAdminPassword covers the -p flag contract: set the password only when
// none exists, never overwrite, and reject passwords below the length floor.
func TestSeedAdminPassword(t *testing.T) {
	skipWithoutDSN(t)

	dsn, _, err := db.DSN()
	if err != nil {
		t.Fatalf("dsn: %v", err)
	}
	pg, err := db.Open(dsn)
	if err != nil {
		t.Fatalf("open db: %v", err)
	}
	t.Cleanup(func() { pg.Close() })

	// The suite shares one database, so start from a clean slate and leave it
	// that way: another test may rely on the password being unset.
	reset := func() {
		if _, err := pg.Exec(`DELETE FROM settings WHERE key = $1`, testAdminPassKey); err != nil {
			t.Fatalf("reset password setting: %v", err)
		}
	}
	reset()
	t.Cleanup(reset)

	srv := &Server{m: &Manager{pg: pg}}

	t.Run("short password is rejected", func(t *testing.T) {
		seeded, err := srv.SeedAdminPassword("short")
		if err == nil {
			t.Fatal("expected an error for a password below the minimum length")
		}
		if seeded {
			t.Fatal("must not seed an invalid password")
		}
	})

	t.Run("seeds when none is set", func(t *testing.T) {
		seeded, err := srv.SeedAdminPassword("ArtexTest12345")
		if err != nil {
			t.Fatalf("seed: %v", err)
		}
		if !seeded {
			t.Fatal("expected the password to be seeded")
		}
		hash, _, err := pg.GetSetting(testAdminPassKey)
		if err != nil || hash == "" {
			t.Fatalf("password not stored: %q %v", hash, err)
		}
		if bcrypt.CompareHashAndPassword([]byte(hash), []byte("ArtexTest12345")) != nil {
			t.Fatal("stored hash does not match the seeded password")
		}
	})

	t.Run("never overwrites an existing password", func(t *testing.T) {
		seeded, err := srv.SeedAdminPassword("AnotherPass123")
		if err != nil {
			t.Fatalf("second seed: %v", err)
		}
		if seeded {
			t.Fatal("a second seed must not overwrite the password")
		}
		hash, _, err := pg.GetSetting(testAdminPassKey)
		if err != nil {
			t.Fatal(err)
		}
		if bcrypt.CompareHashAndPassword([]byte(hash), []byte("ArtexTest12345")) != nil {
			t.Fatal("the original password was replaced")
		}
	})
}

// TestWithAdminPasswordOption checks that -p is carried into the server so New
// can seed it before the setup token is minted.
func TestWithAdminPasswordOption(t *testing.T) {
	s := &Server{}
	WithAdminPassword("ArtexTest12345")(s)
	if s.seedPassword != "ArtexTest12345" {
		t.Fatalf("seedPassword = %q", s.seedPassword)
	}
	// Unrelated options must not set a password.
	s2 := &Server{}
	WithSecretScrub()(s2)
	if s2.seedPassword != "" {
		t.Fatal("unrelated options must not set a password")
	}
}
