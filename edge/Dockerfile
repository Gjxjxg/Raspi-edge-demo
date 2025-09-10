FROM python:3.10-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential libjpeg-dev zlib1g-dev && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY requirements.txt /app/
RUN pip install --no-cache-dir -r requirements.txt

COPY app.py /app/app.py

ENV BROKER_HOST=broker \
    BROKER_PORT=1883 \
    MODEL_NAME=mv3_small \
    TORCH_THREADS=4 \
    CLIENT_ID=edge-infer \
    TASK_CLEANUP_SEC=120

CMD ["python", "app.py"]
