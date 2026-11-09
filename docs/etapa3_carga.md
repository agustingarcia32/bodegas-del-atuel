# Etapa 3 — Carga masiva

## Volúmenes (semilla 2026) — cumple los mínimos
Todas las tablas tienen filas; 5 tablas superan las 10.000 y 2 superan las 100.000.

| Tabla | Filas | Tabla | Filas |
|---|---:|---|---:|
| renglon_comprobante | 562.295 | vino_maridaje | 1.656 |
| comprobante | 150.720 | composicion | 1.322 |
| cliente | 20.000 | exportador | 982 |
| socio | 17.032 | stock_deposito | 800 |
| analisis_calidad | 10.490 | vino | 800 |
| renglon_transferencia | 9.037 | auditoria_precio | 894 |
| renglon_ingreso | 8.844 | parcela | 600 |
| stock_sala | 4.252 | empleado | 150 |
| ingreso / lote / transferencia | 3.000 c/u | transportista_localidad | 118 |
| permiso_exportacion | 2.768 | finca | 80 |
| distribuidor | 1.986 | sala_venta / bodega | 60 / 40 |
| | | localidad / transportista / cepa / maridaje | 28 / 25 / 12 / 8 |

Total: 803.999 filas. Base de ~80 MB; dump de 8 MB.

## Orden de carga (según claves foráneas)
```
nivel 0  localidad · cepa · maridaje · bodega · transportista
nivel 1  sala_venta · finca · transportista_localidad
nivel 2  empleado · parcela · vino · cliente
nivel 3  lote · composicion · vino_maridaje · socio · distribuidor · exportador
nivel 4  analisis_calidad · permiso_exportacion · ingreso · transferencia · comprobante
nivel 5  renglon_ingreso · renglon_transferencia · renglon_comprobante · stock_deposito · stock_sala · auditoria_precio
```

## Reproducibilidad
`random.Random(2026)` única fuente de azar, fecha de referencia fija (no `date.today()`). Dos corridas: misma huella sha256 `cfcb352a…e07e8c`; con otra semilla la huella cambia.

## Coherencia de los datos
- Catálogos reales desde CSV; el resto, generado.
- Ingresos y transferencias procesados desde 2020-06; ventas desde 2020-11 hasta ayer (así hay comprobantes de más de 5 años para D1); los documentos terminado / en_confeccion son de los últimos 65 días, así `v_documentos_pendientes` tiene datos. El 2 % de los clientes nunca compra (para D4 / D6); el 30 % de los exportadores tiene 4 o 5 permisos (para U6) y 12 vinos «estrella» se vendieron en las 60 salas (para S2). Esos agregados usan un segundo generador aleatorio (`semilla + 1`) para no alterar el resto de los datos.
- Las consultas con «última semana / trimestre» usan `CURRENT_DATE`: si presentan días después de la fecha de referencia (2026-11-06), regeneren con `python generar_datos.py --hoy AAAA-MM-DD` y vuelvan a cargar.
- Cada ingreso trae solo vinos de su bodega y con añada ≤ año del ingreso. Cosecha en feb–abr; los análisis de calidad son anteriores o del mismo día que la cosecha de su lote.
- Cortes de vino que suman exactamente 100. Descuentos 10/20/30 según el tipo de cliente. El precio del renglón es el que tenía el vino en la fecha de la venta (historial reflejado en `auditoria_precio`; el último precio nuevo = precio actual).
- Stock final = stock inicial + lo que entra − lo que sale, calculado para que nunca sea negativo.
- Subtotales redondeados igual que `fn_subtotal_renglon` (half-up, centavos enteros: sin errores de coma flotante).

## Triggers durante la carga (decisión y riesgos)
Se usa `ALTER TABLE … DISABLE TRIGGER USER` en las 29 tablas y `ENABLE TRIGGER USER` al final (en un `finally`, para que no queden deshabilitados si la carga falla).
- **Por qué:** el trigger de ventas bloquea y descuenta stock fila por fila (561 mil veces) y el historial ya viene con el stock final calculado; dejarlos activos duplicaría los movimientos.
- **Por qué USER y no ALL:** `ALL` también apaga los triggers internos de las claves foráneas y requiere superusuario. Con `USER` las FK y los CHECK siguen protegiendo la carga.
- **Riesgos:** mientras están apagados nada valida las reglas que viven en triggers (RN-05, RN-08, RN-09, RN-10/11/12, RN-13). Por eso la carga se hace con la API detenida y con el propietario, y se valida después con `consultas_control.sql` (cortes = 100, totales, stock, estados). Si alguien olvida volver a habilitarlos, `SELECT tgname, tgenabled FROM pg_trigger WHERE NOT tgisinternal` lo muestra.
- Verificado después de cargar: 14 triggers habilitados, 0 deshabilitados; una venta y un `sp_procesar_ingreso` sobre los datos cargados funcionan (se probaron en una transacción con ROLLBACK).

## Tiempos
Carga completa con COPY (`psql \copy`): **10,4 s** (renglon_comprobante ≈ 5 s, el resto menos de 1 s cada una).

Comparación de métodos, 20.000 filas, PostgreSQL 16 con `fsync` activado (`bench_carga.py`, archivo `seed/resultado_benchmark.txt`):

| Método | Tiempo | Filas/s | Veces más rápido |
|---|---:|---:|---:|
| 1) fila por fila, un COMMIT por fila | 3,96 s | 5.055 | 1,0× |
| 2) fila por fila, una transacción | 1,04 s | 19.197 | 3,8× |
| 3) lotes de 1.000 filas | 0,10 s | 192.857 | 38× |
| 4) COPY | 0,05 s | 409.566 | 81× |

Lectura: lo más caro del método 1 no es insertar sino confirmar (un COMMIT con escritura a disco por fila); la transacción única lo reparte; agrupar sentencias evita el viaje de ida y vuelta y el análisis de cada INSERT; COPY evita además el análisis SQL por fila. Medido con psql (una sentencia por fila ≈ `execute`; lotes ≈ `executemany`/`execute_values`); los números en sus máquinas serán otros, la proporción no. Hay una versión de `bench_carga.py` para psycopg que no pude ejecutar acá.

## Consultas de control (resultado real)
20 controles, todos con 0 problemas: huérfanos (5), stock negativo, totales de comprobante vs renglones, subtotal vs `fn_subtotal_renglon`, descuento del renglón vs cliente, descuento vs tipo, subtipo de cliente, cortes ≠ 100, vinos sin composición, ventas antes del alta del cliente, ventas antes del primer ingreso, ingresos con vinos de otra bodega o añada posterior, análisis posteriores a la cosecha, última auditoría vs precio actual, documentos pendientes viejos. Se repitió después de restaurar `dump_completo.sql.gz` en una base nueva: mismo resultado.
