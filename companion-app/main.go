package main

import (
	"encoding/json"
	"log"
	"net/http"
	"os"
	"time"
)

func main() {
	port := env("PORT", "8081")
	mux := http.NewServeMux()
	mux.HandleFunc("/healthz", func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(map[string]any{"status": "ok", "service": "companion-app"})
	})
	mux.HandleFunc("/hello", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(map[string]any{
			"message": "Hello from the BaseHarbor companion app",
			"time":    time.Now().UTC().Format(time.RFC3339),
			"caller":  r.RemoteAddr,
		})
	})
	log.Printf("companion-app listening on :%s", port)
	log.Fatal(http.ListenAndServe(":"+port, mux))
}

func env(name, fallback string) string {
	if value := os.Getenv(name); value != "" {
		return value
	}
	return fallback
}
