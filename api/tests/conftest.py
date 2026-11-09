"""
Pruebas de la API contra una base PostgreSQL REAL (nada de mocks).
Preparar la base de pruebas (ver README): migraciones 001-009, 007 con las contrasenas, y la carga con
`python generar_datos.py --chico` + `python cargar.py`. Variables: PGHOST, PGPORT, PGDATABASE, PGUSER=app_rw, PGPASSWORD.
Las pruebas modifican datos: usar SIEMPRE una base descartable, nunca la de produccion.
"""
import os
import sys

import pytest

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from app import app as flask_app  # noqa: E402
from db import pool  # noqa: E402


@pytest.fixture(scope="session")
def client():
    flask_app.config["TESTING"] = True
    with flask_app.test_client() as c:
        yield c
    pool.cerrar()


@pytest.fixture(scope="session")
def sql():
    """Consulta de apoyo para preparar o comprobar datos (solo lectura)."""
    def ejecutar(texto, params=()):
        with pool.transaccion() as cur:
            cur.execute(texto, params)
            return cur.fetchall()
    return ejecutar
