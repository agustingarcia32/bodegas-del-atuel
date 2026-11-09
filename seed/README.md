# seed/ — carga masiva (Etapa 3)

```
seed/
  catalogos/            CSV de catálogo (no se generan al azar): localidades, departamentos, cepas,
                        maridajes, bodegas, transportistas, tipos de vino, presentaciones
  generar_datos.py      genera un CSV por tabla en seed/salida/ (semilla fija, solo librería estándar)
  cargar.py             deshabilita triggers de usuario, COPY en orden, reajusta secuencias, habilita, controla
  consultas_control.sql conteos y 20 controles de coherencia (todos tienen que dar 0 problemas)
  bench_carga.py        fila por fila vs lotes vs COPY
  dump_completo.sql.gz  base cargada (8 MB), para restaurar sin regenerar
```

## Pasos (PostgreSQL ≥ 14, Python ≥ 3.9)

```bash
createdb bodegas
for f in 001_esquema 002_constraints 003_funciones 004_procedimientos 005_triggers 006_vistas; do
  psql -d bodegas -v ON_ERROR_STOP=1 -f migrations/$f.sql
done
cd seed
python generar_datos.py              # ~5 s, escribe seed/salida/*.csv y muestra la huella sha256
python cargar.py                     # ~10 s; imprime conteos y controles
python bench_carga.py                # comparación de tiempos
```
La conexión sale de las variables de entorno de psql (`PGHOST`, `PGPORT`, `PGUSER`, `PGPASSWORD`, `PGDATABASE`). Se carga con el **propietario** del esquema, no con `app_rw` (que no puede deshabilitar triggers). Con `pip install psycopg[binary]` el cargador usa psycopg (COPY); sin él usa `psql \copy`. En Windows hace falta `psql` en el PATH.

Restaurar sin generar: `createdb bodegas2 && gunzip -c dump_completo.sql.gz | psql -d bodegas2`.
Para generar otro volumen: `python generar_datos.py --chico` (1 %). Otra semilla: `--semilla 7`. Otra fecha de referencia (para que "última semana" tenga datos): `--hoy 2026-12-01`.

## Notas
- Los códigos postales y los nombres de encargados de `localidades.csv` son de referencia (los encargados son inventados): revisen los códigos postales antes de entregar.
- Bodegas y transportistas son nombres inventados con CUIT de dígito verificador válido.
- Las variables `PG*` y las contraseñas no se guardan en ningún archivo.
