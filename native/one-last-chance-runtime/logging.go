package runtimebridge

import (
	"bytes"
	"log" //nolint:depguard // olcRTC mobile writes through the standard library logger.
	"strings"
	"sync"
)

// LogWriter receives complete, newline-free runtime log messages.
type LogWriter interface {
	WriteLog(message string)
}

type callbackWriter struct {
	mu       sync.Mutex
	callback LogWriter
	buffer   []byte
}

func installLogging(callback LogWriter) {
	if callback == nil {
		return
	}
	w := &callbackWriter{callback: callback}
	log.SetFlags(0)
	log.SetOutput(w)
}

func (w *callbackWriter) Write(data []byte) (int, error) {
	w.mu.Lock()
	defer w.mu.Unlock()
	w.buffer = append(w.buffer, data...)
	for {
		index := bytes.IndexByte(w.buffer, '\n')
		if index < 0 {
			break
		}
		w.emit(w.buffer[:index])
		w.buffer = w.buffer[index+1:]
	}
	return len(data), nil
}

func (w *callbackWriter) emit(line []byte) {
	message := strings.TrimSpace(string(line))
	if message != "" {
		w.callback.WriteLog(message)
	}
}
