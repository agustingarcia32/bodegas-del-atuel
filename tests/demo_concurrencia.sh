#!/bin/bash
# Demo de concurrencia (Etapa 2). Dos sesiones psql al mismo tiempo.
# Uso: PGDATABASE=bodegas ./demo_concurrencia.sh   (base con 001-006; deja datos de prueba)
P="psql -X -q -At -v ON_ERROR_STOP=0"
$P <<'SQL'
INSERT INTO localidad(nombre,provincia,cod_postal,encargado_regional) VALUES ('Conc','Mendoza','5600','E') ON CONFLICT DO NOTHING;
INSERT INTO sala_venta(calle,numero,dia_cierre,id_localidad) VALUES ('Conc',1,'lunes',(SELECT id_localidad FROM localidad WHERE nombre='Conc'));
INSERT INTO bodega VALUES ('30799999990','B conc','d') ON CONFLICT DO NOTHING;
INSERT INTO transportista(razon_social,cuit,email,telefono,domicilio) VALUES ('T conc','30799999991','a@b.com','1','d') ON CONFLICT DO NOTHING;
INSERT INTO cepa(nombre,tipo) VALUES ('CepaConc','tinta') ON CONFLICT DO NOTHING;
INSERT INTO cliente(nombre_razon_social,tipo_doc,nro_doc,direccion,tipo_cliente,id_localidad)
  VALUES ('C conc','DNI','conc1','d','socio',(SELECT id_localidad FROM localidad WHERE nombre='Conc'));
INSERT INTO socio SELECT id_cliente FROM cliente WHERE nro_doc='conc1';
BEGIN;
INSERT INTO vino(nombre,tipo,anada,volumen_ml,graduacion,precio,cuit_bodega) VALUES ('VConc','tinto',2024,750,14,1000,'30799999990');
INSERT INTO composicion SELECT currval(pg_get_serial_sequence('vino','cod_vino')),(SELECT id_cepa FROM cepa WHERE nombre='CepaConc'),100;
COMMIT;
INSERT INTO stock_sala SELECT (SELECT max(id_sala) FROM sala_venta),(SELECT max(cod_vino) FROM vino),1;
SQL
SALA=$($P -c "SELECT max(id_sala) FROM sala_venta"); VINO=$($P -c "SELECT max(cod_vino) FROM vino"); CLI=$($P -c "SELECT id_cliente FROM cliente WHERE nro_doc='conc1'")
echo "### Demo 1: dos clientes compran la ULTIMA botella (stock = 1) al mismo tiempo"
venta() { $P -c "BEGIN; INSERT INTO comprobante(id_cliente,id_sala) VALUES ($CLI,$SALA); INSERT INTO renglon_comprobante(nro_comprobante,cod_vino,cantidad) VALUES (currval(pg_get_serial_sequence('comprobante','nro_comprobante')),$VINO,1); SELECT pg_sleep(1); COMMIT;" 2>&1 | grep -v '^$' | sed "s/^/  sesion $1: /"; }
venta A & sleep 0.3; venta B & wait
echo "  stock final: $($P -c "SELECT cantidad FROM stock_sala WHERE id_sala=$SALA AND cod_vino=$VINO")  (nunca negativo)"
echo "  ventas del vino: $($P -c "SELECT count(*) FROM renglon_comprobante WHERE cod_vino=$VINO")  (solo una se concreta)"
echo
echo "### Demo 2: dos sesiones procesan el MISMO ingreso al mismo tiempo"
$P <<SQL
INSERT INTO ingreso(cod_transporte,cuit_bodega) VALUES ((SELECT max(cod_transporte) FROM transportista),'30799999990');
INSERT INTO renglon_ingreso VALUES (currval(pg_get_serial_sequence('ingreso','cod_ingreso')),$VINO,100);
UPDATE ingreso SET estado='terminado' WHERE cod_ingreso=currval(pg_get_serial_sequence('ingreso','cod_ingreso'));
SQL
ING=$($P -c "SELECT max(cod_ingreso) FROM ingreso"); ANT=$($P -c "SELECT coalesce(max(cantidad),0) FROM stock_deposito WHERE cod_vino=$VINO")
proc() { $P -c "BEGIN; CALL sp_procesar_ingreso($ING); SELECT pg_sleep(1); COMMIT;" 2>&1 | grep -v '^$' | sed "s/^/  sesion $1: /"; echo "  sesion $1: terminada"; }
proc A & sleep 0.3; proc B & wait
echo "  deposito antes: $ANT, despues: $($P -c "SELECT cantidad FROM stock_deposito WHERE cod_vino=$VINO")  (+100 una sola vez)"
