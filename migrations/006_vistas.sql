-- =====================================================================
-- 006_vistas.sql  ·  Bodegas del Atuel  ·  Etapa 2
-- Va después de 001 a 005. Tres vistas de solo lectura para reportes.
-- Son vistas comunes (no materializadas): siempre muestran el dato
-- actual y no hay que refrescarlas.
-- =====================================================================


-- ---------------------------------------------------------------------
-- v_stock_total_vino
-- Stock de cada vino: en el depósito, sumado en todas las salas y total.
-- Salen TODOS los vinos, también los que no tienen ninguna fila de stock
-- (aparecen con 0). El stock de las salas se suma antes de unir para no
-- repetir filas.
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW v_stock_total_vino AS
SELECT v.cod_vino,
       v.nombre,
       v.anada,
       v.volumen_ml,
       COALESCE(d.cantidad, 0)                          AS stock_deposito,
       COALESCE(s.cantidad, 0)                          AS stock_salas,
       COALESCE(d.cantidad, 0) + COALESCE(s.cantidad, 0) AS stock_total
  FROM vino v
  LEFT JOIN stock_deposito d ON d.cod_vino = v.cod_vino
  LEFT JOIN (SELECT cod_vino, SUM(cantidad) AS cantidad
               FROM stock_sala
              GROUP BY cod_vino) s ON s.cod_vino = v.cod_vino;

COMMENT ON VIEW v_stock_total_vino IS
    'Stock por vino: deposito, suma de salas y total. Incluye vinos sin stock (0).';


-- ---------------------------------------------------------------------
-- v_ventas_mensuales_sala
-- Por sala y por mes: cantidad de comprobantes, botellas vendidas e
-- importe total. Solo aparecen los meses en que la sala vendió algo; un
-- comprobante sin renglones cuenta como comprobante con 0 botellas.
-- Las botellas se suman por comprobante antes de unir, así el total del
-- comprobante no se multiplica por la cantidad de renglones.
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW v_ventas_mensuales_sala AS
SELECT c.id_sala,
       sv.calle || ' ' || sv.numero                 AS sala,
       l.nombre                                     AS localidad,
       date_trunc('month', c.fecha)::date           AS mes,
       COUNT(*)                                     AS comprobantes,
       COALESCE(SUM(r.botellas), 0)                 AS botellas,
       SUM(c.total)                                 AS total_vendido
  FROM comprobante c
  JOIN sala_venta sv ON sv.id_sala = c.id_sala
  JOIN localidad  l  ON l.id_localidad = sv.id_localidad
  LEFT JOIN (SELECT nro_comprobante, SUM(cantidad) AS botellas
               FROM renglon_comprobante
              GROUP BY nro_comprobante) r ON r.nro_comprobante = c.nro_comprobante
 GROUP BY c.id_sala, sv.calle, sv.numero, l.nombre, date_trunc('month', c.fecha);

COMMENT ON VIEW v_ventas_mensuales_sala IS
    'Ventas por sala y mes: comprobantes, botellas e importe total.';


-- ---------------------------------------------------------------------
-- v_documentos_pendientes
-- Ingresos y transferencias que todavía no se procesaron (en confección
-- o terminados), con cuántos renglones y botellas tienen y hace cuántos
-- días están pendientes. Los terminados son los que esperan que se
-- llame a sp_procesar_ingreso / sp_procesar_transferencia.
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW v_documentos_pendientes AS
SELECT 'ingreso'::text                         AS tipo,
       i.cod_ingreso                           AS numero,
       i.fecha,
       i.estado,
       b.razon_social                          AS origen_o_destino,
       COALESCE(r.renglones, 0)                AS renglones,
       COALESCE(r.botellas, 0)                 AS botellas,
       CURRENT_DATE - i.fecha                  AS dias_pendiente
  FROM ingreso i
  JOIN bodega b ON b.cuit = i.cuit_bodega
  LEFT JOIN (SELECT cod_ingreso, COUNT(*) AS renglones, SUM(cantidad) AS botellas
               FROM renglon_ingreso
              GROUP BY cod_ingreso) r ON r.cod_ingreso = i.cod_ingreso
 WHERE i.estado <> 'procesado'
UNION ALL
SELECT 'transferencia'::text,
       t.nro_solicitud,
       t.fecha_confeccion,
       t.estado,
       'Sala ' || sv.calle || ' ' || sv.numero,
       COALESCE(r.renglones, 0),
       COALESCE(r.botellas, 0),
       CURRENT_DATE - t.fecha_confeccion
  FROM transferencia t
  JOIN sala_venta sv ON sv.id_sala = t.id_sala
  LEFT JOIN (SELECT nro_solicitud, COUNT(*) AS renglones, SUM(cantidad) AS botellas
               FROM renglon_transferencia
              GROUP BY nro_solicitud) r ON r.nro_solicitud = t.nro_solicitud
 WHERE t.estado <> 'procesado';

COMMENT ON VIEW v_documentos_pendientes IS
    'Ingresos y transferencias no procesados, con renglones, botellas y dias pendiente.';
