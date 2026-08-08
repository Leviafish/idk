FROM python:3.12-slim
LABEL version="3.3.0" description="Levititas v3.3"

RUN apt-get update && \
    apt-get install -y --no-install-recommends lua5.4 && \
    ln -sf /usr/bin/lua5.4 /usr/bin/lua && \
    lua -v && \
    apt-get clean && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY . .
RUN mkdir -p output && chmod 777 output

EXPOSE 5000
ENV PORT=5000 DEBUG=0

HEALTHCHECK --interval=30s --timeout=10s --retries=3 \
  CMD lua -v && python -c "import urllib.request; urllib.request.urlopen('http://localhost:5000/api/status')" || exit 1

CMD ["python", "server.py"]
