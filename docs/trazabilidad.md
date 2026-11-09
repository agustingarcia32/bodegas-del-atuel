# Trazabilidad de reglas de negocio

Cada regla → qué mecanismo la protege → dónde está → qué caso la prueba (`tests/db_tests.sql`, 87 casos, todos PASA; ver `tests/resultado_db_tests.txt`).

| Regla | Mecanismo | Archivo / objeto | Casos de prueba |
|---|---|---|---|
| RN-01 precio único y > 0 | atributo `vino.precio` (no hay precio por sala) + CHECK | 002 `ck_vino_precio_positivo` | precio 0, precio negativo, no existe precio en `stock_sala` |
| RN-02 sala en una localidad; localidad con un encargado | FK NOT NULL + `encargado_regional` solo en `localidad` (3FN) + UNIQUE | 001 `sala_venta.id_localidad`; 002 `uq_localidad_nombre_provincia` | localidad inexistente, sin localidad, localidad repetida, encargado solo en localidad |
| RN-03 empleado en una sala | FK NOT NULL | 001 `empleado.id_sala` | sala válida, sin sala, sala inexistente |
| RN-04 parcela con una cepa; una cosecha por parcela y campaña | FK NOT NULL en `parcela.id_cepa` + UNIQUE (parcela, campaña) | 001; 002 `uq_lote_parcela_campania` | parcela sin cepa, 2ª cosecha misma campaña, otra campaña sí |
| RN-05 cortes suman 100 | constraint trigger DEFERRABLE INITIALLY DEFERRED | 005 `trg_composicion_suma` / `fn_chequear_suma_composicion` | 70 no suma, 70+30 sí, 101 rechazado por CHECK (+ `test_005_rn05_diferido.sql`) |
| RN-06 descuento por tipo | función `fn_descuento_cliente` + trigger BEFORE INSERT + CHECK 0..100 | 003; 005 `trg_cliente_descuento`; 002 | 10/20/30, tipo desconocido, fuera de rango, cliente sin descuento |
| RN-07 permisos del exportador; vencimiento > emisión | tabla `permiso_exportacion` (FK a `exportador`) + CHECK entre columnas | 001; 002 `ck_permiso_vencimiento_posterior` | dos permisos, igual, anterior, cliente socio |
| RN-08 total = suma de renglones con descuento | `fn_subtotal_renglon`, `fn_total_comprobante` + trigger AFTER en renglones + CHECK de coherencia | 003; 005 `trg_renglon_stock_totales`; 002 `ck_comprobante_total_coherente` | 2500 / 250 / 2250, suma de renglones, total manual incoherente |
| RN-09 no vender más que el stock; stock ≥ 0 | trigger BEFORE INSERT (con `FOR UPDATE`) + CHECK | 005 `trg_renglon_valida_stock`; 002 `ck_stock_sala_no_negativo` | 9 con 8, vino que la sala no tiene, justo 8, stock negativo directo, carrera por la última botella (`demo_concurrencia.sh`) |
| RN-10 ingreso: estados sin retroceso, solo terminado impacta | ENUM + trigger de estados + `sp_procesar_ingreso` | 001; 005 `trg_ingreso_estado`; 004 | saltar estado, procesar sin terminar, a mano, retroceder, doble procesamiento, estado inexistente |
| RN-11 igual para transferencias; fecha = hoy e inmodificable | ENUM + triggers de estado y fecha + `sp_procesar_transferencia` | 005 `trg_transferencia_estado`, `trg_transferencia_fecha`; 004 | fecha pisada, fecha inmodificable, estados, stock insuficiente en depósito |
| RN-12 renglones solo en confección | trigger sobre los renglones | 005 `trg_renglon_ingreso_bloqueo`, `trg_renglon_transferencia_bloqueo` | agregar / modificar / quitar en procesado y terminado; en confección sí; borrar documento arrastra renglones |
| RN-13 auditoría de precios | trigger AFTER UPDATE OF precio + tabla `auditoria_precio` (app_rw no puede modificarla) | 005 `trg_vino_auditoria`; 007 | cambio auditado con usuario, mismo precio y otro campo no auditan, CHECK de la tabla |
| RN-14 no borrar con movimientos | FK `ON DELETE RESTRICT` | 001 | vino con ventas, bodega con vinos, transportista con ingresos, vino sin uso sí |
| RN-15 positivos; graduación 5–20 | CHECK | 002 (`ck_*_positiv*`, `ck_vino_graduacion_rango`) | 4.9, 20.1, 5 y 20 válidas, superficies, kilos, salario, cantidades, stock |

## Cómo se corre

```
psql -d bodegas -f tests/db_tests.sql        # base vacía con 001-006
```
