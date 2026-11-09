"""
generar_datos.py - Bodegas del Atuel - Etapa 3
Genera los datos de prueba como archivos CSV (uno por tabla) en seed/salida/.
Usa solo la biblioteca estandar de Python (no hace falta Faker) y una semilla
fija: dos ejecuciones con la misma semilla producen archivos identicos.

    python generar_datos.py                 # semilla 2026
    python generar_datos.py --semilla 7     # otra semilla
    python generar_datos.py --chico         # volumenes chicos (para probar rapido)

Los plazos y los stocks se arman para que los datos sean coherentes sin
depender de los triggers (que se deshabilitan durante la carga):
  * ingresos y transferencias procesados desde 2020-06; ventas desde 2020-11 hasta 'hoy'
  * cada ingreso trae solo vinos de SU bodega, y la anada del vino <= fecha
  * stock final = stock inicial + lo que entra - lo que sale (siempre >= 0)
  * renglon: precio del vino a la fecha de la venta, descuento del cliente,
    subtotal redondeado igual que fn_subtotal_renglon
  * comprobante: subtotal bruto, total = suma de renglones, descuento = diferencia
"""
import argparse
import bisect
import csv
import hashlib
import random
from datetime import date, datetime, timedelta
from pathlib import Path

AQUI = Path(__file__).resolve().parent
CAT = AQUI / "catalogos"
HOY = date(2026, 11, 6)          # fijo (no date.today()) para que sea reproducible; se cambia con --hoy

NOMBRES = ["Juan", "María", "Carlos", "Laura", "Diego", "Sofía", "Martín", "Lucía", "Pablo", "Valentina",
           "Nicolás", "Camila", "Federico", "Agustina", "Matías", "Julieta", "Sebastián", "Florencia",
           "Gonzalo", "Carolina", "Ezequiel", "Natalia", "Facundo", "Micaela", "Leandro", "Romina"]
APELLIDOS = ["González", "Rodríguez", "Gómez", "Fernández", "López", "Díaz", "Martínez", "Pérez", "Romero",
             "Sánchez", "García", "Sosa", "Torres", "Álvarez", "Ruiz", "Ramírez", "Flores", "Benítez",
             "Acosta", "Medina", "Herrera", "Suárez", "Aguirre", "Giménez", "Gutiérrez", "Rojas", "Molina",
             "Castro", "Ortiz", "Silva", "Núñez", "Luna", "Juárez", "Cabrera", "Ríos", "Morales"]
CALLES = ["San Martín", "Belgrano", "Rivadavia", "Mitre", "Sarmiento", "Libertador", "Moreno", "Alsina",
          "Las Heras", "Güemes", "Independencia", "Urquiza", "Ituzaingó", "Pellegrini", "9 de Julio"]
DIAS = ["lunes", "martes", "miercoles", "jueves", "viernes", "sabado", "domingo"]
MARCAS = ["Reserva", "Gran Reserva", "Roble", "Terruño", "Altura", "Antigua", "Selección", "Cosecha", "Línea Clásica",
          "Edición Limitada", "Parcela", "Finca", "Origen", "Tradición", "Estirpe", "Horizonte", "Cumbre", "Oasis"]
LUGARES = ["del Atuel", "del Diamante", "de Cuyo", "del Sur", "de la Cordillera", "del Valle", "de Altura", "del Médano",
           "del Cañón", "de los Andes", "del Pedemonte", "de la Ribera"]

PESOS = [("socio", 0.85), ("distribuidor", 0.10), ("exportador", 0.05)]
DESC = {"socio": 10, "distribuidor": 20, "exportador": 30}   # RN-06


def leer(nombre):
    with open(CAT / nombre, newline="", encoding="utf-8") as f:
        return list(csv.DictReader(f))


def cuit_valido(rng, prefijo):
    pesos = [5, 4, 3, 2, 7, 6, 5, 4, 3, 2]
    while True:
        base = prefijo + "".join(str(rng.randint(0, 9)) for _ in range(8))
        d = 11 - sum(int(c) * p for c, p in zip(base, pesos)) % 11
        d = 0 if d == 11 else d
        if d != 10:
            return base + str(d)


def fecha_entre(rng, a, b):
    return a + timedelta(days=rng.randint(0, (b - a).days))


def redondear_centavos(x_centavos, descuento):
    """cantidad*precio*(100-desc)/100 en centavos, redondeo half-up (igual que numeric)."""
    return (x_centavos * (100 - descuento) + 50) // 100


def generar(semilla, chico, hoy=HOY):
    HOY = hoy
    rng = random.Random(semilla)
    rng2 = random.Random(semilla + 1)         # para agregados que no deben cambiar el resto de los datos
    k = 0.01 if chico else 1.0

    def n(x, minimo=1):
        return max(minimo, int(x * k))

    T = {}                                    # tabla -> (columnas, filas)

    def tabla(nombre, cols):
        T[nombre] = (cols, [])
        return T[nombre][1]

    # ---------------- catalogos (desde los CSV) ----------------
    loc = leer("localidades.csv")
    t = tabla("localidad", ["id_localidad", "nombre", "provincia", "cod_postal", "encargado_regional"])
    for i, r in enumerate(loc, 1):
        t.append([i, r["nombre"], r["provincia"], r["cod_postal"], r["encargado_regional"]])
    n_loc = len(loc)

    cepas = leer("cepas.csv")
    t = tabla("cepa", ["id_cepa", "nombre", "tipo"])
    for i, r in enumerate(cepas, 1):
        t.append([i, r["nombre"], r["tipo"]])
    cepa_tipo = {i: r["tipo"] for i, r in enumerate(cepas, 1)}
    n_cepa = len(cepas)

    mar = leer("maridajes.csv")
    t = tabla("maridaje", ["id_maridaje", "nombre", "temperatura_servicio"])
    for i, r in enumerate(mar, 1):
        t.append([i, r["nombre"], r["temperatura_servicio"]])
    n_mar = len(mar)

    bod = leer("bodegas.csv")
    t = tabla("bodega", ["cuit", "razon_social", "domicilio"])
    for r in bod:
        t.append([r["cuit"], r["razon_social"], r["domicilio"]])
    cuits_bodega = [r["cuit"] for r in bod]

    trs = leer("transportistas.csv")
    t = tabla("transportista", ["cod_transporte", "razon_social", "cuit", "email", "telefono", "domicilio"])
    for i, r in enumerate(trs, 1):
        t.append([i, r["razon_social"], r["cuit"], r["email"], r["telefono"], r["domicilio"]])
    n_trs = len(trs)

    t = tabla("transportista_localidad", ["cod_transporte", "id_localidad"])
    for i in range(1, n_trs + 1):
        for l in rng.sample(range(1, n_loc + 1), rng.randint(2, 6)):
            t.append([i, l])

    deptos = [r["nombre"] for r in leer("departamentos.csv")]

    # ---------------- salas, empleados ----------------
    n_sala = n(60, 3)
    t = tabla("sala_venta", ["id_sala", "calle", "numero", "dia_cierre", "id_localidad"])
    for i in range(1, n_sala + 1):
        t.append([i, rng.choice(CALLES), rng.randint(10, 3500), rng.choice(DIAS), rng.randint(1, n_loc)])

    t = tabla("empleado", ["cuit", "nombre", "fecha_ingreso", "salario", "id_sala"])
    usados = set()
    for i in range(n(150, 3)):
        c = cuit_valido(rng, rng.choice(["20", "23", "27"]))
        while c in usados:
            c = cuit_valido(rng, "20")
        usados.add(c)
        t.append([c, f"{rng.choice(NOMBRES)} {rng.choice(APELLIDOS)}", fecha_entre(rng, date(2012, 1, 1), date(2026, 8, 31)),
                  rng.randrange(450000, 1300000, 5000), (i % n_sala) + 1])

    # ---------------- fincas, parcelas, lotes, analisis ----------------
    n_finca = n(80, 2)
    t = tabla("finca", ["id_finca", "nombre", "superficie_ha", "nombre_departamento", "provincia"])
    for i in range(1, n_finca + 1):
        t.append([i, f"Finca {rng.choice(MARCAS)} {i}", round(rng.uniform(8, 220), 2), rng.choice(deptos), "Mendoza"])

    n_parc = n(600, 2)
    t = tabla("parcela", ["id_finca", "nro_parcela", "superficie", "anio_plantacion", "id_cepa"])
    parcelas = []
    contador = {}
    for i in range(n_parc):
        f = (i % n_finca) + 1
        contador[f] = contador.get(f, 0) + 1
        sup = round(rng.uniform(0.8, 12), 2)
        t.append([f, contador[f], sup, rng.randint(1985, 2018), rng.randint(1, n_cepa)])
        parcelas.append((f, contador[f], sup))

    t = tabla("lote", ["nro_lote", "id_finca", "nro_parcela", "campania", "fecha_cosecha", "kilos", "cuit_bodega"])
    lotes = []
    nro = 0
    for (f, p, sup) in parcelas:
        for camp in range(2022, 2027):
            nro += 1
            fc = date(camp, 2, 15) + timedelta(days=rng.randint(0, 74))        # cosecha feb-abr
            t.append([nro, f, p, camp, fc, round(sup * rng.uniform(5000, 12000), 2), rng.choice(cuits_bodega)])
            lotes.append((nro, fc))

    t = tabla("analisis_calidad", ["id_analisis", "nro_lote", "fecha", "grado_brix", "ph", "acidez_total"])
    nid = 0
    for (nl, fc) in lotes:
        for _ in range(rng.randint(2, 5)):
            nid += 1
            t.append([nid, nl, fc - timedelta(days=rng.randint(0, 20)), round(rng.uniform(18, 26), 1),
                      round(rng.uniform(3.1, 3.8), 2), round(rng.uniform(4.5, 8.0), 2)])

    # ---------------- vinos ----------------
    n_vino = n(800, 5)
    vinos = []                                # (cod, cuit_bodega, anada)
    t = tabla("vino", ["cod_vino", "nombre", "tipo", "anada", "volumen_ml", "graduacion", "precio", "cuit_bodega"])
    t_comp = tabla("composicion", ["cod_vino", "id_cepa", "porcentaje"])
    t_vm = tabla("vino_maridaje", ["cod_vino", "id_maridaje"])
    nombres_usados = set()
    precio0 = {}
    for cod in range(1, n_vino + 1):
        k_cepas = rng.choices([1, 2, 3], [50, 35, 15])[0]
        ids = rng.sample(range(1, n_cepa + 1), k_cepas)
        # corte que suma exactamente 100 (RN-05)
        if k_cepas == 1:
            ps = [100]
        elif k_cepas == 2:
            a = rng.randrange(50, 91, 5); ps = [a, 100 - a]
        else:
            a = rng.randrange(40, 71, 5); b = rng.randrange(10, 100 - a - 9, 5); ps = [a, b, 100 - a - b]
        tintas = sum(1 for i in ids if cepa_tipo[i] == "tinta")
        r = rng.random()
        tipo = "espumante" if r < 0.06 else "rosado" if r < 0.12 else ("tinto" if tintas * 2 >= k_cepas else "blanco")
        anada = rng.randint(2015, 2020)
        vol = rng.choices([187, 375, 750, 1500, 3000], [5, 10, 70, 12, 3])[0]
        base = cepas[ids[0] - 1]["nombre"]
        while True:
            nombre = f"{rng.choice(MARCAS)} {base} {rng.choice(LUGARES)}"
            if (nombre, anada, vol) not in nombres_usados:
                nombres_usados.add((nombre, anada, vol)); break
        p0 = rng.randrange(2500, 45000, 50) * 100 // 100          # pesos enteros multiplo de 50
        precio0[cod] = p0 * 100                                   # en centavos
        cuit_b = rng.choice(cuits_bodega)
        t.append([cod, nombre, tipo, anada, vol, round(rng.uniform(11.5, 15.5), 2), None, cuit_b])
        vinos.append((cod, cuit_b, anada))
        for i, p in zip(ids, ps):
            t_comp.append([cod, i, p])
        for m in rng.sample(range(1, n_mar + 1), rng.randint(1, 3)):
            t_vm.append([cod, m])
    vinos_de_bodega = {}
    for cod, cb, an in vinos:
        vinos_de_bodega.setdefault(cb, []).append(cod)
    bodegas_con_vinos = [c for c in cuits_bodega if c in vinos_de_bodega]

    # historial de precios: lista ordenada de (fecha, precio_centavos) por vino
    INICIO_HIST = date(2020, 6, 1)
    hist = {}                                 # cod -> (fechas[], precios[])
    t_aud = tabla("auditoria_precio", ["id_auditoria", "cod_vino", "precio_anterior", "precio_nuevo", "fecha_hora", "usuario"])
    id_aud = 0
    for cod in range(1, n_vino + 1):
        precios = [precio0[cod]]
        fechas = [date(1990, 1, 1)]
        for _ in range(rng.choices([0, 1, 2, 3], [20, 30, 30, 20])[0]):
            f = fecha_entre(rng, INICIO_HIST + timedelta(days=30), HOY - timedelta(days=10))
            if f in fechas:
                continue
            nuevo = int(precios[-1] * rng.uniform(1.03, 1.25)) // 5000 * 5000
            if nuevo == precios[-1] or nuevo <= 0:
                continue
            i = bisect.bisect(fechas, f)
            if i != len(fechas):          # solo cambios en orden cronologico
                continue
            fechas.append(f); precios.append(nuevo)
            id_aud += 1
            t_aud.append([id_aud, cod, f"{precios[-2] / 100:.2f}", f"{nuevo / 100:.2f}",
                          datetime(f.year, f.month, f.day, rng.randint(8, 18), rng.randint(0, 59), rng.randint(0, 59)),
                          "admin"])
        hist[cod] = (fechas, precios)
        T["vino"][1][cod - 1][6] = f"{precios[-1] / 100:.2f}"

    def precio_en(cod, f):
        fechas, precios = hist[cod]
        return precios[bisect.bisect_right(fechas, f) - 1]

    # ---------------- clientes ----------------
    n_cli = n(20000, 10)
    t = tabla("cliente", ["id_cliente", "nombre_razon_social", "tipo_doc", "nro_doc", "direccion", "fecha_alta",
                          "tipo_cliente", "descuento", "id_localidad"])
    t_soc = tabla("socio", ["id_cliente"])
    t_dis = tabla("distribuidor", ["id_cliente", "zona_cobertura", "nro_habilitacion"])
    t_exp = tabla("exportador", ["id_cliente", "pais_destino"])
    t_per = tabla("permiso_exportacion", ["cod_permiso", "id_cliente", "fecha_emision", "fecha_vencimiento"])
    docs = set()
    clientes = []                             # (id, descuento, fecha_alta)
    paises = ["Brasil", "Chile", "Estados Unidos", "Alemania", "China", "Paraguay", "Uruguay", "Canadá", "España", "Reino Unido"]
    id_per = 0
    ultimo_permiso = {}
    for i in range(1, n_cli + 1):
        tipo = rng.choices([p[0] for p in PESOS], [p[1] for p in PESOS])[0]
        if tipo == "socio":
            td = "DNI"; nd = str(rng.randint(10_000_000, 47_999_999))
            nombre = f"{rng.choice(NOMBRES)} {rng.choice(APELLIDOS)}"
        else:
            td = "CUIT"; nd = cuit_valido(rng, rng.choice(["30", "33"]))
            nombre = f"{rng.choice(APELLIDOS)} {rng.choice(['y Asociados', 'Hnos.', 'SRL', 'SA'])}"
        while (td, nd) in docs:
            nd = str(int(nd) + 1) if td == "DNI" else cuit_valido(rng, "30")
        docs.add((td, nd))
        alta = fecha_entre(rng, date(2018, 1, 1), date(2025, 6, 30))
        t.append([i, nombre, td, nd, f"{rng.choice(CALLES)} {rng.randint(1, 4000)}", alta, tipo, DESC[tipo],
                  rng.randint(1, n_loc)])
        clientes.append((i, DESC[tipo], alta))
        if tipo == "socio":
            t_soc.append([i])
        elif tipo == "distribuidor":
            t_dis.append([i, f"Zona {rng.choice(deptos)}", f"HAB-{i:06d}"])
        else:
            t_exp.append([i, rng.choice(paises)])
            em = alta
            for _ in range(rng.randint(1, 3)):
                id_per += 1
                em = em + timedelta(days=rng.randint(30, 300))
                t_per.append([id_per, i, em, em + timedelta(days=rng.choice([365, 730, 1095]))])
            ultimo_permiso[i] = em
    # algunos exportadores con 4 o 5 permisos (para la consigna U6: mas de 3 permisos)
    for i, em in ultimo_permiso.items():
        if rng2.random() < 0.3:
            for _ in range(rng2.randint(2, 3)):
                id_per += 1
                em = em + timedelta(days=rng2.randint(30, 300))
                t_per.append([id_per, i, em, em + timedelta(days=rng2.choice([365, 730, 1095]))])

    # ---------------- salas: surtido de cada sala ----------------
    surtido = {s: rng.sample(range(1, n_vino + 1), min(60, n_vino)) for s in range(1, n_sala + 1)}

    # ---------------- ingresos (entran al deposito) ----------------
    n_ing = n(3000, 3)
    t_i = tabla("ingreso", ["cod_ingreso", "fecha", "estado", "cod_transporte", "cuit_bodega"])
    t_ri = tabla("renglon_ingreso", ["cod_ingreso", "cod_vino", "cantidad"])
    entra_dep = {}
    for i in range(1, n_ing + 1):
        estado = rng.choices(["procesado", "terminado", "en_confeccion"], [92, 5, 3])[0]
        f = fecha_entre(rng, date(2020, 6, 1), HOY - timedelta(days=7)) if estado == "procesado" \
            else fecha_entre(rng, HOY - timedelta(days=65), HOY)
        cb = rng.choice(bodegas_con_vinos)
        t_i.append([i, f, estado, rng.randint(1, n_trs), cb])
        disp = vinos_de_bodega[cb]
        for v in rng.sample(disp, min(len(disp), rng.randint(1, 5))):
            q = rng.randint(50, 500)
            t_ri.append([i, v, q])
            if estado == "procesado":
                entra_dep[v] = entra_dep.get(v, 0) + q

    # ---------------- transferencias (deposito -> sala) ----------------
    n_tr = n(3000, 3)
    t_t = tabla("transferencia", ["nro_solicitud", "fecha_confeccion", "estado", "id_sala"])
    t_rt = tabla("renglon_transferencia", ["nro_solicitud", "cod_vino", "cantidad"])
    sale_dep = {}
    entra_sala = {}
    for i in range(1, n_tr + 1):
        estado = rng.choices(["procesado", "terminado", "en_confeccion"], [92, 5, 3])[0]
        f = fecha_entre(rng, date(2020, 7, 1), HOY - timedelta(days=7)) if estado == "procesado" \
            else fecha_entre(rng, HOY - timedelta(days=65), HOY)
        s = rng.randint(1, n_sala)
        t_t.append([i, f, estado, s])
        for v in rng.sample(surtido[s], min(len(surtido[s]), rng.randint(1, 5))):
            q = rng.randint(10, 60)
            t_rt.append([i, v, q])
            if estado == "procesado":
                sale_dep[v] = sale_dep.get(v, 0) + q
                entra_sala[(s, v)] = entra_sala.get((s, v), 0) + q

    # ---------------- ventas ----------------
    t_c = tabla("comprobante", ["nro_comprobante", "fecha", "id_cliente", "id_sala", "subtotal", "descuento", "total"])
    t_rc = tabla("renglon_comprobante", ["nro_comprobante", "cod_vino", "cantidad", "precio_unitario", "descuento", "subtotal"])
    vendido = {}
    n_comp = n(150000, 10)
    ini_v = date(2020, 11, 1)
    fin_v = HOY - timedelta(days=1)
    inactivos = set(rng.sample(range(n_cli), max(1, int(n_cli * 0.02))))      # clientes que nunca compran
    compradores = [c for i, c in enumerate(clientes) if i not in inactivos]
    for nc in range(1, n_comp + 1):
        cid, desc, alta = compradores[rng.randrange(len(compradores))]
        f = max(fecha_entre(rng, ini_v, fin_v), alta)
        s = rng.randint(1, n_sala)
        bruto = neto = 0
        for v in rng.sample(surtido[s], min(len(surtido[s]), rng.choices(range(1, 9), [10, 18, 22, 18, 14, 9, 6, 3])[0])):
            q = rng.choices([1, 2, 3, 4, 6, 12], [40, 25, 15, 10, 7, 3])[0]
            p = precio_en(v, f)
            sub = redondear_centavos(q * p, desc)
            t_rc.append([nc, v, q, f"{p / 100:.2f}", desc, f"{sub / 100:.2f}"])
            bruto += q * p
            neto += sub
            vendido[(s, v)] = vendido.get((s, v), 0) + q
        t_c.append([nc, f, cid, s, f"{bruto / 100:.2f}", f"{(bruto - neto) / 100:.2f}", f"{neto / 100:.2f}"])

    # ---------------- vinos "estrella": se vendieron en todas las salas (consigna S2) ----------------
    estrella = rng2.sample(range(1, n_vino + 1), min(12, n_vino))
    extra_par = []                            # pares (sala, vino) que no estaban en el surtido
    nc = n_comp
    for sala in range(1, n_sala + 1):
        for v in estrella:
            nc += 1
            cid, desc, alta = compradores[rng2.randrange(len(compradores))]
            f = max(fecha_entre(rng2, ini_v, fin_v), alta)
            q = rng2.randint(1, 3)
            p = precio_en(v, f)
            sub = redondear_centavos(q * p, desc)
            t_rc.append([nc, v, q, f"{p / 100:.2f}", desc, f"{sub / 100:.2f}"])
            t_c.append([nc, f, cid, sala, f"{q * p / 100:.2f}", f"{(q * p - sub) / 100:.2f}", f"{sub / 100:.2f}"])
            vendido[(sala, v)] = vendido.get((sala, v), 0) + q
            if v not in surtido[sala]:
                extra_par.append((sala, v))

    # ---------------- stocks finales (siempre >= 0) ----------------
    t_sd = tabla("stock_deposito", ["cod_vino", "cantidad"])
    for v in range(1, n_vino + 1):
        inicial = max(0, sale_dep.get(v, 0) - entra_dep.get(v, 0)) + rng.randint(0, 200)
        t_sd.append([v, inicial + entra_dep.get(v, 0) - sale_dep.get(v, 0)])
    t_ss = tabla("stock_sala", ["id_sala", "cod_vino", "cantidad"])
    for s in range(1, n_sala + 1):
        for v in surtido[s]:
            ent = entra_sala.get((s, v), 0)
            ven = vendido.get((s, v), 0)
            inicial = max(0, ven - ent) + rng.randint(0, 30)
            t_ss.append([s, v, inicial + ent - ven])
    for (sala, v) in extra_par:               # pares agregados por los vinos estrella
        ven = vendido[(sala, v)]
        t_ss.append([sala, v, rng2.randint(0, 30)])      # stock inicial = ventas + sobrante; final = sobrante
    return T


# orden de carga segun las claves foraneas
ORDEN = ["localidad", "cepa", "maridaje", "bodega", "transportista",
         "sala_venta", "finca", "transportista_localidad",
         "empleado", "parcela", "vino", "cliente",
         "lote", "composicion", "vino_maridaje", "socio", "distribuidor", "exportador",
         "analisis_calidad", "permiso_exportacion", "ingreso", "transferencia", "comprobante",
         "renglon_ingreso", "renglon_transferencia", "renglon_comprobante",
         "stock_deposito", "stock_sala", "auditoria_precio"]
# tablas con columna identity (hay que reajustar la secuencia despues de cargar)
IDENTIDAD = {"localidad": "id_localidad", "cepa": "id_cepa", "maridaje": "id_maridaje", "transportista": "cod_transporte",
             "sala_venta": "id_sala", "finca": "id_finca", "vino": "cod_vino", "cliente": "id_cliente",
             "lote": "nro_lote", "analisis_calidad": "id_analisis", "permiso_exportacion": "cod_permiso",
             "ingreso": "cod_ingreso", "transferencia": "nro_solicitud", "comprobante": "nro_comprobante",
             "auditoria_precio": "id_auditoria"}


def escribir(T, salida):
    salida.mkdir(parents=True, exist_ok=True)
    resumen = {}
    for nombre in ORDEN:
        cols, filas = T[nombre]
        ruta = salida / f"{nombre}.csv"
        with open(ruta, "w", newline="", encoding="utf-8") as f:
            w = csv.writer(f, lineterminator="\n")
            w.writerow(cols)
            w.writerows(filas)
        resumen[nombre] = len(filas)
    return resumen


def huella(salida):
    h = hashlib.sha256()
    for nombre in ORDEN:
        h.update((salida / f"{nombre}.csv").read_bytes())
    return h.hexdigest()


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--semilla", type=int, default=2026)
    ap.add_argument("--hoy", default=None, help="fecha de referencia AAAA-MM-DD (por defecto 2026-11-06)")
    ap.add_argument("--chico", action="store_true", help="1 %% del volumen, para probar")
    ap.add_argument("--salida", default=str(AQUI / "salida"))
    a = ap.parse_args()
    T = generar(a.semilla, a.chico, date.fromisoformat(a.hoy) if a.hoy else HOY)
    sal = Path(a.salida)
    res = escribir(T, sal)
    for k in ORDEN:
        print(f"{k:26s}{res[k]:>9d}")
    print(f"{'TOTAL':26s}{sum(res.values()):>9d}")
    print("huella sha256:", huella(sal))
