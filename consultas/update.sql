-- =====================================================================
-- update.sql · Etapa 5 · U1 a U6
-- Cada consigna corre dentro de BEGIN ... ROLLBACK: control previo, sentencia,
-- control posterior. Nada queda guardado. Para guardar de verdad, cambiar
-- ROLLBACK por COMMIT. Los valores entre comillas son del dataset de la
-- semilla 2026; dice "PARAMETRO" donde se cambian.
--   psql -d bodegas -f consultas/update.sql
-- =====================================================================
\set ON_ERROR_STOP on
\pset format aligned

-- ---------------------------------------------------------------------
-- U1  Recalcular el total de todos los comprobantes aplicando el descuento
--     que corresponde al tipo de cliente.
-- Estrategia: un CTE calcula, por comprobante, el bruto (cantidad x precio) y el
-- neto aplicando fn_descuento_cliente(tipo) renglon por renglon con
-- fn_subtotal_renglon (mismo redondeo que el trigger). Un solo UPDATE ... FROM
-- cambia subtotal, descuento y total, y solo toca los que difieren (IS DISTINCT FROM).
-- Los comprobantes no tienen trigger propio, asi que no se dispara nada; el
-- CHECK total = subtotal - descuento sigue protegiendo.
-- ---------------------------------------------------------------------
\echo '=== U1 ==='
BEGIN;
-- preparacion de la prueba: se "rompen" 1000 comprobantes (sin descuento) para ver que U1 los arregla
UPDATE comprobante SET descuento = 0, total = subtotal WHERE nro_comprobante <= 1000 AND descuento > 0;
-- control previo: comprobantes cuyo total no es el que corresponde al tipo de cliente
CREATE TEMP VIEW u1_mal AS
SELECT c.nro_comprobante
FROM comprobante c JOIN cliente k USING (id_cliente)
JOIN LATERAL (SELECT SUM(fn_subtotal_renglon(r.cantidad, r.precio_unitario, fn_descuento_cliente(k.tipo_cliente))) AS neto
              FROM renglon_comprobante r WHERE r.nro_comprobante = c.nro_comprobante) x ON true
WHERE c.total <> x.neto;
SELECT count(*) AS comprobantes_mal_antes FROM u1_mal;

WITH calc AS (
    SELECT c.nro_comprobante,
           SUM(r.cantidad * r.precio_unitario)                                                     AS bruto,
           SUM(fn_subtotal_renglon(r.cantidad, r.precio_unitario, fn_descuento_cliente(k.tipo_cliente))) AS neto
    FROM comprobante c
    JOIN cliente k USING (id_cliente)
    JOIN renglon_comprobante r USING (nro_comprobante)
    GROUP BY c.nro_comprobante
)
UPDATE comprobante c
SET subtotal = calc.bruto, descuento = calc.bruto - calc.neto, total = calc.neto
FROM calc
WHERE calc.nro_comprobante = c.nro_comprobante
  AND (c.subtotal, c.descuento, c.total) IS DISTINCT FROM (calc.bruto, calc.bruto - calc.neto, calc.neto);

SELECT count(*) AS comprobantes_mal_despues FROM u1_mal;
ROLLBACK;

-- ---------------------------------------------------------------------
-- U2  Aumentar un 20 % el salario de los empleados con mas de 5 anios de antiguedad.
-- Estrategia: fn_antiguedad_anios(fecha_ingreso) devuelve anios cumplidos
-- (calculados con CURRENT_DATE); "mas de 5" = > 5. ROUND a 2 decimales (NUMERIC(12,2)).
-- ---------------------------------------------------------------------
\echo '=== U2 ==='
BEGIN;
SELECT count(*) FILTER (WHERE fn_antiguedad_anios(fecha_ingreso) > 5) AS con_mas_de_5_anios, round(sum(salario), 2) AS masa_salarial_antes FROM empleado;
UPDATE empleado
SET salario = ROUND(salario * 1.20, 2)
WHERE fn_antiguedad_anios(fecha_ingreso) > 5;
SELECT round(sum(salario), 2) AS masa_salarial_despues FROM empleado;
ROLLBACK;

-- ---------------------------------------------------------------------
-- U3  Incrementar un 13 % el precio de los vinos elaborados por una bodega determinada.
-- PARAMETRO: razon social de la bodega.
-- Estrategia: subconsulta escalar para pasar de razon social a CUIT. El trigger
-- trg_vino_auditoria (RN-13) registra cada cambio en auditoria_precio: se comprueba.
-- ---------------------------------------------------------------------
\echo '=== U3 ==='
BEGIN;
SELECT count(*) AS vinos_de_la_bodega, round(avg(precio), 2) AS precio_promedio_antes,
       (SELECT count(*) FROM auditoria_precio) AS filas_auditoria_antes
FROM vino WHERE cuit_bodega = (SELECT cuit FROM bodega WHERE razon_social = 'Bodega Piedra Colorada');   -- PARAMETRO
UPDATE vino
SET precio = ROUND(precio * 1.13, 2)
WHERE cuit_bodega = (SELECT cuit FROM bodega WHERE razon_social = 'Bodega Piedra Colorada');              -- PARAMETRO
SELECT round(avg(precio), 2) AS precio_promedio_despues,
       (SELECT count(*) FROM auditoria_precio) AS filas_auditoria_despues
FROM vino WHERE cuit_bodega = (SELECT cuit FROM bodega WHERE razon_social = 'Bodega Piedra Colorada');
ROLLBACK;

-- ---------------------------------------------------------------------
-- U4  En las salas cuyo dia de cierre es lunes cambiarlo a miercoles y viceversa,
--     en una sola sentencia.
-- Estrategia: un CASE dentro del mismo UPDATE. PostgreSQL evalua el CASE con el
-- valor ORIGINAL de cada fila, por eso no hace falta una tabla auxiliar ni dos pasos.
-- (El CHECK ck_sala_dia_cierre usa 'miercoles' sin tilde.)
-- ---------------------------------------------------------------------
\echo '=== U4 ==='
BEGIN;
SELECT dia_cierre, count(*) FROM sala_venta WHERE dia_cierre IN ('lunes', 'miercoles') GROUP BY 1 ORDER BY 1;
UPDATE sala_venta
SET dia_cierre = CASE dia_cierre WHEN 'lunes' THEN 'miercoles' ELSE 'lunes' END
WHERE dia_cierre IN ('lunes', 'miercoles');
SELECT dia_cierre, count(*) FROM sala_venta WHERE dia_cierre IN ('lunes', 'miercoles') GROUP BY 1 ORDER BY 1;
ROLLBACK;

-- ---------------------------------------------------------------------
-- U5  Aplicar un 15 % de descuento de precio a los 10 vinos menos vendidos de toda la red.
-- Estrategia: CTE con LEFT JOIN desde vino (para contar tambien los vinos sin ninguna venta,
-- con COALESCE(...,0)), ordenado por botellas y luego por codigo para que el desempate sea
-- siempre el mismo, LIMIT 10. El UPDATE usa esa lista. Cada cambio queda en auditoria_precio.
-- ---------------------------------------------------------------------
\echo '=== U5 ==='
BEGIN;
SELECT round(avg(precio), 2) AS promedio_antes, (SELECT count(*) FROM auditoria_precio) AS auditoria_antes FROM vino;
WITH menos_vendidos AS (
    SELECT v.cod_vino
    FROM vino v
    LEFT JOIN renglon_comprobante r USING (cod_vino)
    GROUP BY v.cod_vino
    ORDER BY COALESCE(SUM(r.cantidad), 0), v.cod_vino
    LIMIT 10
)
UPDATE vino v
SET precio = ROUND(v.precio * 0.85, 2)
FROM menos_vendidos m
WHERE v.cod_vino = m.cod_vino;
SELECT round(avg(precio), 2) AS promedio_despues, (SELECT count(*) FROM auditoria_precio) AS auditoria_despues FROM vino;
ROLLBACK;

-- ---------------------------------------------------------------------
-- U6  A los exportadores con mas de 3 permisos de exportacion, subirles el descuento al 35 %.
-- Estrategia: subconsulta con GROUP BY ... HAVING COUNT(*) > 3 sobre permiso_exportacion.
-- Solo cambia cliente.descuento (rango 0..100 por CHECK); los comprobantes ya emitidos
-- conservan el porcentaje que se aplico al venderlos.
-- ---------------------------------------------------------------------
\echo '=== U6 ==='
BEGIN;
SELECT descuento, count(*) FROM cliente WHERE tipo_cliente = 'exportador' GROUP BY 1 ORDER BY 1;
UPDATE cliente
SET descuento = 35
WHERE tipo_cliente = 'exportador'
  AND id_cliente IN (SELECT id_cliente FROM permiso_exportacion GROUP BY id_cliente HAVING COUNT(*) > 3);
SELECT descuento, count(*) FROM cliente WHERE tipo_cliente = 'exportador' GROUP BY 1 ORDER BY 1;
ROLLBACK;
