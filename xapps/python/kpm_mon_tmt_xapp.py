#!/usr/bin/env python3
"""Starter E2SM-KPM monitoring xApp generated for kpm-mon-tmt."""

import argparse
import math
import signal
import threading
from collections import deque

from lib.xAppBase import xAppBase


class StudentKpmXapp(xAppBase):
    """Subscribe to one node-level KPM report and keep logs bounded."""

    STATES = ("unknown", "below_threshold", "healthy")

    def __init__(
        self,
        config,
        http_server_port,
        rmr_port,
        log_every,
        window_size,
        success_threshold,
    ):
        if window_size < 1:
            raise ValueError("window_size must be positive")
        if not math.isfinite(success_threshold):
            raise ValueError("success_threshold must be finite")

        super(StudentKpmXapp, self).__init__(config, http_server_port, rmr_port)
        self.log_every = max(1, log_every)
        self.indication_count = 0
        self.window_size = window_size
        self.success_threshold = float(success_threshold)
        self._samples = deque(maxlen=self.window_size)
        self._sample_sum = 0.0
        self._sample_count = 0
        self._below_threshold_count = 0
        self._state = "unknown"
        self._state_transitions = 0
        self._state_lock = threading.Lock()

    def _observe(self, value):
        """Update the bounded moving average and return a stable snapshot."""
        with self._state_lock:
            if len(self._samples) == self._samples.maxlen:
                self._sample_sum -= self._samples[0]
            self._samples.append(value)
            self._sample_sum += value
            self._sample_count += 1

            average = self._sample_sum / len(self._samples)
            new_state = (
                "healthy"
                if average >= self.success_threshold
                else "below_threshold"
            )
            if new_state != self._state and self._state != "unknown":
                self._state = new_state
                self._state_transitions += 1
            else:
                self._state = new_state
            if new_state == "below_threshold":
                self._below_threshold_count += 1
            return self._snapshot(average)

    def _snapshot(self, average=None):
        if average is None:
            average = (
                self._sample_sum / len(self._samples) if self._samples else 0.0
            )
        return {
            "average": average,
            "samples": self._sample_count,
            "below_threshold": self._below_threshold_count,
            "state": self._state,
            "transitions": self._state_transitions,
        }

    def _metrics_handler(self, name, path, data, ctype):
        response = super(StudentKpmXapp, self)._metrics_handler(
            name, path, data, ctype
        )
        with self._state_lock:
            snapshot = self._snapshot()

        payload = response["payload"]
        payload += (
            "# HELP oran_kpm_mon_tmt_success_rate_average Moving-average packet success rate.\n"
            "# TYPE oran_kpm_mon_tmt_success_rate_average gauge\n"
            "oran_kpm_mon_tmt_success_rate_average {:.12g}\n"
            "# HELP oran_kpm_mon_tmt_samples_total Valid samples processed.\n"
            "# TYPE oran_kpm_mon_tmt_samples_total counter\n"
            "oran_kpm_mon_tmt_samples_total {}\n"
            "# HELP oran_kpm_mon_tmt_below_threshold_total Samples whose moving average was below the threshold.\n"
            "# TYPE oran_kpm_mon_tmt_below_threshold_total counter\n"
            "oran_kpm_mon_tmt_below_threshold_total {}\n"
            "# HELP oran_kpm_mon_tmt_state Current packet-success classification.\n"
            "# TYPE oran_kpm_mon_tmt_state gauge\n"
        ).format(
            snapshot["average"],
            snapshot["samples"],
            snapshot["below_threshold"],
        )
        for state in self.STATES:
            payload += 'oran_kpm_mon_tmt_state{{state="{}"}} {}\n'.format(
                state, int(snapshot["state"] == state)
            )
        payload += (
            "# HELP oran_kpm_mon_tmt_state_transitions_total Classification transitions.\n"
            "# TYPE oran_kpm_mon_tmt_state_transitions_total counter\n"
            "oran_kpm_mon_tmt_state_transitions_total {}\n"
            "# HELP oran_kpm_mon_tmt_success_threshold Configured success-rate threshold.\n"
            "# TYPE oran_kpm_mon_tmt_success_threshold gauge\n"
            "oran_kpm_mon_tmt_success_threshold {:.12g}\n"
        ).format(snapshot["transitions"], self.success_threshold)
        response["payload"] = payload
        return response

    def indication_callback(
        self,
        e2_agent_id,
        subscription_id,
        indication_header,
        indication_message,
    ):
        self.indication_count += 1
        measurements = self.e2sm_kpm.extract_meas_data(indication_message)
        value = self._latest_numeric(
            measurements.get("measData", {}).get(
                "DRB.PacketSuccessRateUlgNBUu", []
            )
        )
        if value is None:
            return

        snapshot = self._observe(value)
        if (
            snapshot["samples"] != 1
            and self.indication_count % self.log_every
        ):
            return

        header = self.e2sm_kpm.extract_hdr_info(indication_header)
        print(
            "kpm-mon-tmt: indication={} node={} subscription={} time={} "
            "success_rate={:.3f} moving_average={:.3f} state={}".format(
                self.indication_count,
                e2_agent_id,
                subscription_id,
                header.get("colletStartTime"),
                value,
                snapshot["average"],
                snapshot["state"],
            ),
            flush=True,
        )

    @xAppBase.start_function
    def start(self, e2_node_id, metric_names, report_period, granul_period):
        print(
            "kpm-mon-tmt: subscribing node={} style=1 metrics={}".format(
                e2_node_id, metric_names
            ),
            flush=True,
        )
        self.e2sm_kpm.subscribe_report_service_style_1(
            e2_node_id,
            report_period,
            metric_names,
            granul_period,
            self.indication_callback,
        )


def parse_args():
    parser = argparse.ArgumentParser(description="kpm-mon-tmt KPM laboratory xApp")
    parser.add_argument("--config", default="")
    parser.add_argument("--http_server_port", type=int, default=8091)
    parser.add_argument("--rmr_port", type=int, default=4561)
    parser.add_argument("--e2_node_id", required=True)
    parser.add_argument("--ran_func_id", type=int, default=2)
    parser.add_argument("--kpm_report_style", type=int, choices=[1], default=1)
    parser.add_argument("--metrics", default="DRB.PacketSuccessRateUlgNBUu")
    parser.add_argument("--report_period", type=int, default=2000)
    parser.add_argument("--granul_period", type=int, default=2000)
    parser.add_argument("--log_every", type=int, default=30)
    parser.add_argument("--window_size", type=int, default=5)
    parser.add_argument("--success_threshold", type=float, default=99.0)
    return parser.parse_args()


if __name__ == "__main__":
    args = parse_args()
    app = StudentKpmXapp(
        args.config,
        args.http_server_port,
        args.rmr_port,
        args.log_every,
        args.window_size,
        args.success_threshold,
    )
    app.e2sm_kpm.set_ran_func_id(args.ran_func_id)

    signal.signal(signal.SIGQUIT, app.signal_handler)
    signal.signal(signal.SIGTERM, app.signal_handler)
    signal.signal(signal.SIGINT, app.signal_handler)

    app.start(
        args.e2_node_id,
        args.metrics.split(","),
        args.report_period,
        args.granul_period,
    )
