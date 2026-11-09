-- experimentos.sql - Etapa 4. Cada experimento va dentro de BEGIN ... ROLLBACK:
-- crea/borra indices de prueba, mide y deja la base como estaba (el DDL de PostgreSQL es transaccional).
-- Se corre con la base cargada y 008_indices.sql aplicado:  psql -d bodegas -f experimentos.sql
\set ON_ERROR_STOP on
\pset format unaligned
\pset tuples_only on
\timing off

\echo '######## E1. Orden de columnas del indice compuesto ########'
\echo 'Consulta: ventas de la sala 7 en los ultimos 90 dias (id_sala con =, fecha con rango)'
\echo '--- A) elegido: (id_sala, fecha). En una transaccion se saca el indice cubriente para que no compita'
BEGIN;
DROP INDEX idx_comprobante_fecha_cubriente;
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF, TIMING OFF) SELECT count(*), sum(total) FROM comprobante WHERE id_sala = 7 AND fecha >= CURRENT_DATE - 90;
ROLLBACK;
BEGIN;
DROP INDEX idx_comprobante_sala_fecha;
DROP INDEX idx_comprobante_fecha_cubriente;
CREATE INDEX idx_prueba_fecha_sala ON comprobante (fecha, id_sala);
ANALYZE comprobante;
\echo '--- B) descartado: (fecha, id_sala), mismas columnas en el otro orden'
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF, TIMING OFF) SELECT count(*), sum(total) FROM comprobante WHERE id_sala = 7 AND fecha >= CURRENT_DATE - 90;
\echo '--- C) y una consulta que solo filtra por sala (ventas totales de la sala 7), con (fecha, id_sala): no puede usar el indice'
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF, TIMING OFF) SELECT count(*), sum(total) FROM comprobante WHERE id_sala = 7;
ROLLBACK;
BEGIN;
DROP INDEX idx_comprobante_fecha_cubriente;
\echo '--- D) la misma consulta con el elegido (id_sala, fecha): usa el prefijo id_sala'
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF, TIMING OFF) SELECT count(*), sum(total) FROM comprobante WHERE id_sala = 7;
ROLLBACK;

\echo
\echo '######## E2. BRIN sobre comprobante(fecha): evaluado y descartado ########'
SELECT 'correlacion fisica de comprobante.fecha = ' || round(correlation::numeric, 3) || '  (BRIN necesita valores cercanos a 1 o -1)'
FROM pg_stats WHERE tablename = 'comprobante' AND attname = 'fecha';
SELECT 'correlacion fisica de comprobante.nro_comprobante = ' || round(correlation::numeric, 3) FROM pg_stats WHERE tablename = 'comprobante' AND attname = 'nro_comprobante';
BEGIN;
DROP INDEX idx_comprobante_sala_fecha;
DROP INDEX idx_comprobante_fecha_cubriente;
CREATE INDEX idx_prueba_brin ON comprobante USING brin (fecha);
ANALYZE comprobante;
SELECT 'tamano del BRIN: ' || pg_size_pretty(pg_relation_size('idx_prueba_brin')) || ' (el btree cubriente ocupa ' || '4640 kB)';
\echo '--- S8 con el BRIN como unico indice de fecha'
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF, TIMING OFF) SELECT id_sala, SUM(total) FROM comprobante WHERE fecha >= CURRENT_DATE - INTERVAL '3 months' GROUP BY id_sala;
ROLLBACK;

\echo
\echo '######## E3. Indice sobre renglon_transferencia(cod_vino) para S4: evaluado y descartado ########'
\echo '--- sin el indice'
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF, TIMING OFF) SELECT t.id_sala, SUM(rt.cantidad) FROM transferencia t JOIN renglon_transferencia rt USING (nro_solicitud) WHERE rt.cod_vino = 123 AND t.fecha_confeccion >= CURRENT_DATE - 15 GROUP BY t.id_sala;
BEGIN;
CREATE INDEX idx_prueba_rt_vino ON renglon_transferencia (cod_vino);
ANALYZE renglon_transferencia;
\echo '--- con el indice'
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF, TIMING OFF) SELECT t.id_sala, SUM(rt.cantidad) FROM transferencia t JOIN renglon_transferencia rt USING (nro_solicitud) WHERE rt.cod_vino = 123 AND t.fecha_confeccion >= CURRENT_DATE - 15 GROUP BY t.id_sala;
ROLLBACK;

\echo
\echo '######## E4. Indice existente que el planificador NO usa: cliente(tipo_cliente), baja selectividad ########'
SELECT tipo_cliente || ': ' || count(*) || ' filas (' || round(100.0 * count(*) / sum(count(*)) OVER (), 1) || ' %)' FROM cliente GROUP BY tipo_cliente ORDER BY count(*) DESC;
BEGIN;
CREATE INDEX idx_prueba_tipo ON cliente (tipo_cliente);
ANALYZE cliente;
\echo '--- tipo = socio (85 % de la tabla): el indice existe pero conviene Seq Scan'
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF, TIMING OFF) SELECT id_cliente, nombre_razon_social FROM cliente WHERE tipo_cliente = 'socio';
\echo '--- forzando el indice (enable_seqscan = off y enable_bitmapscan = off, solo para esta prueba)'
SET LOCAL enable_seqscan = off; SET LOCAL enable_bitmapscan = off;
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF, TIMING OFF) SELECT id_cliente, nombre_razon_social FROM cliente WHERE tipo_cliente = 'socio';
RESET enable_seqscan; RESET enable_bitmapscan;
\echo '--- tipo = exportador (5 %): ahora si lo usa'
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF, TIMING OFF) SELECT id_cliente, nombre_razon_social FROM cliente WHERE tipo_cliente = 'exportador';
ROLLBACK;

\echo
\echo '######## E5. Indice de 008 que el planificador no usa en S1 (lee toda la tabla) ########'
\echo '--- plan normal (S1 completa)'
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF, TIMING OFF) SELECT v.cod_vino, v.nombre, SUM(r.cantidad) AS botellas FROM renglon_comprobante r JOIN vino v USING (cod_vino) GROUP BY v.cod_vino, v.nombre ORDER BY botellas DESC LIMIT 10;
BEGIN;
SET LOCAL enable_seqscan = off;
\echo '--- forzando el uso de idx_renglon_comprobante_vino (enable_seqscan = off)'
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF, TIMING OFF) SELECT v.cod_vino, v.nombre, SUM(r.cantidad) AS botellas FROM renglon_comprobante r JOIN vino v USING (cod_vino) GROUP BY v.cod_vino, v.nombre ORDER BY botellas DESC LIMIT 10;
ROLLBACK;
