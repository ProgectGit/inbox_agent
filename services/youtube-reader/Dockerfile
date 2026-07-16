FROM python:3.12-slim

RUN pip install --no-cache-dir yt-dlp==2026.7.4 \
    && useradd --create-home --uid 10001 app

WORKDIR /app
COPY app.py /app/app.py
USER app

EXPOSE 8080
CMD ["python", "/app/app.py"]
