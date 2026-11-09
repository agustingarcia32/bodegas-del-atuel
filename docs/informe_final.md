# Bodegas del Atuel — Informe final

**Trabajo Práctico Integrador · Bases de Datos · Ingeniería en Sistemas · UTN FRSR**
Integrantes: [nombres y apellidos] · Docentes: [nombres] · Fecha: [fecha]
Repositorio: [URL] · Sistema en la nube: [URL pública]

> Todas las cifras de este informe provienen de las pruebas y mediciones incluidas en el repositorio (cada sección indica el archivo). Los textos entre corchetes `[...]` deben completarse con material propio del grupo.

---

## 1. Introducción y alcance

Se diseñó e implementó la base de datos de una cooperativa de bodegas del sur mendocino. Las bodegas entregan vino al **depósito central**; del depósito se **transfieren** botellas a las **salas de venta**, donde se **venden** a clientes. Los clientes son de tres tipos (socios, distribuidores y exportadores) y cada tipo recibe un descuento distinto.

**Criterio central del trabajo:** las reglas del negocio viven dentro de PostgreSQL (restricciones, triggers y procedimientos), de modo que valgan para cualquier cliente de la base (API, scripts o consola). La API y el front son capas finas que no repiten reglas.

**Alcance:** las nueve etapas del enunciado: modelo, lógica en la base, carga masiva, índices, consultas SQL, API, front, despliegue y documentación. No se implementó autenticación de usuarios finales, por estar fuera de la consigna.

**Tecnologías:** PostgreSQL 16, Python (Flask y psycopg 3), HTML y JavaScript sin frameworks, Docker Compose.

**Resumen de lo construido**

| Elemento | Cantidad |
|---|---:|
| Tablas | 29 |
| Claves foráneas / UNIQUE / CHECK | 34 / 8 / 40 |
| Funciones de negocio / procedimientos | 5 / 2 |
| Triggers | 14 |
| Vistas | 4 |
| Roles | 3 (propietario, `app_rw`, `app_ro`) |
| Índices propios | 8 |
| Filas cargadas | 803.999 |
| Consultas SQL | 30 (6 + 6 + 6 + 12) |
| Casos de prueba de la base | 87 |
| Pruebas de la API | 17 |

---

## 2. Modelo de datos

### 2.1 Diagrama entidad-relación y esquema relacional
[Insertar el DER y el esquema relacional del grupo. Copiar los archivos a `docs/`.]

Las 29 tablas se agrupan así:

| Grupo | Tablas |
|---|---|
| Producción | `bodega`, `finca`, `parcela`, `lote`, `analisis_calidad` |
| Producto | `vino`, `cepa`, `composicion`, `maridaje`, `vino_maridaje` |
| Lugares y personas | `localidad`, `sala_venta`, `empleado` |
| Clientes | `cliente`, `socio`, `distribuidor`, `exportador`, `permiso_exportacion` |
| Ventas | `comprobante`, `renglon_comprobante` |
| Logística | `transportista`, `transportista_localidad`, `ingreso`, `renglon_ingreso`, `transferencia`, `renglon_transferencia` |
| Stock | `stock_deposito`, `stock_sala` |
| Auditoría | `auditoria_precio` |

Patrones del modelo: **cabecera y renglones** (`comprobante`, `ingreso`, `transferencia`), **supertipo y subtipos** (`cliente` con `socio`, `distribuidor` y `exportador`) y **estados** (`en_confeccion → terminado → procesado`, un tipo ENUM).

### 2.2 Normalización
[Pegar el análisis de normalización del grupo.] Puntos que se reflejan en el esquema final: llega a 3FN; el encargado regional vive en `localidad` y no en la sala; el precio pertenece al vino (no hay precio por sala); el stock se separa en depósito y salas.

### 2.3 Diccionario de datos
[Pegar o enlazar el diccionario de datos.]

### 2.4 Decisiones de diseño
- El descuento depende del tipo de cliente y lo completa la base.
- El precio vigente está en `vino`; cada cambio queda en `auditoria_precio` (precio anterior, nuevo, fecha y usuario).
- Los importes se guardan en `NUMERIC(10,2)`; la carga masiva trabaja en centavos enteros para evitar errores de coma flotante.
- Tipos propios: ENUM `estado_documento` y DOMAIN de CUIT (11 dígitos).
- Los comprobantes y renglones borrados se consideran historial: no devuelven stock.
- [Decisión pendiente del grupo: bodega del ingreso frente a la bodega de los vinos.]

---

## 3. Integridad y lógica en la base

### 3.1 Tabla de trazabilidad: regla → mecanismo → prueba
Detalle completo en `docs/trazabilidad.md`. Las pruebas están en `tests/db_tests.sql` (**87 casos, 87 aprobados**, salida en `tests/resultado_db_tests.txt`).

| Regla | Mecanismo | Prueba |
|---|---|---|
| RN-01 Precio único y mayor que 0 | Atributo `vino.precio` + CHECK | Precio 0, negativo; no existe precio por sala |
| RN-02 Sala en una localidad; localidad con un encargado | FK NOT NULL + `encargado_regional` en `localidad` + UNIQUE | Localidad inexistente o repetida |
| RN-03 Empleado en una sala | FK NOT NULL | Sin sala, sala inexistente |
| RN-04 Parcela con una cepa; una cosecha por parcela y campaña | FK NOT NULL + UNIQUE (parcela, campaña) | Segunda cosecha en la misma campaña |
| RN-05 Los cortes suman 100 | Constraint trigger diferido | 70 no suma; 70 + 30 sí; 101 rechazado |
| RN-06 Descuento por tipo de cliente | `fn_descuento_cliente` + trigger BEFORE INSERT + CHECK 0..100 | 10 / 20 / 30; tipo desconocido |
| RN-07 Permisos del exportador; vencimiento posterior a emisión | Tabla `permiso_exportacion` + CHECK entre columnas | Vencimiento anterior; cliente socio |
| RN-08 Total = suma de renglones con descuento | `fn_subtotal_renglon`, `fn_total_comprobante` + trigger AFTER + CHECK | 2500 / 250 / 2250; total incoherente |
| RN-09 No vender más que el stock; stock ≥ 0 | Trigger BEFORE con `FOR UPDATE` + CHECK | Pedir 9 con 8; carrera por la última botella |
| RN-10 Ingreso: estados sin retroceso; solo «terminado» impacta | ENUM + trigger de estados + `sp_procesar_ingreso` | Saltar estado, procesar dos veces |
| RN-11 Igual para transferencias; fecha = hoy e inmodificable | ENUM + triggers + `sp_procesar_transferencia` | Fecha pisada; stock insuficiente en depósito |
| RN-12 Renglones solo en confección | Trigger sobre los renglones | Agregar o quitar en procesado |
| RN-13 Auditoría de precios | Trigger AFTER UPDATE OF precio + tabla de auditoría | Cambio auditado con usuario |
| RN-14 No borrar con movimientos | FK `ON DELETE RESTRICT` | Vino con ventas, bodega con vinos |
| RN-15 Cantidades positivas; graduación 5 a 20 | CHECK | 4,9 y 20,1 rechazados |

### 3.2 Guía: dónde va cada regla
| Si la regla es… | Se usa… | Ejemplo |
|---|---|---|
| Sobre el valor de una columna | CHECK o DOMAIN | Graduación entre 5 y 20 |
| Entre dos tablas | Clave foránea | No borrar un vino con ventas |
| Entre varias filas, o debe modificar otras tablas | Trigger | Descontar stock; cortes que suman 100 |
| Una secuencia de pasos todo o nada | Procedimiento | Procesar un ingreso |
| Quién puede hacer qué | Roles y permisos | La API no puede borrar tablas |

Un CHECK solo mira una fila y debe dar siempre el mismo resultado (por eso ninguno usa `CURRENT_DATE`). Lo que depende de otras filas o de otras tablas va en un trigger.

### 3.3 Funciones, procedimientos y vistas
- **Funciones:** `fn_descuento_cliente` (IMMUTABLE), `fn_stock_sala`, `fn_subtotal_renglon`, `fn_total_comprobante` y `fn_antiguedad_anios` (STABLE, porque usa la fecha actual; STRICT).
- **Procedimientos transaccionales:** `sp_procesar_ingreso` suma stock al depósito; `sp_procesar_transferencia` lo mueve a una sala, verificando el stock de cada vino y bloqueando las filas siempre en el mismo orden para evitar interbloqueos. Una variable de sesión (`atuel.procesando`) autoriza el paso a «procesado» solo desde los procedimientos.
- **Vistas:** `v_stock_total_vino`, `v_ventas_mensuales_sala`, `v_documentos_pendientes` y `v_ficha_vino`.

### 3.4 Roles y permisos
| Rol | Uso | Permisos |
|---|---|---|
| Propietario | Armar el esquema y cargar datos masivos | Todos |
| `app_rw` | La API | Leer y escribir; sin DDL; sin borrar stock; sin modificar la auditoría |
| `app_ro` | Reportes | Solo lectura |

Se revocan los permisos de `PUBLIC`. Las contraseñas se pasan por variable de entorno (el script `007_roles.sql` se detiene si faltan o son demasiado cortas). Las pruebas (`tests/test_007_roles_denegados.sql`) verifican, por ejemplo, que `app_rw` no puede ejecutar `DROP TABLE`, `TRUNCATE` ni `ALTER TABLE` (error `42501`).

### 3.5 Demostración de concurrencia
Archivo: `tests/demo_concurrencia.sh`; salida en `tests/resultado_concurrencia.txt`.

**Prueba 1: la última botella.** Con stock 1, dos sesiones compran a la vez. El trigger bloquea la fila con `SELECT … FOR UPDATE`: la primera descuenta y confirma; la segunda espera, ve stock 0 y es rechazada.
```
sesion B: ERROR: Stock insuficiente del vino 1 en la sala 1 (hay 0, se piden 1) (RN-09)
stock final: 0  (nunca negativo)
ventas del vino: 1  (solo una se concreta)
```
**Prueba 2: el mismo ingreso procesado dos veces.** La segunda sesión espera, ve el estado «procesado» y falla; el depósito sube +100 una sola vez.

Sin el bloqueo, ambas sesiones leerían stock 1 (nivel READ COMMITTED) y venderían la misma botella; el CHECK `stock >= 0` actuaría solo como red de seguridad, con un error menos claro.

[Captura de la demostración]

---

## 4. Carga masiva

### 4.1 Datos y volúmenes
Los catálogos (bodegas, localidades, cepas, maridajes, transportistas y otros) se cargan desde CSV (`seed/catalogos/`). El resto lo genera `seed/generar_datos.py` con semilla fija (2026): dos corridas producen los mismos datos (misma huella sha256).

Total: **803.999 filas**, base de unos 80 MB. Cinco tablas superan las 10.000 filas y dos superan las 100.000 (`renglon_comprobante` 562.295 y `comprobante` 150.720). Otras: `cliente` 20.000, `socio` 17.032, `analisis_calidad` 10.490.

Coherencia garantizada por el generador: cortes que suman exactamente 100; ventas posteriores al primer ingreso procesado; ingresos solo con vinos de su bodega; stock final nunca negativo; descuentos según el tipo de cliente; precio del renglón igual al vigente el día de la venta; importes con el mismo redondeo que `fn_subtotal_renglon`.

### 4.2 Orden de carga (según claves foráneas)
```
nivel 0  localidad · cepa · maridaje · bodega · transportista
nivel 1  sala_venta · finca · transportista_localidad
nivel 2  empleado · parcela · vino · cliente
nivel 3  lote · composicion · vino_maridaje · socio · distribuidor · exportador
nivel 4  analisis_calidad · permiso_exportacion · ingreso · transferencia · comprobante
nivel 5  renglones · stock · auditoria_precio
```

### 4.3 Estrategia frente a los triggers
Se usa `ALTER TABLE … DISABLE TRIGGER USER` en las 29 tablas y `ENABLE TRIGGER USER` al final (en un `finally`).
- **Por qué:** el trigger de ventas bloquea y descuenta stock fila por fila (561 mil veces) y el historial ya trae el stock final calculado; con los triggers activos los movimientos se duplicarían.
- **Por qué `USER` y no `ALL`:** `ALL` apaga también los triggers internos de las claves foráneas y exige superusuario; con `USER` las FK y los CHECK siguen activos.
- **Riesgos:** mientras están apagados, nada valida las reglas de los triggers. Se mitiga cargando con la API detenida y con el propietario, y validando después con las consultas de control. Se verificó que al terminar queden 14 triggers habilitados y ninguno deshabilitado.

### 4.4 Tiempos y comparación de métodos
Carga completa con `COPY`: **10,4 s**. Comparación con 20.000 filas (`seed/bench_carga.py`, `seed/resultado_benchmark.txt`, con `fsync` activado):

| Método | Tiempo | Filas/s | Mejora |
|---|---:|---:|---:|
| Fila por fila, un COMMIT por fila | 3,96 s | 5.055 | 1× |
| Fila por fila, una transacción | 1,04 s | 19.197 | 3,8× |
| Lotes de 1.000 filas | 0,10 s | 192.857 | 38× |
| `COPY` | 0,05 s | 409.566 | 81× |

Lectura: lo más caro del primer método no es insertar sino confirmar (cada COMMIT fuerza una escritura a disco); una sola transacción reparte ese costo; agrupar sentencias evita el viaje de ida y vuelta y el análisis de cada INSERT; `COPY` evita además el análisis SQL por fila. Los valores absolutos dependen de la máquina; la proporción se mantiene.

### 4.5 Consultas de control
`seed/consultas_control.sql` ejecuta 20 controles, todos con 0 problemas: huérfanos (5 relaciones), stock negativo, totales de comprobantes frente a sus renglones, subtotal frente a `fn_subtotal_renglon`, descuento frente al cliente y al tipo, subtipo de cliente, cortes distintos de 100, vinos sin composición, ventas anteriores al alta del cliente o al primer ingreso, ingresos con vinos de otra bodega o añada posterior, análisis posteriores a la cosecha, última auditoría frente al precio actual y documentos pendientes viejos. El resultado fue el mismo después de restaurar un backup en una base nueva.

---

## 5. Índices y rendimiento

### 5.1 Método
`EXPLAIN (ANALYZE, BUFFERS)` precedido de `VACUUM ANALYZE`; mediana de 5 corridas con caché caliente. Planes completos en `rendimiento/planes_antes/` y `rendimiento/planes_despues/`; resúmenes en `rendimiento/resumen_antes.txt` y `resumen_despues.txt`.

### 5.2 Índices creados (`migrations/008_indices.sql`)
| Tipo | Índice | Objetivo |
|---|---|---|
| Compuesto | `comprobante(id_sala, fecha)` | Ventas de una sala en un período |
| Cubriente | `comprobante(fecha) INCLUDE (id_sala, total)` | Ventas por sala por trimestre, sin leer la tabla |
| Clave foránea | `comprobante(id_cliente, fecha DESC)` | Historial de un cliente; consulta S12 |
| Clave foránea | `renglon_comprobante(cod_vino) INCLUDE (cantidad)` | Consultas por vino |
| Parcial | `transferencia(id_sala) WHERE estado <> 'procesado'` | Solo pendientes (16 kB) |
| De expresión | `lower(nombre_razon_social)` con `text_pattern_ops` | Búsqueda de clientes por prefijo, sin distinguir mayúsculas |
| Clave foránea | `stock_sala(cod_vino)`, `cliente(id_localidad)` | Joins y chequeos al borrar |

### 5.3 Resultados: antes y después
| Consulta | Antes | Después | Mejora |
|---|---:|---:|---:|
| S12 Clientes que compraron todos los vinos de una bodega | 83.235 ms | 601 ms | 138× |
| Historial de un cliente | 6,83 ms | 0,14 ms | 49× |
| S3 Clientes por tipo, una sala, última semana | 8,61 ms | 0,19 ms | 45× |
| Búsqueda por prefijo de nombre | 4,83 ms | 0,34 ms | 14× |
| S8 Ventas por sala, trimestre | 18,45 ms | 2,48 ms | 7× |
| S1 Top 10 vinos más vendidos | 108 ms | 114 ms | sin mejora |

**Caso S12:** para cada uno de 20.000 clientes se verifica si compró cada vino; sin índice sobre `comprobante(id_cliente)` cada una de las 20.652 búsquedas recorría toda la tabla (26,6 millones de páginas leídas, frente a 0,68 millones con el índice). PostgreSQL no crea índices automáticos sobre las claves foráneas, solo sobre PK y UNIQUE.

**S1 no mejora** porque necesita leer los 561 mil renglones; ningún índice acelera una consulta que debe recorrerlo todo.

[Capturas de dos planes `EXPLAIN`, antes y después]

### 5.4 Alternativas descartadas con evidencia
- **BRIN sobre `fecha`:** pesa 24 kB frente a 4,6 MB, pero el planificador lo ignora porque la correlación física es −0,007 (las filas están ordenadas por carga, no por fecha).
- **Índice sobre `renglon_transferencia(cod_vino)`:** reducía una consulta de 0,74 ms a 0,07 ms, pero con 9.000 filas la ganancia no compensa su costo de escritura.
- **Índice sobre `tipo_cliente`:** baja selectividad (el 85 % son socios); el planificador prefiere recorrer la tabla.

### 5.5 Costo de escritura
Carga de 712.000 filas (`rendimiento/costo_escritura.py`, `resultado_costo_escritura.txt`):

| Escenario | Tiempo |
|---|---:|
| Solo claves primarias | 6,79 s |
| Con los índices creados antes de cargar | 8,88 s (+31 %) |
| Cargar sin índices y crearlos después | 8,18 s |

Conclusión: en una carga masiva conviene cargar primero y crear los índices después. En operación normal el costo es aceptable frente a mejoras de entre 2× y 138× en las lecturas.

**Limitaciones de la medición:** una sola máquina y caché caliente; diferencias menores a 1 ms son ruido; S12 se midió una vez antes de indexar porque tardaba 83 s; no se midió con sesiones concurrentes.

---

## 6. Consultas SQL

Archivos: `consultas/update.sql`, `insert.sql`, `delete.sql` y `select.sql`, con su salida real en `consultas/resultado_*.txt`. Las que modifican datos se ejecutaron dentro de `BEGIN … ROLLBACK`, con un control previo y otro posterior.

**Actualización (U1 a U6).** U1 recalcula 1.000 comprobantes con el descuento del tipo de cliente (CTE y `UPDATE … FROM`, con `IS DISTINCT FROM`). U2 aumenta 20 % el salario de 92 empleados con más de 5 años (usa `fn_antiguedad_anios`). U3 sube 13 % el precio de 19 vinos de una bodega y dispara la auditoría. U4 intercambia el día de cierre lunes/miércoles de 14 salas con un solo `UPDATE … CASE` (con dos `UPDATE` el segundo pisaría al primero). U5 baja 15 % el precio de los 10 vinos menos vendidos. U6 fija 35 % de descuento a 258 exportadores con más de 3 permisos.

**Inserción (I1 a I6).** I3 crea un comprobante enviando solo vino y cantidad: los triggers completan precio, descuento y subtotal, validan y descuentan el stock (subtotal 129.000, descuento 12.900, total 116.100). I2 e I6 usan CTE de escritura. En I6 se corrigió un caso en que un vino existente en dos añadas generaba dos ingresos: ahora se toma la más reciente.

**Borrado (D1 a D6).** D1 borra 11.055 comprobantes y, por `ON DELETE CASCADE`, 41.423 renglones, sin reponer stock (historial). D2 prueba que ninguna cepa en uso puede borrarse (`RESTRICT`). D3 borra empleados pero no la sala, que tiene ventas y stock. D5 borra 2.327 ingresos antiguos sin revertir el depósito.

**Selección (S1 a S12).**
- **S2, división relacional:** vinos vendidos en todas las salas, con `HAVING COUNT(DISTINCT sala) = (SELECT COUNT(*) FROM sala_venta)`; resultado: 12 vinos.
- **S12, doble `NOT EXISTS`:** clientes que compraron todos los vinos de una bodega («no existe un vino de la bodega que el cliente no haya comprado»); se validó creando en una transacción una bodega con dos vinos y dos clientes (uno compra ambos, otro solo uno), y solo aparece el primero.
- **S11, funciones de ventana:** ranking por sala con `RANK() OVER (PARTITION BY id_sala …)` y acumulado mensual con `SUM() OVER`.
- **S5:** `LEFT JOIN` para contar salas con cero transferencias pendientes. **S6:** `NOT EXISTS` para vinos sin stock en la sala pero con stock en el depósito. **S7:** `FETCH FIRST 1 ROW WITH TIES`. **S9:** ficha del vino con la vista `v_ficha_vino`.
- **S10:** rendimiento por hectárea con una subconsulta correlacionada (350 ms, se ejecuta una vez por parcela); una función de ventana `AVG() OVER (PARTITION BY …)` la haría de una sola pasada.

Algunas consultas usan `CURRENT_DATE`: si pasan días desde la generación de datos, se regeneran con `python generar_datos.py --hoy AAAA-MM-DD`.

---

## 7. API y front

### 7.1 Arquitectura
`Front (HTML + JavaScript) → API REST (Flask + psycopg 3) → PostgreSQL`. Cada consulta es una función de `api/dal.py` con parámetros `%s`; `api/errores.py` traduce los errores de PostgreSQL a HTTP; `api/openapi.py` genera la documentación en `/openapi.json` y `/docs`. La API se conecta con el rol `app_rw`.

### 7.2 Endpoints
| Grupo | Rutas |
|---|---|
| Estado | `GET /salud` |
| Catálogos | `/cepas`, `/bodegas`, `/salas`, `/localidades`, `/maridajes`, `/transportistas` |
| Vinos | `GET /vinos` (filtros: tipo, cepa, bodega, añada, texto; paginación), `POST /vinos`, `GET/PUT/DELETE /vinos/<cod>` |
| Clientes | CRUD en `/clientes` |
| Ventas | `POST /comprobantes`, `GET /comprobantes/<nro>` |
| Logística | `/transferencias` e `/ingresos`: crear, agregar renglones, terminar, procesar |
| Reportes | `/reportes/top-vinos`, `ventas-por-sala`, `vinos-sin-stock`, `transportista-activo`, `trazabilidad/<cod>` |

### 7.3 Traducción de errores
| SQLSTATE | HTTP | Ejemplo |
|---|---|---|
| 23505, 23503, P0001 | 409 | Documento repetido, vino con ventas, stock insuficiente, cortes distintos de 100 |
| 23514, 23502 | 422 | Precio negativo, dato obligatorio faltante |
| 22P02, 22007 | 400 | `anada=abc`, fecha inválida |
| 42501 | 403 | Rol sin permiso |
| 40001, 40P01 | 503 con `Retry-After` | Conflicto de transacciones |
| Sin conexión | 503 | Base caída |

### 7.4 Pruebas
`api/tests/test_api.py`: 17 pruebas contra PostgreSQL real (resultado en `api/tests/resultado_pytest.txt`): salud con el rol de la API; catálogo con filtros y paginación; ficha y 404; catálogos; CRUD de vinos y clientes; **cortes distintos de 100 → 409 sin dejar el vino**; **precio negativo → 422**; **venta sin stock → 409 sin renglones ni descuento a medias**; venta correcta con importes y descuento de stock; borrar un vino con movimientos → 409; circuito de transferencia con transición inválida; circuito de ingreso; filtros inválidos → 400; inyección SQL; reportes; coherencia del OpenAPI con las rutas.

### 7.5 Demostración de inyección SQL
La prueba `test_inyeccion_sql_no_funciona` envía `'; DROP TABLE vino; --`, `' OR '1'='1` y un `UNION SELECT`: se buscan como texto literal (0 resultados), un `anada` malicioso devuelve 400 y la tabla `vino` sigue intacta. Defensas: consultas parametrizadas, validación de tipos por PostgreSQL y un rol sin permisos de DDL (aunque la inyección prosperara, `DROP TABLE` daría `42501`).

[Captura de la búsqueda del texto malicioso en el front]

### 7.6 Front
Seis pantallas: catálogo con filtros y paginación, ficha del vino (composición, maridajes, historial de precio y trazabilidad), alta de vino con su corte, nueva venta, transferencias (crear, agregar renglones, terminar, procesar) y reportes. El front no calcula nada: importes, descuentos, stock y estados provienen de la API, y los errores de la base se muestran tal cual. La URL de la API se configura en una línea (`front/config.js`).

[Capturas de las pantallas del front: ver `front/capturas/`]

---

## 8. Despliegue en la nube

### 8.1 Proveedor elegido
Comparación de planes gratuitos (consultada en noviembre de 2026; detalle y fuentes en `docs/etapa8_nube.md`):

| Proveedor | Limitación del plan gratuito |
|---|---|
| Render (Postgres) | La base vence a los 30 días y se borra |
| Supabase | Se pausa tras una semana sin actividad |
| Aiven | Se apaga y se reinicia manualmente |
| Neon | Se suspende a los 5 minutos sin uso, se reactiva sola y no vence |

Propuesta: Neon para la base, Render (servicio web) para la API y un sitio estático para el front. **Proveedor efectivamente utilizado: [completar]. URL: [completar].**

### 8.2 Configuración de seguridad
- La API usa `app_rw`, nunca el propietario.
- Contraseñas en variables de entorno; `.env` fuera del repositorio.
- Conexión con `sslmode=require`.
- `CORS_ORIGIN` igual a la URL del front, no `*`.
- Lista de IPs permitidas si el proveedor la ofrece.
- Para tolerar el arranque en frío de la base, `connect_timeout=15` en la cadena de conexión.

### 8.3 Backup y restauración
Se hizo `pg_dump -Fc` y `pg_restore --no-owner --no-privileges` en una base nueva. Resultado:

| Verificación | Original | Restaurada |
|---|---|---|
| Tablas / triggers habilitados / índices / constraints | 29 / 14 / 45 / 112 | 29 / 14 / 45 / 112 |
| Contenido de `comprobante`, `vino` y `stock_sala` (huella md5) | — | idéntico |

Como la restauración no trae propietarios ni permisos, se vuelve a ejecutar `007_roles.sql`. [Completar con la restauración realizada en el proveedor elegido y su captura.]

### 8.4 Docker
`docker-compose.yml` levanta la base (que aplica las migraciones al crearse, con los roles al final), la API y el front, y un servicio de carga que se ejecuta a pedido. [Completar: fecha y máquina donde se verificó `docker compose up` desde cero.]

---

## 9. Conclusiones

**Dificultades**
- Conciliar la carga masiva con los triggers: se resolvió desactivando solo los triggers de usuario y validando después con 20 controles.
- Coherencia del redondeo de importes entre el generador y la función de la base: se resolvió trabajando en centavos enteros con redondeo half-up idéntico.
- La consulta S12 tardaba 83 segundos hasta que se detectó que la clave foránea `comprobante(id_cliente)` no tenía índice.
- Un constraint trigger diferido es difícil de probar fuera de una transacción.

**Decisiones que cambiaríamos**
- Reemplazar la subconsulta correlacionada de S10 por una función de ventana.
- Agregar autenticación de usuarios a la API y paginación por clave en lugar de `OFFSET`.
- Indexar `renglon_transferencia(cod_vino)` si la tabla crece.

**Aprendizajes**
- Las reglas en la base valen para cualquier cliente; la API puede ser una capa fina.
- Medir antes de indexar: BRIN y un índice sobre `tipo_cliente` no servían, y el índice que más ayudó fue sobre una clave foránea.
- La concurrencia se resuelve con bloqueos explícitos y estados, no verificando antes en la aplicación.
- Un backup solo sirve si se probó su restauración.

**Limitaciones**
- Sin autenticación de usuarios finales.
- Mediciones de rendimiento en una sola máquina y sin sesiones concurrentes.

---

## Anexo: cómo reproducir

Ver `README.md`. Resumen: crear la base; aplicar `001` a `006`, `008` y `009`; aplicar `007` con las contraseñas por variable de entorno; `python seed/generar_datos.py` y `python seed/cargar.py`; levantar la API y el front. Pruebas: `tests/db_tests.sql` y `pytest` en `api/`.
