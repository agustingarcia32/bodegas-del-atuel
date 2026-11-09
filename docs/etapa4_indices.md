# Etapa 4 — Índices y rendimiento

Entorno de medición: PostgreSQL 16.15, `fsync` activado, `shared_buffers` 128 MB, `work_mem` 4 MB, base cargada con la semilla 2026 (562.295 renglones, 150.720 comprobantes, 20.000 clientes), `VACUUM ANALYZE` antes de medir. Cada consulta con `EXPLAIN (ANALYZE, BUFFERS)`, mediana de 5 corridas (Q4: una sola antes, tarda 83 s; tres después), caché caliente. Planes completos en `rendimiento/planes_antes/` y `rendimiento/planes_despues/`; consultas en `rendimiento/consultas_medidas.sql`; se repite con `python medir.py <carpeta>`. Los tiempos en otra máquina serán otros; las proporciones y el tipo de recorrido, no.

## Índices creados (`migrations/008_indices.sql`)
| # | Índice | Tipo | Ayuda a | Tamaño |
|---|---|---|---|---:|
| 1 | `idx_comprobante_sala_fecha (id_sala, fecha)` | compuesto | S3, ventas de una sala en un período | 3,8 MB |
| 2 | `idx_comprobante_fecha_cubriente (fecha) INCLUDE (id_sala, total)` | cubriente (INCLUDE) | S8 | 6,0 MB |
| 3 | `idx_comprobante_cliente_fecha (id_cliente, fecha DESC)` | clave foránea | historial de cliente, S12, D4, D6 | 4,4 MB |
| 4 | `idx_renglon_comprobante_vino (cod_vino) INCLUDE (cantidad)` | clave foránea | S12, S2 (y S1, ver abajo) | 14 MB |
| 5 | `idx_transferencia_pendientes (id_sala) WHERE estado <> 'procesado'` | parcial | S5, vista de pendientes | 16 kB |
| 6 | `idx_cliente_nombre_lower (lower(nombre_razon_social) text_pattern_ops)` | de expresión | búsqueda de clientes de la API | 192 kB |
| 7 | `idx_stock_sala_vino (cod_vino)` | clave foránea | S6, S9, `v_stock_total_vino` | 64 kB |
| 8 | `idx_cliente_localidad (id_localidad)` | clave foránea | D6, chequeo de FK al borrar una localidad | 160 kB |

Crear los 8 sobre la base cargada tarda menos de 1 s.

## Tabla comparativa
| Consulta | Antes | Después | Mejora | Recorrido antes → después | Páginas leídas antes → después |
|---|---:|---:|---:|---|---:|
| Q1 · S8 ventas por sala, último trimestre | 18,45 ms | 2,48 ms | 7× | Parallel Seq Scan → **Index Only Scan** (#2) | 1.303 → 35 |
| Q2 · S3 clientes por tipo, sala 7, última semana | 8,61 ms | 0,19 ms | 45× | Parallel Seq Scan → **Bitmap Heap Scan** (#1) | 1.316 → 37 |
| Q4 · S12 clientes que compraron todos los vinos de una bodega | **83.235 ms** | **601 ms** | **138×** | Seq Scan de comprobante ×20.652 → Bitmap Heap Scan (#3) | 26.619.879 → 677.069 |
| Q5 historial de un cliente | 6,83 ms | 0,14 ms | 49× | Seq Scan → Bitmap Heap Scan (#3) | 1.291 → 13 |
| Q7 búsqueda por prefijo de nombre | 4,83 ms | 0,34 ms | 14× | Seq Scan → Bitmap Heap Scan (#6) | 259 → 83 |
| Q6 · S5 transferencias pendientes | 0,24 ms | 0,12 ms | 2× | Seq Scan → Index Only Scan (#5) | 23 → 8 |
| Q3 · S1 top 10 vinos vendidos | 108 ms | 114 ms | sin mejora | Parallel Seq Scan → Parallel Seq Scan (#4 no se usa) | 4.216 → 4.216 |
| Q8 · S4 pedidos de un vino en 15 días | 0,52 ms | 0,48 ms | sin índice nuevo | Seq Scan de `renglon_transferencia` (tabla de 9.000 filas) | 100 → 100 |

Lo más importante: **S12 pasa de 83 segundos a 0,6 segundos**. La consulta busca, para cada uno de los 20.000 clientes, si compró cierto vino: sin índice sobre `comprobante(id_cliente)` cada una de esas 20.652 búsquedas recorre toda la tabla de comprobantes. Es el caso típico de una clave foránea sin índice.

## Por qué ese orden en el índice compuesto
`(id_sala, fecha)` y no `(fecha, id_sala)`: `id_sala` se filtra con `=` y `fecha` con un rango. Con el orden elegido, el índice también sirve para consultas que filtran **solo** por sala (el prefijo). Experimento E1 (`experimentos_resultado.txt`):
- Para «sala 7, últimos 90 días» los dos órdenes leen lo mismo (108 páginas de tabla para 109 filas, 0,4–0,5 ms): en esta consulta no hay diferencia medible.
- Para «todas las ventas de la sala 7» con `(fecha, id_sala)` el planificador **no puede usar el índice** (Seq Scan, 1.288 páginas, 6,8 ms); con `(id_sala, fecha)` usa el prefijo (1,4 ms).

## Índices evaluados y descartados
1. **BRIN sobre `comprobante(fecha)`** (E2). Pesa 24 kB contra 4,6 MB del btree, pero BRIN solo sirve si el orden físico de la tabla sigue al de la columna. Acá la correlación entre `fecha` y la posición física es **−0,007** (los comprobantes se numeran en el orden de carga, no por fecha; `nro_comprobante` sí tiene correlación 1,000). Resultado: el planificador hace Seq Scan y S8 tarda 12,6 ms, como sin índice. Descartado. Sería útil en una tabla de eventos que se agrega siempre en orden cronológico.
2. **`renglon_transferencia(cod_vino)` para S4** (E3). Baja S4 de 0,74 ms a 0,07 ms (10×), pero la tabla tiene 9.000 filas: la ganancia absoluta es de 0,7 ms. Cada índice se paga en cada INSERT/UPDATE/DELETE; no se justifica hoy. Se revisa si la tabla crece 100 veces.

## Casos en que el planificador no usa un índice existente
- **Baja selectividad (E4).** Con un índice de prueba sobre `cliente(tipo_cliente)`, `WHERE tipo_cliente = 'socio'` (85 % de la tabla, 17.032 filas) hace **Seq Scan** (1,6 ms); forzando el índice con `enable_seqscan = off` tarda lo mismo (1,6 ms) pero visita casi la tabla entera de todos modos. Con `'exportador'` (4,9 %) sí usa el índice (Bitmap Heap Scan, 0,26 ms). Moraleja: un índice sobre una columna con pocos valores y muy desparejos solo ayuda para los valores raros. Es por eso que no se creó.
- **S1 lee toda la tabla (E5).** `idx_renglon_comprobante_vino` existe, pero S1 suma las 561.575 filas: el planificador prefiere el Parallel Seq Scan. Forzando el índice (`enable_seqscan = off`) lee menos páginas (1.609 contra 4.213 del Seq Scan) y en esta corrida tarda 65 ms contra 76 ms; en corridas anteriores dio 67 contra 72 y 77 contra 73: la diferencia cambia de signo según la corrida, es ruido. Un índice no acelera una consulta que necesita todas las filas. El índice #4 se justifica por S12/S2, no por S1.

## Costo de escritura
Recarga de `comprobante` + `renglon_comprobante` (712.000 filas) con COPY, de `costo_escritura.py` (`resultado_costo_escritura.txt`), índices de 008 sobre esas dos tablas: 22 MB.

| Escenario | comprobante | renglon | total |
|---|---:|---:|---:|
| A) solo claves primarias | 1,58 s | 5,21 s | 6,79 s |
| B) con los índices de 008 creados antes de cargar | 2,43 s | 6,44 s | 8,88 s (+31 %) |
| C) cargar sin índices y crearlos después | 1,80 s | 5,79 s | 8,18 s (0,58 s de crear los índices) |

5.000 `INSERT` de comprobante uno por uno en una transacción: 0,56 s sin índices, 0,61 s con ellos (+8 %).

Conclusión: los índices agregan alrededor de 30 % al costo de la carga masiva (y entre 8 y 25 % en inserciones sueltas, según la corrida). Para la carga masiva inicial conviene el escenario C (cargar y después indexar); el escenario A es el más rápido porque no hay nada que mantener, pero deja la base sin los índices. En operación normal el costo es aceptable porque las ventas son una escritura por cliente y las consultas de lectura mejoran de 2× a 138×.

## Limitaciones de la medición
- Una sola máquina, caché caliente; las diferencias menores a ~1 ms están dentro del ruido (por eso E1 no concluye por tiempos).
- Q4 se midió una sola vez por durar 81 s.
- No se midió con varias sesiones concurrentes.
