package main

import (
	"bytes"
	"context"
	"crypto/tls"
	"crypto/x509"
	"database/sql"
	"embed"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
	"net/url"
	"os"
	"strconv"
	"strings"
	"sync/atomic"
	"time"

	_ "github.com/jackc/pgx/v5/stdlib"
	"github.com/minio/minio-go/v7"
	"github.com/minio/minio-go/v7/pkg/credentials"
	"github.com/redis/go-redis/v9"
	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/attribute"
	"go.opentelemetry.io/otel/exporters/otlp/otlptrace/otlptracehttp"
	"go.opentelemetry.io/otel/sdk/resource"
	sdktrace "go.opentelemetry.io/otel/sdk/trace"
	semconv "go.opentelemetry.io/otel/semconv/v1.30.0"
)

//go:embed web/*
var webFS embed.FS

type capabilityState struct {
	Ready    bool   `json:"ready"`
	Optional bool   `json:"optional,omitempty"`
	Detail   string `json:"detail,omitempty"`
}

type app struct {
	db        *sql.DB
	cache     *redis.Client
	s3        *minio.Client
	s3Bucket  string
	companion string
	requests  atomic.Uint64
}

func main() {
	ctx := context.Background()
	a := &app{companion: os.Getenv("COMPANION_URL")}
	a.db = openDB()
	a.cache = openCache()
	a.s3, a.s3Bucket = openS3()
	shutdownTrace := configureTracing(ctx)
	defer shutdownTrace(ctx)

	mux := http.NewServeMux()
	mux.HandleFunc("/healthz", a.health)
	mux.HandleFunc("/metrics", a.metrics)
	mux.HandleFunc("/api/status", a.status)
	mux.HandleFunc("/api/sql", a.sqlAction)
	mux.HandleFunc("/api/cache", a.cacheAction)
	mux.HandleFunc("/api/object", a.objectAction)
	mux.HandleFunc("/api/secret", a.secretAction)
	mux.HandleFunc("/api/metrics/verify", a.metricsVerifyAction)
	mux.HandleFunc("/api/trace", a.traceAction)
	mux.HandleFunc("/api/companion", a.companionAction)
	mux.HandleFunc("/api/runtime-resource", a.runtimeResourceAction)
	mux.HandleFunc("/", static)

	port := env("PORT", "8080")
	server := &http.Server{Addr: ":" + port, Handler: requestLog(mux), ReadHeaderTimeout: 5 * time.Second}
	mode, certFile, keyFile, err := serverTransport()
	if err != nil {
		log.Fatal(err)
	}
	log.Printf(`{"level":"info","event":"demo_started","port":%q,"transport":%q}`, port, mode)
	if mode == "https" {
		log.Fatal(server.ListenAndServeTLS(certFile, keyFile))
	}
	log.Fatal(server.ListenAndServe())
}

func openDB() *sql.DB {
	dsn := os.Getenv("DATABASE_URL")
	if dsn == "" {
		return nil
	}
	db, err := sql.Open("pgx", dsn)
	if err != nil {
		log.Printf(`{"level":"warn","event":"sql_init_failed","error":%q}`, err.Error())
		return nil
	}
	return db
}

func openCache() *redis.Client {
	raw := firstEnv("REDIS_URL", "VALKEY_URL")
	if raw == "" {
		return nil
	}
	opts, err := redis.ParseURL(raw)
	if err != nil {
		log.Printf(`{"level":"warn","event":"cache_init_failed","error":%q}`, err.Error())
		return nil
	}
	return redis.NewClient(opts)
}

func openS3() (*minio.Client, string) {
	endpoint := firstEnv("S3_ENDPOINT", "AWS_ENDPOINT_URL")
	bucket := os.Getenv("S3_BUCKET")
	access := firstEnv("AWS_ACCESS_KEY_ID", "S3_ACCESS_KEY")
	secret := firstEnv("AWS_SECRET_ACCESS_KEY", "S3_SECRET_KEY")
	if endpoint == "" || bucket == "" || access == "" || secret == "" {
		return nil, bucket
	}
	u, err := url.Parse(endpoint)
	if err != nil || u.Host == "" {
		return nil, bucket
	}
	client, err := minio.New(u.Host, &minio.Options{
		Creds:  credentials.NewStaticV4(access, secret, ""),
		Secure: u.Scheme == "https",
	})
	if err != nil {
		return nil, bucket
	}
	return client, bucket
}

func configureTracing(ctx context.Context) func(context.Context) error {
	endpoint := os.Getenv("OTEL_EXPORTER_OTLP_ENDPOINT")
	if endpoint == "" {
		return func(context.Context) error { return nil }
	}
	opts := []otlptracehttp.Option{otlptracehttp.WithEndpointURL(endpoint)}
	if strings.HasPrefix(endpoint, "http://") {
		opts = append(opts, otlptracehttp.WithInsecure())
	}
	exporter, err := otlptracehttp.New(ctx, opts...)
	if err != nil {
		log.Printf(`{"level":"warn","event":"otel_init_failed","error":%q}`, err.Error())
		return func(context.Context) error { return nil }
	}
	res, _ := resource.Merge(resource.Default(), resource.NewWithAttributes(
		semconv.SchemaURL,
		semconv.ServiceNameKey.String(env("OTEL_SERVICE_NAME", "baseharbor-demo")),
	))
	tp := sdktrace.NewTracerProvider(sdktrace.WithBatcher(exporter), sdktrace.WithResource(res))
	otel.SetTracerProvider(tp)
	return tp.Shutdown
}

func (a *app) health(w http.ResponseWriter, _ *http.Request) {
	writeJSON(w, http.StatusOK, map[string]any{"status": "ok", "service": "baseharbor-demo"})
}

func (a *app) metrics(w http.ResponseWriter, _ *http.Request) {
	w.Header().Set("Content-Type", "text/plain; version=0.0.4")
	fmt.Fprintf(w, "# HELP baseharbor_demo_requests_total Requests served by the demo app.\n")
	fmt.Fprintf(w, "# TYPE baseharbor_demo_requests_total counter\n")
	fmt.Fprintf(w, "baseharbor_demo_requests_total %d\n", a.requests.Load())
}

func (a *app) status(w http.ResponseWriter, r *http.Request) {
	ctx, cancel := context.WithTimeout(r.Context(), 2*time.Second)
	defer cancel()

	caps := map[string]capabilityState{
		"sql":              a.sqlStatus(ctx),
		"cache":            a.cacheStatus(ctx),
		"object_storage":   a.s3Status(ctx),
		"secrets":          {Ready: os.Getenv("APP_SECRET") != "", Detail: "APP_SECRET binding present"},
		"metrics":          {Ready: true, Detail: "OpenMetrics endpoint /metrics"},
		"telemetry":        {Ready: os.Getenv("OTEL_EXPORTER_OTLP_ENDPOINT") != "", Optional: true, Detail: "standard OTLP endpoint"},
		"companion":        {Ready: a.companion != "", Optional: true, Detail: "cross-app target"},
		"runtime_resource": {Ready: runtimeResourceConfigured(), Optional: true, Detail: "BaseHarbor runtime HTTPS API"},
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"service":      "baseharbor-demo",
		"capabilities": caps,
		"links": map[string]string{
			"swagger": strings.TrimSpace(os.Getenv("BASEHARBOR_RUNTIME_DOCS_URL")),
			"metrics": "/metrics",
			"health":  "/healthz",
		},
		"bindings": []string{
			"DATABASE_URL", "REDIS_URL/VALKEY_URL", "S3_ENDPOINT/AWS_ENDPOINT_URL",
			"S3_BUCKET", "AWS_ACCESS_KEY_ID", "AWS_SECRET_ACCESS_KEY", "APP_SECRET",
			"OTEL_EXPORTER_OTLP_ENDPOINT",
		},
	})
}

func (a *app) sqlStatus(ctx context.Context) capabilityState {
	if a.db == nil {
		return capabilityState{Detail: "DATABASE_URL missing"}
	}
	if err := a.db.PingContext(ctx); err != nil {
		return capabilityState{Detail: "database unavailable"}
	}
	return capabilityState{Ready: true, Detail: "PostgreSQL protocol ready"}
}

func (a *app) cacheStatus(ctx context.Context) capabilityState {
	if a.cache == nil {
		return capabilityState{Detail: "REDIS_URL/VALKEY_URL missing"}
	}
	if err := a.cache.Ping(ctx).Err(); err != nil {
		return capabilityState{Detail: "cache unavailable"}
	}
	return capabilityState{Ready: true, Detail: "Redis protocol ready"}
}

func (a *app) s3Status(ctx context.Context) capabilityState {
	if a.s3 == nil || a.s3Bucket == "" {
		return capabilityState{Detail: "S3 bindings missing"}
	}
	ok, err := a.s3.BucketExists(ctx, a.s3Bucket)
	if err != nil || !ok {
		return capabilityState{Detail: "bucket unavailable"}
	}
	return capabilityState{Ready: true, Detail: "S3 bucket " + a.s3Bucket}
}

func (a *app) sqlAction(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		methodNotAllowed(w)
		return
	}
	if a.db == nil {
		writeError(w, "DATABASE_URL missing")
		return
	}
	ctx, cancel := context.WithTimeout(r.Context(), 5*time.Second)
	defer cancel()
	if _, err := a.db.ExecContext(ctx, `CREATE TABLE IF NOT EXISTS demo_records (id BIGSERIAL PRIMARY KEY, value TEXT NOT NULL, created_at TIMESTAMPTZ NOT NULL DEFAULT NOW())`); err != nil {
		writeError(w, err.Error())
		return
	}
	value := "BaseHarbor demo " + time.Now().UTC().Format(time.RFC3339Nano)
	var id int64
	if err := a.db.QueryRowContext(ctx, `INSERT INTO demo_records(value) VALUES($1) RETURNING id`, value).Scan(&id); err != nil {
		writeError(w, err.Error())
		return
	}
	var count int
	_ = a.db.QueryRowContext(ctx, `SELECT COUNT(*) FROM demo_records`).Scan(&count)
	writeJSON(w, http.StatusOK, map[string]any{"id": id, "records": count})
}

func (a *app) cacheAction(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		methodNotAllowed(w)
		return
	}
	if a.cache == nil {
		writeError(w, "REDIS_URL/VALKEY_URL missing")
		return
	}
	ctx, cancel := context.WithTimeout(r.Context(), 3*time.Second)
	defer cancel()
	key := "baseharbor-demo:" + strconv.FormatInt(time.Now().UnixNano(), 10)
	if err := a.cache.Set(ctx, key, "portable-cache-value", 60*time.Second).Err(); err != nil {
		writeError(w, err.Error())
		return
	}
	value, err := a.cache.Get(ctx, key).Result()
	if err != nil {
		writeError(w, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"key": key, "value": value, "ttl_seconds": 60})
}

func (a *app) objectAction(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		methodNotAllowed(w)
		return
	}
	if a.s3 == nil || a.s3Bucket == "" {
		writeError(w, "S3 bindings missing")
		return
	}
	ctx, cancel := context.WithTimeout(r.Context(), 8*time.Second)
	defer cancel()
	exists, err := a.s3.BucketExists(ctx, a.s3Bucket)
	if err != nil {
		writeError(w, err.Error())
		return
	}
	if !exists {
		if err := a.s3.MakeBucket(ctx, a.s3Bucket, minio.MakeBucketOptions{}); err != nil {
			writeError(w, err.Error())
			return
		}
	}
	name := "demo-" + strconv.FormatInt(time.Now().UnixNano(), 10) + ".txt"
	body := []byte("BaseHarbor portable object storage demo\n")
	if _, err := a.s3.PutObject(ctx, a.s3Bucket, name, bytes.NewReader(body), int64(len(body)), minio.PutObjectOptions{ContentType: "text/plain"}); err != nil {
		writeError(w, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"bucket": a.s3Bucket, "object": name, "bytes": len(body)})
}

func (a *app) secretAction(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		methodNotAllowed(w)
		return
	}
	present := os.Getenv("APP_SECRET") != ""
	if !present {
		writeError(w, "APP_SECRET binding missing")
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"name":          "APP_SECRET",
		"present":       true,
		"value_exposed": false,
	})
}

func (a *app) metricsVerifyAction(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		methodNotAllowed(w)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"endpoint": "/metrics",
		"metric":   "baseharbor_demo_requests_total",
		"present":  true,
		"value":    a.requests.Load(),
	})
}

func (a *app) traceAction(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		methodNotAllowed(w)
		return
	}
	ctx, span := otel.Tracer("baseharbor-demo").Start(r.Context(), "demo.scenario")
	span.SetAttributes(attribute.String("demo.capability", "telemetry"))
	time.Sleep(12 * time.Millisecond)
	span.End()
	sc := span.SpanContext()
	writeJSON(w, http.StatusOK, map[string]any{
		"trace_id":          sc.TraceID().String(),
		"export_configured": os.Getenv("OTEL_EXPORTER_OTLP_ENDPOINT") != "",
		"context_active":    ctx != nil,
	})
}

func (a *app) runtimeResourceAction(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		methodNotAllowed(w)
		return
	}
	apiURL := os.Getenv("BASEHARBOR_RUNTIME_API_URL")
	tokenFile := os.Getenv("BASEHARBOR_RUNTIME_TOKEN_FILE")
	caFile := os.Getenv("BASEHARBOR_RUNTIME_CA_FILE")
	certFile := os.Getenv("BASEHARBOR_RUNTIME_CLIENT_CERT_FILE")
	keyFile := os.Getenv("BASEHARBOR_RUNTIME_CLIENT_KEY_FILE")
	if !runtimeResourceConfigured() {
		writeError(w, "runtime resource API bindings missing")
		return
	}
	token, err := os.ReadFile(tokenFile)
	if err != nil {
		writeError(w, "runtime token unavailable")
		return
	}
	caPEM, err := os.ReadFile(caFile)
	if err != nil {
		writeError(w, "runtime CA unavailable")
		return
	}
	pool := x509.NewCertPool()
	if !pool.AppendCertsFromPEM(caPEM) {
		writeError(w, "runtime CA invalid")
		return
	}
	cert, err := tls.LoadX509KeyPair(certFile, keyFile)
	if err != nil {
		writeError(w, "runtime client identity unavailable")
		return
	}
	client := &http.Client{
		Timeout: 10 * time.Second,
		Transport: &http.Transport{TLSClientConfig: &tls.Config{
			MinVersion:   tls.VersionTLS12,
			RootCAs:      pool,
			Certificates: []tls.Certificate{cert},
		}},
	}
	name := "demo-runtime-" + strconv.FormatInt(time.Now().Unix(), 10)
	payload, _ := json.Marshal(map[string]string{"capability": "object-storage.s3/v1", "name": name})
	req, _ := http.NewRequestWithContext(r.Context(), http.MethodPost, strings.TrimRight(apiURL, "/")+"/runtime/v1/resources", bytes.NewReader(payload))
	req.Header.Set("Authorization", "Bearer "+strings.TrimSpace(string(token)))
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Idempotency-Key", "demo-"+name)
	resp, err := client.Do(req)
	if err != nil {
		writeError(w, err.Error())
		return
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
	if resp.StatusCode/100 != 2 {
		writeError(w, fmt.Sprintf("runtime API %s: %s", resp.Status, strings.TrimSpace(string(body))))
		return
	}
	var created map[string]any
	if err := json.Unmarshal(body, &created); err != nil {
		writeError(w, "runtime API returned invalid JSON")
		return
	}
	writeJSON(w, http.StatusOK, created)
}

func (a *app) companionAction(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		methodNotAllowed(w)
		return
	}
	if a.companion == "" {
		writeError(w, "COMPANION_URL missing")
		return
	}
	ctx, cancel := context.WithTimeout(r.Context(), 3*time.Second)
	defer cancel()
	req, _ := http.NewRequestWithContext(ctx, http.MethodGet, strings.TrimRight(a.companion, "/")+"/hello", nil)
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		writeError(w, err.Error())
		return
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(io.LimitReader(resp.Body, 4096))
	if resp.StatusCode/100 != 2 {
		writeError(w, "companion returned "+resp.Status)
		return
	}
	var result any
	if json.Unmarshal(body, &result) != nil {
		result = string(body)
	}
	writeJSON(w, http.StatusOK, map[string]any{"status": resp.StatusCode, "response": result})
}

func runtimeResourceConfigured() bool {
	for _, name := range []string{
		"BASEHARBOR_RUNTIME_API_URL",
		"BASEHARBOR_RUNTIME_TOKEN_FILE",
		"BASEHARBOR_RUNTIME_CA_FILE",
		"BASEHARBOR_RUNTIME_CLIENT_CERT_FILE",
		"BASEHARBOR_RUNTIME_CLIENT_KEY_FILE",
	} {
		if strings.TrimSpace(os.Getenv(name)) == "" {
			return false
		}
	}
	return true
}

func serverTransport() (mode, certFile, keyFile string, err error) {
	certFile = strings.TrimSpace(os.Getenv("BASEHARBOR_TLS_CERT_FILE"))
	keyFile = strings.TrimSpace(os.Getenv("BASEHARBOR_TLS_KEY_FILE"))
	switch {
	case certFile == "" && keyFile == "":
		return "http", "", "", nil
	case certFile == "" || keyFile == "":
		return "", "", "", fmt.Errorf("BaseHarbor TLS requires both BASEHARBOR_TLS_CERT_FILE and BASEHARBOR_TLS_KEY_FILE")
	default:
		if _, statErr := os.Stat(certFile); statErr != nil {
			return "", "", "", fmt.Errorf("inspect BaseHarbor TLS certificate: %w", statErr)
		}
		if _, statErr := os.Stat(keyFile); statErr != nil {
			return "", "", "", fmt.Errorf("inspect BaseHarbor TLS private key: %w", statErr)
		}
		return "https", certFile, keyFile, nil
	}
}

func static(w http.ResponseWriter, r *http.Request) {
	path := "web/index.html"
	contentType := "text/html; charset=utf-8"
	switch r.URL.Path {
	case "/", "/index.html":
	case "/assets/styles.css":
		path, contentType = "web/styles.css", "text/css; charset=utf-8"
	case "/assets/brand-tokens.css":
		path, contentType = "web/brand-tokens.css", "text/css; charset=utf-8"
	case "/assets/app.js":
		path, contentType = "web/app.js", "application/javascript; charset=utf-8"
	default:
		http.NotFound(w, r)
		return
	}
	data, err := webFS.ReadFile(path)
	if err != nil {
		http.Error(w, "asset unavailable", http.StatusInternalServerError)
		return
	}
	w.Header().Set("Content-Type", contentType)
	w.Header().Set("Cache-Control", "no-cache")
	_, _ = w.Write(data)
}

func requestLog(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()
		next.ServeHTTP(w, r)
		log.Printf(`{"level":"info","event":"request","method":%q,"path":%q,"duration_ms":%d}`, r.Method, r.URL.Path, time.Since(start).Milliseconds())
	})
}

func writeJSON(w http.ResponseWriter, status int, value any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(value)
}

func writeError(w http.ResponseWriter, message string) {
	writeJSON(w, http.StatusServiceUnavailable, map[string]any{"error": message})
}

func methodNotAllowed(w http.ResponseWriter) {
	writeJSON(w, http.StatusMethodNotAllowed, map[string]any{"error": "method not allowed"})
}

func env(name, fallback string) string {
	if value := os.Getenv(name); value != "" {
		return value
	}
	return fallback
}

func firstEnv(names ...string) string {
	for _, name := range names {
		if value := os.Getenv(name); value != "" {
			return value
		}
	}
	return ""
}
