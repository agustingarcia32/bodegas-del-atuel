-- =====================================================================
-- db_tests.sql  ·  Bodegas del Atuel  ·  Etapa 2
-- Al menos un caso por regla de negocio (RN-01 a RN-15).
--
-- Se corre sobre una base VACÍA con 001 a 006 aplicadas, como propietario:
--     psql -d bodegas -f tests/db_tests.sql
-- Cada línea de salida es PASA o FALLA. Al final hay un resumen.
-- Los casos que tienen que dar error lo prueban con la función
-- pg_temp.falla(descripcion, sentencia, sqlstate_esperado); si la sentencia
-- NO da error, o da otro, el caso FALLA. Deja datos de prueba en la base.
-- =====================================================================
\set ON_ERROR_STOP off
\set VERBOSITY terse
\pset format unaligned
\pset tuples_only on

CREATE TABLE pg_temp.resultado(ok boolean, detalle text);

-- Espera que la sentencia dé error con ese SQLSTATE.
CREATE FUNCTION pg_temp.falla(p_desc text, p_sql text, p_esperado text) RETURNS void
LANGUAGE plpgsql AS $$
DECLARE v_estado text; v_msg text;
BEGIN
    BEGIN
        EXECUTE p_sql;
        v_estado := 'sin error';
    EXCEPTION WHEN OTHERS THEN
        v_estado := SQLSTATE; v_msg := SQLERRM;
    END;
    INSERT INTO pg_temp.resultado VALUES (v_estado = p_esperado,
        CASE WHEN v_estado = p_esperado THEN 'PASA   ' || p_desc || '  [' || v_estado || ']'
             ELSE 'FALLA  ' || p_desc || '  (esperado ' || p_esperado || ', obtenido ' || v_estado || ')' END);
END $$;

-- Espera que la sentencia funcione.
CREATE FUNCTION pg_temp.anda(p_desc text, p_sql text) RETURNS void
LANGUAGE plpgsql AS $$
DECLARE v_msg text;
BEGIN
    BEGIN
        EXECUTE p_sql;
        INSERT INTO pg_temp.resultado VALUES (true, 'PASA   ' || p_desc);
    EXCEPTION WHEN OTHERS THEN
        INSERT INTO pg_temp.resultado VALUES (false, 'FALLA  ' || p_desc || '  (error ' || SQLSTATE || ': ' || SQLERRM || ')');
    END;
END $$;

-- Espera que la condición sea verdadera.
CREATE FUNCTION pg_temp.es(p_desc text, p_sql text) RETURNS void
LANGUAGE plpgsql AS $$
DECLARE v boolean;
BEGIN
    EXECUTE p_sql INTO v;
    INSERT INTO pg_temp.resultado VALUES (COALESCE(v, false),
        CASE WHEN COALESCE(v, false) THEN 'PASA   ' ELSE 'FALLA  ' END || p_desc);
EXCEPTION WHEN OTHERS THEN
    INSERT INTO pg_temp.resultado VALUES (false, 'FALLA  ' || p_desc || '  (error ' || SQLSTATE || ': ' || SQLERRM || ')');
END $$;

-- ---------------------------------------------------------------------
-- Datos base
-- ---------------------------------------------------------------------
INSERT INTO localidad(nombre,provincia,cod_postal,encargado_regional) VALUES
  ('San Rafael','Mendoza','5600','Enc Uno'), ('General Alvear','Mendoza','5620','Enc Dos');
INSERT INTO sala_venta(calle,numero,dia_cierre,id_localidad) VALUES ('Belgrano',100,'lunes',1);
INSERT INTO bodega VALUES ('30711111112','Bodega Uno','Domicilio 1');
INSERT INTO transportista(razon_social,cuit,email,telefono,domicilio) VALUES ('Trans SA','30722222223','a@b.com','260123','Dom');
INSERT INTO cepa(nombre,tipo) VALUES ('Malbec','tinta'),('Syrah','tinta');
INSERT INTO finca(nombre,superficie_ha,nombre_departamento,provincia) VALUES ('Finca 1',10,'San Rafael','Mendoza');
INSERT INTO parcela VALUES (1,1,2.5,2010,1);
INSERT INTO vino(nombre,tipo,anada,volumen_ml,graduacion,precio,cuit_bodega) VALUES
  ('Vino A','tinto',2021,750,14,1000,'30711111112'), ('Vino B','tinto',2022,750,13,500,'30711111112');
INSERT INTO composicion VALUES (1,1,60),(1,2,40),(2,1,100);
INSERT INTO cliente(nombre_razon_social,tipo_doc,nro_doc,direccion,tipo_cliente,id_localidad) VALUES
  ('Socio','DNI','1','d','socio',1),
  ('Distrib','CUIT','2','d','distribuidor',1),
  ('Export','CUIT','3','d','exportador',1);
INSERT INTO socio VALUES (1);
INSERT INTO distribuidor VALUES (2,'Zona sur','HAB-1');
INSERT INTO exportador VALUES (3,'Brasil');
INSERT INTO stock_sala VALUES (1,1,10);

\echo '=== RN-01 precio unico y mayor que cero ==='
SELECT pg_temp.falla('RN-01 precio 0 rechazado',
  $$INSERT INTO vino(nombre,tipo,anada,volumen_ml,graduacion,precio,cuit_bodega) VALUES ('X','tinto',2021,750,14,0,'30711111112')$$, '23514');
SELECT pg_temp.falla('RN-01 precio negativo rechazado',
  $$UPDATE vino SET precio = -5 WHERE cod_vino = 1$$, '23514');
SELECT pg_temp.es('RN-01 el precio es un atributo de vino: no existe precio por sala',
  $$SELECT NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name = 'stock_sala' AND column_name = 'precio')$$);

\echo '=== RN-02 sala en una sola localidad; localidad con un solo encargado ==='
SELECT pg_temp.falla('RN-02 sala con localidad inexistente (FK)',
  $$INSERT INTO sala_venta(calle,numero,dia_cierre,id_localidad) VALUES ('X',1,'lunes',999)$$, '23503');
SELECT pg_temp.falla('RN-02 sala sin localidad (NOT NULL)',
  $$INSERT INTO sala_venta(calle,numero,dia_cierre,id_localidad) VALUES ('X',1,'lunes',NULL)$$, '23502');
SELECT pg_temp.falla('RN-02 localidad repetida (nombre, provincia)',
  $$INSERT INTO localidad(nombre,provincia,cod_postal,encargado_regional) VALUES ('San Rafael','Mendoza','5601','Otro')$$, '23505');
SELECT pg_temp.es('RN-02 el encargado vive solo en localidad (3FN)',
  $$SELECT NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name = 'sala_venta' AND column_name LIKE '%encargado%')$$);

\echo '=== RN-03 empleado en una sola sala ==='
SELECT pg_temp.anda('RN-03 empleado con sala valida',
  $$INSERT INTO empleado VALUES ('20111111119','Ana',CURRENT_DATE,100000,1)$$);
SELECT pg_temp.falla('RN-03 empleado sin sala (NOT NULL)',
  $$INSERT INTO empleado VALUES ('20222222229','Beto',CURRENT_DATE,100000,NULL)$$, '23502');
SELECT pg_temp.falla('RN-03 empleado con sala inexistente (FK)',
  $$INSERT INTO empleado VALUES ('20333333339','Carla',CURRENT_DATE,100000,999)$$, '23503');

\echo '=== RN-04 parcela con una cepa; una cosecha por parcela y campania ==='
SELECT pg_temp.falla('RN-04 parcela sin cepa (NOT NULL)',
  $$INSERT INTO parcela VALUES (1,2,1,2010,NULL)$$, '23502');
SELECT pg_temp.anda('RN-04 primera cosecha de la parcela en 2025',
  $$INSERT INTO lote(id_finca,nro_parcela,campania,fecha_cosecha,kilos,cuit_bodega) VALUES (1,1,2025,'2025-03-10',1000,'30711111112')$$);
SELECT pg_temp.falla('RN-04 segunda cosecha de la misma parcela y campania',
  $$INSERT INTO lote(id_finca,nro_parcela,campania,fecha_cosecha,kilos,cuit_bodega) VALUES (1,1,2025,'2025-03-20',500,'30711111112')$$, '23505');
SELECT pg_temp.anda('RN-04 la misma parcela en otra campania si se puede',
  $$INSERT INTO lote(id_finca,nro_parcela,campania,fecha_cosecha,kilos,cuit_bodega) VALUES (1,1,2026,'2026-03-10',900,'30711111112')$$);

\echo '=== RN-05 los porcentajes de corte suman 100 (trigger diferido) ==='
-- el trigger es DEFERRABLE INITIALLY DEFERRED: se evalua al COMMIT.
-- Aca se lo fuerza con SET CONSTRAINTS ... IMMEDIATE dentro de la transaccion.
BEGIN;
INSERT INTO vino(nombre,tipo,anada,volumen_ml,graduacion,precio,cuit_bodega) VALUES ('Vino C','tinto',2023,750,14,900,'30711111112');
INSERT INTO composicion SELECT currval(pg_get_serial_sequence('vino','cod_vino')), 1, 70;
SELECT pg_temp.falla('RN-05 70 % no suma 100',
  $$SET CONSTRAINTS ALL IMMEDIATE$$, 'P0001');
ROLLBACK;
BEGIN;
INSERT INTO vino(nombre,tipo,anada,volumen_ml,graduacion,precio,cuit_bodega) VALUES ('Vino C','tinto',2023,750,14,900,'30711111112');
INSERT INTO composicion SELECT currval(pg_get_serial_sequence('vino','cod_vino')), 1, 70;
INSERT INTO composicion SELECT currval(pg_get_serial_sequence('vino','cod_vino')), 2, 30;
SELECT pg_temp.anda('RN-05 70 + 30 suma 100 (carga en etapas dentro de la transaccion)', $$SET CONSTRAINTS ALL IMMEDIATE$$);
COMMIT;
SELECT pg_temp.falla('RN-05 un porcentaje de 101 no entra (CHECK de rango)',
  $$INSERT INTO composicion VALUES (2,2,101)$$, '23514');

\echo '=== RN-06 descuento segun tipo de cliente ==='
SELECT pg_temp.es('RN-06 socio 10 %, distribuidor 20 %, exportador 30 %',
  $$SELECT (SELECT descuento FROM cliente WHERE id_cliente = 1) = 10
       AND (SELECT descuento FROM cliente WHERE id_cliente = 2) = 20
       AND (SELECT descuento FROM cliente WHERE id_cliente = 3) = 30$$);
SELECT pg_temp.es('RN-06 fn_descuento_cliente devuelve 10/20/30',
  $$SELECT fn_descuento_cliente('socio') = 10 AND fn_descuento_cliente('distribuidor') = 20 AND fn_descuento_cliente('exportador') = 30$$);
SELECT pg_temp.falla('RN-06 un tipo desconocido no tiene descuento',
  $$SELECT fn_descuento_cliente('mayorista')$$, '22023');
SELECT pg_temp.falla('RN-06 descuento fuera de 0..100 (CHECK de rango)',
  $$UPDATE cliente SET descuento = 150 WHERE id_cliente = 1$$, '23514');
SELECT pg_temp.anda('RN-06 cliente cargado sin descuento (NULL)',
  $$INSERT INTO cliente(nombre_razon_social,tipo_doc,nro_doc,direccion,tipo_cliente,id_localidad,descuento) VALUES ('Socio2','DNI','9','d','socio',1,NULL)$$);
SELECT pg_temp.es('RN-06 ...el trigger le puso el del tipo (10)',
  $$SELECT descuento = 10 FROM cliente WHERE nro_doc = '9'$$);

\echo '=== RN-07 permisos del exportador ==='
SELECT pg_temp.anda('RN-07 un exportador con dos permisos',
  $$INSERT INTO permiso_exportacion(id_cliente,fecha_emision,fecha_vencimiento) VALUES (3,'2026-01-01','2027-01-01'),(3,'2027-01-01','2028-01-01')$$);
SELECT pg_temp.falla('RN-07 vencimiento igual a la emision',
  $$INSERT INTO permiso_exportacion(id_cliente,fecha_emision,fecha_vencimiento) VALUES (3,'2026-01-01','2026-01-01')$$, '23514');
SELECT pg_temp.falla('RN-07 vencimiento anterior a la emision',
  $$INSERT INTO permiso_exportacion(id_cliente,fecha_emision,fecha_vencimiento) VALUES (3,'2026-06-01','2026-01-01')$$, '23514');
SELECT pg_temp.falla('RN-07 un socio no puede tener permisos (FK a exportador)',
  $$INSERT INTO permiso_exportacion(id_cliente,fecha_emision,fecha_vencimiento) VALUES (1,'2026-01-01','2027-01-01')$$, '23503');

\echo '=== RN-08 el total del comprobante lo calcula la base ==='
-- socio (10 %): vino A 1000, vino B 500
BEGIN;
INSERT INTO comprobante(id_cliente,id_sala) VALUES (1,1);
INSERT INTO stock_sala VALUES (1,2,10);
INSERT INTO renglon_comprobante(nro_comprobante,cod_vino,cantidad) VALUES (1,1,2),(1,2,1);
COMMIT;
-- 2 x 1000 = 2000 ; 1 x 500 = 500 ; bruto 2500 ; descuento 10 % = 250 ; total 2250
SELECT pg_temp.es('RN-08 subtotal 2500, descuento 250, total 2250',
  $$SELECT subtotal = 2500 AND descuento = 250 AND total = 2250 FROM comprobante WHERE nro_comprobante = 1$$);
SELECT pg_temp.es('RN-08 el total coincide con la suma de los renglones',
  $$SELECT total = (SELECT sum(subtotal) FROM renglon_comprobante WHERE nro_comprobante = 1) FROM comprobante WHERE nro_comprobante = 1$$);
SELECT pg_temp.falla('RN-08 un total cargado a mano incoherente se rechaza (CHECK)',
  $$UPDATE comprobante SET total = 1 WHERE nro_comprobante = 1$$, '23514');
SELECT pg_temp.es('RN-08 fn_total_comprobante da lo mismo',
  $$SELECT fn_total_comprobante(1) = 2250$$);

\echo '=== RN-09 no se vende mas de lo que hay; stock nunca negativo ==='
SELECT pg_temp.es('RN-09 la venta descuento el stock (10 - 2 = 8)',
  $$SELECT cantidad = 8 FROM stock_sala WHERE id_sala = 1 AND cod_vino = 1$$);
SELECT pg_temp.anda('RN-09 comprobante nuevo', $$INSERT INTO comprobante(id_cliente,id_sala) VALUES (1,1)$$);
SELECT pg_temp.falla('RN-09 vender 9 con 8 en stock',
  $$INSERT INTO renglon_comprobante(nro_comprobante,cod_vino,cantidad) VALUES (2,1,9)$$, 'P0001');
SELECT pg_temp.falla('RN-09 vender un vino que la sala no tiene',
  $$INSERT INTO renglon_comprobante(nro_comprobante,cod_vino,cantidad) VALUES (2,3,1)$$, 'P0001');
SELECT pg_temp.anda('RN-09 vender exactamente lo que hay (8)',
  $$INSERT INTO renglon_comprobante(nro_comprobante,cod_vino,cantidad) VALUES (2,1,8)$$);
SELECT pg_temp.es('RN-09 el stock quedo en 0, no negativo',
  $$SELECT cantidad = 0 FROM stock_sala WHERE id_sala = 1 AND cod_vino = 1$$);
SELECT pg_temp.falla('RN-09 CHECK: stock negativo directo',
  $$UPDATE stock_sala SET cantidad = -1 WHERE id_sala = 1 AND cod_vino = 1$$, '23514');

\echo '=== RN-10 ingresos: en_confeccion -> terminado -> procesado ==='
INSERT INTO ingreso(cod_transporte,cuit_bodega) VALUES (1,'30711111112');
INSERT INTO renglon_ingreso VALUES (1,1,50),(1,2,30);
SELECT pg_temp.es('RN-10 el ingreso nace en_confeccion y no toco el deposito',
  $$SELECT (SELECT estado FROM ingreso WHERE cod_ingreso = 1) = 'en_confeccion' AND NOT EXISTS (SELECT 1 FROM stock_deposito)$$);
SELECT pg_temp.falla('RN-10 en_confeccion -> procesado (saltea terminado)',
  $$UPDATE ingreso SET estado = 'procesado' WHERE cod_ingreso = 1$$, 'P0001');
SELECT pg_temp.falla('RN-10 no se puede procesar un ingreso que no esta terminado',
  $$CALL sp_procesar_ingreso(1)$$, 'P0001');
SELECT pg_temp.anda('RN-10 en_confeccion -> terminado', $$UPDATE ingreso SET estado = 'terminado' WHERE cod_ingreso = 1$$);
SELECT pg_temp.falla('RN-10 terminado -> procesado a mano (sin el procedimiento)',
  $$UPDATE ingreso SET estado = 'procesado' WHERE cod_ingreso = 1$$, 'P0001');
SELECT pg_temp.falla('RN-10 terminado -> en_confeccion (retroceso)',
  $$UPDATE ingreso SET estado = 'en_confeccion' WHERE cod_ingreso = 1$$, 'P0001');
SELECT pg_temp.es('RN-10 todavia no impacto en el deposito',
  $$SELECT NOT EXISTS (SELECT 1 FROM stock_deposito)$$);
SELECT pg_temp.anda('RN-10 sp_procesar_ingreso', $$CALL sp_procesar_ingreso(1)$$);
SELECT pg_temp.es('RN-10 deposito: vino A 50, vino B 30 y el ingreso quedo procesado',
  $$SELECT (SELECT cantidad FROM stock_deposito WHERE cod_vino = 1) = 50
       AND (SELECT cantidad FROM stock_deposito WHERE cod_vino = 2) = 30
       AND (SELECT estado FROM ingreso WHERE cod_ingreso = 1) = 'procesado'$$);
SELECT pg_temp.falla('RN-10 procesado no se procesa dos veces',
  $$CALL sp_procesar_ingreso(1)$$, 'P0001');
SELECT pg_temp.falla('RN-10 procesado -> terminado (retroceso)',
  $$UPDATE ingreso SET estado = 'terminado' WHERE cod_ingreso = 1$$, 'P0001');
SELECT pg_temp.falla('RN-10 estado inexistente (ENUM)',
  $$UPDATE ingreso SET estado = 'cancelado' WHERE cod_ingreso = 1$$, '22P02');

\echo '=== RN-11 transferencias: estados y fecha de confeccion ==='
INSERT INTO transferencia(id_sala) VALUES (1);
INSERT INTO renglon_transferencia VALUES (1,1,20);
SELECT pg_temp.es('RN-11 la fecha de confeccion es la de hoy',
  $$SELECT fecha_confeccion = CURRENT_DATE FROM transferencia WHERE nro_solicitud = 1$$);
SELECT pg_temp.anda('RN-11 insertar con otra fecha: se pisa por la de hoy',
  $$INSERT INTO transferencia(id_sala, fecha_confeccion) VALUES (1, DATE '2020-01-01')$$);
SELECT pg_temp.es('RN-11 ...quedo con la fecha de hoy',
  $$SELECT fecha_confeccion = CURRENT_DATE FROM transferencia WHERE nro_solicitud = 2$$);
SELECT pg_temp.falla('RN-11 la fecha de confeccion no se modifica',
  $$UPDATE transferencia SET fecha_confeccion = DATE '2020-01-01' WHERE nro_solicitud = 1$$, 'P0001');
SELECT pg_temp.falla('RN-11 en_confeccion -> procesado',
  $$UPDATE transferencia SET estado = 'procesado' WHERE nro_solicitud = 1$$, 'P0001');
SELECT pg_temp.anda('RN-11 en_confeccion -> terminado', $$UPDATE transferencia SET estado = 'terminado' WHERE nro_solicitud = 1$$);
SELECT pg_temp.anda('RN-11 sp_procesar_transferencia', $$CALL sp_procesar_transferencia(1)$$);
SELECT pg_temp.es('RN-11 deposito 50 - 20 = 30 y sala 0 + 20 = 20',
  $$SELECT (SELECT cantidad FROM stock_deposito WHERE cod_vino = 1) = 30
       AND (SELECT cantidad FROM stock_sala WHERE id_sala = 1 AND cod_vino = 1) = 20$$);
SELECT pg_temp.falla('RN-11 procesado -> terminado (retroceso)',
  $$UPDATE transferencia SET estado = 'terminado' WHERE nro_solicitud = 1$$, 'P0001');
-- transferencia que pide mas de lo que hay en el deposito
INSERT INTO transferencia(id_sala) VALUES (1);
INSERT INTO renglon_transferencia VALUES (3,1,999);
UPDATE transferencia SET estado = 'terminado' WHERE nro_solicitud = 3;
SELECT pg_temp.falla('RN-11 transferencia mayor al stock del deposito (hay 30, pide 999)',
  $$CALL sp_procesar_transferencia(3)$$, 'P0001');

\echo '=== RN-12 documentos que no estan en confeccion no admiten cambios de renglones ==='
-- ingreso 1 ya esta procesado; transferencia 3 esta terminada
SELECT pg_temp.falla('RN-12 agregar renglon a un ingreso procesado',
  $$INSERT INTO renglon_ingreso VALUES (1,3,5)$$, 'P0001');
SELECT pg_temp.falla('RN-12 modificar renglon de un ingreso procesado',
  $$UPDATE renglon_ingreso SET cantidad = 99 WHERE cod_ingreso = 1 AND cod_vino = 1$$, 'P0001');
SELECT pg_temp.falla('RN-12 quitar renglon de un ingreso procesado',
  $$DELETE FROM renglon_ingreso WHERE cod_ingreso = 1 AND cod_vino = 1$$, 'P0001');
SELECT pg_temp.falla('RN-12 modificar renglon de una transferencia terminada',
  $$UPDATE renglon_transferencia SET cantidad = 1 WHERE nro_solicitud = 3$$, 'P0001');
SELECT pg_temp.falla('RN-12 quitar renglon de una transferencia terminada',
  $$DELETE FROM renglon_transferencia WHERE nro_solicitud = 3$$, 'P0001');
INSERT INTO ingreso(cod_transporte,cuit_bodega) VALUES (1,'30711111112');
SELECT pg_temp.anda('RN-12 en confeccion si admite renglones',
  $$INSERT INTO renglon_ingreso VALUES (2,1,5)$$);
SELECT pg_temp.anda('RN-12 borrar un documento en confeccion arrastra sus renglones',
  $$DELETE FROM ingreso WHERE cod_ingreso = 2$$);

\echo '=== RN-13 auditoria de cambios de precio ==='
SELECT pg_temp.anda('RN-13 cambiar el precio del vino 1', $$UPDATE vino SET precio = 1200 WHERE cod_vino = 1$$);
SELECT pg_temp.es('RN-13 quedo una fila con precio anterior 1000, nuevo 1200 y el usuario',
  $$SELECT count(*) = 1 AND bool_and(precio_anterior = 1000 AND precio_nuevo = 1200 AND usuario = current_user AND fecha_hora IS NOT NULL) FROM auditoria_precio WHERE cod_vino = 1$$);
SELECT pg_temp.anda('RN-13 actualizar con el mismo precio', $$UPDATE vino SET precio = 1200 WHERE cod_vino = 1$$);
SELECT pg_temp.anda('RN-13 cambiar solo el nombre', $$UPDATE vino SET nombre = 'Vino A2' WHERE cod_vino = 1$$);
SELECT pg_temp.es('RN-13 ...y no genero auditoria (sigue 1 fila)',
  $$SELECT count(*) = 1 FROM auditoria_precio WHERE cod_vino = 1$$);
SELECT pg_temp.falla('RN-13 no se registra "cambio" a un precio igual (CHECK de la auditoria)',
  $$INSERT INTO auditoria_precio(cod_vino,precio_anterior,precio_nuevo) VALUES (1,5,5)$$, '23514');

\echo '=== RN-14 no se borra lo que tiene movimientos ==='
SELECT pg_temp.falla('RN-14 borrar un vino con ventas',
  $$DELETE FROM vino WHERE cod_vino = 1$$, '23503');
SELECT pg_temp.falla('RN-14 borrar una bodega con vinos',
  $$DELETE FROM bodega WHERE cuit = '30711111112'$$, '23503');
SELECT pg_temp.falla('RN-14 borrar un transportista con ingresos',
  $$DELETE FROM transportista WHERE cod_transporte = 1$$, '23503');
SELECT pg_temp.anda('RN-14 un vino sin movimientos si se borra',
  $$INSERT INTO vino(nombre,tipo,anada,volumen_ml,graduacion,precio,cuit_bodega) VALUES ('Sin uso','blanco',2020,750,12,300,'30711111112')$$);
SELECT pg_temp.anda('RN-14 ...se borra', $$DELETE FROM vino WHERE nombre = 'Sin uso'$$);

\echo '=== RN-15 cantidades, superficies, kilos y precios positivos; graduacion 5 a 20 ==='
SELECT pg_temp.falla('RN-15 graduacion 4.9', $$UPDATE vino SET graduacion = 4.9 WHERE cod_vino = 2$$, '23514');
SELECT pg_temp.falla('RN-15 graduacion 20.1', $$UPDATE vino SET graduacion = 20.1 WHERE cod_vino = 2$$, '23514');
SELECT pg_temp.anda('RN-15 graduacion 5 y 20 son validas',
  $$UPDATE vino SET graduacion = 5 WHERE cod_vino = 2; UPDATE vino SET graduacion = 20 WHERE cod_vino = 2; UPDATE vino SET graduacion = 13 WHERE cod_vino = 2$$);
SELECT pg_temp.falla('RN-15 superficie de finca 0', $$UPDATE finca SET superficie_ha = 0 WHERE id_finca = 1$$, '23514');
SELECT pg_temp.falla('RN-15 superficie de parcela negativa', $$UPDATE parcela SET superficie = -1 WHERE id_finca = 1$$, '23514');
SELECT pg_temp.falla('RN-15 kilos 0', $$UPDATE lote SET kilos = 0 WHERE nro_lote = 1$$, '23514');
SELECT pg_temp.falla('RN-15 salario 0', $$UPDATE empleado SET salario = 0$$, '23514');
SELECT pg_temp.falla('RN-15 cantidad de renglon de ingreso 0',
  $$INSERT INTO ingreso(cod_transporte,cuit_bodega) VALUES (1,'30711111112'); INSERT INTO renglon_ingreso VALUES (currval(pg_get_serial_sequence('ingreso','cod_ingreso')),1,0)$$, '23514');
SELECT pg_temp.falla('RN-15 cantidad de venta 0',
  $$INSERT INTO renglon_comprobante(nro_comprobante,cod_vino,cantidad,precio_unitario,descuento,subtotal) VALUES (2,2,0,500,10,0)$$, '23514');
SELECT pg_temp.falla('RN-15 stock negativo', $$UPDATE stock_sala SET cantidad = -5$$, '23514');

-- ---------------------------------------------------------------------
-- Resumen
-- ---------------------------------------------------------------------
\echo
\echo '=================== RESULTADO ==================='
SELECT detalle FROM pg_temp.resultado ORDER BY ctid;
SELECT '--- ' || count(*) FILTER (WHERE ok) || ' pasan, ' || count(*) FILTER (WHERE NOT ok) || ' fallan, de ' || count(*) FROM pg_temp.resultado;
