\set ON_ERROR_STOP off
\set VERBOSITY terse
\pset format unaligned
\pset tuples_only on

CREATE FUNCTION pg_temp.chk(label text, ok boolean) RETURNS text
LANGUAGE sql AS $$ SELECT CASE WHEN COALESCE(ok, false) THEN 'PASA  ' ELSE 'FALLA ' END || label $$;

\echo '=== vistas con la base vacia ==='
SELECT pg_temp.chk('las 3 vistas se pueden consultar sin datos (0 filas)',
  (SELECT count(*) FROM v_stock_total_vino) = 0
  AND (SELECT count(*) FROM v_ventas_mensuales_sala) = 0
  AND (SELECT count(*) FROM v_documentos_pendientes) = 0);

-- ---------- datos de prueba (cuentas hechas a mano abajo) ----------
INSERT INTO localidad(nombre,provincia,cod_postal,encargado_regional) VALUES ('San Rafael','Mendoza','5600','E1'),('General Alvear','Mendoza','5620','E2');
INSERT INTO sala_venta(calle,numero,dia_cierre,id_localidad) VALUES ('Belgrano',100,'lunes',1),('Mitre',200,'martes',2);
INSERT INTO bodega VALUES ('30711111112','Bodega Uno','Domicilio 1');
INSERT INTO transportista(razon_social,cuit,email,telefono,domicilio) VALUES ('Trans SA','30722222223','a@b.com','260123','Dom');
INSERT INTO vino(nombre,tipo,anada,volumen_ml,graduacion,precio,cuit_bodega) VALUES
  ('V1','tinto',2021,750,14,1000.00,'30711111112'),
  ('V2','tinto',2022,750,14,500.50,'30711111112'),
  ('V3','blanco',2023,750,13,800.00,'30711111112');
INSERT INTO cliente(nombre_razon_social,tipo_doc,nro_doc,direccion,tipo_cliente,id_localidad)
  VALUES ('Socio','DNI','1','d','socio',1);                                  -- descuento 10 %

-- stock inicial en salas: sala1 v1=10 v2=5 | sala2 v1=3
INSERT INTO stock_sala VALUES (1,1,10),(1,2,5),(2,1,3);

-- ingreso 3 procesado: deposito v1=100
INSERT INTO ingreso(cod_transporte,cuit_bodega) VALUES (1,'30711111112'),(1,'30711111112'),(1,'30711111112');
INSERT INTO renglon_ingreso VALUES (1,1,5),(1,2,7),(2,1,20),(3,1,100);
UPDATE ingreso SET fecha = CURRENT_DATE - 10 WHERE cod_ingreso = 1;
UPDATE ingreso SET estado = 'terminado' WHERE cod_ingreso IN (2,3);
CALL sp_procesar_ingreso(3);

-- transferencias: 1 en confeccion sin renglones | 2 terminada (v1:5) | 3 procesada (sala1 v1:10)
INSERT INTO transferencia(id_sala) VALUES (1),(2),(1);
INSERT INTO renglon_transferencia VALUES (2,1,5),(3,1,10);
UPDATE transferencia SET estado = 'terminado' WHERE nro_solicitud IN (2,3);
CALL sp_procesar_transferencia(3);

-- ventas (socio, 10 % de descuento)
INSERT INTO comprobante(fecha,id_cliente,id_sala) VALUES
  ('2026-09-10',1,1), ('2026-09-25',1,1), ('2026-10-05',1,1), ('2026-09-12',1,2), ('2026-10-20',1,2);
INSERT INTO renglon_comprobante(nro_comprobante,cod_vino,cantidad) VALUES
  (1,1,2),            -- 2 x 1000 -10% = 1800.00
  (2,2,1),(2,1,1),    -- 450.45 + 900.00 = 1350.45
  (3,1,3),            -- 2700.00
  (4,1,1);            -- 900.00   (comprobante 5 queda sin renglones)

\echo '=== v_stock_total_vino ==='
-- cuentas: v1 deposito 100-10 = 90; salas sala1 (10+10-2-1-3 = 14) + sala2 (3-1 = 2) = 16; total 106
--          v2 sin fila en deposito -> 0; salas 5-1 = 4; total 4 | v3 sin stock en ningun lado -> 0/0/0
SELECT pg_temp.chk('V1: deposito 90, salas 16, total 106',
  (SELECT stock_deposito = 90 AND stock_salas = 16 AND stock_total = 106 FROM v_stock_total_vino WHERE nombre = 'V1'));
SELECT pg_temp.chk('V2 (sin fila en el deposito): deposito 0, salas 4, total 4',
  (SELECT stock_deposito = 0 AND stock_salas = 4 AND stock_total = 4 FROM v_stock_total_vino WHERE nombre = 'V2'));
SELECT pg_temp.chk('V3 (sin stock en ningun lado) aparece igual, con 0/0/0',
  (SELECT stock_deposito = 0 AND stock_salas = 0 AND stock_total = 0 FROM v_stock_total_vino WHERE nombre = 'V3'));
SELECT pg_temp.chk('hay una fila por vino (3), sin repetir por tener varias salas',
  (SELECT count(*) FROM v_stock_total_vino) = 3);
-- 100 del ingreso + 18 iniciales en salas - 8 vendidas (2+2+3+1) = 110
SELECT pg_temp.chk('conservacion: 100 + 18 - 8 vendidas = 110 = suma de totales',
  (SELECT sum(stock_total) FROM v_stock_total_vino) = 110);
SELECT pg_temp.chk('...y las vendidas calculadas desde los renglones tambien dan 8',
  (SELECT sum(cantidad) FROM renglon_comprobante) = 8
  AND (SELECT sum(stock_total) FROM v_stock_total_vino) = 100 + 18 - (SELECT sum(cantidad) FROM renglon_comprobante));

\echo '=== v_ventas_mensuales_sala ==='
-- sala1 sep: c1+c2 -> 2 comprobantes, botellas 2+1+1 = 4, total 1800 + 1350.45 = 3150.45
-- sala1 oct: c3 -> 1, 3 botellas, 2700.00
-- sala2 sep: c4 -> 1, 1 botella, 900.00 | sala2 oct: c5 sin renglones -> 1, 0 botellas, 0.00
SELECT pg_temp.chk('sala 1 septiembre: 2 comprobantes, 4 botellas, 3150.45',
  (SELECT comprobantes = 2 AND botellas = 4 AND total_vendido = 3150.45
     FROM v_ventas_mensuales_sala WHERE id_sala = 1 AND mes = DATE '2026-09-01'));
SELECT pg_temp.chk('sala 1 octubre: 1 comprobante, 3 botellas, 2700.00',
  (SELECT comprobantes = 1 AND botellas = 3 AND total_vendido = 2700.00
     FROM v_ventas_mensuales_sala WHERE id_sala = 1 AND mes = DATE '2026-10-01'));
SELECT pg_temp.chk('sala 2 septiembre: 1 comprobante, 1 botella, 900.00',
  (SELECT comprobantes = 1 AND botellas = 1 AND total_vendido = 900.00
     FROM v_ventas_mensuales_sala WHERE id_sala = 2 AND mes = DATE '2026-09-01'));
SELECT pg_temp.chk('sala 2 octubre: comprobante SIN renglones cuenta como 1 comprobante, 0 botellas, 0.00',
  (SELECT comprobantes = 1 AND botellas = 0 AND total_vendido = 0
     FROM v_ventas_mensuales_sala WHERE id_sala = 2 AND mes = DATE '2026-10-01'));
SELECT pg_temp.chk('son exactamente 4 filas (sala, mes)', (SELECT count(*) FROM v_ventas_mensuales_sala) = 4);
SELECT pg_temp.chk('la suma de la vista = suma de los comprobantes (no se multiplica por renglones)',
  (SELECT sum(total_vendido) FROM v_ventas_mensuales_sala) = (SELECT sum(total) FROM comprobante));
SELECT pg_temp.chk('trae el nombre de la sala y de la localidad',
  (SELECT sala = 'Belgrano 100' AND localidad = 'San Rafael' FROM v_ventas_mensuales_sala WHERE id_sala = 1 LIMIT 1));

\echo '=== v_documentos_pendientes ==='
-- pendientes: ingreso 1 (en_confeccion, 2 renglones, 12 botellas, 10 dias) | ingreso 2 (terminado, 1, 20)
--             transferencia 1 (en_confeccion, 0, 0) | transferencia 2 (terminada, 1, 5)
-- NO aparecen: ingreso 3 y transferencia 3 (procesados)
SELECT pg_temp.chk('son 4 documentos pendientes', (SELECT count(*) FROM v_documentos_pendientes) = 4);
SELECT pg_temp.chk('los procesados NO aparecen',
  NOT EXISTS (SELECT 1 FROM v_documentos_pendientes WHERE (tipo = 'ingreso' AND numero = 3) OR (tipo = 'transferencia' AND numero = 3)));
SELECT pg_temp.chk('ingreso 1: en_confeccion, 2 renglones, 12 botellas, 10 dias, bodega Uno',
  (SELECT estado = 'en_confeccion' AND renglones = 2 AND botellas = 12 AND dias_pendiente = 10 AND origen_o_destino = 'Bodega Uno'
     FROM v_documentos_pendientes WHERE tipo = 'ingreso' AND numero = 1));
SELECT pg_temp.chk('ingreso 2: terminado, 1 renglon, 20 botellas',
  (SELECT estado = 'terminado' AND renglones = 1 AND botellas = 20 FROM v_documentos_pendientes WHERE tipo = 'ingreso' AND numero = 2));
SELECT pg_temp.chk('transferencia 1 (sin renglones): 0 renglones, 0 botellas, hoy = 0 dias',
  (SELECT renglones = 0 AND botellas = 0 AND dias_pendiente = 0 AND origen_o_destino = 'Sala Belgrano 100'
     FROM v_documentos_pendientes WHERE tipo = 'transferencia' AND numero = 1));
SELECT pg_temp.chk('transferencia 2: terminada, 1 renglon, 5 botellas, destino sala Mitre 200',
  (SELECT estado = 'terminado' AND renglones = 1 AND botellas = 5 AND origen_o_destino = 'Sala Mitre 200'
     FROM v_documentos_pendientes WHERE tipo = 'transferencia' AND numero = 2));

-- al procesar uno, sale de la vista
CALL sp_procesar_ingreso(2);
SELECT pg_temp.chk('al procesar el ingreso 2 deja de ser pendiente (quedan 3)',
  (SELECT count(*) FROM v_documentos_pendientes) = 3
  AND NOT EXISTS (SELECT 1 FROM v_documentos_pendientes WHERE tipo = 'ingreso' AND numero = 2));

\echo '=== son solo lectura ==='
SELECT pg_temp.chk('no se puede insertar en una vista de agregados',
  (SELECT CASE WHEN EXISTS (SELECT 1 FROM information_schema.views
                             WHERE table_schema = 'public' AND table_name LIKE 'v\_%' AND is_insertable_into = 'YES')
               THEN false ELSE true END));
