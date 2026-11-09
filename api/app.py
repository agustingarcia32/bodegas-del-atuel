"""
app.py - API REST de Bodegas del Atuel (Flask + psycopg 3).
Reglas de diseno:
  * La API NO recalcula totales, descuentos ni stock: lo hacen los triggers y procedimientos de la base.
  * Los errores de la base se traducen por SQLSTATE (errores.py); el mensaje de las reglas (P0001) viaja tal cual.
  * Todo el SQL esta en dal.py y es parametrizado.
Arranque:  flask --app app run     (o gunicorn app:app)
"""
import datetime
import os
from decimal import Decimal

from flask import Flask, jsonify, request
from flask.json.provider import DefaultJSONProvider

import dal
import errores
from db import pool
from errores import ApiError


class Proveedor(DefaultJSONProvider):
    def default(self, o):
        if isinstance(o, Decimal):
            return float(o)
        if isinstance(o, (datetime.date, datetime.datetime)):
            return o.isoformat()
        return super().default(o)


app = Flask(__name__)
app.json = Proveedor(app)
app.json.ensure_ascii = False
app.json.sort_keys = False
errores.registrar(app)

DOCS = {}          # endpoint -> metadata para openapi.json


def doc(resumen, query=None, body=None, codigos=None):
    """Decorador: guarda el resumen, los parametros de query y un ejemplo de cuerpo para OpenAPI."""
    def deco(f):
        DOCS[f.__name__] = {"resumen": resumen, "query": query or [], "body": body, "codigos": codigos or {}}
        return f
    return deco


# ----------------------------------------------------------------------------- utilidades
@app.after_request
def cors(resp):
    resp.headers["Access-Control-Allow-Origin"] = os.environ.get("CORS_ORIGIN", "*")
    resp.headers["Access-Control-Allow-Headers"] = "Content-Type"
    resp.headers["Access-Control-Allow-Methods"] = "GET, POST, PUT, DELETE, OPTIONS"
    return resp


@app.before_request
def preflight():
    if request.method == "OPTIONS":      # respuesta al preflight de CORS, sin tocar el resto de las rutas
        return "", 204


def cuerpo():
    datos = request.get_json(silent=True)
    if not isinstance(datos, dict):
        raise ApiError(400, "El cuerpo debe ser un objeto JSON")
    return datos


def requeridos(datos, *campos):
    faltan = [c for c in campos if c not in datos]
    if faltan:
        raise ApiError(400, "Faltan campos: " + ", ".join(faltan))
    return [datos[c] for c in campos]


def parametro(nombre):
    """Parametro de query tal cual llega (texto o None). Los tipos los valida PostgreSQL (22P02 -> 400)."""
    valor = request.args.get(nombre)
    return valor if valor not in (None, "") else None


def paginacion():
    try:
        pagina = int(request.args.get("pagina", 1))
        por_pagina = int(request.args.get("por_pagina", 20))
    except ValueError:
        raise ApiError(400, "pagina y por_pagina deben ser enteros")
    if pagina < 1 or not 1 <= por_pagina <= 100:
        raise ApiError(400, "pagina >= 1 y por_pagina entre 1 y 100")
    return pagina, por_pagina, (pagina - 1) * por_pagina


def listado(datos, total, pagina, por_pagina):
    return jsonify({"datos": datos, "total": total, "pagina": pagina, "por_pagina": por_pagina})


def no_encontrado(fila, que):
    if fila is None:
        raise ApiError(404, f"{que} inexistente")
    return fila


# ----------------------------------------------------------------------------- salud y catalogos
@app.get("/salud")
@doc("Verifica que la API llega a la base")
def salud():
    with pool.transaccion() as cur:
        fila = dal.salud(cur)
    return jsonify({"estado": "ok", "base": fila["base"], "usuario": fila["usuario"]})


def _catalogo(nombre, funcion, resumen):
    def vista():
        with pool.transaccion() as cur:
            return jsonify(funcion(cur))
    vista.__name__ = nombre
    app.add_url_rule("/" + nombre, nombre, vista, methods=["GET"])
    DOCS[nombre] = {"resumen": resumen, "query": [], "body": None, "codigos": {}}


_catalogo("cepas", dal.listar_cepas, "Catalogo de cepas")
_catalogo("bodegas", dal.listar_bodegas, "Catalogo de bodegas")
_catalogo("salas", dal.listar_salas, "Salas de venta")
_catalogo("localidades", dal.listar_localidades, "Localidades")
_catalogo("maridajes", dal.listar_maridajes, "Maridajes")
_catalogo("transportistas", dal.listar_transportistas, "Transportistas")


# ----------------------------------------------------------------------------- vinos
CAMPOS_VINO = ("nombre", "tipo", "anada", "volumen_ml", "graduacion", "precio", "cuit_bodega")
EJEMPLO_VINO = {"nombre": "Malbec Reserva", "tipo": "tinto", "anada": 2021, "volumen_ml": 750, "graduacion": 14,
                "precio": 12000, "cuit_bodega": "30161033967",
                "composicion": [{"id_cepa": 1, "porcentaje": 85}, {"id_cepa": 2, "porcentaje": 15}],
                "maridajes": [1, 2]}


def _detalle_vino(cur, cod):
    ficha = no_encontrado(dal.obtener_ficha_vino(cur, cod), "Vino")
    ficha["composicion"] = dal.obtener_composicion(cur, cod)
    ficha["maridajes_detalle"] = dal.obtener_maridajes(cur, cod)
    ficha["historial_precio"] = dal.listar_auditoria_precio(cur, cod)
    return ficha


def _cargar_composicion(cur, cod, datos):
    comp = datos.get("composicion")
    if not isinstance(comp, list) or not comp:
        raise ApiError(400, "composicion debe ser una lista con al menos una cepa")
    for item in comp:
        if not isinstance(item, dict) or "id_cepa" not in item or "porcentaje" not in item:
            raise ApiError(400, "cada item de composicion necesita id_cepa y porcentaje")
        dal.insertar_composicion(cur, cod, item["id_cepa"], item["porcentaje"])
    for id_maridaje in datos.get("maridajes", []):
        dal.insertar_vino_maridaje(cur, cod, id_maridaje)


@app.get("/vinos")
@doc("Catalogo de vinos con filtros y paginacion",
     query=["tipo", "cepa (id_cepa)", "bodega (cuit)", "anada", "q (texto en el nombre)", "pagina", "por_pagina"])
def listar_vinos():
    pagina, por_pagina, desde = paginacion()
    filtros = dict(tipo=parametro("tipo"), id_cepa=parametro("cepa"), cuit_bodega=parametro("bodega"),
                   anada=parametro("anada"), texto=parametro("q"))
    with pool.transaccion() as cur:
        total = dal.contar_vinos(cur, **filtros)
        datos = dal.listar_vinos(cur, por_pagina, desde, **filtros)
    return listado(datos, total, pagina, por_pagina)


@app.get("/vinos/<int:cod>")
@doc("Detalle del vino: cepas con porcentajes, bodega, maridajes, stock e historial de precio",
     codigos={404: "No existe"})
def detalle_vino(cod):
    with pool.transaccion() as cur:
        return jsonify(_detalle_vino(cur, cod))


@app.post("/vinos")
@doc("Alta de vino con su composicion (los porcentajes deben sumar 100: lo controla la base al confirmar)",
     body=EJEMPLO_VINO, codigos={409: "Porcentajes que no suman 100 (RN-05)", 422: "Precio o graduacion invalidos"})
def crear_vino():
    datos = cuerpo()
    valores = requeridos(datos, *CAMPOS_VINO)
    with pool.transaccion() as cur:
        cod = dal.insertar_vino(cur, *valores)
        _cargar_composicion(cur, cod, datos)
    with pool.transaccion() as cur:
        ficha = _detalle_vino(cur, cod)
    resp = jsonify(ficha)
    resp.status_code = 201
    resp.headers["Location"] = f"/vinos/{cod}"
    return resp


@app.put("/vinos/<int:cod>")
@doc("Modificacion de vino (si cambia el precio, la base lo audita); si trae composicion, la reemplaza",
     body=EJEMPLO_VINO, codigos={404: "No existe"})
def modificar_vino(cod):
    datos = cuerpo()
    valores = requeridos(datos, *CAMPOS_VINO)
    with pool.transaccion() as cur:
        no_encontrado(dal.actualizar_vino(cur, cod, *valores) or None, "Vino")
        if "composicion" in datos:
            dal.borrar_composicion(cur, cod)
            dal.borrar_vino_maridajes(cur, cod)
            _cargar_composicion(cur, cod, datos)
    with pool.transaccion() as cur:
        return jsonify(_detalle_vino(cur, cod))


@app.delete("/vinos/<int:cod>")
@doc("Baja de vino (la base lo rechaza si tiene movimientos: RN-14)", codigos={404: "No existe", 409: "Tiene movimientos"})
def borrar_vino(cod):
    with pool.transaccion() as cur:
        no_encontrado(dal.borrar_vino(cur, cod) or None, "Vino")
    return "", 204


# ----------------------------------------------------------------------------- clientes
EJEMPLO_CLIENTE = {"nombre_razon_social": "Ana Perez", "tipo_doc": "DNI", "nro_doc": "30111222", "direccion": "Belgrano 100",
                   "tipo_cliente": "socio", "id_localidad": 16,
                   "zona_cobertura": "(solo distribuidor)", "nro_habilitacion": "(solo distribuidor)",
                   "pais_destino": "(solo exportador)"}


def _detalle_cliente(cur, id_cliente):
    c = no_encontrado(dal.obtener_cliente(cur, id_cliente), "Cliente")
    if c["tipo_cliente"] == "exportador":
        c["permisos"] = dal.listar_permisos(cur, id_cliente)
    return c


@app.get("/clientes")
@doc("Listado de clientes paginado", query=["tipo", "q (prefijo del nombre)", "pagina", "por_pagina"])
def listar_clientes():
    pagina, por_pagina, desde = paginacion()
    with pool.transaccion() as cur:
        total = dal.contar_clientes(cur, parametro("tipo"), parametro("q"))
        datos = dal.listar_clientes(cur, por_pagina, desde, parametro("tipo"), parametro("q"))
    return listado(datos, total, pagina, por_pagina)


@app.get("/clientes/<int:id_cliente>")
@doc("Detalle del cliente con los datos de su subtipo (y permisos si es exportador)", codigos={404: "No existe"})
def detalle_cliente(id_cliente):
    with pool.transaccion() as cur:
        return jsonify(_detalle_cliente(cur, id_cliente))


@app.post("/clientes")
@doc("Alta de cliente (socio, distribuidor o exportador); el descuento lo completa la base segun el tipo",
     body=EJEMPLO_CLIENTE, codigos={409: "Documento repetido"})
def crear_cliente():
    d = cuerpo()
    nombre, tipo_doc, nro_doc, direccion, tipo, id_loc = requeridos(
        d, "nombre_razon_social", "tipo_doc", "nro_doc", "direccion", "tipo_cliente", "id_localidad")
    with pool.transaccion() as cur:
        idc = dal.insertar_cliente(cur, nombre, tipo_doc, nro_doc, direccion, tipo, id_loc, d.get("descuento"))
        if tipo == "socio":
            dal.insertar_socio(cur, idc)
        elif tipo == "distribuidor":
            zona, hab = requeridos(d, "zona_cobertura", "nro_habilitacion")
            dal.insertar_distribuidor(cur, idc, zona, hab)
        elif tipo == "exportador":
            dal.insertar_exportador(cur, idc, requeridos(d, "pais_destino")[0])
    with pool.transaccion() as cur:
        c = _detalle_cliente(cur, idc)
    resp = jsonify(c)
    resp.status_code = 201
    resp.headers["Location"] = f"/clientes/{idc}"
    return resp


@app.put("/clientes/<int:id_cliente>")
@doc("Modificacion de cliente (el tipo no se cambia)", body=EJEMPLO_CLIENTE, codigos={404: "No existe"})
def modificar_cliente(id_cliente):
    d = cuerpo()
    nombre, direccion, id_loc = requeridos(d, "nombre_razon_social", "direccion", "id_localidad")
    with pool.transaccion() as cur:
        actual = no_encontrado(dal.obtener_cliente(cur, id_cliente), "Cliente")
        dal.actualizar_cliente(cur, id_cliente, nombre, direccion, id_loc, d.get("descuento", actual["descuento"]))
        if actual["tipo_cliente"] == "distribuidor":
            zona, hab = requeridos(d, "zona_cobertura", "nro_habilitacion")
            dal.actualizar_distribuidor(cur, id_cliente, zona, hab)
        elif actual["tipo_cliente"] == "exportador":
            dal.actualizar_exportador(cur, id_cliente, requeridos(d, "pais_destino")[0])
    with pool.transaccion() as cur:
        return jsonify(_detalle_cliente(cur, id_cliente))


@app.delete("/clientes/<int:id_cliente>")
@doc("Baja de cliente (se rechaza si tiene comprobantes)", codigos={404: "No existe", 409: "Tiene comprobantes"})
def borrar_cliente(id_cliente):
    with pool.transaccion() as cur:
        no_encontrado(dal.borrar_cliente(cur, id_cliente) or None, "Cliente")
    return "", 204


# ----------------------------------------------------------------------------- comprobantes
@app.post("/comprobantes")
@doc("Venta completa (cabecera y renglones) en una sola transaccion; importes y stock los resuelve la base",
     body={"id_cliente": 1, "id_sala": 1, "renglones": [{"cod_vino": 3, "cantidad": 2}, {"cod_vino": 5, "cantidad": 1}]},
     codigos={409: "Stock insuficiente (RN-09): no queda nada guardado"})
def crear_comprobante():
    d = cuerpo()
    id_cliente, id_sala, renglones = requeridos(d, "id_cliente", "id_sala", "renglones")
    if not isinstance(renglones, list) or not renglones:
        raise ApiError(400, "renglones debe ser una lista con al menos un renglon")
    with pool.transaccion() as cur:
        nro = dal.insertar_comprobante(cur, id_cliente, id_sala)
        for r in renglones:
            cod_vino, cantidad = requeridos(r if isinstance(r, dict) else {}, "cod_vino", "cantidad")
            dal.insertar_renglon_comprobante(cur, nro, cod_vino, cantidad)
    with pool.transaccion() as cur:
        c = dal.obtener_comprobante(cur, nro)
        c["renglones"] = dal.listar_renglones_comprobante(cur, nro)
    resp = jsonify(c)
    resp.status_code = 201
    resp.headers["Location"] = f"/comprobantes/{nro}"
    return resp


@app.get("/comprobantes/<int:nro>")
@doc("Comprobante con sus renglones y los importes calculados por la base", codigos={404: "No existe"})
def detalle_comprobante(nro):
    with pool.transaccion() as cur:
        c = no_encontrado(dal.obtener_comprobante(cur, nro), "Comprobante")
        c["renglones"] = dal.listar_renglones_comprobante(cur, nro)
    return jsonify(c)


# ----------------------------------------------------------------------------- transferencias e ingresos (mismo circuito)
def _renglones_de(d):
    """Acepta un renglon {cod_vino, cantidad} o una lista de renglones."""
    lista = d if isinstance(d, list) else [d]
    out = []
    for r in lista:
        if not isinstance(r, dict):
            raise ApiError(400, "cada renglon debe ser un objeto con cod_vino y cantidad")
        out.append(requeridos(r, "cod_vino", "cantidad"))
    if not out:
        raise ApiError(400, "no hay renglones")
    return out


def _documento(nombre, plural, insertar, cargar, terminar, procesar, obtener, renglones, clave, campos_alta, ej_alta):
    """Registra las rutas de un documento con estados (transferencia o ingreso)."""
    ruta = f"/{plural}"

    def crear():
        d = cuerpo()
        valores = requeridos(d, *campos_alta)
        with pool.transaccion() as cur:
            nro = insertar(cur, *valores)
            for r in (_renglones_de(d["renglones"]) if d.get("renglones") else []):
                cargar(cur, nro, *r)
        with pool.transaccion() as cur:
            doc_ = obtener(cur, nro)
            doc_["renglones"] = renglones(cur, nro)
        resp = jsonify(doc_)
        resp.status_code = 201
        resp.headers["Location"] = f"{ruta}/{nro}"
        return resp

    def detalle(nro):
        with pool.transaccion() as cur:
            doc_ = no_encontrado(obtener(cur, nro), nombre.capitalize())
            doc_["renglones"] = renglones(cur, nro)
        return jsonify(doc_)

    def agregar_renglon(nro):
        rs = _renglones_de(request.get_json(silent=True))
        with pool.transaccion() as cur:
            no_encontrado(obtener(cur, nro), nombre.capitalize())
            for r in rs:
                cargar(cur, nro, *r)
        with pool.transaccion() as cur:
            return jsonify(renglones(cur, nro)), 201

    def terminar_(nro):
        with pool.transaccion() as cur:
            no_encontrado(terminar(cur, nro) or None, nombre.capitalize())
        with pool.transaccion() as cur:
            return jsonify(obtener(cur, nro))

    def procesar_(nro):
        with pool.transaccion() as cur:
            no_encontrado(obtener(cur, nro), nombre.capitalize())
            procesar(cur, nro)
        with pool.transaccion() as cur:
            return jsonify(obtener(cur, nro))

    for f, n in ((crear, f"crear_{nombre}"), (detalle, f"detalle_{nombre}"), (agregar_renglon, f"renglones_{nombre}"),
                 (terminar_, f"terminar_{nombre}"), (procesar_, f"procesar_{nombre}")):
        f.__name__ = n
    app.add_url_rule(ruta, f"crear_{nombre}", crear, methods=["POST"])
    app.add_url_rule(f"{ruta}/<int:nro>", f"detalle_{nombre}", detalle, methods=["GET"])
    app.add_url_rule(f"{ruta}/<int:nro>/renglones", f"renglones_{nombre}", agregar_renglon, methods=["POST"])
    app.add_url_rule(f"{ruta}/<int:nro>/terminar", f"terminar_{nombre}", terminar_, methods=["POST"])
    app.add_url_rule(f"{ruta}/<int:nro>/procesar", f"procesar_{nombre}", procesar_, methods=["POST"])
    DOCS.update({
        f"crear_{nombre}": {"resumen": f"Crea un{'a' if nombre == 'transferencia' else ''} {nombre} en confeccion (con renglones opcionales)",
                            "query": [], "body": ej_alta, "codigos": {}},
        f"detalle_{nombre}": {"resumen": f"{nombre.capitalize()} con su estado y renglones", "query": [], "body": None, "codigos": {404: "No existe"}},
        f"renglones_{nombre}": {"resumen": f"Agrega renglones mientras esta en confeccion (RN-12)", "query": [],
                                "body": {"cod_vino": 3, "cantidad": 10}, "codigos": {409: "El documento ya no esta en confeccion"}},
        f"terminar_{nombre}": {"resumen": "en_confeccion -> terminado", "query": [], "body": None, "codigos": {409: "Transicion invalida"}},
        f"procesar_{nombre}": {"resumen": f"terminado -> procesado: invoca sp_procesar_{nombre} (impacta el stock)", "query": [], "body": None,
                               "codigos": {409: "No esta terminado / stock insuficiente en el deposito"}},
    })


_documento("transferencia", "transferencias", dal.insertar_transferencia, dal.insertar_renglon_transferencia,
           dal.terminar_transferencia, dal.procesar_transferencia, dal.obtener_transferencia,
           dal.listar_renglones_transferencia, "nro_solicitud", ("id_sala",),
           {"id_sala": 1, "renglones": [{"cod_vino": 3, "cantidad": 10}]})
_documento("ingreso", "ingresos", dal.insertar_ingreso, dal.insertar_renglon_ingreso,
           dal.terminar_ingreso, dal.procesar_ingreso, dal.obtener_ingreso,
           dal.listar_renglones_ingreso, "cod_ingreso", ("cod_transporte", "cuit_bodega"),
           {"cod_transporte": 1, "cuit_bodega": "30161033967", "renglones": [{"cod_vino": 3, "cantidad": 120}]})


@app.get("/transferencias")
@doc("Listado de transferencias paginado", query=["estado", "pagina", "por_pagina"])
def listar_transferencias():
    pagina, por_pagina, desde = paginacion()
    estado = parametro("estado")
    with pool.transaccion() as cur:
        total = dal.contar_transferencias(cur, estado)
        datos = dal.listar_transferencias(cur, por_pagina, desde, estado)
    return listado(datos, total, pagina, por_pagina)


# ----------------------------------------------------------------------------- reportes (consultas de la seccion 8)
@app.get("/reportes/top-vinos")
@doc("S1 - Ranking de los vinos mas vendidos", query=["limite (por defecto 10)"])
def reporte_top_vinos():
    try:
        limite = int(request.args.get("limite", 10))
    except ValueError:
        raise ApiError(400, "limite debe ser un entero")
    with pool.transaccion() as cur:
        return jsonify(dal.reporte_top_vinos(cur, limite))


@app.get("/reportes/ventas-por-sala")
@doc("S8 - Monto vendido por sala en el ultimo trimestre")
def reporte_ventas_por_sala():
    with pool.transaccion() as cur:
        return jsonify(dal.reporte_ventas_por_sala(cur))


@app.get("/reportes/vinos-sin-stock")
@doc("S6 - Vinos sin stock en una sala pero con stock en el deposito", query=["id_sala (obligatorio)"])
def reporte_vinos_sin_stock():
    id_sala = parametro("id_sala")
    if id_sala is None:
        raise ApiError(400, "Falta id_sala")
    with pool.transaccion() as cur:
        return jsonify(dal.reporte_vinos_sin_stock(cur, id_sala))


@app.get("/reportes/transportista-activo")
@doc("S7 - Transportista con mas ingresos en el ultimo mes")
def reporte_transportista_activo():
    with pool.transaccion() as cur:
        return jsonify(dal.reporte_transportista_activo(cur))


@app.get("/reportes/trazabilidad/<int:cod>")
@doc("Trazabilidad de un vino: lotes de uva de su corte e ingresos al deposito", codigos={404: "No existe"})
def reporte_trazabilidad(cod):
    with pool.transaccion() as cur:
        vino = no_encontrado(dal.obtener_ficha_vino(cur, cod), "Vino")
        return jsonify({"vino": {"cod_vino": cod, "nombre": vino["nombre"], "bodega": vino["bodega"], "cepas": vino["cepas"]},
                        "lotes": dal.reporte_trazabilidad_lotes(cur, cod),
                        "ingresos": dal.reporte_trazabilidad_ingresos(cur, cod)})


# ----------------------------------------------------------------------------- documentacion
import openapi  # noqa: E402  (necesita DOCS y app)


@app.get("/openapi.json")
def openapi_json():
    return jsonify(openapi.generar(app, DOCS))


@app.get("/docs")
def swagger():
    return ("<!doctype html><html><head><meta charset='utf-8'><title>API Bodegas del Atuel</title>"
            "<link rel='stylesheet' href='https://unpkg.com/swagger-ui-dist@5.17.14/swagger-ui.css'></head>"
            "<body><div id='ui'></div><script src='https://unpkg.com/swagger-ui-dist@5.17.14/swagger-ui-bundle.js'></script>"
            "<script>SwaggerUIBundle({url:'/openapi.json',dom_id:'#ui'})</script></body></html>")
