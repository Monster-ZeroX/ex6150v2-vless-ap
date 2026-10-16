// sing-box-mini: the official sing-box core with only `run`, `check` and `version`,
// for the 16 MB-flash / 256 MB-RAM EX6150v2. Mirrors cmd/sing-box run/check logic.
//
//	sing-box run -c config.json [-D workdir]
//	sing-box check -c config.json
//	sing-box version
//	sing-box pin <host> <port> [sni] [ip]   verify host's certificate (ClientHello shows sni), print its SPKI sha256
//	sing-box resolve <host>                 A records via DNS-over-HTTPS to 1.1.1.1
package main

import (
	"context"
	"crypto/sha256"
	"crypto/tls"
	"crypto/x509"
	"encoding/base64"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"os/signal"
	runtimeDebug "runtime/debug"
	"syscall"
	"time"

	"github.com/sagernet/sing-box"
	C "github.com/sagernet/sing-box/constant"
	"github.com/sagernet/sing-box/experimental/deprecated"
	"github.com/sagernet/sing-box/include"
	"github.com/sagernet/sing-box/log"
	"github.com/sagernet/sing-box/option"
	E "github.com/sagernet/sing/common/exceptions"
	"github.com/sagernet/sing/common/json"
	"github.com/sagernet/sing/service"

	"github.com/miekg/dns"
)

func usage() {
	fmt.Fprintln(os.Stderr, "usage: sing-box run|check -c config.json [-D dir] | version | pin <host> <port> [sni] [ip] | resolve <host>")
	os.Exit(2)
}

func main() {
	if len(os.Args) < 2 {
		usage()
	}
	command := os.Args[1]
	if command == "pin" {
		if len(os.Args) < 4 || len(os.Args) > 6 {
			usage()
		}
		sni, addr := os.Args[2], ""
		if len(os.Args) >= 5 {
			sni = os.Args[4]
		}
		if len(os.Args) == 6 {
			addr = os.Args[5]
		}
		if err := pin(os.Args[2], os.Args[3], sni, addr); err != nil {
			fmt.Fprintln(os.Stderr, "pin:", err)
			os.Exit(1)
		}
		return
	}
	if command == "resolve" {
		if len(os.Args) != 3 {
			usage()
		}
		if err := resolve(os.Args[2]); err != nil {
			fmt.Fprintln(os.Stderr, "resolve:", err)
			os.Exit(1)
		}
		return
	}
	configPath, workingDir := "config.json", ""
	args := os.Args[2:]
	for i := 0; i < len(args); i++ {
		switch args[i] {
		case "-c", "--config":
			i++
			if i < len(args) {
				configPath = args[i]
			}
		case "-D", "--directory":
			i++
			if i < len(args) {
				workingDir = args[i]
			}
		default:
			usage()
		}
	}
	if command == "version" {
		fmt.Println("sing-box version " + C.Version)
		return
	}
	if workingDir != "" {
		os.MkdirAll(workingDir, 0o755)
		if err := os.Chdir(workingDir); err != nil {
			log.Fatal(err)
		}
	}
	ctx := include.Context(service.ContextWith(context.Background(), deprecated.NewStderrManager(log.StdLogger())))
	options, err := readConfig(ctx, configPath)
	if err != nil {
		log.Fatal(err)
	}
	switch command {
	case "check":
		boxCtx, cancel := context.WithCancel(service.ExtendContext(ctx))
		instance, err := box.New(box.Options{Context: boxCtx, Options: options})
		if err == nil {
			instance.Close()
		}
		cancel()
		if err != nil {
			log.Fatal(err)
		}
	case "run":
		if err := run(ctx, options); err != nil {
			log.Fatal(err)
		}
	default:
		usage()
	}
}

// pin prints the leaf key pin used for links that spoof SNI (certificate_public_key_sha256).
// The ClientHello carries sni (what an observer sees); the certificate chain is still fully
// verified against the server's real name, so the real name never appears on the wire.
func pin(host, port, sni, addr string) error {
	if addr == "" {
		addr = host
	}
	dialer := &net.Dialer{Timeout: 10 * time.Second}
	config := &tls.Config{
		ServerName:         sni,
		InsecureSkipVerify: true, // replaced by the explicit verification below
		VerifyConnection: func(cs tls.ConnectionState) error {
			if len(cs.PeerCertificates) == 0 {
				return errors.New("no certificate")
			}
			intermediates := x509.NewCertPool()
			for _, c := range cs.PeerCertificates[1:] {
				intermediates.AddCert(c)
			}
			_, err := cs.PeerCertificates[0].Verify(x509.VerifyOptions{DNSName: host, Intermediates: intermediates})
			return err
		},
	}
	conn, err := tls.DialWithDialer(dialer, "tcp", net.JoinHostPort(addr, port), config)
	if err != nil {
		return err
	}
	defer conn.Close()
	sum := sha256.Sum256(conn.ConnectionState().PeerCertificates[0].RawSubjectPublicKeyInfo)
	fmt.Println(base64.StdEncoding.EncodeToString(sum[:]))
	return nil
}

// resolve looks up A records over DNS-over-HTTPS to Cloudflare by IP address, so the query is
// encrypted and no SNI or plaintext DNS reveals the name being resolved.
func resolve(host string) error {
	query := new(dns.Msg)
	query.SetQuestion(dns.Fqdn(host), dns.TypeA)
	query.Id = 0
	wire, err := query.Pack()
	if err != nil {
		return err
	}
	client := &http.Client{Timeout: 8 * time.Second}
	var lastErr error
	for _, server := range []string{"1.1.1.1", "1.0.0.1"} {
		req, _ := http.NewRequest("GET", "https://"+server+"/dns-query?dns="+base64.RawURLEncoding.EncodeToString(wire), nil)
		req.Header.Set("Accept", "application/dns-message")
		resp, err := client.Do(req)
		if err != nil {
			lastErr = err
			continue
		}
		body, err := io.ReadAll(io.LimitReader(resp.Body, 65535))
		resp.Body.Close()
		if err != nil || resp.StatusCode != http.StatusOK {
			lastErr = fmt.Errorf("doh %s: status %d %v", server, resp.StatusCode, err)
			continue
		}
		answer := new(dns.Msg)
		if err = answer.Unpack(body); err != nil {
			lastErr = err
			continue
		}
		found := false
		for _, rr := range answer.Answer {
			if a, ok := rr.(*dns.A); ok {
				fmt.Println(a.A.String())
				found = true
			}
		}
		if found {
			return nil
		}
		lastErr = errors.New("no A records for " + host)
	}
	return lastErr
}

func readConfig(ctx context.Context, path string) (option.Options, error) {
	content, err := os.ReadFile(path)
	if err != nil {
		return option.Options{}, E.Cause(err, "read config at ", path)
	}
	options, err := json.UnmarshalExtendedContext[option.Options](ctx, content)
	if err != nil {
		return option.Options{}, E.Cause(err, "decode config at ", path)
	}
	return options, nil
}

func run(ctx context.Context, options option.Options) error {
	boxCtx, cancel := context.WithCancel(service.ExtendContext(ctx))
	instance, err := box.New(box.Options{Context: boxCtx, Options: options})
	if err != nil {
		cancel()
		return E.Cause(err, "create service")
	}
	osSignals := make(chan os.Signal, 1)
	signal.Notify(osSignals, os.Interrupt, syscall.SIGTERM, syscall.SIGHUP)
	defer signal.Stop(osSignals)

	startCtx, finishStart := context.WithCancel(context.Background())
	go func() {
		// a signal during start: cancel and give up after the fatal timeout
		select {
		case <-osSignals:
			cancel()
			closeMonitor(startCtx)
		case <-startCtx.Done():
		}
	}()
	err = instance.Start()
	finishStart()
	if err != nil {
		cancel()
		instance.Close()
		return E.Cause(err, "start service")
	}
	runtimeDebug.FreeOSMemory()

	<-osSignals
	cancel()
	closeCtx, closed := context.WithCancel(context.Background())
	go closeMonitor(closeCtx)
	err = instance.Close()
	closed()
	if err != nil {
		log.Error(E.Cause(err, "sing-box did not close properly"))
	}
	return nil
}

func closeMonitor(ctx context.Context) {
	time.Sleep(C.FatalStopTimeout)
	select {
	case <-ctx.Done():
		return
	default:
	}
	log.Fatal("sing-box did not close!")
}
