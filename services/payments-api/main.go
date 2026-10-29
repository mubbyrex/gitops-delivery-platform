// payments-api is a stub. It computes nothing.
//
// There is no payment logic here, no ledger, no settlement, and no arithmetic
// involving money, and there never will be. This service exists so that the
// delivery machinery around it — building, scanning, publishing, releasing,
// measuring, rolling back — can be demonstrated against something that runs,
// without anyone having to trust the thing it is pretending to be.
//
// What it provides is the surface a real service would have, and nothing
// behind that surface:
//
//	/healthz   liveness  — is the process broken and in need of a restart
//	/readyz    readiness — should this instance receive traffic right now
//	/metrics   the numbers a monitoring stack would scrape
//	/          a trivial response, so that a request from outside has
//	           something to arrive at
//
// The two health endpoints are deliberately separate and independently
// breakable. They mean different things and a release that confuses them fails
// in a way that looks like the service is fine.
package main

import (
	"context"
	"errors"
	"fmt"
	"log"
	"net/http"
	"os"
	"os/signal"
	"strconv"
	"syscall"
	"time"

	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/promauto"
	"github.com/prometheus/client_golang/prometheus/promhttp"
)

var (
	requests = promauto.NewCounterVec(prometheus.CounterOpts{
		Name: "payments_api_requests_total",
		Help: "Requests served, by path and status. The status label is what a " +
			"release gate would later be written against.",
	}, []string{"path", "status"})

	latency = promauto.NewHistogramVec(prometheus.HistogramOpts{
		Name:    "payments_api_request_duration_seconds",
		Help:    "Request duration. Present so that a later stage has a latency signal to measure, not because this service does anything slow.",
		Buckets: prometheus.DefBuckets,
	}, []string{"path"})

	info = promauto.NewGaugeVec(prometheus.GaugeOpts{
		Name: "payments_api_build_info",
		Help: "Always 1. The labels carry the version, so that two versions running at once are distinguishable while traffic is split between them.",
	}, []string{"version"})
)

// Configuration, read once at startup. Every one of these is set through the
// environment rather than through a flag or a file, so that changing one is a
// change to a committed values file and arrives through the same route as
// everything else.
type config struct {
	addr    string
	version string

	// The failure switch, split in two because the two halves of it fail
	// differently and the difference is the point.
	failLiveness  bool
	failReadiness bool

	// A delay before readiness turns true, so that a rollout has something to
	// wait for rather than everything being ready instantly.
	readyAfter time.Duration
}

func load() config {
	return config{
		addr:          env("LISTEN_ADDR", ":8080"),
		version:       env("VERSION", "dev"),
		failLiveness:  env("FAIL_LIVENESS", "false") == "true",
		failReadiness: env("FAIL_READINESS", "false") == "true",
		readyAfter:    duration("READY_AFTER", 0),
	}
}

func env(key, fallback string) string {
	if v, ok := os.LookupEnv(key); ok {
		return v
	}
	return fallback
}

func duration(key string, fallback time.Duration) time.Duration {
	v, ok := os.LookupEnv(key)
	if !ok {
		return fallback
	}
	secs, err := strconv.Atoi(v)
	if err != nil {
		log.Printf("ignoring %s=%q: not a whole number of seconds", key, v)
		return fallback
	}
	return time.Duration(secs) * time.Second
}

func main() {
	cfg := load()
	started := time.Now()
	info.WithLabelValues(cfg.version).Set(1)

	mux := http.NewServeMux()

	// Liveness. A failure here means the process is broken and restarting it is
	// the only thing that might help. Kubernetes answers a failure by killing
	// the container.
	mux.HandleFunc("/healthz", instrument("/healthz", func(w http.ResponseWriter, r *http.Request) int {
		if cfg.failLiveness {
			http.Error(w, "liveness failing: FAIL_LIVENESS is set", http.StatusInternalServerError)
			return http.StatusInternalServerError
		}
		fmt.Fprintln(w, "ok")
		return http.StatusOK
	}))

	// Readiness. A failure here means this instance is running but should not
	// be sent traffic. Kubernetes answers a failure by removing it from the
	// service and leaving it alone.
	mux.HandleFunc("/readyz", instrument("/readyz", func(w http.ResponseWriter, r *http.Request) int {
		switch {
		case cfg.failReadiness:
			http.Error(w, "readiness failing: FAIL_READINESS is set", http.StatusServiceUnavailable)
			return http.StatusServiceUnavailable
		case time.Since(started) < cfg.readyAfter:
			http.Error(w, "starting up", http.StatusServiceUnavailable)
			return http.StatusServiceUnavailable
		}
		fmt.Fprintln(w, "ready")
		return http.StatusOK
	}))

	// The catch-all. Anything that is not one of the routes above lands here,
	// and the path label matters: a later stage writes release gates against
	// these series, and attributing every stray request to "/" would let a
	// scanner hammering unknown URLs fail a release for the one route that was
	// working fine. Unknown paths are counted under a single "other" label
	// rather than under their own, because labelling by request path lets an
	// outsider create unbounded series by inventing URLs.
	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/" {
			instrument("other", func(w http.ResponseWriter, r *http.Request) int {
				http.NotFound(w, r)
				return http.StatusNotFound
			})(w, r)
			return
		}
		instrument("/", func(w http.ResponseWriter, r *http.Request) int {
			fmt.Fprintf(w, "payments-api %s — a stub. It settles nothing.\n", cfg.version)
			return http.StatusOK
		})(w, r)
	})

	mux.Handle("/metrics", promhttp.Handler())

	srv := &http.Server{
		Addr:              cfg.addr,
		Handler:           mux,
		ReadHeaderTimeout: 5 * time.Second,
	}

	// Shut down on the signal Kubernetes sends, rather than being killed after
	// the grace period. Without this, every rollout drops whatever requests
	// were in flight — which would make a later stage's measurements a
	// measurement of this omission.
	go func() {
		stop := make(chan os.Signal, 1)
		signal.Notify(stop, syscall.SIGTERM, syscall.SIGINT)
		<-stop
		log.Println("signal received, draining")
		ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer cancel()
		if err := srv.Shutdown(ctx); err != nil {
			log.Printf("shutdown: %v", err)
		}
	}()

	log.Printf("payments-api %s listening on %s (fail_liveness=%t fail_readiness=%t)",
		cfg.version, cfg.addr, cfg.failLiveness, cfg.failReadiness)
	if err := srv.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
		log.Fatalf("serve: %v", err)
	}
	log.Println("stopped")
}

// instrument records the count and duration of every request, so the metrics
// are a by-product of serving rather than something the handlers remember to
// do.
func instrument(path string, h func(http.ResponseWriter, *http.Request) int) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()
		status := h(w, r)
		latency.WithLabelValues(path).Observe(time.Since(start).Seconds())
		requests.WithLabelValues(path, strconv.Itoa(status)).Inc()
	}
}
