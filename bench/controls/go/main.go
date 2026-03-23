// Go benchmark control — mirrors snek's example app exactly.
//
// Routes:
//   GET /           -> {"message":"hello"}
//   GET /health     -> {"status":"ok"}
//   GET /greet/{name} -> {"message":"hello {name}"}
//
// Behavior: Connection: close on every response, fd closed after write.
//
// Usage:
//   go build -o go-control . && ./go-control [port]

package main

import (
	"fmt"
	"net"
	"os"
	"strings"
)

func main() {
	port := "8080"
	if len(os.Args) > 1 {
		port = os.Args[1]
	}

	ln, err := net.Listen("tcp", ":"+port)
	if err != nil {
		fmt.Fprintf(os.Stderr, "listen: %v\n", err)
		os.Exit(1)
	}
	fmt.Printf("\n  go control listening on http://127.0.0.1:%s/\n\n", port)

	for {
		conn, err := ln.Accept()
		if err != nil {
			continue
		}
		go handleConn(conn)
	}
}

func handleConn(conn net.Conn) {
	defer conn.Close()

	buf := make([]byte, 4096)
	n, err := conn.Read(buf)
	if err != nil || n == 0 {
		return
	}

	req := string(buf[:n])
	// Parse method and path from first line
	firstLine := req
	if idx := strings.Index(req, "\r\n"); idx >= 0 {
		firstLine = req[:idx]
	}
	parts := strings.SplitN(firstLine, " ", 3)
	if len(parts) < 2 {
		return
	}
	path := parts[1]

	var body string
	switch {
	case path == "/":
		body = `{"message":"hello"}`
	case path == "/health":
		body = `{"status":"ok"}`
	case strings.HasPrefix(path, "/greet/"):
		name := strings.TrimPrefix(path, "/greet/")
		body = `{"message":"hello ` + name + `"}`
	default:
		resp := "HTTP/1.1 404 Not Found\r\nContent-Type: application/json\r\nConnection: close\r\nContent-Length: 20\r\n\r\n{\"error\":\"not found\"}"
		conn.Write([]byte(resp))
		return
	}

	resp := fmt.Sprintf("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nConnection: close\r\nContent-Length: %d\r\n\r\n%s", len(body), body)
	conn.Write([]byte(resp))
}
