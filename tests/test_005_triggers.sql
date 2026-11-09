\set ON_ERROR_STOP off
\set VERBOSITY terse
\pset format unaligned
\pset tuples_only on

CREATE FUNCTION pg_temp.chk(label text, ok boolean) RETURNS text
LANGUAGE sql AS $$ SELECT CASE WHEN COALESCE(ok, false) THEN 'PASA  ' ELSE 'FALLA ' END || label $$;

-- ejecuta un statement y devuelve 'OK' o 'SQLSTATE mensaje'
CREATE FUNCTION pg_temp.run(stmt text) RETURNS text
LANGUAGE plpgsql AS $$
BEGIN EXECUTE stmt; RETURN 'OK';
EXCEPTION WHEN OTHERS THEN RETURN SQLSTATE || ' ' || SQLERRM; END $$;

-- ---------- datos base ----------
INSERT INTO localidad(nombre,provincia,cod_postal,encargado_regional) VALUES ('San Rafael','Mendoza','5600','Enc');
INSERT INTO sala_venta(calle,numero,dia_cierre,id_localidad) VALUES ('Belgrano',100,'lunes',1);
INSERT INTO bodega VALUES ('30711111112','Bodega Uno','Domicilio 1');
INSERT INTO transportista(razon_social,cuit,email,telefono,domicilio) VALUES ('Trans SA','30722222223','a@b.com','260123','Dom');
INSERT INTO vino(nombre,tipo,anada,volumen_ml,graduacion,precio,cuit_bodega) VALUES
  ('V1','tinto',2021,750,14,1000.00,'30711111112'),
  ('V2','tinto',2022,750,14,500.50,'30711111112'),
  ('V3','blanco',2023,750,13,800.00,'30711111112');
INSERT INTO cepa(nombre,tipo) VALUES ('Malbec','tinta'),('Syrah','tinta'),('Merlot','tinta');

\echo '=== RN-06: descuento del cliente ==='
INSERT INTO cliente(nombre_razon_social,tipo_doc,nro_doc,direccion,tipo_cliente,id_localidad) VALUES
  ('Socio 1','DNI','1','d','socio',1),
  ('Distrib 1','DNI','2','d','distribuidor',1),
  ('Export 1','DNI','3','d','exportador',1);
INSERT INTO cliente(nombre_razon_social,tipo_doc,nro_doc,direccion,tipo_cliente,descuento,id_localidad)
  VALUES ('Export 2','DNI','4','d','exportador',35,1);
SELECT pg_temp.chk('sin descuento: socio 10, distribuidor 20, exportador 30',
  (SELECT array_agg(descuento ORDER BY id_cliente) FROM cliente WHERE id_cliente <= 3) = ARRAY[10,20,30]::numeric[]);
SELECT pg_temp.chk('con descuento explicito (35) se respeta', (SELECT descuento FROM cliente WHERE id_cliente = 4) = 35);

\echo '=== subtipos de cliente ==='
SELECT pg_temp.chk('socio en tabla socio: OK',           pg_temp.run($$INSERT INTO socio VALUES (1)$$) = 'OK');
SELECT pg_temp.chk('exportador en tabla socio: falla',   pg_temp.run($$INSERT INTO socio VALUES (3)$$) LIKE 'P0001%');
SELECT pg_temp.chk('socio en tabla exportador: falla',   pg_temp.run($$INSERT INTO exportador VALUES (1,'Chile')$$) LIKE 'P0001%');
SELECT pg_temp.chk('exportador en tabla exportador: OK', pg_temp.run($$INSERT INTO exportador VALUES (3,'Brasil')$$) = 'OK');
SELECT pg_temp.chk('cambiar tipo de un cliente que ya tiene subtipo: falla',
  pg_temp.run($$UPDATE cliente SET tipo_cliente = 'socio' WHERE id_cliente = 3$$) LIKE 'P0001%');
SELECT pg_temp.chk('cambiar tipo de un cliente SIN subtipo: OK (cliente 2)',
  pg_temp.run($$UPDATE cliente SET tipo_cliente = 'socio' WHERE id_cliente = 2$$) = 'OK');
UPDATE cliente SET tipo_cliente = 'distribuidor' WHERE id_cliente = 2;

\echo '=== RN-09 / RN-08: venta ==='
-- stock sala 1: v1=10, v2=5 ; v3 sin fila
INSERT INTO stock_sala VALUES (1,1,10),(1,2,5);
INSERT INTO comprobante(id_cliente,id_sala) VALUES (1,1);   -- cliente socio, descuento 10
INSERT INTO renglon_comprobante(nro_comprobante,cod_vino,cantidad) VALUES (1,1,3);
SELECT pg_temp.chk('renglon: precio del vino (1000), descuento del cliente (10), subtotal neto 2700',
  (SELECT precio_unitario = 1000 AND descuento = 10 AND subtotal = 2700
     FROM renglon_comprobante WHERE nro_comprobante = 1 AND cod_vino = 1));
SELECT pg_temp.chk('stock de la sala bajo de 10 a 7', fn_stock_sala(1,1) = 7);
SELECT pg_temp.chk('comprobante: bruto 3000, descuento 300, total 2700',
  (SELECT subtotal = 3000 AND descuento = 300 AND total = 2700 FROM comprobante WHERE nro_comprobante = 1));

-- subtotal / precio pasados "a mano" se ignoran
INSERT INTO renglon_comprobante(nro_comprobante,cod_vino,cantidad,precio_unitario,descuento,subtotal) VALUES (1,2,2,1,99,1);
SELECT pg_temp.chk('precio/descuento/subtotal cargados a mano se pisan: 2 x 500.50 con 10% = 900.90',
  (SELECT precio_unitario = 500.50 AND descuento = 10 AND subtotal = 900.90
     FROM renglon_comprobante WHERE nro_comprobante = 1 AND cod_vino = 2));
SELECT pg_temp.chk('comprobante: bruto 4001.00, total 3600.90, descuento 400.10',
  (SELECT subtotal = 4001.00 AND total = 3600.90 AND descuento = 400.10 FROM comprobante WHERE nro_comprobante = 1));
SELECT pg_temp.chk('stock v2 bajo de 5 a 3', fn_stock_sala(1,2) = 3);

SELECT pg_temp.chk('vender mas de lo que hay (v1 tiene 7, pido 8): falla',
  pg_temp.run($$INSERT INTO renglon_comprobante(nro_comprobante,cod_vino,cantidad) VALUES (1,1,8)$$) LIKE 'P0001%Stock insuficiente%');
SELECT pg_temp.chk('vino sin fila de stock en la sala (v3): falla',
  pg_temp.run($$INSERT INTO renglon_comprobante(nro_comprobante,cod_vino,cantidad) VALUES (1,3,1)$$) LIKE 'P0001%Stock insuficiente%');
SELECT pg_temp.chk('tras los rechazos no cambio nada: stock v1=7 y 2 renglones',
  fn_stock_sala(1,1) = 7 AND (SELECT count(*) FROM renglon_comprobante) = 2);
INSERT INTO comprobante(id_cliente,id_sala) VALUES (1,1);
INSERT INTO renglon_comprobante(nro_comprobante,cod_vino,cantidad) VALUES (2,1,7);
SELECT pg_temp.chk('vender exactamente todo lo que queda (v1: 7) deja stock 0 y no falla',
  fn_stock_sala(1,1) = 0 AND (SELECT count(*) FROM renglon_comprobante WHERE nro_comprobante = 2) = 1);

-- U1: cambiar el descuento de un renglon recalcula subtotal y comprobante
UPDATE renglon_comprobante SET descuento = 20 WHERE nro_comprobante = 1 AND cod_vino = 1;
SELECT pg_temp.chk('U1: renglon con 20% -> 3 x 1000 = 2400; comprobante 1 total 2400 + 900.90 = 3300.90',
  (SELECT subtotal = 2400 FROM renglon_comprobante WHERE nro_comprobante = 1 AND cod_vino = 1)
  AND (SELECT total = 3300.90 AND subtotal = 4001.00 AND descuento = 700.10 FROM comprobante WHERE nro_comprobante = 1));
SELECT pg_temp.chk('cambiar la cantidad de un renglon: falla',
  pg_temp.run($$UPDATE renglon_comprobante SET cantidad = 1 WHERE nro_comprobante = 1 AND cod_vino = 1$$) LIKE 'P0001%');

-- borrar un renglon: recalcula el comprobante y NO devuelve stock
DELETE FROM renglon_comprobante WHERE nro_comprobante = 1 AND cod_vino = 2;
SELECT pg_temp.chk('borrar un renglon: comprobante 1 queda en total 2400 y el stock NO se devuelve (v2 sigue en 3)',
  (SELECT total = 2400 AND subtotal = 3000 AND descuento = 600 FROM comprobante WHERE nro_comprobante = 1)
  AND fn_stock_sala(1,2) = 3);

-- D1: borrar un comprobante con renglones no da error (cascada)
DELETE FROM comprobante WHERE nro_comprobante = 2;
SELECT pg_temp.chk('D1: borrar un comprobante con renglones funciona (y se van sus renglones)',
  NOT EXISTS (SELECT 1 FROM comprobante WHERE nro_comprobante = 2)
  AND NOT EXISTS (SELECT 1 FROM renglon_comprobante WHERE nro_comprobante = 2));

\echo '=== RN-10 / RN-11: estados ==='
INSERT INTO ingreso(cod_transporte,cuit_bodega) VALUES (1,'30711111112');         -- 1
INSERT INTO renglon_ingreso VALUES (1,1,100);
SELECT pg_temp.chk('ingreso nace en_confeccion', (SELECT estado FROM ingreso WHERE cod_ingreso = 1) = 'en_confeccion');
SELECT pg_temp.chk('en_confeccion -> procesado: falla',  pg_temp.run($$UPDATE ingreso SET estado='procesado' WHERE cod_ingreso=1$$) LIKE 'P0001%');
SELECT pg_temp.chk('en_confeccion -> terminado: OK',     pg_temp.run($$UPDATE ingreso SET estado='terminado' WHERE cod_ingreso=1$$) = 'OK');
SELECT pg_temp.chk('terminado -> en_confeccion: falla',  pg_temp.run($$UPDATE ingreso SET estado='en_confeccion' WHERE cod_ingreso=1$$) LIKE 'P0001%');
SELECT pg_temp.chk('terminado -> procesado a mano: falla y avisa que se usa el procedimiento',
  pg_temp.run($$UPDATE ingreso SET estado='procesado' WHERE cod_ingreso=1$$) LIKE 'P0001%sp_procesar_ingreso%');
SELECT pg_temp.chk('...y el deposito sigue vacio', (SELECT count(*) FROM stock_deposito) = 0);
CALL sp_procesar_ingreso(1);
SELECT pg_temp.chk('con el procedimiento: procesado y deposito v1=100',
  (SELECT estado FROM ingreso WHERE cod_ingreso = 1) = 'procesado' AND (SELECT cantidad FROM stock_deposito WHERE cod_vino = 1) = 100);
SELECT pg_temp.chk('procesado -> terminado: falla',      pg_temp.run($$UPDATE ingreso SET estado='terminado' WHERE cod_ingreso=1$$) LIKE 'P0001%');
SELECT pg_temp.chk('procesado -> en_confeccion: falla',  pg_temp.run($$UPDATE ingreso SET estado='en_confeccion' WHERE cod_ingreso=1$$) LIKE 'P0001%');
SELECT pg_temp.chk('la variable atuel.procesando no queda activa',
  COALESCE(current_setting('atuel.procesando', true), '') <> 'on');

INSERT INTO transferencia(id_sala) VALUES (1);                                     -- 1
INSERT INTO renglon_transferencia VALUES (1,1,10);
SELECT pg_temp.chk('transferencia: en_confeccion -> procesado falla',
  pg_temp.run($$UPDATE transferencia SET estado='procesado' WHERE nro_solicitud=1$$) LIKE 'P0001%');
UPDATE transferencia SET estado = 'terminado' WHERE nro_solicitud = 1;
SELECT pg_temp.chk('transferencia terminada -> procesada a mano: falla',
  pg_temp.run($$UPDATE transferencia SET estado='procesado' WHERE nro_solicitud=1$$) LIKE 'P0001%sp_procesar_transferencia%');
CALL sp_procesar_transferencia(1);
SELECT pg_temp.chk('transferencia por procedimiento: procesada, deposito v1=90, sala v1=10',
  (SELECT estado FROM transferencia WHERE nro_solicitud = 1) = 'procesado'
  AND (SELECT cantidad FROM stock_deposito WHERE cod_vino = 1) = 90 AND fn_stock_sala(1,1) = 10);
SELECT pg_temp.chk('UPDATE de otra columna sin cambiar el estado no dispara el control',
  pg_temp.run($$UPDATE ingreso SET fecha = fecha WHERE cod_ingreso=1$$) = 'OK');

\echo '=== RN-12: renglones de documentos que no estan en confeccion ==='
INSERT INTO ingreso(cod_transporte,cuit_bodega) VALUES (1,'30711111112');         -- 2 (en confeccion)
SELECT pg_temp.chk('agregar renglon a ingreso en confeccion: OK', pg_temp.run($$INSERT INTO renglon_ingreso VALUES (2,2,5)$$) = 'OK');
SELECT pg_temp.chk('modificar renglon en confeccion: OK',         pg_temp.run($$UPDATE renglon_ingreso SET cantidad = 6 WHERE cod_ingreso=2 AND cod_vino=2$$) = 'OK');
UPDATE ingreso SET estado = 'terminado' WHERE cod_ingreso = 2;
SELECT pg_temp.chk('agregar renglon a ingreso terminado: falla',  pg_temp.run($$INSERT INTO renglon_ingreso VALUES (2,3,5)$$) LIKE 'P0001%RN-12%');
SELECT pg_temp.chk('modificar renglon de ingreso terminado: falla', pg_temp.run($$UPDATE renglon_ingreso SET cantidad = 9 WHERE cod_ingreso=2 AND cod_vino=2$$) LIKE 'P0001%RN-12%');
SELECT pg_temp.chk('quitar renglon de ingreso terminado: falla', pg_temp.run($$DELETE FROM renglon_ingreso WHERE cod_ingreso=2 AND cod_vino=2$$) LIKE 'P0001%RN-12%');
SELECT pg_temp.chk('renglon de ingreso procesado (1): modificar falla', pg_temp.run($$UPDATE renglon_ingreso SET cantidad = 1 WHERE cod_ingreso=1$$) LIKE 'P0001%RN-12%');
SELECT pg_temp.chk('renglon de ingreso procesado (1): borrar falla',    pg_temp.run($$DELETE FROM renglon_ingreso WHERE cod_ingreso=1$$) LIKE 'P0001%RN-12%');
SELECT pg_temp.chk('el renglon del ingreso terminado sigue intacto (6)',
  (SELECT cantidad FROM renglon_ingreso WHERE cod_ingreso=2 AND cod_vino=2) = 6);
SELECT pg_temp.chk('transferencia procesada: agregar renglon falla',
  pg_temp.run($$INSERT INTO renglon_transferencia VALUES (1,2,1)$$) LIKE 'P0001%RN-12%');
SELECT pg_temp.chk('transferencia procesada: borrar renglon falla',
  pg_temp.run($$DELETE FROM renglon_transferencia WHERE nro_solicitud=1$$) LIKE 'P0001%RN-12%');
INSERT INTO transferencia(id_sala) VALUES (1);                                     -- 2 (en confeccion)
SELECT pg_temp.chk('transferencia en confeccion: agregar y borrar renglon OK',
  pg_temp.run($$INSERT INTO renglon_transferencia VALUES (2,2,1)$$) = 'OK'
  AND pg_temp.run($$DELETE FROM renglon_transferencia WHERE nro_solicitud=2$$) = 'OK');

\echo '=== D5: borrar ingresos procesados viejos (cascada de renglones) ==='
INSERT INTO ingreso(fecha,cod_transporte,cuit_bodega) VALUES (CURRENT_DATE - 400,1,'30711111112');   -- 3
INSERT INTO renglon_ingreso VALUES (3,2,10),(3,3,20);
UPDATE ingreso SET estado='terminado' WHERE cod_ingreso = 3;
CALL sp_procesar_ingreso(3);
SELECT pg_temp.chk('antes del DELETE: el ingreso 3 esta procesado y tiene 2 renglones',
  (SELECT estado FROM ingreso WHERE cod_ingreso = 3) = 'procesado'
  AND (SELECT count(*) FROM renglon_ingreso WHERE cod_ingreso = 3) = 2);
DELETE FROM ingreso WHERE estado = 'procesado' AND fecha < CURRENT_DATE - 365;
SELECT pg_temp.chk('D5: borrar ingresos procesados de hace mas de 365 dias funciona y borra sus renglones',
  NOT EXISTS (SELECT 1 FROM ingreso WHERE cod_ingreso = 3)
  AND NOT EXISTS (SELECT 1 FROM renglon_ingreso WHERE cod_ingreso = 3));
SELECT pg_temp.chk('...y el ingreso procesado reciente (1) y sus renglones siguen',
  EXISTS (SELECT 1 FROM ingreso WHERE cod_ingreso = 1) AND EXISTS (SELECT 1 FROM renglon_ingreso WHERE cod_ingreso = 1));
SELECT pg_temp.chk('borrar un ingreso terminado entero (con renglones) tambien funciona',
  pg_temp.run($$DELETE FROM ingreso WHERE cod_ingreso = 2$$) = 'OK');

\echo '=== RN-11: fecha de confeccion ==='
INSERT INTO transferencia(id_sala, fecha_confeccion) VALUES (1, DATE '2020-01-01');   -- 3
SELECT pg_temp.chk('insertar con fecha vieja: queda la fecha de hoy',
  (SELECT fecha_confeccion FROM transferencia WHERE nro_solicitud = 3) = CURRENT_DATE);
SELECT pg_temp.chk('modificar la fecha: falla',
  pg_temp.run($$UPDATE transferencia SET fecha_confeccion = DATE '2020-01-01' WHERE nro_solicitud = 3$$) LIKE 'P0001%RN-11%');
SELECT pg_temp.chk('actualizar otra columna (sin tocar la fecha): OK',
  pg_temp.run($$UPDATE transferencia SET id_sala = 1 WHERE nro_solicitud = 3$$) = 'OK');

\echo '=== RN-13: auditoria de precio ==='
UPDATE vino SET precio = 1200.00 WHERE cod_vino = 1;
SELECT pg_temp.chk('cambio de precio: 1 registro con anterior 1000 y nuevo 1200',
  (SELECT count(*) FROM auditoria_precio) = 1
  AND (SELECT precio_anterior = 1000 AND precio_nuevo = 1200 AND cod_vino = 1 FROM auditoria_precio));
SELECT pg_temp.chk('el registro tiene fecha de hoy y usuario',
  (SELECT fecha_hora::date = CURRENT_DATE AND usuario = current_user FROM auditoria_precio));
UPDATE vino SET precio = 1200.00 WHERE cod_vino = 1;             -- mismo precio
UPDATE vino SET graduacion = 13 WHERE cod_vino = 1;              -- otra columna
SELECT pg_temp.chk('mismo precio u otra columna: no audita', (SELECT count(*) FROM auditoria_precio) = 1);
UPDATE vino SET precio = round(precio * 1.13, 2);                -- U3 sobre todos
SELECT pg_temp.chk('U3: +13% a todos los vinos audita uno por vino (1 + 3 = 4)', (SELECT count(*) FROM auditoria_precio) = 4);
SELECT pg_temp.chk('...y las ventas ya hechas conservan el precio de ese momento',
  (SELECT precio_unitario FROM renglon_comprobante WHERE nro_comprobante = 1 AND cod_vino = 1) = 1000);
