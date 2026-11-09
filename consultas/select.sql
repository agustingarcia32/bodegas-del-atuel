-- =====================================================================
-- select.sql · Etapa 5 · S1 a S12
-- Solo lectura. Las fechas relativas ("ultima semana", "ultimo trimestre") se calculan con
-- CURRENT_DATE. "PARAMETRO" marca los valores que se cambian (sala 7, vino 123, etc.).
-- Requiere 001-006, 008 y 009.   psql -d bodegas -f consultas/select.sql
-- S9 a S12 llevan EXPLAIN (ANALYZE, BUFFERS) al final de cada bloque (resumido en docs/etapa5_consultas.md).
-- =====================================================================
\set ON_ERROR_STOP on
\pset format aligned

-- ---------------------------------------------------------------------
-- S1  Ranking de los 10 vinos con mayor cantidad de botellas vendidas en toda la red de salas.
-- Estrategia: agregar los renglones por vino (SUM de cantidad), unir con vino para el nombre,
-- ordenar descendente y LIMIT 10. Se desempata por codigo para que el ranking sea estable.
-- ---------------------------------------------------------------------
\echo '=== S1 ==='
SELECT v.cod_vino, v.nombre, SUM(r.cantidad) AS botellas
FROM renglon_comprobante r
JOIN vino v USING (cod_vino)
GROUP BY v.cod_vino, v.nombre
ORDER BY botellas DESC, v.cod_vino
LIMIT 10;

-- ---------------------------------------------------------------------
-- S2  Codigos y nombres de los vinos que se vendieron en todas las salas (division relacional).
-- Estrategia: "vendido en todas" = la cantidad de salas distintas donde se vendio es igual a la
-- cantidad total de salas. Se cuenta con GROUP BY ... HAVING contra (SELECT COUNT(*) FROM sala_venta).
-- Es mas rapido que el doble NOT EXISTS (usado en S12) porque recorre los renglones una sola vez.
-- ---------------------------------------------------------------------
\echo '=== S2 ==='
SELECT v.cod_vino, v.nombre
FROM vino v
JOIN renglon_comprobante r USING (cod_vino)
JOIN comprobante c USING (nro_comprobante)
GROUP BY v.cod_vino, v.nombre
HAVING COUNT(DISTINCT c.id_sala) = (SELECT COUNT(*) FROM sala_venta)
ORDER BY v.cod_vino;

-- ---------------------------------------------------------------------
-- S3  Cantidad de clientes de cada tipo que compraron en una sala determinada en la ultima semana.
-- PARAMETRO: id_sala = 7.
-- Estrategia: join comprobante-cliente, filtro por sala y fecha >= CURRENT_DATE - 7 y
-- COUNT(DISTINCT id_cliente) por tipo (un cliente que compro dos veces cuenta una).
-- Usa idx_comprobante_sala_fecha.
-- ---------------------------------------------------------------------
\echo '=== S3 ==='
SELECT k.tipo_cliente, COUNT(DISTINCT c.id_cliente) AS clientes
FROM comprobante c
JOIN cliente k USING (id_cliente)
WHERE c.id_sala = 7                                  -- PARAMETRO
  AND c.fecha >= CURRENT_DATE - 7
GROUP BY k.tipo_cliente
ORDER BY k.tipo_cliente;

-- ---------------------------------------------------------------------
-- S4  Top 5 de las salas que solicitaron mayor cantidad de un vino determinado mediante
--     transferencias en los ultimos 15 dias.
-- PARAMETRO: cod_vino = 116.
-- Estrategia: transferencias (cualquier estado: "solicitaron") de los ultimos 15 dias, join con sus
-- renglones del vino, SUM por sala, ORDER BY DESC LIMIT 5.
-- ---------------------------------------------------------------------
\echo '=== S4 ==='
SELECT t.id_sala, SUM(rt.cantidad) AS cantidad_solicitada
FROM transferencia t
JOIN renglon_transferencia rt USING (nro_solicitud)
WHERE rt.cod_vino = 116                          -- PARAMETRO
  AND t.fecha_confeccion >= CURRENT_DATE - 15
GROUP BY t.id_sala
ORDER BY cantidad_solicitada DESC, t.id_sala
LIMIT 5;

-- ---------------------------------------------------------------------
-- S5  Salas con menor cantidad de transferencias pendientes (no procesadas).
-- Estrategia: LEFT JOIN desde sala_venta para que las salas SIN pendientes aparezcan con 0
-- (un join comun las perderia, y son justamente las que tienen "menos"). Un CTE cuenta y el
-- WHERE final deja todas las que empatan en el minimo. Usa idx_transferencia_pendientes.
-- ---------------------------------------------------------------------
\echo '=== S5 ==='
WITH pendientes AS (
    SELECT s.id_sala, COUNT(t.nro_solicitud) AS pendientes
    FROM sala_venta s
    LEFT JOIN transferencia t ON t.id_sala = s.id_sala AND t.estado <> 'procesado'
    GROUP BY s.id_sala
)
SELECT id_sala, pendientes
FROM pendientes
WHERE pendientes = (SELECT MIN(pendientes) FROM pendientes)
ORDER BY id_sala;

-- ---------------------------------------------------------------------
-- S6  Para una sala determinada, los vinos sin stock en la sala pero con stock en el deposito central.
-- PARAMETRO: id_sala = 7.
-- Estrategia: parte de stock_deposito con cantidad > 0 y deja los vinos para los que NO EXISTE una
-- fila de la sala con cantidad > 0 (cubre los dos casos: fila en 0 y vino sin fila).
-- ---------------------------------------------------------------------
\echo '=== S6 ==='
SELECT v.cod_vino, v.nombre, sd.cantidad AS stock_deposito
FROM stock_deposito sd
JOIN vino v USING (cod_vino)
WHERE sd.cantidad > 0
  AND NOT EXISTS (SELECT 1 FROM stock_sala ss
                  WHERE ss.id_sala = 7 AND ss.cod_vino = sd.cod_vino AND ss.cantidad > 0)   -- PARAMETRO
ORDER BY sd.cantidad DESC, v.cod_vino
LIMIT 15;

-- ---------------------------------------------------------------------
-- S7  Cual es la empresa de transporte con mayor actividad en el ultimo mes.
-- Estrategia: actividad = ingresos trasladados (cualquier estado) en el ultimo mes; COUNT por
-- transportista y FETCH FIRST 1 ROW WITH TIES para devolver todas las que empaten en el maximo.
-- ---------------------------------------------------------------------
\echo '=== S7 ==='
SELECT t.cod_transporte, t.razon_social, COUNT(*) AS ingresos
FROM ingreso i
JOIN transportista t USING (cod_transporte)
WHERE i.fecha >= CURRENT_DATE - INTERVAL '1 month'
GROUP BY t.cod_transporte, t.razon_social
ORDER BY ingresos DESC
FETCH FIRST 1 ROW WITH TIES;

-- ---------------------------------------------------------------------
-- S8  Monto total de ventas por sala en el ultimo trimestre, en orden descendente.
-- Estrategia: SUM(total) de comprobante (el total ya trae el descuento) agrupado por sala,
-- fecha >= CURRENT_DATE - 3 meses. Usa idx_comprobante_fecha_cubriente (Index Only Scan).
-- ---------------------------------------------------------------------
\echo '=== S8 ==='
SELECT s.id_sala, s.calle || ' ' || s.numero AS sala, SUM(c.total) AS ventas
FROM comprobante c
JOIN sala_venta s USING (id_sala)
WHERE c.fecha >= CURRENT_DATE - INTERVAL '3 months'
GROUP BY s.id_sala, s.calle, s.numero
ORDER BY ventas DESC
LIMIT 15;

-- ---------------------------------------------------------------------
-- S9  Ficha de un vino: cepas con sus porcentajes, bodega elaboradora, maridajes y stock total
--     (deposito mas salas).
-- PARAMETRO: cod_vino = 123.
-- Estrategia: la vista v_ficha_vino (009) arma una fila por vino con subconsultas para las listas
-- (string_agg) y junta v_stock_total_vino para el stock; la consulta es solo un filtro.
-- ---------------------------------------------------------------------
\echo '=== S9 ==='
SELECT * FROM v_ficha_vino WHERE cod_vino = 123;                         -- PARAMETRO
\echo '--- plan S9'
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF, TIMING OFF) SELECT * FROM v_ficha_vino WHERE cod_vino = 123;

-- ---------------------------------------------------------------------
-- S10 Rendimiento en kg por hectarea de cada parcela y campania, e identificar las parcelas que
--     rinden menos que el promedio de su finca.
-- Estrategia: CTE "rend" calcula kilos / superficie por lote (cada lote es una parcela en una
-- campania). La consulta final compara cada fila con el promedio de su finca EN LA MISMA CAMPANIA
-- mediante una subconsulta correlacionada. Se muestran las 15 mas lejos del promedio.
-- ---------------------------------------------------------------------
\echo '=== S10 ==='
WITH rend AS (
    SELECT l.id_finca, l.nro_parcela, l.campania,
           ROUND(l.kilos / p.superficie, 1) AS kg_por_ha
    FROM lote l
    JOIN parcela p USING (id_finca, nro_parcela)
)
SELECT r.id_finca, r.nro_parcela, r.campania, r.kg_por_ha,
       (SELECT ROUND(AVG(r2.kg_por_ha), 1) FROM rend r2
         WHERE r2.id_finca = r.id_finca AND r2.campania = r.campania) AS promedio_finca
FROM rend r
WHERE r.kg_por_ha < (SELECT AVG(r2.kg_por_ha) FROM rend r2
                      WHERE r2.id_finca = r.id_finca AND r2.campania = r.campania)
ORDER BY r.kg_por_ha - (SELECT AVG(r2.kg_por_ha) FROM rend r2
                         WHERE r2.id_finca = r.id_finca AND r2.campania = r.campania)
LIMIT 15;
\echo '--- plan S10 (resumen: cantidad de parcelas-campania por debajo del promedio de su finca)'
WITH rend AS (SELECT l.id_finca, l.campania, l.kilos / p.superficie AS kg_por_ha FROM lote l JOIN parcela p USING (id_finca, nro_parcela))
SELECT count(*) AS parcelas_campania_debajo_del_promedio, (SELECT count(*) FROM lote) AS total_lotes
FROM rend r WHERE r.kg_por_ha < (SELECT AVG(r2.kg_por_ha) FROM rend r2 WHERE r2.id_finca = r.id_finca AND r2.campania = r.campania);
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF, TIMING OFF)
WITH rend AS (SELECT l.id_finca, l.nro_parcela, l.campania, l.kilos / p.superficie AS kg_por_ha FROM lote l JOIN parcela p USING (id_finca, nro_parcela))
SELECT r.id_finca, r.nro_parcela FROM rend r WHERE r.kg_por_ha < (SELECT AVG(r2.kg_por_ha) FROM rend r2 WHERE r2.id_finca = r.id_finca AND r2.campania = r.campania);

-- ---------------------------------------------------------------------
-- S11 Ranking de vinos dentro de cada sala por botellas vendidas, y ventas acumuladas mensuales por sala.
-- Estrategia: (a) se agrupa por (sala, vino) y RANK() OVER (PARTITION BY sala ORDER BY botellas DESC)
-- numera dentro de cada sala (RANK deja empates con el mismo puesto); se muestran los 3 primeros de
-- las salas 1 a 3. (b) v_ventas_mensuales_sala ya trae el total por (sala, mes); SUM(...) OVER
-- (PARTITION BY sala ORDER BY mes) lo acumula mes a mes.
-- ---------------------------------------------------------------------
\echo '=== S11a: ranking de vinos por sala (top 3 de las salas 1 a 3) ==='
SELECT * FROM (
    SELECT c.id_sala, r.cod_vino, SUM(r.cantidad) AS botellas,
           RANK() OVER (PARTITION BY c.id_sala ORDER BY SUM(r.cantidad) DESC) AS puesto
    FROM renglon_comprobante r
    JOIN comprobante c USING (nro_comprobante)
    WHERE c.id_sala BETWEEN 1 AND 3                                       -- PARAMETRO
    GROUP BY c.id_sala, r.cod_vino
) x
WHERE puesto <= 3
ORDER BY id_sala, puesto, cod_vino;
\echo '=== S11b: ventas acumuladas por mes de la sala 1 (ultimos 8 meses) ==='
SELECT id_sala, mes, total_vendido,
       SUM(total_vendido) OVER (PARTITION BY id_sala ORDER BY mes) AS acumulado
FROM v_ventas_mensuales_sala
WHERE id_sala = 1                                                         -- PARAMETRO
ORDER BY mes DESC
LIMIT 8;
\echo '--- plan S11a'
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF, TIMING OFF)
SELECT * FROM (
    SELECT c.id_sala, r.cod_vino, SUM(r.cantidad) AS botellas,
           RANK() OVER (PARTITION BY c.id_sala ORDER BY SUM(r.cantidad) DESC) AS puesto
    FROM renglon_comprobante r JOIN comprobante c USING (nro_comprobante) WHERE c.id_sala BETWEEN 1 AND 3 GROUP BY c.id_sala, r.cod_vino) x
WHERE puesto <= 3;

-- ---------------------------------------------------------------------
-- S12 (a) Clientes que compraron TODOS los vinos de una bodega. (b) Clientes que nunca compraron
--     ningun vino tinto.
-- PARAMETRO: bodega (a) = 'Bodega Vista al Diamante' queda como ejemplo en la prueba de abajo.
-- Estrategia (a): division relacional con doble NOT EXISTS: "no existe un vino de la bodega que el
-- cliente NO haya comprado". Es lo que usa idx_comprobante_cliente_fecha + idx_renglon_comprobante_vino.
-- Estrategia (b): anti-join con NOT EXISTS: clientes para los que no existe ninguna compra de un
-- vino tinto (incluye a los que nunca compraron nada).
-- ---------------------------------------------------------------------
\echo '=== S12a: clientes que compraron todos los vinos de la bodega ==='
SELECT k.id_cliente, k.nombre_razon_social
FROM cliente k
WHERE NOT EXISTS (
    SELECT 1 FROM vino v
    WHERE v.cuit_bodega = (SELECT cuit FROM bodega WHERE razon_social = 'Bodega Piedra Colorada')   -- PARAMETRO
      AND NOT EXISTS (
          SELECT 1 FROM comprobante c JOIN renglon_comprobante r USING (nro_comprobante)
          WHERE c.id_cliente = k.id_cliente AND r.cod_vino = v.cod_vino))
ORDER BY k.id_cliente;
\echo '=== S12b: clientes que nunca compraron un vino tinto (cantidad por tipo de cliente) ==='
SELECT k.tipo_cliente, COUNT(*) AS clientes
FROM cliente k
WHERE NOT EXISTS (
    SELECT 1 FROM comprobante c
    JOIN renglon_comprobante r USING (nro_comprobante)
    JOIN vino v USING (cod_vino)
    WHERE c.id_cliente = k.id_cliente AND v.tipo = 'tinto')
GROUP BY k.tipo_cliente
ORDER BY k.tipo_cliente;
\echo '--- plan S12b'
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF, TIMING OFF)
SELECT k.id_cliente FROM cliente k WHERE NOT EXISTS (
    SELECT 1 FROM comprobante c JOIN renglon_comprobante r USING (nro_comprobante) JOIN vino v USING (cod_vino)
    WHERE c.id_cliente = k.id_cliente AND v.tipo = 'tinto');

-- Prueba de que la division de S12a funciona: en una transaccion se crea una bodega con 2 vinos y un
-- cliente que compra los dos, y otro que compra solo uno. Solo el primero tiene que aparecer.
\echo '=== S12a, prueba de la division (BEGIN ... ROLLBACK) ==='
BEGIN;
INSERT INTO bodega VALUES ('30712345679', 'Bodega Vista al Diamante', 'Ruta 143, San Rafael');
INSERT INTO vino (nombre, tipo, anada, volumen_ml, graduacion, precio, cuit_bodega) VALUES
  ('Prueba A', 'tinto', 2020, 750, 14, 1000, '30712345679'), ('Prueba B', 'tinto', 2020, 750, 14, 1000, '30712345679');
INSERT INTO composicion SELECT cod_vino, 1, 100 FROM vino WHERE nombre LIKE 'Prueba %';
INSERT INTO stock_sala SELECT 1, cod_vino, 50 FROM vino WHERE nombre LIKE 'Prueba %';
INSERT INTO comprobante (id_cliente, id_sala) VALUES (1, 1), (2, 1);
INSERT INTO renglon_comprobante (nro_comprobante, cod_vino, cantidad)
SELECT (SELECT max(nro_comprobante) - 1 FROM comprobante), cod_vino, 1 FROM vino WHERE nombre LIKE 'Prueba %';      -- cliente 1: los 2 vinos
INSERT INTO renglon_comprobante (nro_comprobante, cod_vino, cantidad)
SELECT (SELECT max(nro_comprobante) FROM comprobante), cod_vino, 1 FROM vino WHERE nombre = 'Prueba A';             -- cliente 2: solo uno
SELECT k.id_cliente
FROM cliente k
WHERE NOT EXISTS (
    SELECT 1 FROM vino v
    WHERE v.cuit_bodega = (SELECT cuit FROM bodega WHERE razon_social = 'Bodega Vista al Diamante')
      AND NOT EXISTS (
          SELECT 1 FROM comprobante c JOIN renglon_comprobante r USING (nro_comprobante)
          WHERE c.id_cliente = k.id_cliente AND r.cod_vino = v.cod_vino));
ROLLBACK;
