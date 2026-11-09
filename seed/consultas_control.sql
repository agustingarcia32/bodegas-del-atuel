-- consultas_control.sql - Etapa 3. Cada control devuelve cuantas filas tienen el problema (0 = bien).
\pset format aligned
\pset tuples_only off
\echo '=== 1) conteo por tabla ==='
SELECT t.tabla, t.filas FROM (
  SELECT 'localidad' tabla, count(*) filas FROM localidad UNION ALL SELECT 'cepa', count(*) FROM cepa
  UNION ALL SELECT 'maridaje', count(*) FROM maridaje UNION ALL SELECT 'bodega', count(*) FROM bodega
  UNION ALL SELECT 'transportista', count(*) FROM transportista UNION ALL SELECT 'transportista_localidad', count(*) FROM transportista_localidad
  UNION ALL SELECT 'sala_venta', count(*) FROM sala_venta UNION ALL SELECT 'finca', count(*) FROM finca
  UNION ALL SELECT 'empleado', count(*) FROM empleado UNION ALL SELECT 'parcela', count(*) FROM parcela
  UNION ALL SELECT 'lote', count(*) FROM lote UNION ALL SELECT 'analisis_calidad', count(*) FROM analisis_calidad
  UNION ALL SELECT 'vino', count(*) FROM vino UNION ALL SELECT 'composicion', count(*) FROM composicion
  UNION ALL SELECT 'vino_maridaje', count(*) FROM vino_maridaje UNION ALL SELECT 'cliente', count(*) FROM cliente
  UNION ALL SELECT 'socio', count(*) FROM socio UNION ALL SELECT 'distribuidor', count(*) FROM distribuidor
  UNION ALL SELECT 'exportador', count(*) FROM exportador UNION ALL SELECT 'permiso_exportacion', count(*) FROM permiso_exportacion
  UNION ALL SELECT 'comprobante', count(*) FROM comprobante UNION ALL SELECT 'renglon_comprobante', count(*) FROM renglon_comprobante
  UNION ALL SELECT 'ingreso', count(*) FROM ingreso UNION ALL SELECT 'renglon_ingreso', count(*) FROM renglon_ingreso
  UNION ALL SELECT 'transferencia', count(*) FROM transferencia UNION ALL SELECT 'renglon_transferencia', count(*) FROM renglon_transferencia
  UNION ALL SELECT 'stock_sala', count(*) FROM stock_sala UNION ALL SELECT 'stock_deposito', count(*) FROM stock_deposito
  UNION ALL SELECT 'auditoria_precio', count(*) FROM auditoria_precio) t
ORDER BY t.filas DESC, t.tabla;

\echo '=== 2) controles (problemas = 0 en todos) ==='
SELECT control, problemas, CASE WHEN problemas = 0 THEN 'OK' ELSE 'FALLA' END AS resultado FROM (
  SELECT 'huerfanos: renglon_comprobante sin comprobante' control, count(*) problemas
    FROM renglon_comprobante r LEFT JOIN comprobante c USING (nro_comprobante) WHERE c.nro_comprobante IS NULL
  UNION ALL SELECT 'huerfanos: renglon_comprobante sin vino', count(*)
    FROM renglon_comprobante r LEFT JOIN vino v USING (cod_vino) WHERE v.cod_vino IS NULL
  UNION ALL SELECT 'huerfanos: comprobante sin cliente o sin sala', count(*)
    FROM comprobante c LEFT JOIN cliente k USING (id_cliente) LEFT JOIN sala_venta s USING (id_sala) WHERE k.id_cliente IS NULL OR s.id_sala IS NULL
  UNION ALL SELECT 'huerfanos: lote sin parcela', count(*)
    FROM lote l LEFT JOIN parcela p USING (id_finca, nro_parcela) WHERE p.id_finca IS NULL
  UNION ALL SELECT 'huerfanos: renglones de ingreso / transferencia sin cabecera', (
      SELECT count(*) FROM renglon_ingreso r LEFT JOIN ingreso i USING (cod_ingreso) WHERE i.cod_ingreso IS NULL)
    + (SELECT count(*) FROM renglon_transferencia r LEFT JOIN transferencia t USING (nro_solicitud) WHERE t.nro_solicitud IS NULL)
  UNION ALL SELECT 'stock negativo (sala o deposito)', (SELECT count(*) FROM stock_sala WHERE cantidad < 0) + (SELECT count(*) FROM stock_deposito WHERE cantidad < 0)
  UNION ALL SELECT 'comprobantes cuyo total no coincide con la suma de sus renglones', count(*)
    FROM comprobante c LEFT JOIN (SELECT nro_comprobante, sum(subtotal) neto, sum(cantidad * precio_unitario) bruto FROM renglon_comprobante GROUP BY 1) r USING (nro_comprobante)
    WHERE c.total <> COALESCE(r.neto, 0) OR c.subtotal <> COALESCE(r.bruto, 0) OR c.descuento <> COALESCE(r.bruto, 0) - COALESCE(r.neto, 0)
  UNION ALL SELECT 'renglones cuyo subtotal no es fn_subtotal_renglon(...)', count(*)
    FROM renglon_comprobante WHERE subtotal <> fn_subtotal_renglon(cantidad, precio_unitario, descuento)
  UNION ALL SELECT 'renglones con descuento distinto al del cliente', count(*)
    FROM renglon_comprobante r JOIN comprobante c USING (nro_comprobante) JOIN cliente k USING (id_cliente) WHERE r.descuento <> k.descuento
  UNION ALL SELECT 'clientes con descuento distinto al de su tipo (10/20/30)', count(*)
    FROM cliente WHERE descuento <> fn_descuento_cliente(tipo_cliente)
  UNION ALL SELECT 'clientes sin su fila de subtipo o con subtipo equivocado', (
      SELECT count(*) FROM cliente c WHERE NOT (
        (tipo_cliente = 'socio' AND EXISTS (SELECT 1 FROM socio s WHERE s.id_cliente = c.id_cliente))
     OR (tipo_cliente = 'distribuidor' AND EXISTS (SELECT 1 FROM distribuidor d WHERE d.id_cliente = c.id_cliente))
     OR (tipo_cliente = 'exportador' AND EXISTS (SELECT 1 FROM exportador e WHERE e.id_cliente = c.id_cliente))))
  UNION ALL SELECT 'vinos cuyo corte no suma 100 (RN-05)', count(*)
    FROM (SELECT cod_vino FROM composicion GROUP BY 1 HAVING sum(porcentaje) <> 100) x
  UNION ALL SELECT 'vinos sin composicion', count(*) FROM vino v WHERE NOT EXISTS (SELECT 1 FROM composicion c WHERE c.cod_vino = v.cod_vino)
  UNION ALL SELECT 'ventas anteriores al alta del cliente', count(*)
    FROM comprobante c JOIN cliente k USING (id_cliente) WHERE c.fecha < k.fecha_alta
  UNION ALL SELECT 'ventas anteriores al primer ingreso procesado', count(*)
    FROM comprobante WHERE fecha < (SELECT min(fecha) FROM ingreso WHERE estado = 'procesado') AND (SELECT count(*) FROM ingreso) >= 1000   -- solo con el volumen completo
  UNION ALL SELECT 'ingresos con vinos de otra bodega', count(*)
    FROM renglon_ingreso r JOIN ingreso i USING (cod_ingreso) JOIN vino v USING (cod_vino) WHERE v.cuit_bodega <> i.cuit_bodega
  UNION ALL SELECT 'ingresos con vino de anada posterior a la fecha', count(*)
    FROM renglon_ingreso r JOIN ingreso i USING (cod_ingreso) JOIN vino v USING (cod_vino) WHERE v.anada > EXTRACT(YEAR FROM i.fecha)
  UNION ALL SELECT 'analisis posteriores a la cosecha del lote', count(*)
    FROM analisis_calidad a JOIN lote l USING (nro_lote) WHERE a.fecha > l.fecha_cosecha
  UNION ALL SELECT 'auditoria: ultimo precio nuevo distinto del precio actual del vino', count(*)
    FROM vino v JOIN (SELECT DISTINCT ON (cod_vino) cod_vino, precio_nuevo FROM auditoria_precio ORDER BY cod_vino, fecha_hora DESC, id_auditoria DESC) a USING (cod_vino)
    WHERE a.precio_nuevo <> v.precio
  UNION ALL SELECT 'documentos no procesados con fecha vieja (deberian ser recientes)', (
      SELECT count(*) FROM ingreso WHERE estado <> 'procesado' AND fecha < (SELECT max(fecha) FROM ingreso) - 90)
    + (SELECT count(*) FROM transferencia WHERE estado <> 'procesado' AND fecha_confeccion < (SELECT max(fecha_confeccion) FROM transferencia) - 90)
) c ORDER BY 3 DESC, 1;

\echo '=== 3) los tres estados existen en ingreso y transferencia ==='
SELECT 'ingreso' doc, estado, count(*) FROM ingreso GROUP BY 2 UNION ALL SELECT 'transferencia', estado, count(*) FROM transferencia GROUP BY 2 ORDER BY 1, 2;
