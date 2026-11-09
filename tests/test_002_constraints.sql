\set ON_ERROR_STOP on
\pset format unaligned
\pset tuples_only on

CREATE FUNCTION pg_temp.expect(label text, stmt text, esperado text) RETURNS text
LANGUAGE plpgsql AS $$
DECLARE obtenido text; nombre text;
BEGIN
  BEGIN
    EXECUTE stmt;
    obtenido := 'OK';
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS nombre = CONSTRAINT_NAME;
    obtenido := SQLSTATE || COALESCE(' ' || nombre, '');
  END;
  RETURN CASE WHEN obtenido LIKE esperado || '%' THEN 'PASA  ' ELSE 'FALLA ' END
         || label || '  [esperado ' || esperado || ' / obtenido ' || obtenido || ']';
END $$;

-- ---------- datos base (deben funcionar) ----------
INSERT INTO localidad(nombre,provincia,cod_postal,encargado_regional) VALUES ('San Rafael','Mendoza','5600','Enc');
INSERT INTO sala_venta(calle,numero,dia_cierre,id_localidad) VALUES ('Belgrano',100,'lunes',1);
INSERT INTO bodega VALUES ('30711111112','Bodega Uno','Domicilio 1');
INSERT INTO cepa(nombre,tipo) VALUES ('Malbec','tinta');
INSERT INTO finca(nombre,superficie_ha,nombre_departamento) VALUES ('Finca A',10,'San Rafael');
INSERT INTO parcela VALUES (1,1,2.5,2010,1);
INSERT INTO vino(nombre,tipo,anada,volumen_ml,graduacion,precio,cuit_bodega)
  VALUES ('Malbec Reserva','tinto',2021,750,14,12500,'30711111112');
INSERT INTO cliente(nombre_razon_social,tipo_doc,nro_doc,direccion,tipo_cliente,descuento,id_localidad)
  VALUES ('Exportadora SA','CUIT','30700000001','Calle 1','exportador',30,1);
INSERT INTO exportador VALUES (1,'Brasil');
INSERT INTO transportista(razon_social,cuit,email,telefono,domicilio)
  VALUES ('Trans SA','30722222223','a@b.com','260123','Dom');

-- ---------- defaults ----------
SELECT 'DEFAULT finca.provincia = ' || provincia FROM finca WHERE id_finca = 1;
INSERT INTO ingreso(cod_transporte,cuit_bodega) VALUES (1,'30711111112');
SELECT 'DEFAULT ingreso.estado = ' || estado || ', fecha = hoy: ' || (fecha = CURRENT_DATE) FROM ingreso;
INSERT INTO transferencia(id_sala) VALUES (1);
SELECT 'DEFAULT transferencia.estado = ' || estado || ', fecha = hoy: ' || (fecha_confeccion = CURRENT_DATE) FROM transferencia;
INSERT INTO comprobante(id_cliente,id_sala) VALUES (1,1);
SELECT 'DEFAULT comprobante: subtotal/desc/total = ' || subtotal || '/' || descuento || '/' || total || ', fecha = hoy: ' || (fecha = CURRENT_DATE) FROM comprobante;
INSERT INTO stock_deposito(cod_vino) VALUES (1);
SELECT 'DEFAULT stock_deposito.cantidad = ' || cantidad FROM stock_deposito;
INSERT INTO cliente(nombre_razon_social,tipo_doc,nro_doc,direccion,tipo_cliente,descuento,id_localidad)
  VALUES ('Socio','DNI','1','d','socio',10,1);
SELECT 'DEFAULT cliente.fecha_alta = hoy: ' || (fecha_alta = CURRENT_DATE) FROM cliente WHERE id_cliente = 2;

-- ---------- casos que deben fallar ----------
SELECT pg_temp.expect('UNIQUE localidad (nombre,provincia)',
  $$INSERT INTO localidad(nombre,provincia,cod_postal,encargado_regional) VALUES ('San Rafael','Mendoza','5601','X')$$, '23505');
SELECT pg_temp.expect('UNIQUE vino (nombre,anada,volumen)  [uq_vino]',
  $$INSERT INTO vino(nombre,tipo,anada,volumen_ml,graduacion,precio,cuit_bodega) VALUES ('Malbec Reserva','tinto',2021,750,14,1,'30711111112')$$, '23505');
SELECT pg_temp.expect('RN-01 precio = 0',
  $$INSERT INTO vino(nombre,tipo,anada,volumen_ml,graduacion,precio,cuit_bodega) VALUES ('X','tinto',2021,750,14,0,'30711111112')$$, '23514');
SELECT pg_temp.expect('RN-15 graduacion = 4',
  $$INSERT INTO vino(nombre,tipo,anada,volumen_ml,graduacion,precio,cuit_bodega) VALUES ('X','tinto',2021,750,4,1,'30711111112')$$, '23514');
SELECT pg_temp.expect('RN-15 graduacion = 21',
  $$INSERT INTO vino(nombre,tipo,anada,volumen_ml,graduacion,precio,cuit_bodega) VALUES ('X','tinto',2021,750,21,1,'30711111112')$$, '23514');
SELECT pg_temp.expect('vino volumen 500 no valido',
  $$INSERT INTO vino(nombre,tipo,anada,volumen_ml,graduacion,precio,cuit_bodega) VALUES ('X','tinto',2021,500,14,1,'30711111112')$$, '23514');
SELECT pg_temp.expect('vino tipo invalido',
  $$INSERT INTO vino(nombre,tipo,anada,volumen_ml,graduacion,precio,cuit_bodega) VALUES ('X','naranja',2021,750,14,1,'30711111112')$$, '23514');
SELECT pg_temp.expect('RN-04 lote OK la primera vez (debe pasar)',
  $$INSERT INTO lote(id_finca,nro_parcela,campania,fecha_cosecha,kilos,cuit_bodega) VALUES (1,1,2024,'2024-03-10',1000,'30711111112')$$, 'OK');
SELECT pg_temp.expect('RN-04 lote repetido misma parcela y campania',
  $$INSERT INTO lote(id_finca,nro_parcela,campania,fecha_cosecha,kilos,cuit_bodega) VALUES (1,1,2024,'2024-03-20',500,'30711111112')$$, '23505');
SELECT pg_temp.expect('lote campania distinta al anio de cosecha',
  $$INSERT INTO lote(id_finca,nro_parcela,campania,fecha_cosecha,kilos,cuit_bodega) VALUES (1,1,2023,'2024-03-20',500,'30711111112')$$, '23514');
SELECT pg_temp.expect('RN-15 lote kilos = 0',
  $$INSERT INTO lote(id_finca,nro_parcela,campania,fecha_cosecha,kilos,cuit_bodega) VALUES (1,1,2022,'2022-03-20',0,'30711111112')$$, '23514');
SELECT pg_temp.expect('RN-07 permiso OK (debe pasar)',
  $$INSERT INTO permiso_exportacion(id_cliente,fecha_emision,fecha_vencimiento) VALUES (1,'2026-01-01','2027-01-01')$$, 'OK');
SELECT pg_temp.expect('RN-07 vencimiento = emision',
  $$INSERT INTO permiso_exportacion(id_cliente,fecha_emision,fecha_vencimiento) VALUES (1,'2026-01-01','2026-01-01')$$, '23514');
SELECT pg_temp.expect('RN-07 vencimiento anterior a emision',
  $$INSERT INTO permiso_exportacion(id_cliente,fecha_emision,fecha_vencimiento) VALUES (1,'2026-01-01','2025-01-01')$$, '23514');
SELECT pg_temp.expect('RN-06 descuento 150',
  $$INSERT INTO cliente(nombre_razon_social,tipo_doc,nro_doc,direccion,tipo_cliente,descuento,id_localidad) VALUES ('Z','DNI','9','d','socio',150,1)$$, '23514');
SELECT pg_temp.expect('UNIQUE cliente (tipo_doc,nro_doc)',
  $$INSERT INTO cliente(nombre_razon_social,tipo_doc,nro_doc,direccion,tipo_cliente,descuento,id_localidad) VALUES ('Z','DNI','1','d','socio',10,1)$$, '23505');
SELECT pg_temp.expect('cliente tipo_cliente invalido',
  $$INSERT INTO cliente(nombre_razon_social,tipo_doc,nro_doc,direccion,tipo_cliente,descuento,id_localidad) VALUES ('Z','DNI','8','d','vip',10,1)$$, '23514');
SELECT pg_temp.expect('RN-08 comprobante total incoherente',
  $$UPDATE comprobante SET subtotal = 100, descuento = 10, total = 95$$, '23514');
SELECT pg_temp.expect('RN-08 comprobante coherente (debe pasar)',
  $$UPDATE comprobante SET subtotal = 100, descuento = 10, total = 90$$, 'OK');
SELECT pg_temp.expect('RN-09 stock_sala negativo',
  $$INSERT INTO stock_sala VALUES (1,1,-1)$$, '23514');
SELECT pg_temp.expect('RN-09 stock_deposito negativo',
  $$UPDATE stock_deposito SET cantidad = -5$$, '23514');
SELECT pg_temp.expect('RN-15 renglon_comprobante cantidad = 0',
  $$INSERT INTO renglon_comprobante VALUES (1,1,0,12500,10,0)$$, '23514');
SELECT pg_temp.expect('RN-15 renglon_ingreso cantidad = 0',
  $$INSERT INTO renglon_ingreso VALUES (1,1,0)$$, '23514');
SELECT pg_temp.expect('RN-15 renglon_transferencia cantidad negativa',
  $$INSERT INTO renglon_transferencia VALUES (1,1,-3)$$, '23514');
SELECT pg_temp.expect('RN-15 empleado salario = 0',
  $$INSERT INTO empleado(cuit,nombre,salario,id_sala) VALUES ('20111111112','X',0,1)$$, '23514');
SELECT pg_temp.expect('RN-15 empleado: CUIT invalido (DOMAIN)',
  $$INSERT INTO empleado(cuit,nombre,salario,id_sala) VALUES ('123','X',100,1)$$, '22');
SELECT pg_temp.expect('sala dia_cierre invalido',
  $$INSERT INTO sala_venta(calle,numero,dia_cierre,id_localidad) VALUES ('C',1,'feriado',1)$$, '23514');
SELECT pg_temp.expect('transportista email sin arroba',
  $$INSERT INTO transportista(razon_social,cuit,email,telefono,domicilio) VALUES ('T','30733333334','sin-arroba','1','d')$$, '23514');
SELECT pg_temp.expect('UNIQUE transportista.cuit',
  $$INSERT INTO transportista(razon_social,cuit,email,telefono,domicilio) VALUES ('T','30722222223','a@b.com','1','d')$$, '23505');
SELECT pg_temp.expect('composicion porcentaje = 0',
  $$INSERT INTO composicion VALUES (1,1,0)$$, '23514');
SELECT pg_temp.expect('composicion porcentaje = 101',
  $$INSERT INTO composicion VALUES (1,1,101)$$, '23514');
SELECT pg_temp.expect('auditoria con precio igual',
  $$INSERT INTO auditoria_precio(cod_vino,precio_anterior,precio_nuevo) VALUES (1,100,100)$$, '23514');
SELECT pg_temp.expect('auditoria valida con defaults de fecha y usuario (debe pasar)',
  $$INSERT INTO auditoria_precio(cod_vino,precio_anterior,precio_nuevo) VALUES (1,100,120)$$, 'OK');
SELECT 'DEFAULT auditoria: usuario = ' || usuario || ', fecha_hora no nula: ' || (fecha_hora IS NOT NULL) FROM auditoria_precio;
SELECT pg_temp.expect('analisis ph = 15',
  $$INSERT INTO analisis_calidad(nro_lote,fecha,grado_brix,ph,acidez_total) VALUES (1,'2024-03-11',22,15,5)$$, '23514');
SELECT pg_temp.expect('parcela anio_plantacion = 1800',
  $$INSERT INTO parcela VALUES (1,2,1,1800,1)$$, '23514');
SELECT pg_temp.expect('maridaje temperatura = 40',
  $$INSERT INTO maridaje(nombre,temperatura_servicio) VALUES ('X',40)$$, '23514');
