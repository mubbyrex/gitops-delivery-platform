// settlement-worker is a stub. It computes nothing.
//
// There is no payment logic here, no ledger, no settlement, and no arithmetic
// involving money, and there never will be. It exists to be the *other shape*:
// where payments-api is a long-running process that can have two versions
// serving at once, this one runs on a schedule, takes a while, and must never
// have two copies running together.
//
// Why that matters, stated plainly because the code cannot show it: in the
// scenario this platform is built around, a second copy of a settlement run
// processing the same batch would pay a merchant twice. Nothing here would
// actually do that — there is nothing to pay and nobody to pay it — but the
// delivery machinery is built as though it would, because that is the
// constraint the whole repository exists to take seriously.
//
// It runs once and exits. Metrics are served while it works, because a process
// that exits cannot be scraped afterwards; how a scheduled job's numbers are
// actually collected is a problem for whatever comes to scrape them.
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
	runs = promauto.NewCounterVec(prometheus.CounterOpts{
		Name: "settlement_worker_runs_total",
		Help: "Runs started and how they ended. A later stage gates releases on the failure count here.",
	}, []string{"outcome"})

	duration = promauto.NewGauge(prometheus.GaugeOpts{
		Name: "settlement_worker_run_duration_seconds",
		Help: "How long the last run took. Worth watching because a run that outlasts its own schedule is the condition that makes overlap possible.",
	})

	items = promauto.NewCounter(prometheus.CounterOpts{
		Name: "settlement_worker_items_processed_total",
		Help: "Items the run pretended to process. There are no real items; this counts loop iterations so the number moves.",
	})

	info = promauto.NewGaugeVec(prometheus.GaugeOpts{
		Name: "settlement_worker_build_info",
		Help: "Always 1. The labels carry the version, so that a run can be attributed to the version that performed it.",
	}, []string{"version"})
)

type config struct {
	addr    string
	version string

	// How long a run takes. Deliberately configurable, because the
	// demonstration that two runs cannot overlap needs a run that lasts longer
	// than the gap to the next one.
	runFor time.Duration

	// How many items to pretend to process during that time.
	itemCount int

	// The failure switch. A run that fails exits non-zero, which is what the
	// scheduler and any later release gate actually react to.
	fail bool
}

func load() config {
	return config{
		addr:      env("LISTEN_ADDR", ":8080"),
		version:   env("VERSION", "dev"),
		runFor:    seconds("RUN_FOR", 10*time.Second),
		itemCount: number("ITEM_COUNT", 10),
		fail:      env("FAIL_RUN", "false") == "true",
	}
}

func env(key, fallback string) string {
	if v, ok := os.LookupEnv(key); ok {
		return v
	}
	return fallback
}

func number(key string, fallback int) int {
	v, ok := os.LookupEnv(key)
	if !ok {
		return fallback
	}
	n, err := strconv.Atoi(v)
	if err != nil || n < 0 {
		log.Printf("ignoring %s=%q: not a non-negative whole number", key, v)
		return fallback
	}
	return n
}

func seconds(key string, fallback time.Duration) time.Duration {
	n := number(key, int(fallback/time.Second))
	return time.Duration(n) * time.Second
}

func main() {
	cfg := load()
	info.WithLabelValues(cfg.version).Set(1)

	// Metrics are served for as long as the run lasts and no longer. The
	// listener is started before the work and stopped after it.
	mux := http.NewServeMux()
	mux.Handle("/metrics", promhttp.Handler())
	mux.HandleFunc("/healthz", func(w http.ResponseWriter, r *http.Request) {
		fmt.Fprintln(w, "running")
	})
	srv := &http.Server{Addr: cfg.addr, Handler: mux, ReadHeaderTimeout: 5 * time.Second}
	go func() {
		if err := srv.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
			log.Printf("metrics listener: %v", err)
		}
	}()

	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGTERM, syscall.SIGINT)
	defer stop()

	code := run(ctx, cfg)

	shutCtx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	_ = srv.Shutdown(shutCtx)
	os.Exit(code)
}

// run does the pretending. It sleeps in slices so that a signal arriving
// part-way through is noticed promptly rather than at the end — a scheduled job
// that ignores a shutdown signal is one that gets killed mid-run, which is
// exactly the situation the no-overlap rule exists to avoid compounding.
func run(ctx context.Context, cfg config) int {
	log.Printf("settlement-worker %s starting a run (run_for=%s items=%d fail=%t)",
		cfg.version, cfg.runFor, cfg.itemCount, cfg.fail)
	started := time.Now()

	slice := cfg.runFor
	if cfg.itemCount > 0 {
		slice = cfg.runFor / time.Duration(cfg.itemCount)
	}

	for i := 0; i < cfg.itemCount; i++ {
		select {
		case <-ctx.Done():
			duration.Set(time.Since(started).Seconds())
			runs.WithLabelValues("interrupted").Inc()
			log.Printf("interrupted after %d of %d items", i, cfg.itemCount)
			return 1
		case <-time.After(slice):
			items.Inc()
		}
	}

	duration.Set(time.Since(started).Seconds())

	if cfg.fail {
		runs.WithLabelValues("failed").Inc()
		log.Printf("run failed deliberately after %s: FAIL_RUN is set", time.Since(started).Round(time.Millisecond))
		return 1
	}

	runs.WithLabelValues("succeeded").Inc()
	log.Printf("run finished in %s, %d items", time.Since(started).Round(time.Millisecond), cfg.itemCount)
	return 0
}
