-- Se corre CONECTADO COMO app_rw (el rol de la API), sobre una base vacía con
-- 001 a 007 aplicadas:   psql -U app_rw -d bodegas -f test_007_roles_api.sql
-- Recorre el trabajo normal de la API: si algo necesita un permiso que app_rw
-- no tiene, el script se corta con "permission denied".
\set ON_ERROR_STOP on
\pset tuples_only on
\pset format unaligned

SELECT 'conectado como: ' || current_user || ' | superusuario: ' || (SELECT rolsuper FROM pg_roles WHERE rolname = current_user);

-- catalogos
INSERT INTO localidad(nombre,provincia,cod_postal,encargado_regional) VALUES ('San Rafael','Mendoza','5600','Enc');
INSERT INTO sala_venta(calle,numero,dia_cierre,id_localidad) VALUES ('Belgrano',100,'lunes',1);
INSERT INTO bodega VALUES ('30711111112','Bodega Uno','Domicilio 1');
INSERT INTO transportista(razon_social,cuit,email,telefono,domicilio) VALUES ('Trans SA','30722222223','a@b.com','260123','Dom');
INSERT INTO cepa(nombre,tipo) VALUES ('Malbec','tinta'),('Syrah','tinta');

-- vino + composicion en una sola transaccion (RN-05)
BEGIN;
INSERT INTO vino(nombre,tipo,anada,volumen_ml,graduacion,precio,cuit_bodega) VALUES ('V1','tinto',2021,750,14,1000,'30711111112');
INSERT INTO composicion VALUES (1,1,60),(1,2,40);
COMMIT;

INSERT INTO cliente(nombre_razon_social,tipo_doc,nro_doc,direccion,tipo_cliente,id_localidad) VALUES ('Socio','DNI','1','d','socio',1);
INSERT INTO socio VALUES (1);
INSERT INTO stock_sala VALUES (1,1,10);

-- ingreso: confeccion -> terminado -> procesado (por procedimiento)
INSERT INTO ingreso(cod_transporte,cuit_bodega) VALUES (1,'30711111112');
INSERT INTO renglon_ingreso VALUES (1,1,100);
UPDATE ingreso SET estado = 'terminado' WHERE cod_ingreso = 1;
CALL sp_procesar_ingreso(1);

-- transferencia: deposito -> sala
INSERT INTO transferencia(id_sala) VALUES (1);
INSERT INTO renglon_transferencia VALUES (1,1,20);
UPDATE transferencia SET estado = 'terminado' WHERE nro_solicitud = 1;
CALL sp_procesar_transferencia(1);

-- venta (descuenta stock y calcula totales por triggers)
BEGIN;
INSERT INTO comprobante(id_cliente,id_sala) VALUES (1,1);
INSERT INTO renglon_comprobante(nro_comprobante,cod_vino,cantidad) VALUES (1,1,3);
COMMIT;

-- cambio de precio (el trigger escribe en auditoria_precio con los permisos de app_rw)
UPDATE vino SET precio = 1100 WHERE cod_vino = 1;

-- una venta sin stock se rechaza con el error de la regla
DO $$
BEGIN
    BEGIN
        INSERT INTO comprobante(id_cliente,id_sala) VALUES (1,1);
        INSERT INTO renglon_comprobante(nro_comprobante,cod_vino,cantidad) VALUES (2,1,999);
        RAISE EXCEPTION 'FALLA: la venta sin stock no se rechazo';
    EXCEPTION WHEN raise_exception THEN
        IF SQLERRM NOT LIKE '%Stock insuficiente%' THEN RAISE; END IF;
        RAISE NOTICE 'PASA  venta sin stock rechazada: %', SQLERRM;
    END;
END $$;

-- lectura de vistas
SELECT 'vista stock: ' || stock_deposito || ' dep + ' || stock_salas || ' salas' FROM v_stock_total_vino;

DO $$
BEGIN
    IF (SELECT cantidad FROM stock_deposito WHERE cod_vino = 1) <> 80 THEN RAISE EXCEPTION 'deposito esperado 80'; END IF;
    IF (SELECT cantidad FROM stock_sala WHERE id_sala = 1 AND cod_vino = 1) <> 27 THEN RAISE EXCEPTION 'sala esperada 27 (10 + 20 - 3)'; END IF;
    IF (SELECT total FROM comprobante WHERE nro_comprobante = 1) <> 2700 THEN RAISE EXCEPTION 'total esperado 2700'; END IF;
    IF (SELECT count(*) FROM auditoria_precio) <> 1 THEN RAISE EXCEPTION 'auditoria esperada 1'; END IF;
    IF (SELECT usuario FROM auditoria_precio) <> 'app_rw' THEN RAISE EXCEPTION 'la auditoria debe registrar al usuario app_rw'; END IF;
END $$;

SELECT 'PASA  flujo completo de la API como app_rw (identity sin permisos de secuencia, triggers, procedimientos, auditoria)';
