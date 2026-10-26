FROM python:3.12-alpine
WORKDIR /app
COPY push_server.py /app/push_server.py
RUN adduser -D -u 10001 zpush && mkdir -p /data && chown zpush:zpush /data
USER zpush
ENV ZPUSH_DB=/data/push.db \
    ZPUSH_TOKEN_FILE=/run/secrets/token \
    ZPUSH_HOST=0.0.0.0 \
    ZPUSH_PORT=8788
EXPOSE 8788
HEALTHCHECK --interval=30s --timeout=5s --retries=3 \
  CMD wget -qO- http://127.0.0.1:8788/zpush/healthz || exit 1
CMD ["python3", "-u", "/app/push_server.py"]
