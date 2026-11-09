r"""
cargar.py - Bodegas del Atuel - Etapa 3
Carga los CSV de seed/salida/ en la base. Usa psycopg (COPY) si esta instalado
y, si no, psql con \copy. Las dos formas hacen lo mismo.

    # 1) las migraciones 001-006 ya aplicadas, y los CSV generados:
    python generar_datos.py
    # 2) conexion por variables de entorno (las de psql): PGHOST, PGPORT, PGUSER, PGPASSWORD, PGDATABASE
    python cargar.py                 # usa el propietario (necesita ALTER TABLE)
    python cargar.py --solo-control  # solo corre las consultas de control

Triggers: durante la carga se deshabilitan los triggers DE USUARIO de cada tabla
(ALTER TABLE ... DISABLE TRIGGER USER). Las claves foraneas y los CHECK siguen
activos, asi que cualquier dato roto igual falla. Al terminar se vuelven a
habilitar y se corren las consultas de control (consultas_control.sql).
"""
import argparse
import subprocess
import sys
import time
from pathlib import Path

from generar_datos import AQUI, IDENTIDAD, ORDEN

try:
    import psycopg
except ImportError:
    psycopg = None

SALIDA = AQUI / "salida"


def psql(args, entrada=None):
    r = subprocess.run(["psql", "-X", "-q", "-v", "ON_ERROR_STOP=1", *args], input=entrada,
                       text=True, capture_output=True)
    if r.returncode != 0:
        sys.exit(f"psql fallo: {r.stderr.strip()}")
    return r.stdout


def columnas(nombre):
    with open(SALIDA / f"{nombre}.csv", encoding="utf-8") as f:
        return f.readline().strip()


class Cargador:
    def __init__(self):
        self.conn = psycopg.connect("") if psycopg else None
        if self.conn:
            self.conn.autocommit = True

    def sql(self, texto):
        if self.conn:
            self.conn.execute(texto)
        else:
            psql(["-c", texto])

    def copiar(self, nombre):
        cols = columnas(nombre)
        ruta = SALIDA / f"{nombre}.csv"
        if self.conn:
            with self.conn.cursor() as cur, open(ruta, "rb") as f:
                with cur.copy(f"COPY {nombre} ({cols}) FROM STDIN WITH (FORMAT csv, HEADER true)") as cp:
                    while True:
                        bloque = f.read(1 << 20)
                        if not bloque:
                            break
                        cp.write(bloque)
        else:
            psql(["-c", f"\\copy {nombre} ({cols}) FROM '{ruta.as_posix()}' WITH (FORMAT csv, HEADER true)"])


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--solo-control", action="store_true")
    a = ap.parse_args()
    control = AQUI / "consultas_control.sql"
    if a.solo_control:
        print(psql(["-f", str(control)]))
        return
    print("driver:", "psycopg (COPY)" if psycopg else "psql (\\copy)")
    c = Cargador()
    t0 = time.perf_counter()
    for t in ORDEN:
        c.sql(f"ALTER TABLE {t} DISABLE TRIGGER USER")
    print("triggers de usuario deshabilitados")
    try:
        for t in ORDEN:
            t1 = time.perf_counter()
            c.copiar(t)
            print(f"  {t:26s}{time.perf_counter() - t1:7.2f} s")
        for t, col in IDENTIDAD.items():
            c.sql(f"SELECT setval(pg_get_serial_sequence('{t}', '{col}'), (SELECT max({col}) FROM {t}))")
    finally:
        for t in ORDEN:
            c.sql(f"ALTER TABLE {t} ENABLE TRIGGER USER")
        print("triggers de usuario vueltos a habilitar")
    c.sql("ANALYZE")
    print(f"carga total: {time.perf_counter() - t0:.1f} s\n")
    print(psql(["-f", str(control)]))


if __name__ == "__main__":
    main()
