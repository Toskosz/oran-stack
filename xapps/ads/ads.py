"""
ADS (Anomaly Detection Sidecar) - xapps/ads/ads.py
====================================================
Runs as a sidecar container sharing the network namespace with an Open5GS UPF
container (network_mode: service:5g-core-upf[2]).  Sniffs IP packets on the
UPF's TUN interface, extracts per-flow features, and streams JSON lines to the
xapp-kpi TCP server for FHE preprocessing.

Configuration (environment variables):
  ADS_SST          - S-NSSAI SST value for this slice (default: 1)
  ADS_SD           - S-NSSAI SD value for this slice (default: 1)
  ADS_SUBNET       - BPF filter subnet, e.g. "10.45.0.0/16"
  ADS_IFACE        - TUN interface name (default: ogstun)
  KPI_HOST         - xapp-kpi hostname/IP (default: xapp-kpi)
  KPI_PORT         - xapp-kpi TCP port    (default: 8080)
  RECONNECT_DELAY  - seconds between reconnect attempts (default: 5)
"""

import json
import logging
import os
import socket
import time

from scapy.all import sniff
from scapy.layers.inet import IP, TCP, UDP, ICMP

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [ADS-%(slice)s] %(message)s",
)

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
SST = int(os.environ.get("ADS_SST", "1"))
SD  = int(os.environ.get("ADS_SD",  "1"))
SUBNET    = os.environ.get("ADS_SUBNET", "10.45.0.0/16")
IFACE     = os.environ.get("ADS_IFACE",  "ogstun")
KPI_HOST  = os.environ.get("KPI_HOST",   "xapp-kpi")
KPI_PORT  = int(os.environ.get("KPI_PORT", "8080"))
RECONNECT = int(os.environ.get("RECONNECT_DELAY", "5"))

SLICE_LABEL = f"sst{SST}sd{SD}"

log = logging.LoggerAdapter(logging.getLogger(), {"slice": SLICE_LABEL})

# ---------------------------------------------------------------------------
# Port → service name mapping (NSL KDD-99 compatible labels)
# ---------------------------------------------------------------------------
SERVICE_PORTS: dict[int, str] = {
    80: "http", 443: "https", 21: "ftp", 20: "ftp_data", 25: "smtp",
    110: "pop_3", 23: "telnet", 143: "imap4", 22: "ssh", 53: "domain",
    70: "gopher", 11: "systat", 13: "daytime", 15: "netstat", 7: "echo",
    9: "discard", 6000: "X11", 5001: "urp_i", 113: "auth",
    117: "uucp_path", 513: "login", 514: "shell", 515: "printer",
    520: "efs", 530: "courier", 531: "conference", 532: "netnews",
    137: "netbios_ns", 138: "netbios_dgm", 139: "netbios_ssn",
    543: "klogin", 544: "kshell", 389: "ldap", 512: "exec",
    43: "whois", 150: "sql_net", 123: "ntp_u", 69: "tftp_u",
    194: "IRC", 109: "pop_2", 111: "sunrpc", 119: "nntp", 0: "other",
}

# ---------------------------------------------------------------------------
# Global socket (reconnected on error)
# ---------------------------------------------------------------------------
_sock: socket.socket | None = None


def _connect() -> socket.socket:
    """Block until xapp-kpi is reachable, return connected socket."""
    while True:
        try:
            s = socket.create_connection((KPI_HOST, KPI_PORT), timeout=10)
            log.info("Connected to xapp-kpi at %s:%d", KPI_HOST, KPI_PORT)
            return s
        except OSError as exc:
            log.warning("Cannot reach xapp-kpi (%s). Retrying in %ds…", exc, RECONNECT)
            time.sleep(RECONNECT)


def _send(data: dict) -> None:
    global _sock
    msg = json.dumps(data) + "\n"
    while True:
        try:
            if _sock is None:
                _sock = _connect()
            _sock.sendall(msg.encode())
            return
        except OSError as exc:
            log.warning("Send failed (%s). Reconnecting…", exc)
            try:
                _sock.close()
            except Exception:
                pass
            _sock = None


# ---------------------------------------------------------------------------
# Packet handler
# ---------------------------------------------------------------------------
def process_packet(pkt) -> None:
    if IP not in pkt:
        return

    ip = pkt[IP]
    protocol_type = "unknown"
    service = "other"
    src_bytes = 0
    dst_bytes = 0

    if TCP in ip:
        protocol_type = "tcp"
        dst_port = ip[TCP].dport
        service = SERVICE_PORTS.get(dst_port, "other")
        src_bytes = dst_bytes = len(bytes(ip[TCP].payload))
    elif UDP in ip:
        protocol_type = "udp"
        dst_port = ip[UDP].dport
        service = SERVICE_PORTS.get(dst_port, "other")
        src_bytes = dst_bytes = len(bytes(ip[UDP].payload))
    elif ICMP in ip:
        protocol_type = "icmp"
        src_bytes = dst_bytes = len(bytes(ip[ICMP].payload))

    features = {
        "sst": SST,
        "sd": SD,
        "protocol_type": protocol_type,
        "service": service,
        "src_bytes": src_bytes,
        "dst_bytes": dst_bytes,
    }
    log.info("features: %s", features)
    _send(features)


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
def main() -> None:
    global _sock
    log.info("ADS starting — iface=%s subnet=%s → xapp-kpi=%s:%d",
             IFACE, SUBNET, KPI_HOST, KPI_PORT)
    _sock = _connect()

    bpf = f"net {SUBNET}"
    while True:
        try:
            sniff(iface=IFACE, filter=bpf, prn=process_packet, store=False)
        except KeyboardInterrupt:
            log.info("Interrupted. Exiting.")
            break
        except Exception as exc:
            log.error("Sniff error: %s. Restarting in %ds…", exc, RECONNECT)
            time.sleep(RECONNECT)


if __name__ == "__main__":
    main()
