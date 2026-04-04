FROM python:3.10-slim

WORKDIR /app
COPY inference.py entrypoint.sh ./

RUN apt-get update && apt-get install -y --no-install-recommends unzip \
    && rm -rf /var/lib/apt/lists/* \
    && chmod +x entrypoint.sh

RUN pip install --no-cache-dir \
    redis==5.0.8 \
    "concrete-ml==1.5.0"

# /model is mounted at runtime (contains server.zip and client.zip).
# entrypoint.sh extracts server.zip → /tmp/fhe_model/ before starting inference.py.
# FHEModelClient is also loaded to generate eval keys — client.zip is needed too.
ENV MODEL_PATH=/tmp/fhe_model \
    REDIS_HOST=ric-dbaas \
    REDIS_PORT=6379 \
    STREAM_KEY=xapp:messages

ENTRYPOINT ["/app/entrypoint.sh"]
CMD ["python", "-u", "inference.py"]
