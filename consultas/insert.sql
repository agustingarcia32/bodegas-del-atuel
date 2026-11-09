-- =====================================================================
-- insert.sql · Etapa 5 · I1 a I6
-- Cada consigna corre dentro de BEGIN ... ROLLBACK (control previo, sentencia,
-- control posterior). Para guardar de verdad, cambiar ROLLBACK por COMMIT.
-- "PARAMETRO" marca los valores que se cambian.
--   psql -d bodegas -f consultas/insert.sql
-- =====================================================================
\set ON_ERROR_STOP on
\pset format aligned

-- ---------------------------------------------------------------------
-- I1  Insertar en transportista_localidad una nueva cobertura que vincule la localidad
--     de General Alvear con el transportista que menos envios (ingresos trasladados)
--     haya realizado en el ultimo trimestre.
-- Estrategia: LEFT JOIN desde transportista a los ingresos del trimestre (los que no
-- trasladaron nada cuentan 0), ORDER BY cantidad, codigo LIMIT 1. INSERT ... SELECT con
-- ON CONFLICT DO NOTHING: si ese transportista ya cubria General Alvear no hace nada
-- (la PK evita duplicados) en vez de fallar.
-- ---------------------------------------------------------------------
\echo '=== I1 ==='
BEGIN;
SELECT count(*) AS coberturas_antes FROM transportista_localidad;
WITH menos_envios AS (
    SELECT t.cod_transporte, COUNT(i.cod_ingreso) AS envios
    FROM transportista t
    LEFT JOIN ingreso i ON i.cod_transporte = t.cod_transporte
                       AND i.fecha >= CURRENT_DATE - INTERVAL '3 months'
    GROUP BY t.cod_transporte
    ORDER BY envios, t.cod_transporte
    LIMIT 1
)
INSERT INTO transportista_localidad (cod_transporte, id_localidad)
SELECT m.cod_transporte, l.id_localidad
FROM menos_envios m, localidad l
WHERE l.nombre = 'General Alvear'                      -- PARAMETRO
ON CONFLICT DO NOTHING
RETURNING cod_transporte, id_localidad;
SELECT count(*) AS coberturas_despues FROM transportista_localidad;
ROLLBACK;

-- ---------------------------------------------------------------------
-- I2  Si existe algun vino tinto con graduacion de 14 grados o mas, crear el maridaje
--     "cordero al disco" y asociarlo a todos los vinos que cumplan esa condicion.
-- Estrategia: dos INSERT encadenados en un solo statement con CTE de escritura: el primero
-- crea el maridaje solo si la condicion existe (INSERT ... SELECT ... WHERE EXISTS) y
-- devuelve su id con RETURNING; el segundo usa ese id para llenar vino_maridaje.
-- Si el maridaje ya existiera, el UNIQUE uq_maridaje_nombre haria fallar la sentencia.
-- ---------------------------------------------------------------------
\echo '=== I2 ==='
BEGIN;
SELECT count(*) AS tintos_14_o_mas FROM vino WHERE tipo = 'tinto' AND graduacion >= 14;
WITH nuevo AS (
    INSERT INTO maridaje (nombre, temperatura_servicio)
    SELECT 'Cordero al disco', 17
    WHERE EXISTS (SELECT 1 FROM vino WHERE tipo = 'tinto' AND graduacion >= 14)
    RETURNING id_maridaje
)
INSERT INTO vino_maridaje (cod_vino, id_maridaje)
SELECT v.cod_vino, n.id_maridaje
FROM vino v CROSS JOIN nuevo n
WHERE v.tipo = 'tinto' AND v.graduacion >= 14;
SELECT count(*) AS vinos_con_cordero_al_disco
FROM vino_maridaje vm JOIN maridaje m USING (id_maridaje) WHERE m.nombre = 'Cordero al disco';
ROLLBACK;

-- ---------------------------------------------------------------------
-- I3  Crear un comprobante con tres renglones para un cliente dado, en la sala con ID 1,
--     dentro de una transaccion y usando las funciones de calculo.
-- PARAMETRO: id_cliente (1 es un socio).
-- Estrategia: el comprobante se inserta sin importes (los llena la base). Los tres renglones
-- se cargan solo con vino y cantidad: trg_renglon_valida_stock comprueba el stock (RN-09), pone
-- precio, descuento del cliente y subtotal con fn_subtotal_renglon, y trg_renglon_stock_totales
-- descuenta el stock y recalcula subtotal / descuento / total del comprobante (RN-08).
-- Los vinos se eligen de los que la sala 1 tiene en stock. Al final se compara el total guardado
-- con fn_total_comprobante().
-- ---------------------------------------------------------------------
\echo '=== I3 ==='
BEGIN;
INSERT INTO comprobante (id_cliente, id_sala) VALUES (1, 1);                       -- PARAMETRO: cliente
SELECT currval(pg_get_serial_sequence('comprobante', 'nro_comprobante')) AS nro_comprobante \gset
CREATE TEMP TABLE i3_stock_antes AS SELECT cod_vino, cantidad FROM stock_sala WHERE id_sala = 1;
INSERT INTO renglon_comprobante (nro_comprobante, cod_vino, cantidad)
SELECT :nro_comprobante, cod_vino, 2
FROM stock_sala WHERE id_sala = 1 AND cantidad >= 2
ORDER BY cod_vino LIMIT 3;
SELECT r.cod_vino, r.cantidad, r.precio_unitario, r.descuento AS descuento_pct, r.subtotal,
       s.cantidad AS stock_ahora, a.cantidad AS stock_antes
FROM renglon_comprobante r
JOIN stock_sala s ON s.id_sala = 1 AND s.cod_vino = r.cod_vino
JOIN i3_stock_antes a ON a.cod_vino = r.cod_vino
WHERE r.nro_comprobante = :nro_comprobante ORDER BY r.cod_vino;
SELECT c.subtotal, c.descuento, c.total, fn_total_comprobante(c.nro_comprobante) AS total_con_funcion,
       c.total = fn_total_comprobante(c.nro_comprobante) AS coincide
FROM comprobante c WHERE c.nro_comprobante = :nro_comprobante;
ROLLBACK;

-- ---------------------------------------------------------------------
-- I4  Insertar una nueva bodega.
-- Estrategia: INSERT simple. El CUIT debe tener 11 digitos (dominio cuit_dom) y no repetirse (PK).
-- ---------------------------------------------------------------------
\echo '=== I4 ==='
BEGIN;
SELECT count(*) AS bodegas_antes FROM bodega;
INSERT INTO bodega (cuit, razon_social, domicilio)
VALUES ('30712345679', 'Bodega Vista al Diamante', 'Ruta 143 km 12, San Rafael');       -- PARAMETRO
SELECT count(*) AS bodegas_despues FROM bodega;
ROLLBACK;

-- ---------------------------------------------------------------------
-- I5  Insertar una nueva sala de venta.
-- Estrategia: el id es identity (lo genera la base). La localidad se busca por nombre
-- con una subconsulta; dia_cierre debe ser uno de los 7 dias que acepta el CHECK.
-- ---------------------------------------------------------------------
\echo '=== I5 ==='
BEGIN;
SELECT count(*) AS salas_antes FROM sala_venta;
INSERT INTO sala_venta (calle, numero, dia_cierre, id_localidad)
VALUES ('Av. Hipolito Yrigoyen', 1250, 'domingo',
        (SELECT id_localidad FROM localidad WHERE nombre = 'San Rafael'))                -- PARAMETRO
RETURNING id_sala, calle, numero, dia_cierre, id_localidad;
SELECT count(*) AS salas_despues FROM sala_venta;
ROLLBACK;

-- ---------------------------------------------------------------------
-- I6  Crear un ingreso en confeccion de 120 botellas de un vino determinado (por ejemplo
--     "Malbec Reserva" de 750 ml), elaborado por una bodega dada y trasladado por un
--     transportista dado.
-- PARAMETROS: nombre del vino, volumen, razon social del transportista. (Si el vino existe en
-- varias anadas se toma la mas reciente; con eso el INSERT crea UN solo ingreso.)
-- Estrategia: CTE de escritura: el primer INSERT crea la cabecera del ingreso (estado y fecha
-- salen de los DEFAULT: en_confeccion y hoy) tomando la bodega del propio vino, y el
-- segundo carga el renglon con 120 botellas. Como el documento esta en confeccion, el trigger
-- RN-12 admite renglones; el deposito NO cambia hasta que se procese (RN-10).
-- ---------------------------------------------------------------------
\echo '=== I6 ==='
BEGIN;
SELECT count(*) AS ingresos_antes, (SELECT cantidad FROM stock_deposito WHERE cod_vino = 26) AS deposito_antes FROM ingreso;
WITH v AS (
    SELECT cod_vino, cuit_bodega FROM vino
    WHERE nombre = 'Tradición Malbec del Cañón' AND volumen_ml = 750                      -- PARAMETRO
    ORDER BY anada DESC LIMIT 1          -- el nombre se repite en varias anadas: se toma la mas nueva
), cab AS (
    INSERT INTO ingreso (cod_transporte, cuit_bodega)
    SELECT t.cod_transporte, v.cuit_bodega
    FROM v, transportista t WHERE t.razon_social = 'Transportes del Atuel SRL'            -- PARAMETRO
    RETURNING cod_ingreso
)
INSERT INTO renglon_ingreso (cod_ingreso, cod_vino, cantidad)
SELECT cab.cod_ingreso, v.cod_vino, 120 FROM cab, v;
SELECT i.cod_ingreso, i.estado, i.fecha, b.razon_social AS bodega, t.razon_social AS transportista, r.cod_vino, r.cantidad
FROM ingreso i JOIN bodega b ON b.cuit = i.cuit_bodega JOIN transportista t USING (cod_transporte)
JOIN renglon_ingreso r USING (cod_ingreso)
WHERE i.cod_ingreso = (SELECT max(cod_ingreso) FROM ingreso);
SELECT count(*) AS ingresos_despues, (SELECT cantidad FROM stock_deposito WHERE cod_vino = 26) AS deposito_despues FROM ingreso;
ROLLBACK;
