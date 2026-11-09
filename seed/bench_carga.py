"""
bench_carga.py - Etapa 3, paso 6: tiempo de insertar N filas de 4 maneras.
Usa una tabla temporal propia (bench_carga) y la borra al terminar.

    python bench_carga.py            # N = 20000
    python bench_carga.py --n 50000

Con psycopg usa execute / executemany / COPY; sin psycopg arma archivos SQL y
los pasa por psql (mismo efecto: una sentencia por fila, una por lote, COPY).
"""
import argparse
import subprocess
import sys
import tempfile
import time
from pathlib import Path

try:
    import psycopg
except ImportError:
    psycopg = None


def psql(args, entrada=None):
    r = subprocess.run(["psql", "-X", "-q", "-v", "ON_ERROR_STOP=1", *args], input=entrada, text=True, capture_output=True)
    if r.returncode != 0:
        sys.exit("psql fallo: " + r.stderr.strip())


def filas(n):
    return [(i, i % 800 + 1, i % 50 + 1, f"fila {i}") for i in range(1, n + 1)]


def medir(nombre, f, resultados):
    psql(["-c", "TRUNCATE bench_carga"])
    t = time.perf_counter()
    f()
    dt = time.perf_counter() - t
    resultados.append((nombre, dt))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--n", type=int, default=20000)
    n = ap.parse_args().n
    datos = filas(n)
    psql(["-c", "DROP TABLE IF EXISTS bench_carga; CREATE TABLE bench_carga(id int PRIMARY KEY, cod_vino int, cantidad int, texto text)"])
    res = []
    tmp = Path(tempfile.mkdtemp())
    try:
        if psycopg:
            conn = psycopg.connect(""); conn.autocommit = True
            sql = "INSERT INTO bench_carga VALUES (%s,%s,%s,%s)"

            def a():
                for r in datos:
                    conn.execute(sql, r)

            def b():
                with conn.transaction():
                    for r in datos:
                        conn.execute(sql, r)

            def c():
                with conn.transaction(), conn.cursor() as cur:
                    for i in range(0, n, 1000):
                        cur.executemany(sql, datos[i:i + 1000])

            def d():
                with conn.cursor() as cur, cur.copy("COPY bench_carga FROM STDIN") as cp:
                    for r in datos:
                        cp.write_row(r)
        else:
            f1 = tmp / "a.sql"; f1.write_text("".join(f"INSERT INTO bench_carga VALUES ({r[0]},{r[1]},{r[2]},'{r[3]}');\n" for r in datos))
            f2 = tmp / "b.sql"; f2.write_text("BEGIN;\n" + f1.read_text() + "COMMIT;\n")
            f3 = tmp / "c.sql"
            with open(f3, "w") as f:
                f.write("BEGIN;\n")
                for i in range(0, n, 1000):
                    f.write("INSERT INTO bench_carga VALUES " + ",".join(f"({r[0]},{r[1]},{r[2]},'{r[3]}')" for r in datos[i:i + 1000]) + ";\n")
                f.write("COMMIT;\n")
            f4 = tmp / "d.csv"; f4.write_text("".join(f"{r[0]},{r[1]},{r[2]},{r[3]}\n" for r in datos))
            a = lambda: psql(["-f", str(f1)])
            b = lambda: psql(["-f", str(f2)])
            c = lambda: psql(["-f", str(f3)])
            d = lambda: psql(["-c", f"\\copy bench_carga FROM '{f4.as_posix()}' WITH (FORMAT csv)"])
        medir("1) fila por fila, un COMMIT por fila (autocommit)", a, res)
        medir("2) fila por fila, una sola transaccion", b, res)
        medir("3) por lotes: INSERT/executemany de 1000 filas", c, res)
        medir("4) COPY", d, res)
    finally:
        psql(["-c", "DROP TABLE IF EXISTS bench_carga"])
    base = res[0][1]
    print(f"driver: {'psycopg' if psycopg else 'psql'} | filas: {n}")
    for nom, dt in res:
        print(f"{nom:58s}{dt:8.2f} s{n / dt:12.0f} filas/s{base / dt:8.1f}x")


if __name__ == "__main__":
    main()
