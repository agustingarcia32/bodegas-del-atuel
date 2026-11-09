"""
medir.py - corre cada consulta de consultas_medidas.sql con EXPLAIN (ANALYZE, BUFFERS)
N veces (por defecto 5), se queda con la mediana del tiempo de ejecucion y guarda el
ultimo plan completo en <carpeta>/Qn.txt.

    python medir.py planes_antes            # conexion por variables PG*
    python medir.py planes_despues --n 5
Imprime una linea por consulta: tiempo (ms), nodo principal de lectura, buffers leidos.
"""
import argparse
import re
import statistics
import subprocess
import sys
from pathlib import Path

AQUI = Path(__file__).resolve().parent


def consultas():
    out, nombre, buf = [], None, []
    for linea in (AQUI / "consultas_medidas.sql").read_text(encoding="utf-8").splitlines():
        m = re.match(r"-- @(Q\d+) (.*)", linea)
        if m:
            if nombre:
                out.append((nombre, "\n".join(buf).strip()))
            nombre, buf = m.group(1), []
        elif nombre and not linea.startswith("--"):
            buf.append(linea)
    out.append((nombre, "\n".join(buf).strip()))
    return out


def explain(sql):
    r = subprocess.run(["psql", "-X", "-At", "-v", "ON_ERROR_STOP=1", "-c", "EXPLAIN (ANALYZE, BUFFERS) " + sql.rstrip(";")],
                       capture_output=True, text=True)
    if r.returncode:
        sys.exit(r.stderr)
    return r.stdout


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("carpeta")
    ap.add_argument("--n", type=int, default=5)
    ap.add_argument("--solo", default=None, help="ej. Q1,Q3")
    a = ap.parse_args()
    dest = AQUI / a.carpeta
    dest.mkdir(exist_ok=True)
    for nombre, sql in consultas():
        if a.solo and nombre not in a.solo.split(","):
            continue
        tiempos, plan = [], ""
        for _ in range(a.n):
            plan = explain(sql)
            tiempos.append(float(re.search(r"Execution Time: ([\d.]+) ms", plan).group(1)))
        (dest / f"{nombre}.txt").write_text(plan, encoding="utf-8")
        nodos = re.findall(r"(Seq Scan|Index Only Scan|Index Scan|Bitmap Heap Scan|Bitmap Index Scan) (?:using (\S+) )?on (\w+)|(Bitmap Index Scan) on (\S+)", plan)
        tipos = []
        for t in re.findall(r"->\s+((?:Parallel )?(?:Seq Scan|Index Only Scan|Index Scan|Bitmap Heap Scan)) (?:using \S+ )?on (\w+)", plan):
            tipos.append(f"{t[0]} {t[1]}")
        if plan.startswith(("Seq Scan", "Index", "Bitmap")):
            m = re.match(r"((?:Parallel )?(?:Seq Scan|Index Only Scan|Index Scan|Bitmap Heap Scan)) (?:using \S+ )?on (\w+)", plan)
            tipos.insert(0, f"{m.group(1)} {m.group(2)}")
        leidos = re.search(r"Buffers: shared hit=(\d+)(?: read=(\d+))?", plan)
        buffers = int(leidos.group(1)) + int(leidos.group(2) or 0) if leidos else 0
        print(f"{nombre}  {statistics.median(tiempos):10.2f} ms  buffers={buffers:7d}  " + "; ".join(tipos))


if __name__ == "__main__":
    main()
