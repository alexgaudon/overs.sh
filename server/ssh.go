package overssh

import (
	"bufio"
	"fmt"
	"io"
	"log"
	"os"
	"strings"
	"time"

	"github.com/alexgaudon/overssh/settings"
	"github.com/gliderlabs/ssh"
	"github.com/google/uuid"
)

var Pipes map[string]Pipe

var url string

type Transfer struct {
	reader *bufio.Reader
}

type Pipe struct {
	id       string
	donech   chan bool
	transfer *Transfer
}

func (p *Pipe) GetContent() (string, error) {
	var result strings.Builder
	buffer := make([]byte, 4096) // Adjust the buffer size as needed

	for {
		n, err := p.transfer.reader.Read(buffer)
		if err != nil {
			if err == io.EOF {
				result.WriteString(string(buffer[:n]))
				break
			}
			return "", err
		}
		result.WriteString(string(buffer[:n]))
	}

	return result.String(), nil
}

func (p *Pipe) Close() {
	p.donech <- true
	delete(Pipes, p.id)
}

func init() {
	Pipes = make(map[string]Pipe)

	if os.Getenv("DEV") == "true" {
		url = "http://localhost:3000/d/"
	} else {
		url = fmt.Sprintf("%s/d/", os.Getenv("URL"))
	}
}

type PeekResult struct {
	Err      error
	Transfer *Transfer
}

func peekSession(s ssh.Session) chan PeekResult {
	pr := bufio.NewReader(s)
	peekch := make(chan PeekResult)

	go func(p *bufio.Reader) {
		b, err := p.Peek(1)
		if err != nil {
			peekch <- PeekResult{
				Err: err,
			}
			return
		}
		if p.Buffered() == 1 {
			peekch <- PeekResult{
				Err: fmt.Errorf("buffered is 1"),
			}
			return
		}

		if len(b) == 0 {
			peekch <- PeekResult{
				Err: fmt.Errorf("no data"),
			}
			return
		} else {
			peekch <- PeekResult{
				Err: nil,
				Transfer: &Transfer{
					reader: p,
				},
			}
			return
		}
	}(pr)

	return peekch
}

func handler(s ssh.Session) {
	builder := strings.Builder{}

	builder.WriteString(getConnectionHeader())
	s.Write([]byte(builder.String()))

	peekch := peekSession(s)

	var transfer Transfer

	select {
	case p := <-peekch:
		{
			if p.Err != nil {
				s.Write([]byte(p.Err.Error() + "\n"))
				return
			} else {
				transfer = *p.Transfer
			}
		}
	case <-time.After(time.Minute * 2):
		s.Write([]byte("Too much data. Try a smaller file.\n"))
		return
	}

	id := uuid.NewString()
	id = strings.Split(id, "-")[0]

	donech := make(chan bool)

	Pipes[id] = Pipe{
		id:       id,
		donech:   donech,
		transfer: &transfer,
	}

	s.Write([]byte("Waiting for someone to download the file...\n"))

	s.Write([]byte("Download link:\n" + url + id + "\n"))

	for {
		select {
		case <-donech:
			s.Write([]byte("File downloaded successfully\n"))
			return
		case <-s.Context().Done():
			delete(Pipes, id)
			return
		}
	}
}

func StartSSH() error {

	listenAddr := ":22"

	if os.Getenv("DEV") == "true" {
		listenAddr = ":2222"
	}

	ssh.Handle(handler)

	server := &ssh.Server{
		Addr:        listenAddr,
		MaxTimeout:  settings.DeadlineTimeout,
		IdleTimeout: settings.IdleTimeout,
	}

	log.Println("Starting server at " + listenAddr)

	server.SetOption(ssh.HostKeyFile("./key"))

	err := server.ListenAndServe()

	if err != nil {
		return err
	}

	return nil
}
