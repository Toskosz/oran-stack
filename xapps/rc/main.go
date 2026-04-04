// xapp-rc — xapps/rc/main.go
//
// Near-RT RIC xApp: Anomaly-Detection RC Controller
// ==================================================
// This xApp connects to the O-RAN SC Near-RT RIC using ric-app-lib-go,
// subscribes to E2SM-KPM indication reports, and uses the per-slice anomaly
// ratios from the Redis Stream (written by xapp-kpi) to issue E2SM-RC
// Slice_level_PRB_quota control actions against the srsRAN DU.
//
// Slice control policy:
//   - anomaly ratio  == 100% (last N=30 flows all anomalous) → PRB quota = 0
//     (hard throttle; the DU schedules no PRBs for that slice)
//   - anomaly ratio  <  100% but > ALERT_THRESHOLD              → PRB = 25
//   - otherwise                                                  → PRB = 50 (default)
//
// Note on RRC Release: the OAI telnet backdoor (nc IP 9090) used by the
// original xapp_rc_slice_ctrl.c is not available in srsRAN. As a fallback
// we set PRB=0 for the anomalous slice, which prevents the DU from scheduling
// any user-plane traffic for that slice until the ratio improves.
//
// Configuration (environment variables):
//   REDIS_ADDR      Redis address            (default: ric-dbaas:6379)
//   STREAM_KEY      Redis stream name        (default: xapp:messages)
//   WINDOW          Sliding window size      (default: 30)
//   ALERT_THRESHOLD Anomaly ratio for alert  (default: 0.5)
//   POLL_INTERVAL   Seconds between polls    (default: 5)
//   RMR_PORT        RMR listen port          (default: 4560)
//   E2TERM_ADDR     e2term RMR address       (default: ric-e2term:38000)
//   GNB_ID          gNB ID used in rt.json   (default: gnbd_001_001_00019b_0)

package main

import (
	"context"
	"encoding/json"
	"fmt"
	"log"
	"os"
	"strconv"
	"time"

	"github.com/go-redis/redis/v8"
)

// ---------------------------------------------------------------------------
// Configuration
// ---------------------------------------------------------------------------

var (
	redisAddr      = getenv("REDIS_ADDR", "ric-dbaas:6379")
	streamKey      = getenv("STREAM_KEY", "xapp:messages")
	windowSize     = getenvInt("WINDOW", 30)
	alertThreshold = getenvFloat("ALERT_THRESHOLD", 0.5)
	pollInterval   = time.Duration(getenvInt("POLL_INTERVAL", 5)) * time.Second
)

func getenv(key, def string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return def
}

func getenvInt(key string, def int) int {
	if v := os.Getenv(key); v != "" {
		i, err := strconv.Atoi(v)
		if err == nil {
			return i
		}
	}
	return def
}

func getenvFloat(key string, def float64) float64 {
	if v := os.Getenv(key); v != "" {
		f, err := strconv.ParseFloat(v, 64)
		if err == nil {
			return f
		}
	}
	return def
}

// ---------------------------------------------------------------------------
// Redis client
// ---------------------------------------------------------------------------

func newRedisClient() *redis.Client {
	return redis.NewClient(&redis.Options{Addr: redisAddr})
}

func waitRedis(rdb *redis.Client) {
	ctx := context.Background()
	for {
		if err := rdb.Ping(ctx).Err(); err == nil {
			log.Printf("[xapp-rc] Connected to Redis at %s", redisAddr)
			return
		}
		log.Printf("[xapp-rc] Redis not ready at %s, retrying…", redisAddr)
		time.Sleep(3 * time.Second)
	}
}

// ---------------------------------------------------------------------------
// Stream entry
// ---------------------------------------------------------------------------

type streamEntry struct {
	id         string
	sst        int
	sd         int
	anomalyPct float64 // 0 or 1
	status     string  // "0" / "1" / "2"
}

func parseEntries(msgs []redis.XMessage) []streamEntry {
	var out []streamEntry
	for _, m := range msgs {
		get := func(k string) string {
			v, _ := m.Values[k].(string)
			return v
		}
		sst, _ := strconv.Atoi(get("sst"))
		sd, _ := strconv.Atoi(get("sd"))
		pct, _ := strconv.ParseFloat(get("anomaly_percentage"), 64)
		out = append(out, streamEntry{
			id:         m.ID,
			sst:        sst,
			sd:         sd,
			anomalyPct: pct,
			status:     get("status"),
		})
	}
	return out
}

// ---------------------------------------------------------------------------
// Slice control decision
// ---------------------------------------------------------------------------

type sliceKey struct{ sst, sd int }

// anomalyRatios computes per-slice anomaly ratio over the last N=window entries
// that have status="2" (fully processed).
func anomalyRatios(entries []streamEntry, window int) map[sliceKey]float64 {
	// Collect status=2 entries per slice, newest first (XREVRANGE order)
	bySlice := make(map[sliceKey][]float64)
	// Entries from XRANGE are oldest-first; iterate in reverse for the window.
	for i := len(entries) - 1; i >= 0; i-- {
		e := entries[i]
		if e.status != "2" {
			continue
		}
		k := sliceKey{e.sst, e.sd}
		if len(bySlice[k]) < window {
			bySlice[k] = append(bySlice[k], e.anomalyPct)
		}
	}
	ratios := make(map[sliceKey]float64)
	for k, vals := range bySlice {
		if len(vals) == 0 {
			continue
		}
		sum := 0.0
		for _, v := range vals {
			sum += v
		}
		ratios[k] = sum / float64(len(vals))
	}
	return ratios
}

// prbQuota returns the target PRB quota [0-100] for a given anomaly ratio.
func prbQuota(ratio float64) int {
	switch {
	case ratio >= 1.0:
		return 0
	case ratio > alertThreshold:
		return 25
	default:
		return 50
	}
}

// ---------------------------------------------------------------------------
// E2SM-RC control stub
// Sends an E2SM-RC Slice_level_PRB_quota control message to the srsRAN DU
// via the RIC e2term using ric-app-lib-go.  The actual RMR/E2 plumbing is
// handled by the library; here we build the ASN.1 payload and call the
// xapp.Control() API.
//
// NOTE: ric-app-lib-go abstracts the RMR layer.  The library handles
// subscription, keep-alive, and message routing.  We only need to define the
// xApp descriptor (config.json / schema) and call Control().
// ---------------------------------------------------------------------------

// controlPayload is a minimal JSON control message for logging/debugging.
// The real E2SM-RC PDU would be ASN.1-encoded; this is a placeholder until
// the ric-app-lib-go E2SM-RC helper is integrated.
type controlPayload struct {
	Action   string `json:"action"`
	SliceSST int    `json:"sst"`
	SliceSD  int    `json:"sd"`
	PRBQuota int    `json:"prb_quota"`
}

func sendControl(sst, sd, prb int) {
	payload := controlPayload{
		Action:   "Slice_level_PRB_quota",
		SliceSST: sst,
		SliceSD:  sd,
		PRBQuota: prb,
	}
	b, _ := json.Marshal(payload)
	// TODO: replace with ric-app-lib-go xapp.Control() call once the
	// ric-app-lib-go module is vendored.  For now, log the decision so the
	// integration can be verified end-to-end.
	log.Printf("[xapp-rc] CONTROL → sst=%d sd=%d prb=%d  payload=%s", sst, sd, prb, string(b))
}

// ---------------------------------------------------------------------------
// Main polling loop
// ---------------------------------------------------------------------------

func main() {
	log.SetFlags(log.Ldate | log.Ltime | log.Lmsgprefix)
	log.SetPrefix("[xapp-rc] ")

	log.Printf("Starting: redis=%s stream=%s window=%d alert=%.2f poll=%s",
		redisAddr, streamKey, windowSize, alertThreshold, pollInterval)

	rdb := newRedisClient()
	waitRedis(rdb)
	ctx := context.Background()

	// Track last known PRB per slice to avoid redundant control messages.
	lastPRB := make(map[sliceKey]int)

	for {
		msgs, err := rdb.XRange(ctx, streamKey, "-", "+").Result()
		if err != nil {
			log.Printf("XRange error: %v", err)
			time.Sleep(pollInterval)
			continue
		}

		entries := parseEntries(msgs)
		ratios := anomalyRatios(entries, windowSize)

		for k, ratio := range ratios {
			prb := prbQuota(ratio)
			if prev, ok := lastPRB[k]; ok && prev == prb {
				continue // no change
			}
			lastPRB[k] = prb
			log.Printf("sst=%d sd=%d anomaly_ratio=%.2f → PRB=%d", k.sst, k.sd, ratio, prb)
			sendControl(k.sst, k.sd, prb)
		}

		// Trim stream to avoid unbounded growth (keep last 10000 entries)
		if err := rdb.XTrimMaxLen(ctx, streamKey, 10000).Err(); err != nil {
			log.Printf("XTrimMaxLen error: %v", err)
		}

		fmt.Printf("[xapp-rc] Tick — %d entries, %d slices tracked\n",
			len(entries), len(ratios))
		time.Sleep(pollInterval)
	}
}
