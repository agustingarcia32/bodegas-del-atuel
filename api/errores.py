"""
errores.py - traduce los errores de PostgreSQL (SQLSTATE) a respuestas HTTP.
La API no inventa mensajes para las reglas del negocio: cuando una regla la rechaza un
trigger o un procedimiento (RAISE EXCEPTION -> P0001), el mensaje de la base viaja tal cual.
"""
import logging

import psycopg
from flask import jsonify

log = logging.getLogger("api")


class ApiError(Exception):
    """Error propio de la API (datos mal formados, recurso inexistente)."""

    def __init__(self, http, mensaje):
        super().__init__(mensaje)
        self.http, self.mensaje = http, mensaje


# SQLSTATE -> (HTTP, descripcion corta). Ver la tabla del enunciado.
TABLA = {
    "23505": (409, "Ya existe un registro con esos datos (restriccion UNIQUE)"),
    "23503": (409, "Referencia invalida o con dependientes (clave foranea)"),
    "23514": (422, "Un valor no cumple una restriccion (CHECK)"),
    "23502": (422, "Falta un dato obligatorio (NOT NULL)"),
    "P0001": (409, None),                       # el mensaje es el de la regla
    "22P02": (400, "Formato invalido para el tipo de dato"),
    "22003": (422, "Numero fuera de rango"),
    "22007": (400, "Formato de fecha invalido"),
    "22023": (422, "Valor de parametro invalido"),
    "42501": (403, "El rol de la API no tiene permiso para esta operacion"),
    "40001": (503, "Conflicto de transacciones, reintente"),
    "40P01": (503, "Deadlock detectado, reintente"),
}


def traducir(e: psycopg.Error):
    if isinstance(e, psycopg.OperationalError) and not getattr(e, "sqlstate", None):
        return 503, {"sqlstate": None, "mensaje": "Sin conexion con la base de datos"}
    sqlstate = getattr(e, "sqlstate", None) or "XX000"
    http, texto = TABLA.get(sqlstate, (500, "Error interno de base de datos"))
    diag = e.diag
    cuerpo = {"sqlstate": sqlstate, "mensaje": diag.message_primary if sqlstate == "P0001" else (texto or str(e))}
    if sqlstate == "P0001":
        cuerpo["regla"] = True
    if sqlstate != "XX000" and http != 500:
        if diag.constraint_name:
            cuerpo["restriccion"] = diag.constraint_name
        if diag.table_name:
            cuerpo["tabla"] = diag.table_name
        if diag.message_detail and sqlstate in ("23505", "23503"):
            cuerpo["detalle"] = diag.message_detail
        if sqlstate in ("22P02", "22007", "22003", "23514", "23502"):
            cuerpo["detalle"] = diag.message_primary
    if http == 500:
        log.exception("error de base no mapeado: %s", sqlstate)
    return http, cuerpo


def registrar(app):
    @app.errorhandler(ApiError)
    def _api(e):
        return jsonify({"error": {"mensaje": e.mensaje}}), e.http

    @app.errorhandler(psycopg.Error)
    def _pg(e):
        http, cuerpo = traducir(e)
        resp = jsonify({"error": cuerpo})
        if http == 503:
            resp.headers["Retry-After"] = "1"
        return resp, http

    @app.errorhandler(404)
    def _404(_):
        return jsonify({"error": {"mensaje": "Ruta inexistente"}}), 404

    @app.errorhandler(405)
    def _405(_):
        return jsonify({"error": {"mensaje": "Metodo no permitido"}}), 405
