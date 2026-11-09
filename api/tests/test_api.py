import itertools
import time

_n = itertools.count(1)
_corrida = int(time.time() * 1000) % 10000000


def unico(prefijo):
    return f"{prefijo} {_corrida}-{next(_n)}"


def cuerpo_vino(sql, **cambios):
    bodega = sql("SELECT cuit FROM bodega ORDER BY cuit LIMIT 1")[0]["cuit"]
    cepas = sql("SELECT id_cepa FROM cepa ORDER BY id_cepa LIMIT 2")
    datos = {"nombre": unico("Vino de prueba"), "tipo": "tinto", "anada": 2021, "volumen_ml": 750, "graduacion": 14,
             "precio": 12000, "cuit_bodega": bodega,
             "composicion": [{"id_cepa": cepas[0]["id_cepa"], "porcentaje": 70},
                             {"id_cepa": cepas[1]["id_cepa"], "porcentaje": 30}]}
    datos.update(cambios)
    return datos


def contar(sql, tabla):
    return sql(f"SELECT count(*) AS n FROM {tabla}")[0]["n"]


# ------------------------------------------------------------ lectura
def test_salud_usa_el_rol_de_la_api(client):
    r = client.get("/salud")
    assert r.status_code == 200 and r.json["estado"] == "ok" and r.json["usuario"] == "app_rw"


def test_catalogo_paginado_y_filtros(client, sql):
    r = client.get("/vinos?por_pagina=5")
    assert r.status_code == 200 and len(r.json["datos"]) == 5 and r.json["total"] >= 5
    tipo = r.json["datos"][0]["tipo"]
    r2 = client.get(f"/vinos?tipo={tipo}&por_pagina=100")
    assert r2.json["total"] > 0 and all(v["tipo"] == tipo for v in r2.json["datos"])
    cepa = sql("SELECT id_cepa FROM composicion LIMIT 1")[0]["id_cepa"]
    assert client.get(f"/vinos?cepa={cepa}").json["total"] > 0


def test_detalle_vino_y_404(client):
    cod = client.get("/vinos?por_pagina=1").json["datos"][0]["cod_vino"]
    r = client.get(f"/vinos/{cod}")
    assert r.status_code == 200
    assert abs(sum(float(c["porcentaje"]) for c in r.json["composicion"]) - 100) < 0.01
    assert client.get("/vinos/99999999").status_code == 404
    assert client.get("/ruta/que/no/existe").status_code == 404


def test_catalogos(client):
    for c in ("cepas", "bodegas", "salas", "localidades", "maridajes", "transportistas"):
        r = client.get("/" + c)
        assert r.status_code == 200 and len(r.json) > 0, c


# ------------------------------------------------------------ CRUD
def test_crud_de_vino(client, sql):
    r = client.post("/vinos", json=cuerpo_vino(sql))
    assert r.status_code == 201 and r.headers["Location"].startswith("/vinos/")
    cod = r.json["cod_vino"]
    cuerpo = cuerpo_vino(sql, precio=15000, nombre=r.json["nombre"])
    r = client.put(f"/vinos/{cod}", json=cuerpo)
    assert r.status_code == 200 and float(r.json["precio"]) == 15000
    # el cambio de precio quedo auditado por el trigger, no por la API
    assert sql("SELECT count(*) AS n FROM auditoria_precio WHERE cod_vino=%s", (cod,))[0]["n"] >= 1
    # con historial de precios (auditoria) la base no deja borrarlo
    assert client.delete(f"/vinos/{cod}").status_code == 409
    # uno recien creado, sin movimientos, si se puede borrar
    nuevo = client.post("/vinos", json=cuerpo_vino(sql)).json["cod_vino"]
    assert client.delete(f"/vinos/{nuevo}").status_code == 204
    assert client.get(f"/vinos/{nuevo}").status_code == 404
    assert client.delete(f"/vinos/{nuevo}").status_code == 404


def test_crud_de_cliente_el_descuento_lo_pone_la_base(client, sql):
    loc = sql("SELECT id_localidad FROM localidad LIMIT 1")[0]["id_localidad"]
    doc = str(80000000 + _corrida + next(_n))
    r = client.post("/clientes", json={"nombre_razon_social": unico("Cliente prueba"), "tipo_doc": "DNI", "nro_doc": doc,
                                        "direccion": "Calle 1", "tipo_cliente": "socio", "id_localidad": loc})
    assert r.status_code == 201, r.json
    assert float(r.json["descuento"]) == 10                  # socio: 10 %, lo completa el trigger
    idc = r.json["id_cliente"]
    assert client.get(f"/clientes/{idc}").status_code == 200
    # mismo documento -> UNIQUE -> 409
    r2 = client.post("/clientes", json={"nombre_razon_social": "otro", "tipo_doc": "DNI", "nro_doc": doc,
                                         "direccion": "x", "tipo_cliente": "socio", "id_localidad": loc})
    assert r2.status_code == 409
    assert client.delete(f"/clientes/{idc}").status_code == 204


# ------------------------------------------------------------ reglas de negocio (la base las impone)
def test_regla_porcentajes_distintos_de_100_da_409_y_no_deja_nada(client, sql):
    antes = contar(sql, "vino")
    cuerpo = cuerpo_vino(sql)
    cuerpo["composicion"][1]["porcentaje"] = 20               # 70 + 20 = 90
    r = client.post("/vinos", json=cuerpo)
    assert r.status_code == 409 and r.json["error"]["regla"] is True
    assert contar(sql, "vino") == antes                       # rollback: el vino tampoco quedo


def test_precio_negativo_da_422(client, sql):
    r = client.post("/vinos", json=cuerpo_vino(sql, precio=-5))
    assert r.status_code == 422 and r.json["error"]["sqlstate"] == "23514"


def test_venta_sin_stock_da_409_sin_datos_a_medias(client, sql):
    fila = sql("SELECT id_sala, cod_vino, cantidad FROM stock_sala ORDER BY cantidad DESC LIMIT 1")[0]
    cliente = sql("SELECT id_cliente FROM cliente LIMIT 1")[0]["id_cliente"]
    otro = sql("SELECT cod_vino FROM stock_sala WHERE id_sala=%s AND cod_vino<>%s AND cantidad>0 LIMIT 1",
               (fila["id_sala"], fila["cod_vino"]))
    antes_c, antes_r = contar(sql, "comprobante"), contar(sql, "renglon_comprobante")
    renglones = [{"cod_vino": fila["cod_vino"], "cantidad": 1}, {"cod_vino": fila["cod_vino"], "cantidad": fila["cantidad"] + 1000}]
    r = client.post("/comprobantes", json={"id_cliente": cliente, "id_sala": fila["id_sala"], "renglones": renglones})
    assert r.status_code == 409, r.json
    assert (contar(sql, "comprobante"), contar(sql, "renglon_comprobante")) == (antes_c, antes_r)
    stock = sql("SELECT cantidad FROM stock_sala WHERE id_sala=%s AND cod_vino=%s", (fila["id_sala"], fila["cod_vino"]))[0]["cantidad"]
    assert stock == fila["cantidad"]                          # el primer renglon tampoco descontó


def test_venta_correcta_calcula_importes_y_descuenta_stock(client, sql):
    fila = sql("SELECT id_sala, cod_vino, cantidad FROM stock_sala WHERE cantidad >= 5 LIMIT 1")[0]
    cliente = sql("SELECT id_cliente FROM cliente LIMIT 1")[0]["id_cliente"]
    r = client.post("/comprobantes", json={"id_cliente": cliente, "id_sala": fila["id_sala"],
                                            "renglones": [{"cod_vino": fila["cod_vino"], "cantidad": 2}]})
    assert r.status_code == 201, r.json
    c = r.json
    assert abs(float(c["subtotal"]) - float(c["descuento"]) - float(c["total"])) < 0.005
    assert len(c["renglones"]) == 1 and c["renglones"][0]["cantidad"] == 2
    nuevo = sql("SELECT cantidad FROM stock_sala WHERE id_sala=%s AND cod_vino=%s", (fila["id_sala"], fila["cod_vino"]))[0]["cantidad"]
    assert nuevo == fila["cantidad"] - 2
    assert client.get(f"/comprobantes/{c['nro_comprobante']}").status_code == 200


def test_borrar_vino_con_movimientos_da_409(client, sql):
    cod = sql("SELECT cod_vino FROM renglon_comprobante LIMIT 1")[0]["cod_vino"]
    r = client.delete(f"/vinos/{cod}")
    assert r.status_code == 409
    assert client.get(f"/vinos/{cod}").status_code == 200


def test_circuito_transferencia_y_transicion_invalida(client, sql):
    fila = sql("SELECT d.cod_vino, d.cantidad FROM stock_deposito d WHERE d.cantidad >= 20 LIMIT 1")[0]
    sala = sql("SELECT id_sala FROM sala_venta LIMIT 1")[0]["id_sala"]
    r = client.post("/transferencias", json={"id_sala": sala})
    assert r.status_code == 201 and r.json["estado"] == "en_confeccion"
    nro = r.json["nro_solicitud"]
    # no se puede procesar sin haber terminado
    assert client.post(f"/transferencias/{nro}/procesar").status_code == 409
    assert client.post(f"/transferencias/{nro}/renglones", json={"cod_vino": fila["cod_vino"], "cantidad": 10}).status_code == 201
    assert client.post(f"/transferencias/{nro}/terminar").json["estado"] == "terminado"
    # terminada: ya no admite renglones (RN-12)
    assert client.post(f"/transferencias/{nro}/renglones", json={"cod_vino": fila["cod_vino"], "cantidad": 1}).status_code == 409
    antes_dep = fila["cantidad"]
    r = client.post(f"/transferencias/{nro}/procesar")
    assert r.status_code == 200 and r.json["estado"] == "procesado"
    dep = sql("SELECT cantidad FROM stock_deposito WHERE cod_vino=%s", (fila["cod_vino"],))[0]["cantidad"]
    assert dep == antes_dep - 10
    assert client.post(f"/transferencias/{nro}/procesar").status_code == 409     # no se procesa dos veces


def test_circuito_ingreso_suma_al_deposito(client, sql):
    v = sql("SELECT cod_vino, cuit_bodega FROM vino ORDER BY cod_vino LIMIT 1")[0]
    tr = sql("SELECT cod_transporte FROM transportista LIMIT 1")
    tr = tr[0]["cod_transporte"] if tr else None
    if tr is None:
        return
    antes = sql("SELECT coalesce(sum(cantidad),0) AS n FROM stock_deposito WHERE cod_vino=%s", (v["cod_vino"],))[0]["n"]
    r = client.post("/ingresos", json={"cod_transporte": tr, "cuit_bodega": v["cuit_bodega"]})
    assert r.status_code == 201, r.json
    nro = r.json["cod_ingreso"]
    assert client.post(f"/ingresos/{nro}/renglones", json={"cod_vino": v["cod_vino"], "cantidad": 24}).status_code == 201
    assert client.post(f"/ingresos/{nro}/terminar").status_code == 200
    assert client.post(f"/ingresos/{nro}/procesar").json["estado"] == "procesado"
    despues = sql("SELECT coalesce(sum(cantidad),0) AS n FROM stock_deposito WHERE cod_vino=%s", (v["cod_vino"],))[0]["n"]
    assert despues == antes + 24


# ------------------------------------------------------------ validación y seguridad
def test_filtros_invalidos_dan_400(client):
    assert client.get("/vinos?anada=abc").status_code == 400
    assert client.get("/vinos?pagina=0").status_code == 400
    assert client.get("/vinos?cepa=xx").status_code == 400
    assert client.post("/vinos", data="no es json", content_type="application/json").status_code == 400
    assert client.post("/comprobantes", json={"id_cliente": 1}).status_code == 400


def test_inyeccion_sql_no_funciona(client, sql):
    antes = contar(sql, "vino")
    for ataque in ("'; DROP TABLE vino; --", "' OR '1'='1", "x' UNION SELECT 1,2,3 --"):
        r = client.get("/vinos", query_string={"q": ataque})
        assert r.status_code == 200 and r.json["total"] == 0, ataque       # se busca como texto literal
    assert client.get("/vinos", query_string={"anada": "2020; DROP TABLE vino"}).status_code == 400
    assert client.get("/vinos", query_string={"tipo": "' OR 1=1 --"}).json["total"] == 0
    assert contar(sql, "vino") == antes                                  # la tabla sigue ahi


def test_reportes(client, sql):
    assert client.get("/reportes/top-vinos?limite=3").status_code == 200
    assert client.get("/reportes/ventas-por-sala").status_code == 200
    sala = sql("SELECT id_sala FROM sala_venta LIMIT 1")[0]["id_sala"]
    assert client.get(f"/reportes/vinos-sin-stock?id_sala={sala}").status_code == 200
    assert client.get("/reportes/vinos-sin-stock").status_code == 400
    cod = sql("SELECT cod_vino FROM vino LIMIT 1")[0]["cod_vino"]
    assert client.get(f"/reportes/trazabilidad/{cod}").status_code == 200


def test_openapi_coincide_con_las_rutas(client):
    from app import app
    spec = client.get("/openapi.json").json
    rutas = {r.rule.replace("<int:", "{").replace(">", "}") for r in app.url_map.iter_rules()
             if r.endpoint not in ("static", "openapi_json", "swagger")}
    assert rutas <= set(spec["paths"]), rutas - set(spec["paths"])
    assert client.get("/docs").status_code == 200
