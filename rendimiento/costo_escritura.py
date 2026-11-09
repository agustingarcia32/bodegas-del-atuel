"""
costo_escritura.py - Etapa 4, paso 7: cuanto cuestan los indices de 008 al escribir.
Recarga comprobante y renglon_comprobante (150 mil y 560 mil filas) tres veces:
  A) solo con las claves primarias (sin indices de 008)
  B) con los indices de 008 ya creados antes de cargar
  C) sin indices y creandolos DESPUES de cargar
y mide ademas 5000 INSERT de comprobante uno por uno en una transaccion (A y B).
Necesita los CSV de seed/salida/ (python generar_datos.py) y la base cargada.
Al terminar deja la base como estaba (mismos datos, indices creados, triggers habilitados).

    python costo_escritura.py ../seed/salida
"""
import subprocess
import sys
import time
from pathlib import Path


def psql(sql=None, archivo=None):
    args = ["psql", "-X", "-At", "-v", "ON_ERROR_STOP=1"] + (["-c", sql] if sql else ["-f", str(archivo)])
    r = subprocess.run(args, capture_output=True, text=True)
    if r.returncode:
        sys.exit(r.stderr)
    return r.stdout.strip()


def cronometrar(f):
    t = time.perf_counter()
    f()
    return time.perf_counter() - t


def copiar(csv, tabla):
    ruta = (csv / f"{tabla}.csv").resolve().as_posix()
    cols = (csv / f"{tabla}.csv").read_text(encoding="utf-8").split("\n", 1)[0]
    psql(f"\\copy {tabla} ({cols}) FROM '{ruta}' WITH (FORMAT csv, HEADER true)")


def cargar_tablas(csv):
    return (cronometrar(lambda: copiar(csv, "comprobante")), cronometrar(lambda: copiar(csv, "renglon_comprobante")))


def main():
    csv = Path(sys.argv[1])
    defs = psql("SELECT indexname || '|' || indexdef FROM pg_indexes WHERE schemaname='public' AND indexname LIKE 'idx\\_%' "
                "AND tablename IN ('comprobante','renglon_comprobante') ORDER BY 1").splitlines()
    defs = [d.split("|", 1) for d in defs]
    print("indices de 008 sobre estas tablas:", ", ".join(n for n, _ in defs))
    tam = psql("SELECT pg_size_pretty(sum(pg_relation_size(indexrelid))) FROM pg_stat_user_indexes WHERE relname IN ('comprobante','renglon_comprobante') AND indexrelname LIKE 'idx\\_%'")
    psql("ALTER TABLE comprobante DISABLE TRIGGER USER; ALTER TABLE renglon_comprobante DISABLE TRIGGER USER")
    res = {}
    try:
        for n, _ in defs:
            psql(f"DROP INDEX {n}")
        # A) solo PK
        psql("TRUNCATE comprobante CASCADE")
        res["A"] = cargar_tablas(csv)
        # 5000 insert uno por uno, sin indices
        filas = "BEGIN;\n" + "".join(
            f"INSERT INTO comprobante(fecha,id_cliente,id_sala,subtotal,descuento,total) VALUES ('2026-01-01',{i % 19000 + 1},{i % 60 + 1},100,10,90);\n"
            for i in range(5000)) + "COMMIT;\n"
        arch = Path("insert_5000.sql"); arch.write_text(filas)
        res["A1"] = cronometrar(lambda: psql(archivo=arch))
        # B) indices antes de cargar
        psql("TRUNCATE comprobante CASCADE")
        for n, d in defs:
            psql(d)
        res["B"] = cargar_tablas(csv)
        res["B1"] = cronometrar(lambda: psql(archivo=arch))
        # C) cargar sin indices y crearlos despues
        psql("TRUNCATE comprobante CASCADE")
        for n, _ in defs:
            psql(f"DROP INDEX {n}")
        c = cargar_tablas(csv)
        t = cronometrar(lambda: [psql(d) for _, d in defs])
        res["C"] = (c[0], c[1], t)
        arch.unlink()
        # la base queda con los 5000 inserts de prueba del paso B: se vuelve a cargar limpio
        psql("TRUNCATE comprobante CASCADE")
        cargar_tablas(csv)
    finally:
        psql("ALTER TABLE comprobante ENABLE TRIGGER USER; ALTER TABLE renglon_comprobante ENABLE TRIGGER USER")
        existentes = psql("SELECT indexname FROM pg_indexes WHERE schemaname='public'").splitlines()
        for n, d in defs:
            if n not in existentes:
                psql(d)
        psql("SELECT setval(pg_get_serial_sequence('comprobante','nro_comprobante'), (SELECT max(nro_comprobante) FROM comprobante)); ANALYZE")
    a, b, c = res["A"], res["B"], res["C"]
    print(f"\nTamano de los indices de 008 en estas dos tablas: {tam}\n")
    print(f"{'Escenario':58s}{'comprobante':>13s}{'renglon':>10s}{'total':>9s}")
    print(f"{'A) solo claves primarias':58s}{a[0]:12.2f}s{a[1]:9.2f}s{sum(a):8.2f}s")
    print(f"{'B) con los indices de 008 creados antes de cargar':58s}{b[0]:12.2f}s{b[1]:9.2f}s{sum(b):8.2f}s   (+{(sum(b) / sum(a) - 1) * 100:.0f} % vs A)")
    print(f"{'C) sin indices, cargar y crear los indices despues':58s}{c[0]:12.2f}s{c[1]:9.2f}s{c[0] + c[1] + c[2]:8.2f}s   (de los cuales {c[2]:.2f} s crear los indices)")
    print(f"\n5000 INSERT de comprobante, uno por uno en una transaccion:  A) {res['A1']:.2f} s   B) {res['B1']:.2f} s   (+{(res['B1'] / res['A1'] - 1) * 100:.0f} %)")


if __name__ == "__main__":
    main()
