package main

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/json"
	"encoding/pem"
	"math/big"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestSecretActionDoesNotExposeValue(t *testing.T) {
	t.Setenv("APP_SECRET", "super-secret-value")
	a := &app{}
	req := httptest.NewRequest(http.MethodPost, "/api/secret", nil)
	rec := httptest.NewRecorder()

	a.secretAction(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, want %d", rec.Code, http.StatusOK)
	}
	if strings.Contains(rec.Body.String(), "super-secret-value") {
		t.Fatal("secret value leaked in response")
	}
	var body map[string]any
	if err := json.Unmarshal(rec.Body.Bytes(), &body); err != nil {
		t.Fatal(err)
	}
	if body["present"] != true || body["value_exposed"] != false {
		t.Fatalf("unexpected response: %#v", body)
	}
}

func TestSecretActionFailsWhenBindingMissing(t *testing.T) {
	t.Setenv("APP_SECRET", "")
	a := &app{}
	req := httptest.NewRequest(http.MethodPost, "/api/secret", nil)
	rec := httptest.NewRecorder()

	a.secretAction(rec, req)

	if rec.Code != http.StatusServiceUnavailable {
		t.Fatalf("status = %d, want %d", rec.Code, http.StatusServiceUnavailable)
	}
}

func TestMetricsVerifyAction(t *testing.T) {
	a := &app{}
	a.requests.Store(42)
	req := httptest.NewRequest(http.MethodPost, "/api/metrics/verify", nil)
	rec := httptest.NewRecorder()

	a.metricsVerifyAction(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, want %d", rec.Code, http.StatusOK)
	}
	var body map[string]any
	if err := json.Unmarshal(rec.Body.Bytes(), &body); err != nil {
		t.Fatal(err)
	}
	if body["metric"] != "baseharbor_demo_requests_total" || body["present"] != true {
		t.Fatalf("unexpected response: %#v", body)
	}
}

func TestStatusPublishesSafeDeveloperLinks(t *testing.T) {
	t.Setenv("APP_SECRET", "super-secret-value")
	t.Setenv("BASEHARBOR_RUNTIME_DOCS_URL", "https://127.0.0.1:46811/")
	a := &app{}
	req := httptest.NewRequest(http.MethodGet, "/api/status", nil)
	rec := httptest.NewRecorder()

	a.status(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, want %d", rec.Code, http.StatusOK)
	}
	body := rec.Body.String()
	if !strings.Contains(body, "https://127.0.0.1:46811/") {
		t.Fatalf("Swagger URL missing from status: %s", body)
	}
	if strings.Contains(body, "super-secret-value") {
		t.Fatalf("secret value leaked in status: %s", body)
	}
}

func TestServerTransportDefaultsToHTTPForStandalone(t *testing.T) {
	t.Setenv("TLS_CERT_FILE", "")
	t.Setenv("TLS_KEY_FILE", "")
	t.Setenv("BASEHARBOR_RUNTIME_API_URL", "")
	t.Setenv("BASEHARBOR_RUNTIME_TOKEN_FILE", "")

	mode, cert, key, err := serverTransport()
	if err != nil {
		t.Fatal(err)
	}
	if mode != "http" || cert != "" || key != "" {
		t.Fatalf("got mode=%q cert=%q key=%q", mode, cert, key)
	}
}

func TestServerTransportFailsClosedForManagedAppWithoutTLS(t *testing.T) {
	t.Setenv("TLS_CERT_FILE", "")
	t.Setenv("TLS_KEY_FILE", "")
	t.Setenv("BASEHARBOR_RUNTIME_API_URL", "https://baseharbor-runtime:8443")

	if _, _, _, err := serverTransport(); err == nil {
		t.Fatal("expected BaseHarbor-managed app without TLS bindings to fail closed")
	}
}

func TestServerTransportRequiresCompleteTLSBinding(t *testing.T) {
	t.Setenv("TLS_CERT_FILE", "/tmp/cert.pem")
	t.Setenv("TLS_KEY_FILE", "")

	if _, _, _, err := serverTransport(); err == nil {
		t.Fatal("expected incomplete TLS binding to fail")
	}
}

func TestServerTransportUsesManagedTLSFiles(t *testing.T) {
	dir := t.TempDir()
	cert := filepath.Join(dir, "tls.crt")
	key := filepath.Join(dir, "tls.key")
	if err := os.WriteFile(cert, []byte("cert"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(key, []byte("key"), 0o600); err != nil {
		t.Fatal(err)
	}
	t.Setenv("TLS_CERT_FILE", cert)
	t.Setenv("TLS_KEY_FILE", key)

	mode, gotCert, gotKey, err := serverTransport()
	if err != nil {
		t.Fatal(err)
	}
	if mode != "https" || gotCert != cert || gotKey != key {
		t.Fatalf("got mode=%q cert=%q key=%q", mode, gotCert, gotKey)
	}
}

func TestTLSConfigFromCAFile(t *testing.T) {
	dir := t.TempDir()
	caPath := filepath.Join(dir, "ca.pem")
	if err := os.WriteFile(caPath, testCAPEM(t), 0o644); err != nil {
		t.Fatal(err)
	}
	config, err := tlsConfigFromCAFile(caPath)
	if err != nil {
		t.Fatal(err)
	}
	if config.RootCAs == nil || config.MinVersion == 0 {
		t.Fatalf("unexpected TLS config: %+v", config)
	}
}

func TestTLSConfigFromCAFileRejectsInvalidPEM(t *testing.T) {
	path := filepath.Join(t.TempDir(), "ca.pem")
	if err := os.WriteFile(path, []byte("not-a-certificate"), 0o644); err != nil {
		t.Fatal(err)
	}
	if _, err := tlsConfigFromCAFile(path); err == nil {
		t.Fatal("expected invalid CA file to fail")
	}
}

func testCAPEM(t *testing.T) []byte {
	t.Helper()
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	now := time.Now().UTC()
	template := &x509.Certificate{
		SerialNumber:          big.NewInt(now.UnixNano()),
		Subject:               pkix.Name{CommonName: "baseharbor-demo-test-ca"},
		NotBefore:             now.Add(-time.Minute),
		NotAfter:              now.Add(time.Hour),
		IsCA:                  true,
		BasicConstraintsValid: true,
		KeyUsage:              x509.KeyUsageCertSign,
	}
	der, err := x509.CreateCertificate(rand.Reader, template, template, &key.PublicKey, key)
	if err != nil {
		t.Fatal(err)
	}
	return pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der})
}

func TestEmbeddedUIContainsPersistentHistoryAndSwaggerLink(t *testing.T) {
	data, err := webFS.ReadFile("web/index.html")
	if err != nil {
		t.Fatal(err)
	}
	page := string(data)
	for _, want := range []string{"id=\"history\"", "data-link=\"swagger\"", "Verify binding", "Verify metrics"} {
		if !strings.Contains(page, want) {
			t.Fatalf("UI missing %q", want)
		}
	}
}
