// Go benchmark control — mirrors snek's example app exactly.
//
// Routes:
//   GET /           -> {"message":"hello"}
//   GET /health     -> {"status":"ok"}
//   GET /greet/{name} -> {"message":"hello {name}"}
//
// Behavior: Connection: close on every response, manual JSON (no encoding/json).
//
// Usage:
//   go build -o go-control . && ./go-control [port]

package main

import (
	"fmt"
	"net/http"
	"os"
	"strings"
)

func main() {
	port := "8080"
	if len(os.Args) > 1 {
		port = os.Args[1]
	}

	mux := http.NewServeMux()
	mux.HandleFunc("/", handleRoot)
	mux.HandleFunc("/health", handleHealth)
	mux.HandleFunc("/greet/", handleGreet)

	fmt.Printf("\n  snek is listening on http://127.0.0.1:%s/\n\n", port)

	server := &http.Server{
		Addr:    ":" + port,
		Handler: mux,
	}
	server.SetKeepAlivesEnabled(false)

	if err := server.ListenAndServe(); err != nil {
		fmt.Fprintf(os.Stderr, "error: %v\n", err)
		os.Exit(1)
	}
}

func handleRoot(w http.ResponseWriter, r *http.Request) {
	if r.URL.Path != "/" {
		w.Header().Set("Content-Type", "application/json")
		w.Header().Set("Connection", "close")
		w.WriteHeader(404)
		w.Write([]byte(`{"error":"not found"}`))
		return
	}
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Connection", "close")
	w.Write([]byte(`{"message":"hello"}`))
}

func handleHealth(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Connection", "close")
	w.Write([]byte(`{"status":"ok"}`))
}

func handleGreet(w http.ResponseWriter, r *http.Request) {
	name := strings.TrimPrefix(r.URL.Path, "/greet/")
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Connection", "close")
	w.Write([]byte(`{"message":"hello ` + name + `"}`))
}
