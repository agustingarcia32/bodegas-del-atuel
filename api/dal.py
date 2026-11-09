"""
dal.py - capa de acceso a datos. Una funcion por consulta; todo el SQL de la API vive aca.
Todas las consultas son parametrizadas (%s): los valores del usuario viajan separados del texto SQL.
Los unicos fragmentos de texto que se unen al SQL son constantes escritas en este archivo.
Cada funcion recibe un cursor (cur) abierto por db.pool.transaccion(): la transaccion la
decide quien llama. La API no calcula totales ni stock: los hacen los triggers y procedimientos.
"""

# ----------------------------------------------------------------------------- catalogos
def listar_cepas(cur):
    cur.execute("SELECT id_cepa, nombre, tipo FROM cepa ORDER BY nombre")
    return cur.fetchall()


def listar_bodegas(cur):
    cur.execute("SELECT cuit, razon_social FROM bodega ORDER BY razon_social")
    return cur.fetchall()


def listar_salas(cur):
    cur.execute("""SELECT s.id_sala, s.calle || ' ' || s.numero AS nombre, l.nombre AS localidad
                   FROM sala_venta s JOIN localidad l USING (id_localidad) ORDER BY s.id_sala""")
    return cur.fetchall()


def listar_localidades(cur):
    cur.execute("SELECT id_localidad, nombre, provincia FROM localidad ORDER BY nombre")
    return cur.fetchall()


def listar_maridajes(cur):
    cur.execute("SELECT id_maridaje, nombre, temperatura_servicio FROM maridaje ORDER BY nombre")
    return cur.fetchall()


def listar_transportistas(cur):
    cur.execute("SELECT cod_transporte, razon_social FROM transportista ORDER BY razon_social")
    return cur.fetchall()


def salud(cur):
    cur.execute("SELECT 1 AS ok, current_user AS usuario, current_database() AS base")
    return cur.fetchone()


# ----------------------------------------------------------------------------- vinos
def _filtros_vino(tipo, id_cepa, cuit_bodega, anada, texto):
    where, params = [], []
    if tipo is not None:
        where.append("v.tipo = %s"); params.append(tipo)
    if id_cepa is not None:
        where.append("EXISTS (SELECT 1 FROM composicion co WHERE co.cod_vino = v.cod_vino AND co.id_cepa = %s)"); params.append(id_cepa)
    if cuit_bodega is not None:
        where.append("v.cuit_bodega = %s"); params.append(cuit_bodega)
    if anada is not None:
        where.append("v.anada = %s"); params.append(anada)
    if texto is not None:
        where.append("v.nombre ILIKE %s"); params.append("%" + texto + "%")
    return (" WHERE " + " AND ".join(where)) if where else "", params


def contar_vinos(cur, tipo=None, id_cepa=None, cuit_bodega=None, anada=None, texto=None):
    donde, params = _filtros_vino(tipo, id_cepa, cuit_bodega, anada, texto)
    cur.execute("SELECT count(*) AS n FROM vino v" + donde, params)
    return cur.fetchone()["n"]


def listar_vinos(cur, limite, desplazamiento, tipo=None, id_cepa=None, cuit_bodega=None, anada=None, texto=None):
    donde, params = _filtros_vino(tipo, id_cepa, cuit_bodega, anada, texto)
    cur.execute("""SELECT v.cod_vino, v.nombre, v.tipo, v.anada, v.volumen_ml, v.graduacion, v.precio,
                          v.cuit_bodega, b.razon_social AS bodega
                   FROM vino v JOIN bodega b ON b.cuit = v.cuit_bodega""" + donde +
                " ORDER BY v.nombre, v.anada, v.volumen_ml, v.cod_vino LIMIT %s OFFSET %s",
                params + [limite, desplazamiento])
    return cur.fetchall()


def obtener_ficha_vino(cur, cod_vino):
    cur.execute("SELECT * FROM v_ficha_vino WHERE cod_vino = %s", (cod_vino,))
    return cur.fetchone()


def obtener_composicion(cur, cod_vino):
    cur.execute("""SELECT co.id_cepa, c.nombre AS cepa, c.tipo, co.porcentaje
                   FROM composicion co JOIN cepa c USING (id_cepa)
                   WHERE co.cod_vino = %s ORDER BY co.porcentaje DESC, c.nombre""", (cod_vino,))
    return cur.fetchall()


def obtener_maridajes(cur, cod_vino):
    cur.execute("""SELECT m.id_maridaje, m.nombre, m.temperatura_servicio
                   FROM vino_maridaje vm JOIN maridaje m USING (id_maridaje)
                   WHERE vm.cod_vino = %s ORDER BY m.nombre""", (cod_vino,))
    return cur.fetchall()


def insertar_vino(cur, nombre, tipo, anada, volumen_ml, graduacion, precio, cuit_bodega):
    cur.execute("""INSERT INTO vino (nombre, tipo, anada, volumen_ml, graduacion, precio, cuit_bodega)
                   VALUES (%s, %s, %s, %s, %s, %s, %s) RETURNING cod_vino""",
                (nombre, tipo, anada, volumen_ml, graduacion, precio, cuit_bodega))
    return cur.fetchone()["cod_vino"]


def insertar_composicion(cur, cod_vino, id_cepa, porcentaje):
    cur.execute("INSERT INTO composicion (cod_vino, id_cepa, porcentaje) VALUES (%s, %s, %s)",
                (cod_vino, id_cepa, porcentaje))


def borrar_composicion(cur, cod_vino):
    cur.execute("DELETE FROM composicion WHERE cod_vino = %s", (cod_vino,))


def insertar_vino_maridaje(cur, cod_vino, id_maridaje):
    cur.execute("INSERT INTO vino_maridaje (cod_vino, id_maridaje) VALUES (%s, %s)", (cod_vino, id_maridaje))


def borrar_vino_maridajes(cur, cod_vino):
    cur.execute("DELETE FROM vino_maridaje WHERE cod_vino = %s", (cod_vino,))


def actualizar_vino(cur, cod_vino, nombre, tipo, anada, volumen_ml, graduacion, precio, cuit_bodega):
    """Actualiza todos los campos; el trigger audita el precio solo si cambio (RN-13)."""
    cur.execute("""UPDATE vino SET nombre = %s, tipo = %s, anada = %s, volumen_ml = %s,
                                   graduacion = %s, precio = %s, cuit_bodega = %s
                   WHERE cod_vino = %s""",
                (nombre, tipo, anada, volumen_ml, graduacion, precio, cuit_bodega, cod_vino))
    return cur.rowcount


def borrar_vino(cur, cod_vino):
    cur.execute("DELETE FROM vino WHERE cod_vino = %s", (cod_vino,))
    return cur.rowcount


def listar_auditoria_precio(cur, cod_vino):
    cur.execute("""SELECT fecha_hora, usuario, precio_anterior, precio_nuevo
                   FROM auditoria_precio WHERE cod_vino = %s ORDER BY id_auditoria DESC""", (cod_vino,))
    return cur.fetchall()


# ----------------------------------------------------------------------------- clientes
def contar_clientes(cur, tipo=None, texto=None):
    donde, params = _filtros_cliente(tipo, texto)
    cur.execute("SELECT count(*) AS n FROM cliente k" + donde, params)
    return cur.fetchone()["n"]


def _filtros_cliente(tipo, texto):
    where, params = [], []
    if tipo is not None:
        where.append("k.tipo_cliente = %s"); params.append(tipo)
    if texto is not None:                      # prefijo, usa idx_cliente_nombre_lower
        where.append("lower(k.nombre_razon_social) LIKE %s"); params.append(texto.lower() + "%")
    return (" WHERE " + " AND ".join(where)) if where else "", params


def listar_clientes(cur, limite, desplazamiento, tipo=None, texto=None):
    donde, params = _filtros_cliente(tipo, texto)
    cur.execute("""SELECT k.id_cliente, k.nombre_razon_social, k.tipo_doc, k.nro_doc, k.tipo_cliente,
                          k.descuento, l.nombre AS localidad
                   FROM cliente k JOIN localidad l USING (id_localidad)""" + donde +
                " ORDER BY k.id_cliente LIMIT %s OFFSET %s", params + [limite, desplazamiento])
    return cur.fetchall()


def obtener_cliente(cur, id_cliente):
    cur.execute("""SELECT k.*, l.nombre AS localidad, d.zona_cobertura, d.nro_habilitacion, e.pais_destino
                   FROM cliente k JOIN localidad l USING (id_localidad)
                   LEFT JOIN distribuidor d ON d.id_cliente = k.id_cliente
                   LEFT JOIN exportador e ON e.id_cliente = k.id_cliente
                   WHERE k.id_cliente = %s""", (id_cliente,))
    return cur.fetchone()


def listar_permisos(cur, id_cliente):
    cur.execute("""SELECT cod_permiso, fecha_emision, fecha_vencimiento
                   FROM permiso_exportacion WHERE id_cliente = %s ORDER BY fecha_emision""", (id_cliente,))
    return cur.fetchall()


def insertar_cliente(cur, nombre, tipo_doc, nro_doc, direccion, tipo_cliente, id_localidad, descuento=None):
    """descuento=None: lo completa el trigger segun el tipo (RN-06)."""
    cur.execute("""INSERT INTO cliente (nombre_razon_social, tipo_doc, nro_doc, direccion, tipo_cliente, id_localidad, descuento)
                   VALUES (%s, %s, %s, %s, %s, %s, %s) RETURNING id_cliente""",
                (nombre, tipo_doc, nro_doc, direccion, tipo_cliente, id_localidad, descuento))
    return cur.fetchone()["id_cliente"]


def insertar_socio(cur, id_cliente):
    cur.execute("INSERT INTO socio (id_cliente) VALUES (%s)", (id_cliente,))


def insertar_distribuidor(cur, id_cliente, zona, habilitacion):
    cur.execute("INSERT INTO distribuidor (id_cliente, zona_cobertura, nro_habilitacion) VALUES (%s, %s, %s)",
                (id_cliente, zona, habilitacion))


def insertar_exportador(cur, id_cliente, pais):
    cur.execute("INSERT INTO exportador (id_cliente, pais_destino) VALUES (%s, %s)", (id_cliente, pais))


def actualizar_cliente(cur, id_cliente, nombre, direccion, id_localidad, descuento):
    cur.execute("""UPDATE cliente SET nombre_razon_social = %s, direccion = %s, id_localidad = %s, descuento = %s
                   WHERE id_cliente = %s""", (nombre, direccion, id_localidad, descuento, id_cliente))
    return cur.rowcount


def actualizar_distribuidor(cur, id_cliente, zona, habilitacion):
    cur.execute("UPDATE distribuidor SET zona_cobertura = %s, nro_habilitacion = %s WHERE id_cliente = %s",
                (zona, habilitacion, id_cliente))


def actualizar_exportador(cur, id_cliente, pais):
    cur.execute("UPDATE exportador SET pais_destino = %s WHERE id_cliente = %s", (pais, id_cliente))


def borrar_cliente(cur, id_cliente):
    cur.execute("DELETE FROM cliente WHERE id_cliente = %s", (id_cliente,))
    return cur.rowcount


# ----------------------------------------------------------------------------- comprobantes
def insertar_comprobante(cur, id_cliente, id_sala):
    cur.execute("INSERT INTO comprobante (id_cliente, id_sala) VALUES (%s, %s) RETURNING nro_comprobante",
                (id_cliente, id_sala))
    return cur.fetchone()["nro_comprobante"]


def insertar_renglon_comprobante(cur, nro, cod_vino, cantidad):
    """Solo vino y cantidad: precio, descuento, subtotal y stock los resuelve la base (RN-08, RN-09)."""
    cur.execute("INSERT INTO renglon_comprobante (nro_comprobante, cod_vino, cantidad) VALUES (%s, %s, %s)",
                (nro, cod_vino, cantidad))


def obtener_comprobante(cur, nro):
    cur.execute("""SELECT c.nro_comprobante, c.fecha, c.id_cliente, k.nombre_razon_social AS cliente,
                          c.id_sala, c.subtotal, c.descuento, c.total
                   FROM comprobante c JOIN cliente k USING (id_cliente) WHERE c.nro_comprobante = %s""", (nro,))
    return cur.fetchone()


def listar_renglones_comprobante(cur, nro):
    cur.execute("""SELECT r.cod_vino, v.nombre AS vino, r.cantidad, r.precio_unitario, r.descuento AS descuento_pct, r.subtotal
                   FROM renglon_comprobante r JOIN vino v USING (cod_vino)
                   WHERE r.nro_comprobante = %s ORDER BY r.cod_vino""", (nro,))
    return cur.fetchall()


# ----------------------------------------------------------------------------- transferencias
def insertar_transferencia(cur, id_sala):
    cur.execute("INSERT INTO transferencia (id_sala) VALUES (%s) RETURNING nro_solicitud", (id_sala,))
    return cur.fetchone()["nro_solicitud"]


def insertar_renglon_transferencia(cur, nro, cod_vino, cantidad):
    cur.execute("INSERT INTO renglon_transferencia (nro_solicitud, cod_vino, cantidad) VALUES (%s, %s, %s)",
                (nro, cod_vino, cantidad))


def terminar_transferencia(cur, nro):
    cur.execute("UPDATE transferencia SET estado = 'terminado' WHERE nro_solicitud = %s", (nro,))
    return cur.rowcount


def procesar_transferencia(cur, nro):
    cur.execute("CALL sp_procesar_transferencia(%s)", (nro,))


def obtener_transferencia(cur, nro):
    cur.execute("""SELECT t.nro_solicitud, t.fecha_confeccion, t.estado, t.id_sala,
                          s.calle || ' ' || s.numero AS sala
                   FROM transferencia t JOIN sala_venta s USING (id_sala) WHERE t.nro_solicitud = %s""", (nro,))
    return cur.fetchone()


def listar_renglones_transferencia(cur, nro):
    cur.execute("""SELECT r.cod_vino, v.nombre AS vino, r.cantidad
                   FROM renglon_transferencia r JOIN vino v USING (cod_vino)
                   WHERE r.nro_solicitud = %s ORDER BY r.cod_vino""", (nro,))
    return cur.fetchall()


def contar_transferencias(cur, estado=None):
    if estado is None:
        cur.execute("SELECT count(*) AS n FROM transferencia")
    else:
        cur.execute("SELECT count(*) AS n FROM transferencia WHERE estado = %s", (estado,))
    return cur.fetchone()["n"]


def listar_transferencias(cur, limite, desplazamiento, estado=None):
    base = """SELECT t.nro_solicitud, t.fecha_confeccion, t.estado, t.id_sala
              FROM transferencia t"""
    if estado is None:
        cur.execute(base + " ORDER BY t.nro_solicitud DESC LIMIT %s OFFSET %s", (limite, desplazamiento))
    else:
        cur.execute(base + " WHERE t.estado = %s ORDER BY t.nro_solicitud DESC LIMIT %s OFFSET %s",
                    (estado, limite, desplazamiento))
    return cur.fetchall()


# ----------------------------------------------------------------------------- ingresos
def insertar_ingreso(cur, cod_transporte, cuit_bodega):
    cur.execute("INSERT INTO ingreso (cod_transporte, cuit_bodega) VALUES (%s, %s) RETURNING cod_ingreso",
                (cod_transporte, cuit_bodega))
    return cur.fetchone()["cod_ingreso"]


def insertar_renglon_ingreso(cur, cod_ingreso, cod_vino, cantidad):
    cur.execute("INSERT INTO renglon_ingreso (cod_ingreso, cod_vino, cantidad) VALUES (%s, %s, %s)",
                (cod_ingreso, cod_vino, cantidad))


def terminar_ingreso(cur, cod_ingreso):
    cur.execute("UPDATE ingreso SET estado = 'terminado' WHERE cod_ingreso = %s", (cod_ingreso,))
    return cur.rowcount


def procesar_ingreso(cur, cod_ingreso):
    cur.execute("CALL sp_procesar_ingreso(%s)", (cod_ingreso,))


def obtener_ingreso(cur, cod_ingreso):
    cur.execute("""SELECT i.cod_ingreso, i.fecha, i.estado, i.cod_transporte, i.cuit_bodega, b.razon_social AS bodega
                   FROM ingreso i JOIN bodega b ON b.cuit = i.cuit_bodega WHERE i.cod_ingreso = %s""", (cod_ingreso,))
    return cur.fetchone()


def listar_renglones_ingreso(cur, cod_ingreso):
    cur.execute("""SELECT r.cod_vino, v.nombre AS vino, r.cantidad
                   FROM renglon_ingreso r JOIN vino v USING (cod_vino)
                   WHERE r.cod_ingreso = %s ORDER BY r.cod_vino""", (cod_ingreso,))
    return cur.fetchall()


# ----------------------------------------------------------------------------- reportes (seccion 8)
def reporte_top_vinos(cur, limite=10):                       # S1
    cur.execute("""SELECT v.cod_vino, v.nombre, SUM(r.cantidad) AS botellas
                   FROM renglon_comprobante r JOIN vino v USING (cod_vino)
                   GROUP BY v.cod_vino, v.nombre ORDER BY botellas DESC, v.cod_vino LIMIT %s""", (limite,))
    return cur.fetchall()


def reporte_ventas_por_sala(cur):                            # S8
    cur.execute("""SELECT s.id_sala, s.calle || ' ' || s.numero AS sala, SUM(c.total) AS ventas
                   FROM comprobante c JOIN sala_venta s USING (id_sala)
                   WHERE c.fecha >= CURRENT_DATE - INTERVAL '3 months'
                   GROUP BY s.id_sala, s.calle, s.numero ORDER BY ventas DESC""")
    return cur.fetchall()


def reporte_vinos_sin_stock(cur, id_sala):                   # S6
    cur.execute("""SELECT v.cod_vino, v.nombre, sd.cantidad AS stock_deposito
                   FROM stock_deposito sd JOIN vino v USING (cod_vino)
                   WHERE sd.cantidad > 0
                     AND NOT EXISTS (SELECT 1 FROM stock_sala ss
                                     WHERE ss.id_sala = %s AND ss.cod_vino = sd.cod_vino AND ss.cantidad > 0)
                   ORDER BY sd.cantidad DESC, v.cod_vino LIMIT 50""", (id_sala,))
    return cur.fetchall()


def reporte_transportista_activo(cur):                       # S7
    cur.execute("""SELECT t.cod_transporte, t.razon_social, COUNT(*) AS ingresos
                   FROM ingreso i JOIN transportista t USING (cod_transporte)
                   WHERE i.fecha >= CURRENT_DATE - INTERVAL '1 month'
                   GROUP BY t.cod_transporte, t.razon_social
                   ORDER BY ingresos DESC FETCH FIRST 1 ROW WITH TIES""")
    return cur.fetchall()


def reporte_trazabilidad_lotes(cur, cod_vino):
    """Lotes de uva de las cepas del corte, destinados a la bodega que elabora el vino."""
    cur.execute("""SELECT l.nro_lote, l.campania, l.fecha_cosecha, l.kilos, f.nombre AS finca, l.nro_parcela,
                          c.nombre AS cepa, co.porcentaje
                   FROM vino v
                   JOIN composicion co ON co.cod_vino = v.cod_vino
                   JOIN cepa c ON c.id_cepa = co.id_cepa
                   JOIN parcela p ON p.id_cepa = co.id_cepa
                   JOIN lote l ON l.id_finca = p.id_finca AND l.nro_parcela = p.nro_parcela AND l.cuit_bodega = v.cuit_bodega
                   JOIN finca f ON f.id_finca = p.id_finca
                   WHERE v.cod_vino = %s AND l.campania BETWEEN v.anada - 1 AND v.anada + 1
                   ORDER BY l.campania, l.fecha_cosecha, l.nro_lote LIMIT 100""", (cod_vino,))
    return cur.fetchall()


def reporte_trazabilidad_ingresos(cur, cod_vino):
    cur.execute("""SELECT i.cod_ingreso, i.fecha, i.estado, t.razon_social AS transportista, r.cantidad
                   FROM renglon_ingreso r JOIN ingreso i USING (cod_ingreso)
                   JOIN transportista t USING (cod_transporte)
                   WHERE r.cod_vino = %s ORDER BY i.fecha DESC, i.cod_ingreso DESC LIMIT 50""", (cod_vino,))
    return cur.fetchall()
