FROM python:3.12-slim

RUN pip install --no-cache-dir \
      openpyxl==3.1.5 \
      python-docx==1.2.0 \
      python-pptx==1.0.2 \
    && useradd --create-home --uid 10001 app

WORKDIR /app
COPY app.py /app/app.py
USER app

EXPOSE 8080
CMD ["python", "/app/app.py"]
