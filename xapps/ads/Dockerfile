FROM python:3.11-slim

# System deps: libpcap for scapy packet capture
RUN apt-get update && apt-get install -y --no-install-recommends \
        libpcap-dev \
        tcpdump \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY ads.py .

RUN pip install --no-cache-dir \
    scapy==2.5.0 \
    "concrete-ml==1.5.0"

# Needs NET_RAW / NET_ADMIN to sniff on the UPF TUN interface.
# The compose file must grant those capabilities and set
# network_mode: service:5g-core-upf[2].
CMD ["python", "-u", "ads.py"]
