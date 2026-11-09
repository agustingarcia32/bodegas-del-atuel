"""
openapi.py - arma openapi.json a partir de las rutas reales de Flask (app.url_map) y de los
metadatos de @doc: asi la documentacion nunca se desfasa de las rutas.
"""
import re


def generar(app, docs):
    paths = {}
    for regla in app.url_map.iter_rules():
        if regla.endpoint in ("static", "preflight", "openapi_json", "swagger"):
            continue
        ruta = re.sub(r"<(?:\w+:)?(\w+)>", r"{\1}", regla.rule)
        meta = docs.get(regla.endpoint, {"resumen": regla.endpoint, "query": [], "body": None, "codigos": {}})
        for metodo in sorted(regla.methods - {"HEAD", "OPTIONS"}):
            parametros = [{"name": v, "in": "path", "required": True, "schema": {"type": "integer"}}
                          for v in regla.arguments]
            parametros += [{"name": q.split(" ")[0], "in": "query", "description": q, "schema": {"type": "string"}}
                           for q in meta["query"]]
            op = {"summary": meta["resumen"], "tags": [ruta.strip("/").split("/")[0]], "parameters": parametros,
                  "responses": {"200": {"description": "OK"}}}
            if metodo == "POST":
                op["responses"] = {"201": {"description": "Creado"}, "200": {"description": "OK (accion)"}}
            if metodo == "DELETE":
                op["responses"] = {"204": {"description": "Eliminado"}}
            if meta["body"] is not None and metodo in ("POST", "PUT"):
                op["requestBody"] = {"content": {"application/json": {"schema": {"type": "object"}, "example": meta["body"]}}}
            for codigo, texto in meta["codigos"].items():
                op["responses"][str(codigo)] = {"description": texto}
            op["responses"].setdefault("400", {"description": "Dato mal formado (22P02 u otro)"})
            op["responses"].setdefault("409", {"description": "Regla de negocio o conflicto (P0001, 23505, 23503)"})
            op["responses"].setdefault("422", {"description": "Valor invalido (CHECK / NOT NULL)"})
            paths.setdefault(ruta, {})[metodo.lower()] = op
    return {"openapi": "3.0.3",
            "info": {"title": "API Bodegas del Atuel", "version": "1.0",
                     "description": "Los errores de la base se traducen por SQLSTATE: 23505/23503/P0001 -> 409, 23514/23502 -> 422, 22P02 -> 400, 40001/40P01 -> 503."},
            "paths": dict(sorted(paths.items()))}
