\set ON_ERROR_STOP on
\pset format unaligned
\pset tuples_only on

CREATE FUNCTION pg_temp.chk(label text, ok boolean) RETURNS text
LANGUAGE sql AS $$ SELECT CASE WHEN ok THEN 'PASA  ' ELSE 'FALLA ' END || label $$;

CREATE FUNCTION pg_temp.err(stmt text) RETURNS text
LANGUAGE plpgsql AS $$
BEGIN EXECUTE stmt; RETURN 'OK';
EXCEPTION WHEN OTHERS THEN RETURN SQLSTATE; END $$;

-- ---------- volatilidad declarada ----------
SELECT proname || ' -> ' || CASE provolatile WHEN 'i' THEN 'IMMUTABLE' WHEN 's' THEN 'STABLE' ELSE 'VOLATILE' END
  FROM pg_proc WHERE pronamespace = 'public'::regnamespace AND proname LIKE 'fn\_%' ORDER BY proname;

-- ---------- fn_descuento_cliente ----------
SELECT pg_temp.chk('descuento socio = 10',        fn_descuento_cliente('socio') = 10);
SELECT pg_temp.chk('descuento distribuidor = 20', fn_descuento_cliente('distribuidor') = 20);
SELECT pg_temp.chk('descuento exportador = 30',   fn_descuento_cliente('exportador') = 30);
SELECT pg_temp.chk('descuento tipo invalido -> 22023', pg_temp.err($$SELECT fn_descuento_cliente('vip')$$) = '22023');
SELECT pg_temp.chk('descuento tipo NULL -> error',     pg_temp.err($$SELECT fn_descuento_cliente(NULL)$$) = '22023');

-- ---------- datos base ----------
INSERT INTO localidad(nombre,provincia,cod_postal,encargado_regional) VALUES ('San Rafael','Mendoza','5600','Enc');
INSERT INTO sala_venta(calle,numero,dia_cierre,id_localidad) VALUES ('Belgrano',100,'lunes',1);
INSERT INTO bodega VALUES ('30711111112','Bodega Uno','Domicilio 1');
INSERT INTO vino(nombre,tipo,anada,volumen_ml,graduacion,precio,cuit_bodega) VALUES
  ('Malbec Reserva','tinto',2021,750,14,12500,'30711111112'),
  ('Torrontes','blanco',2023,750,13,8000,'30711111112');
INSERT INTO cliente(nombre_razon_social,tipo_doc,nro_doc,direccion,tipo_cliente,descuento,id_localidad)
  VALUES ('Socio','DNI','1','d','socio',10,1);
INSERT INTO stock_sala VALUES (1,1,7);

-- ---------- fn_stock_sala ----------
SELECT pg_temp.chk('stock sala 1 / vino 1 = 7',                 fn_stock_sala(1,1) = 7);
SELECT pg_temp.chk('stock sala 1 / vino 2 (sin fila) = 0',      fn_stock_sala(1,2) = 0);
SELECT pg_temp.chk('stock sala inexistente = 0, no NULL',       fn_stock_sala(99,1) = 0);

-- ---------- fn_subtotal_renglon ----------
SELECT pg_temp.chk('subtotal 3 x 12500 con 10% = 33750.00',      fn_subtotal_renglon(3,12500,10) = 33750.00);
SELECT pg_temp.chk('subtotal 7 x 1234.57 con 15% = 7345.69',     fn_subtotal_renglon(7,1234.57,15) = 7345.69);
SELECT pg_temp.chk('redondeo mitad hacia arriba 5.025 -> 5.03',  fn_subtotal_renglon(1,10.05,50) = 5.03);
SELECT pg_temp.chk('subtotal sin descuento = bruto',             fn_subtotal_renglon(4,100,0) = 400.00);
SELECT pg_temp.chk('subtotal con 100% = 0',                      fn_subtotal_renglon(4,100,100) = 0);
SELECT pg_temp.chk('subtotal con argumento NULL = NULL',         fn_subtotal_renglon(NULL,100,10) IS NULL);

-- ---------- fn_total_comprobante ----------
INSERT INTO comprobante(id_cliente,id_sala) VALUES (1,1), (1,1);
INSERT INTO renglon_comprobante VALUES
  (1,1,3,12500,10,fn_subtotal_renglon(3,12500,10)),
  (1,2,2,8000, 10,fn_subtotal_renglon(2,8000,10));
SELECT pg_temp.chk('total comprobante 1 = 33750 + 14400 = 48150.00', fn_total_comprobante(1) = 48150.00);
SELECT pg_temp.chk('comprobante sin renglones = 0, no NULL',          fn_total_comprobante(2) = 0);
SELECT pg_temp.chk('comprobante inexistente = 0',                     fn_total_comprobante(9999) = 0);
-- el CHECK de 002 acepta lo que el trigger va a escribir a partir de estas funciones
SELECT pg_temp.chk('UPDATE de importes coherente con la funcion (CHECK de 002)',
  pg_temp.err($$UPDATE comprobante c SET
      subtotal  = (SELECT SUM(cantidad * precio_unitario) FROM renglon_comprobante WHERE nro_comprobante = c.nro_comprobante),
      total     = fn_total_comprobante(c.nro_comprobante),
      descuento = (SELECT SUM(cantidad * precio_unitario) FROM renglon_comprobante WHERE nro_comprobante = c.nro_comprobante)
                  - fn_total_comprobante(c.nro_comprobante)
    WHERE nro_comprobante = 1$$) = 'OK');
SELECT 'comprobante 1 -> subtotal ' || subtotal || ', descuento ' || descuento || ', total ' || total
  FROM comprobante WHERE nro_comprobante = 1;

-- ---------- fn_antiguedad_anios ----------
SELECT pg_temp.chk('hoy menos 6 anios = 6',                     fn_antiguedad_anios((CURRENT_DATE - INTERVAL '6 years')::date) = 6);
SELECT pg_temp.chk('hoy menos 5 anios exactos = 5',             fn_antiguedad_anios((CURRENT_DATE - INTERVAL '5 years')::date) = 5);
SELECT pg_temp.chk('5 anios y 11 meses = 5 (anios cumplidos)', fn_antiguedad_anios((CURRENT_DATE - INTERVAL '5 years 11 months')::date) = 5);
SELECT pg_temp.chk('hoy = 0',                                   fn_antiguedad_anios(CURRENT_DATE) = 0);
SELECT pg_temp.chk('fecha futura = 0, no negativo',             fn_antiguedad_anios(CURRENT_DATE + 30) = 0);
SELECT pg_temp.chk('NULL = NULL',                               fn_antiguedad_anios(NULL) IS NULL);

-- ---------- uso real: consigna U2 / D3 ----------
INSERT INTO empleado(cuit,nombre,fecha_ingreso,salario,id_sala) VALUES
  ('20111111112','Veterano', CURRENT_DATE - INTERVAL '7 years', 1000, 1),
  ('20111111113','Justo 5',  CURRENT_DATE - INTERVAL '5 years', 1000, 1),
  ('20111111114','Nuevo',    CURRENT_DATE - INTERVAL '1 year',  1000, 1);
SELECT pg_temp.chk('U2: empleados con mas de 5 anios = 1 (solo el veterano)',
  (SELECT count(*) FROM empleado WHERE fn_antiguedad_anios(fecha_ingreso) > 5) = 1);
SELECT pg_temp.chk('D3: empleados con menos de 2 anios = 1 (solo el nuevo)',
  (SELECT count(*) FROM empleado WHERE fn_antiguedad_anios(fecha_ingreso) < 2) = 1);
