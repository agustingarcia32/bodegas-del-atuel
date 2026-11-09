-- =====================================================================
-- delete.sql · Etapa 5 · D1 a D6
-- Cada consigna corre dentro de BEGIN ... ROLLBACK (control previo, sentencia,
-- control posterior). Para guardar de verdad, cambiar ROLLBACK por COMMIT.
-- "PARAMETRO" marca los valores que se cambian.
--   psql -d bodegas -f consultas/delete.sql
-- =====================================================================
\set ON_ERROR_STOP on
\pset format aligned

-- ---------------------------------------------------------------------
-- D1  Borrar los comprobantes con mas de 5 anios de antiguedad asociados a clientes socios.
-- Estrategia: DELETE ... USING cliente para filtrar por tipo. Los renglones se borran solos
-- por ON DELETE CASCADE. El stock NO se devuelve: son ventas historicas que ya salieron
-- (el trigger de renglones no repone stock al borrar, a proposito).
-- ---------------------------------------------------------------------
\echo '=== D1 ==='
BEGIN;
SELECT (SELECT count(*) FROM comprobante) AS comprobantes_antes, (SELECT count(*) FROM renglon_comprobante) AS renglones_antes;
DELETE FROM comprobante c
USING cliente k
WHERE k.id_cliente = c.id_cliente
  AND k.tipo_cliente = 'socio'
  AND c.fecha < CURRENT_DATE - INTERVAL '5 years';
SELECT (SELECT count(*) FROM comprobante) AS comprobantes_despues, (SELECT count(*) FROM renglon_comprobante) AS renglones_despues;
ROLLBACK;

-- ---------------------------------------------------------------------
-- D2  Eliminar las cepas que no componen ningun vino ni estan plantadas en ninguna parcela.
-- Estrategia: dos NOT EXISTS (anti-join). Las FK son ON DELETE RESTRICT, asi que borrar una
-- cepa en uso fallaria: el filtro garantiza que solo se intentan las libres.
-- En el dataset las 12 cepas se usan, por eso la prueba agrega primero una cepa libre.
-- ---------------------------------------------------------------------
\echo '=== D2 ==='
BEGIN;
INSERT INTO cepa (nombre, tipo) VALUES ('Cepa sin usar (prueba)', 'tinta');     -- solo para esta prueba
SELECT count(*) AS cepas_antes FROM cepa;
DELETE FROM cepa c
WHERE NOT EXISTS (SELECT 1 FROM composicion co WHERE co.id_cepa = c.id_cepa)
  AND NOT EXISTS (SELECT 1 FROM parcela p WHERE p.id_cepa = c.id_cepa);
SELECT count(*) AS cepas_despues FROM cepa;
ROLLBACK;

-- ---------------------------------------------------------------------
-- D3  La sala de una localidad fue dada de baja: eliminar los empleados de esa sala que
--     trabajaron menos de dos anios.
-- PARAMETRO: nombre de la localidad.
-- Estrategia: subconsulta IN para pasar de la localidad a sus salas y fn_antiguedad_anios < 2.
-- Los empleados no tienen dependientes, no hay cascadas. (La sala en si no se borra: tiene
-- comprobantes y stock, la FK lo impide por RN-14/RESTRICT.)
-- ---------------------------------------------------------------------
\echo '=== D3 ==='
BEGIN;
SELECT count(*) AS empleados_de_la_localidad,
       count(*) FILTER (WHERE fn_antiguedad_anios(fecha_ingreso) < 2) AS con_menos_de_2_anios
FROM empleado WHERE id_sala IN (SELECT id_sala FROM sala_venta WHERE id_localidad = (SELECT id_localidad FROM localidad WHERE nombre = 'Guaymallén'));  -- PARAMETRO
DELETE FROM empleado
WHERE id_sala IN (SELECT s.id_sala FROM sala_venta s JOIN localidad l USING (id_localidad) WHERE l.nombre = 'Guaymallén')   -- PARAMETRO
  AND fn_antiguedad_anios(fecha_ingreso) < 2;
SELECT count(*) AS empleados_de_la_localidad_despues
FROM empleado WHERE id_sala IN (SELECT id_sala FROM sala_venta WHERE id_localidad = (SELECT id_localidad FROM localidad WHERE nombre = 'Guaymallén'));
ROLLBACK;

-- ---------------------------------------------------------------------
-- D4  Borrar los clientes socios que nunca compraron y se dieron de alta hace mas de 5 anios.
-- Estrategia: NOT EXISTS sobre comprobante (anti-join; usa idx_comprobante_cliente_fecha).
-- La fila de socio se borra por ON DELETE CASCADE.
-- ---------------------------------------------------------------------
\echo '=== D4 ==='
BEGIN;
SELECT (SELECT count(*) FROM cliente) AS clientes_antes, (SELECT count(*) FROM socio) AS socios_antes;
DELETE FROM cliente k
WHERE k.tipo_cliente = 'socio'
  AND k.fecha_alta < CURRENT_DATE - INTERVAL '5 years'
  AND NOT EXISTS (SELECT 1 FROM comprobante c WHERE c.id_cliente = k.id_cliente);
SELECT (SELECT count(*) FROM cliente) AS clientes_despues, (SELECT count(*) FROM socio) AS socios_despues;
ROLLBACK;

-- ---------------------------------------------------------------------
-- D5  Eliminar los ingresos en estado procesado de hace mas de 365 dias.
-- Estrategia: DELETE directo con estado y fecha. Los renglones se borran por CASCADE y el
-- trigger RN-12 lo permite porque en ese momento la cabecera ya no existe (esa es la excepcion
-- del trigger). Ojo: el stock del deposito NO se revierte (es historia ya aplicada).
-- ---------------------------------------------------------------------
\echo '=== D5 ==='
BEGIN;
SELECT (SELECT count(*) FROM ingreso) AS ingresos_antes, (SELECT count(*) FROM renglon_ingreso) AS renglones_antes,
       (SELECT sum(cantidad) FROM stock_deposito) AS deposito_antes;
DELETE FROM ingreso WHERE estado = 'procesado' AND fecha < CURRENT_DATE - 365;
SELECT (SELECT count(*) FROM ingreso) AS ingresos_despues, (SELECT count(*) FROM renglon_ingreso) AS renglones_despues,
       (SELECT sum(cantidad) FROM stock_deposito) AS deposito_despues;
ROLLBACK;

-- ---------------------------------------------------------------------
-- D6  Borrar los clientes socios sin compras que viven en una localidad especifica.
-- PARAMETRO: nombre de la localidad.
-- Estrategia: igual que D4 (NOT EXISTS) con la localidad como filtro, usando
-- idx_cliente_localidad.
-- ---------------------------------------------------------------------
\echo '=== D6 ==='
BEGIN;
SELECT count(*) AS socios_sin_compras_en_la_localidad
FROM cliente k JOIN localidad l USING (id_localidad)
WHERE k.tipo_cliente = 'socio' AND l.nombre = 'Uspallata'                                                  -- PARAMETRO
  AND NOT EXISTS (SELECT 1 FROM comprobante c WHERE c.id_cliente = k.id_cliente);
DELETE FROM cliente k
USING localidad l
WHERE l.id_localidad = k.id_localidad AND l.nombre = 'Uspallata'                                           -- PARAMETRO
  AND k.tipo_cliente = 'socio'
  AND NOT EXISTS (SELECT 1 FROM comprobante c WHERE c.id_cliente = k.id_cliente);
SELECT count(*) AS socios_de_la_localidad_despues
FROM cliente k JOIN localidad l USING (id_localidad) WHERE k.tipo_cliente = 'socio' AND l.nombre = 'Uspallata';
ROLLBACK;
