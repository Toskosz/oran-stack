FROM golang:1.21-alpine AS builder

WORKDIR /src
COPY go.mod .
COPY main.go .

# Download dependencies and build a statically linked binary
RUN go mod download && \
    CGO_ENABLED=0 GOOS=linux go build -o /xapp-rc .

# ---- runtime image ----
FROM alpine:3.19

COPY --from=builder /xapp-rc /xapp-rc

ENV REDIS_ADDR=ric-dbaas:6379 \
    STREAM_KEY=xapp:messages \
    WINDOW=30 \
    ALERT_THRESHOLD=0.5 \
    POLL_INTERVAL=5

ENTRYPOINT ["/xapp-rc"]
