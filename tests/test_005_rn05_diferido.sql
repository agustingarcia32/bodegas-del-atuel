\set ON_ERROR_STOP off
\set VERBOSITY terse
\pset format unaligned
\pset tuples_only on

INSERT INTO bodega VALUES ('30711111112','Bodega Uno','Domicilio 1');
INSERT INTO cepa(nombre,tipo) VALUES ('Malbec','tinta'),('Syrah','tinta'),('Merlot','tinta');

\echo '-- 1) vino + 60 + 40 en una sola transaccion (debe quedar)'
BEGIN;
INSERT INTO vino(nombre,tipo,anada,volumen_ml,graduacion,precio,cuit_bodega) VALUES ('A','tinto',2021,750,14,100,'30711111112');
INSERT INTO composicion VALUES (1,1,60);
SELECT 'en la transaccion, con 60 cargado (todavia incompleto): sin error, se evalua al cierre';
INSERT INTO composicion VALUES (1,2,40);
COMMIT;
SELECT CASE WHEN (SELECT count(*) FROM composicion WHERE cod_vino = 1) = 2 THEN 'PASA  composicion 60+40 quedo guardada' ELSE 'FALLA composicion 60+40' END;

\echo '-- 2) vino + 60 + 30 (debe fallar al COMMIT y revertir todo)'
BEGIN;
INSERT INTO vino(nombre,tipo,anada,volumen_ml,graduacion,precio,cuit_bodega) VALUES ('B','tinto',2021,750,14,100,'30711111112');
INSERT INTO composicion VALUES (2,1,60);
INSERT INTO composicion VALUES (2,2,30);
COMMIT;
SELECT CASE WHEN NOT EXISTS (SELECT 1 FROM vino WHERE cod_vino = 2) AND NOT EXISTS (SELECT 1 FROM composicion WHERE cod_vino = 2)
            THEN 'PASA  la transaccion se revirtio entera (ni el vino ni la composicion quedaron)' ELSE 'FALLA no se revirtio' END;

\echo '-- 3) vino + 100 de una sola cepa (debe quedar)'
INSERT INTO vino(nombre,tipo,anada,volumen_ml,graduacion,precio,cuit_bodega) VALUES ('C','blanco',2022,750,13,100,'30711111112');
INSERT INTO composicion VALUES (3,3,100);
SELECT CASE WHEN (SELECT count(*) FROM composicion WHERE cod_vino = 3) = 1 THEN 'PASA  100 % de una cepa (autocommit)' ELSE 'FALLA' END;

\echo '-- 4) cargar una sola cepa con 60 en autocommit (debe fallar: el COMMIT implicito lo rechaza)'
INSERT INTO vino(nombre,tipo,anada,volumen_ml,graduacion,precio,cuit_bodega) VALUES ('D','tinto',2020,750,14,100,'30711111112');
INSERT INTO composicion VALUES (4,1,60);
SELECT CASE WHEN NOT EXISTS (SELECT 1 FROM composicion WHERE cod_vino = 4) THEN 'PASA  no quedo la composicion de 60 %' ELSE 'FALLA quedo una composicion que suma 60' END;

\echo '-- 5) modificar un porcentaje para que no sume 100 (debe fallar) y despues repartirlo bien en una transaccion (debe quedar)'
UPDATE composicion SET porcentaje = 50 WHERE cod_vino = 1 AND id_cepa = 1;
SELECT CASE WHEN (SELECT porcentaje FROM composicion WHERE cod_vino = 1 AND id_cepa = 1) = 60 THEN 'PASA  el UPDATE que rompia la suma se revirtio (sigue 60)' ELSE 'FALLA' END;
BEGIN;
UPDATE composicion SET porcentaje = 50 WHERE cod_vino = 1 AND id_cepa = 1;
UPDATE composicion SET porcentaje = 50 WHERE cod_vino = 1 AND id_cepa = 2;
COMMIT;
SELECT CASE WHEN (SELECT sum(porcentaje) FROM composicion WHERE cod_vino = 1) = 100 AND (SELECT porcentaje FROM composicion WHERE cod_vino = 1 AND id_cepa = 1) = 50
            THEN 'PASA  repartir 50/50 en una transaccion funciona' ELSE 'FALLA' END;

\echo '-- 6) borrar una cepa de un vino de 2 cepas (debe fallar)'
DELETE FROM composicion WHERE cod_vino = 1 AND id_cepa = 2;
SELECT CASE WHEN (SELECT count(*) FROM composicion WHERE cod_vino = 1) = 2 THEN 'PASA  el DELETE que rompia la suma se revirtio' ELSE 'FALLA' END;

\echo '-- 7) borrar el vino entero (la composicion se va en cascada: debe funcionar)'
DELETE FROM vino WHERE cod_vino = 1;
SELECT CASE WHEN NOT EXISTS (SELECT 1 FROM vino WHERE cod_vino = 1) AND NOT EXISTS (SELECT 1 FROM composicion WHERE cod_vino = 1)
            THEN 'PASA  borrar un vino con su composicion funciona' ELSE 'FALLA' END;
