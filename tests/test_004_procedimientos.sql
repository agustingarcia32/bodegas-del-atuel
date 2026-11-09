\set ON_ERROR_STOP off
\set VERBOSITY terse
\pset format unaligned
\pset tuples_only on

CREATE FUNCTION pg_temp.chk(label text, ok boolean) RETURNS text
LANGUAGE sql AS $$ SELECT CASE WHEN ok THEN 'PASA  ' ELSE 'FALLA ' END || label $$;

CREATE FUNCTION pg_temp.dep(v int) RETURNS int LANGUAGE sql AS
$$ SELECT cantidad FROM stock_deposito WHERE cod_vino = v $$;
CREATE FUNCTION pg_temp.sala(s int, v int) RETURNS int LANGUAGE sql AS
$$ SELECT cantidad FROM stock_sala WHERE id_sala = s AND cod_vino = v $$;
CREATE FUNCTION pg_temp.est_ing(c int) RETURNS text LANGUAGE sql AS
$$ SELECT estado::text FROM ingreso WHERE cod_ingreso = c $$;
CREATE FUNCTION pg_temp.est_tr(c int) RETURNS text LANGUAGE sql AS
$$ SELECT estado::text FROM transferencia WHERE nro_solicitud = c $$;

-- ---------- datos base ----------
INSERT INTO localidad(nombre,provincia,cod_postal,encargado_regional) VALUES ('San Rafael','Mendoza','5600','Enc');
INSERT INTO sala_venta(calle,numero,dia_cierre,id_localidad) VALUES ('Belgrano',100,'lunes',1), ('Mitre',200,'martes',1);
INSERT INTO bodega VALUES ('30711111112','Bodega Uno','Domicilio 1');
INSERT INTO transportista(razon_social,cuit,email,telefono,domicilio) VALUES ('Trans SA','30722222223','a@b.com','260123','Dom');
INSERT INTO vino(nombre,tipo,anada,volumen_ml,graduacion,precio,cuit_bodega) VALUES
  ('V1','tinto',2021,750,14,1000,'30711111112'),
  ('V2','tinto',2022,750,14,1000,'30711111112'),
  ('V3','blanco',2023,750,13,1000,'30711111112');

-- ingresos: 1 terminado (v1:100, v2:50) | 2 en confeccion | 3 terminado vacio | 4 terminado (v1:20)
INSERT INTO ingreso(cod_transporte,cuit_bodega) VALUES
  (1,'30711111112'), (1,'30711111112'), (1,'30711111112'), (1,'30711111112');
INSERT INTO renglon_ingreso VALUES (1,1,100),(1,2,50),(2,1,5),(4,1,20);
UPDATE ingreso SET estado = 'terminado' WHERE cod_ingreso IN (1,3,4);

\echo '=== INGRESOS ==='
\echo '-- ingreso en confeccion (debe fallar)'
CALL sp_procesar_ingreso(2);
SELECT pg_temp.chk('ingreso 2 sigue en_confeccion y el deposito sigue vacio',
  pg_temp.est_ing(2) = 'en_confeccion' AND (SELECT count(*) FROM stock_deposito) = 0);
\echo '-- ingreso inexistente (debe fallar)'
CALL sp_procesar_ingreso(999);
\echo '-- ingreso terminado sin renglones (debe fallar)'
CALL sp_procesar_ingreso(3);
SELECT pg_temp.chk('ingreso 3 sigue terminado', pg_temp.est_ing(3) = 'terminado');
\echo '-- ingreso 1 (debe funcionar)'
CALL sp_procesar_ingreso(1);
SELECT pg_temp.chk('ingreso 1: deposito v1=100, v2=50 y estado procesado',
  pg_temp.dep(1) = 100 AND pg_temp.dep(2) = 50 AND pg_temp.est_ing(1) = 'procesado');
\echo '-- reprocesar el mismo ingreso (debe fallar)'
CALL sp_procesar_ingreso(1);
SELECT pg_temp.chk('no hay doble impacto: deposito sigue v1=100, v2=50',
  pg_temp.dep(1) = 100 AND pg_temp.dep(2) = 50);
\echo '-- ingreso 4 suma sobre una fila existente'
CALL sp_procesar_ingreso(4);
SELECT pg_temp.chk('ingreso 4 acumula: deposito v1=120',  pg_temp.dep(1) = 120);
SELECT pg_temp.chk('la variable atuel.procesando no queda activa (cada CALL es su transaccion)',
  current_setting('atuel.procesando', true) IS DISTINCT FROM 'on');

-- transferencias
-- T1 sala1 terminado v1:30 v2:10 | T2 sala1 v1:10 v2:500 | T3 sala1 v1:1 v3:5 (v3 sin fila en deposito)
-- T4 en_confeccion | T5 terminado vacio | T6 sala1 v1:5 | T7 sala2 v1:10 v2:5
INSERT INTO transferencia(id_sala) VALUES (1),(1),(1),(1),(1),(1),(2);
INSERT INTO renglon_transferencia VALUES
  (1,1,30),(1,2,10),
  (2,1,10),(2,2,500),
  (3,1,1),(3,3,5),
  (4,1,1),
  (6,1,5),
  (7,1,10),(7,2,5);
UPDATE transferencia SET estado = 'terminado' WHERE nro_solicitud <> 4;

\echo ''
\echo '=== TRANSFERENCIAS ==='
\echo '-- T1 (debe funcionar)'
CALL sp_procesar_transferencia(1);
SELECT pg_temp.chk('T1: deposito v1=90, v2=40',                   pg_temp.dep(1) = 90 AND pg_temp.dep(2) = 40);
SELECT pg_temp.chk('T1: sala 1 recibe v1=30, v2=10 (filas nuevas)', pg_temp.sala(1,1) = 30 AND pg_temp.sala(1,2) = 10);
SELECT pg_temp.chk('T1: estado procesado',                        pg_temp.est_tr(1) = 'procesado');

\echo '-- T2: pide 500 de v2 y solo hay 40 (debe fallar, sin cambios a medias)'
CALL sp_procesar_transferencia(2);
SELECT pg_temp.chk('T2: deposito intacto (v1=90, v2=40) aunque v1 SI alcanzaba',
  pg_temp.dep(1) = 90 AND pg_temp.dep(2) = 40);
SELECT pg_temp.chk('T2: stock de la sala intacto (v1=30, v2=10)', pg_temp.sala(1,1) = 30 AND pg_temp.sala(1,2) = 10);
SELECT pg_temp.chk('T2: sigue terminada',                         pg_temp.est_tr(2) = 'terminado');

\echo '-- T3: v3 NO tiene fila en stock_deposito (trampa del anexo A.6; debe fallar)'
CALL sp_procesar_transferencia(3);
SELECT pg_temp.chk('T3: deposito intacto y la sala NO recibio v3',
  pg_temp.dep(1) = 90 AND pg_temp.sala(1,3) IS NULL AND pg_temp.est_tr(3) = 'terminado');

\echo '-- T4 en confeccion (debe fallar) / T5 vacia (debe fallar) / T999 inexistente (debe fallar)'
CALL sp_procesar_transferencia(4);
CALL sp_procesar_transferencia(5);
CALL sp_procesar_transferencia(999);
SELECT pg_temp.chk('T4 sigue en_confeccion, T5 sigue terminada',
  pg_temp.est_tr(4) = 'en_confeccion' AND pg_temp.est_tr(5) = 'terminado');

\echo '-- T6 acumula sobre fila existente de la sala (debe funcionar)'
CALL sp_procesar_transferencia(6);
SELECT pg_temp.chk('T6: sala 1 v1=35, deposito v1=85',            pg_temp.sala(1,1) = 35 AND pg_temp.dep(1) = 85);

\echo '-- T7 a otra sala (debe funcionar)'
CALL sp_procesar_transferencia(7);
SELECT pg_temp.chk('T7: sala 2 v1=10, v2=5; deposito v1=75, v2=35',
  pg_temp.sala(2,1) = 10 AND pg_temp.sala(2,2) = 5 AND pg_temp.dep(1) = 75 AND pg_temp.dep(2) = 35);

-- suma de control: lo que entro al deposito = lo que hay en deposito + lo que hay en salas
SELECT pg_temp.chk('conservacion de botellas: ingresado (170 v1+50 v2) = deposito + salas',
  (SELECT sum(cantidad) FROM renglon_ingreso WHERE cod_ingreso IN (1,4))
  = (SELECT sum(cantidad) FROM stock_deposito) + (SELECT sum(cantidad) FROM stock_sala));

-- preparacion para las pruebas concurrentes (se ejecutan desde bash)
-- T8 y T9 piden 20 de v2 cada una (deposito v2=35: solo una puede salir bien)
-- T10 pide 10 de v1 y se procesa dos veces a la vez
INSERT INTO transferencia(id_sala) VALUES (2),(2),(2);
INSERT INTO renglon_transferencia VALUES (8,2,20),(9,2,20),(10,1,10);
UPDATE transferencia SET estado = 'terminado' WHERE nro_solicitud IN (8,9,10);
