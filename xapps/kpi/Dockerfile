FROM python:3.10-slim

WORKDIR /app
COPY kpi.py entrypoint.sh ./

RUN apt-get update && apt-get install -y --no-install-recommends unzip \
    && rm -rf /var/lib/apt/lists/* \
    && chmod +x entrypoint.sh

RUN pip install --no-cache-dir \
    redis==5.0.8 \
    "concrete-ml==1.5.0"

# /model is mounted at runtime (contains preprocessor.pkl, client.zip).
# entrypoint.sh extracts client.zip → /tmp/fhe_model/ before starting kpi.py.
ENV MODEL_PATH=/tmp/fhe_model \
    PREPROCESSOR=/model/preprocessor.pkl \
    REDIS_HOST=ric-dbaas \
    REDIS_PORT=6379 \
    STREAM_KEY=xapp:messages \
    KPI_PORT=8080

EXPOSE 8080

ENTRYPOINT ["/app/entrypoint.sh"]
CMD ["python", "-u", "kpi.py"]
