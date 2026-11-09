FROM python:3.12-slim
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY *.py ./
RUN useradd -r api && chown -R api /app
USER api
EXPOSE 8000
# gunicorn: varios hilos; el pool propio de la API es por proceso
CMD ["gunicorn", "-b", "0.0.0.0:8000", "-w", "2", "--threads", "4", "app:app"]
