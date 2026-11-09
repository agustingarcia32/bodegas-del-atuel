# API – Bodegas del Atuel (Flask + psycopg3)

Capa fina: cada endpoint llama a una función de `dal.py` (una consulta por función, siempre con parámetros `%s`).
Las reglas de negocio las impone la base; la API solo traduce el error de PostgreSQL a HTTP (`errores.py`).

## Correr
```
pip install -r requirements.txt
set DATABASE_URL=postgresql://app_rw:CLAVE@localhost:5432/bodegas     (Windows cmd; en PowerShell: $env:DATABASE_URL="...")
set CORS_ORIGIN=http://localhost:8080
python -m flask --app app run --port 8000
```
Documentación interactiva: http://localhost:8000/docs (spec en `/openapi.json`).

## Pruebas (contra PostgreSQL real; modifican datos: usar una base descartable)
```
set PGHOST=localhost & set PGDATABASE=bodegas_test & set PGUSER=app_rw & set PGPASSWORD=CLAVE
python -m pytest tests -v
```
Resultado de referencia: `tests/resultado_pytest.txt` (17 pruebas).

## Traducción de errores
| SQLSTATE | HTTP | Ejemplo |
|---|---|---|
| 23505 / 23503 / P0001 | 409 | documento repetido, vino con movimientos, porcentajes ≠ 100, sin stock |
| 23514 / 23502 | 422 | precio negativo, dato obligatorio faltante |
| 22P02 / 22007 | 400 | `anada=abc`, fecha inválida |
| 42501 | 403 | el rol no tiene permiso |
| 40001 / 40P01 | 503 + Retry-After | conflicto de transacciones |
| sin conexión | 503 | base caída |

## Demostración de inyección SQL
`tests/test_api.py::test_inyeccion_sql_no_funciona` manda `'; DROP TABLE vino; --`, `' OR '1'='1` y un `UNION SELECT`:
se buscan como texto literal (0 resultados), un `anada` malicioso da 400 y la tabla `vino` sigue intacta.
Defensas: parámetros `%s` (nunca concatenación), el tipo lo valida PostgreSQL, y el rol `app_rw` no puede hacer DDL
(aunque hubiera una inyección, `DROP TABLE` da 42501).
