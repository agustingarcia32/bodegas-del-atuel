FROM python:3.12-slim
RUN apt-get update && apt-get install -y --no-install-recommends postgresql-client && rm -rf /var/lib/apt/lists/*
WORKDIR /seed
COPY . .
# genera los CSV y los carga con el propietario (PG* vienen del docker-compose); despues corre los 20 controles
CMD ["sh", "-c", "python generar_datos.py && python cargar.py"]
