# Preparación de la defensa — preguntas probables y respuestas apoyadas en nuestro trabajo
Cada integrante debe poder responder cualquiera. Entre paréntesis, dónde está la prueba.

## Modelo e integridad
1. **¿Por qué el descuento es un trigger y no lo calcula la API?** Porque la regla debe valer sin importar quién escriba (API, psql, un script). `fn_descuento_cliente` + trigger BEFORE INSERT; solo completa si viene NULL (`trazabilidad.md` RN-06).
2. **¿Cómo garantizás que los cortes de un vino suman 100?** Constraint trigger DEFERRABLE INITIALLY DEFERRED: se valida al COMMIT, así se pueden insertar las cepas de a una (RN-05; `test_005_rn05_diferido.sql`). Un CHECK no sirve porque mira una sola fila.
3. **¿Por qué `ON DELETE RESTRICT` en vino y `CASCADE` en renglones?** Un vino con movimientos no puede desaparecer (RN-14); los renglones no existen sin su cabecera.
4. **¿Qué pasa si dos clientes compran la última botella?** `SELECT … FOR UPDATE` en el trigger serializa las dos ventas; la segunda ve stock 0 y se rechaza (`resultado_concurrencia.txt`). Sin bloqueo, en READ COMMITTED ambas leerían 1 y el stock quedaría −1 (lo frena el CHECK `stock >= 0`, pero tarde y con error confuso).
5. **¿Por qué un procedimiento para procesar un ingreso y no un trigger?** Es una operación de negocio de varios pasos que debe ser atómica y se invoca explícitamente; el trigger de estados solo impide transiciones inválidas.
6. **Mostrá en vivo una venta sin stock.** `POST /comprobantes` con cantidad mayor al stock → 409 y mensaje de la base (RN-09); comprobar que no quedó el comprobante ni descuento de stock.

## Carga e índices
7. **¿Cómo cargaron 800 mil filas y qué hicieron con los triggers?** COPY en orden de FK; `DISABLE TRIGGER USER` (no `ALL`: mantiene las FK activas y no requiere superusuario); se reactivan en `finally`; se validó con 20 consultas de control (`etapa3_carga.md`).
8. **¿Por qué COPY es 81 veces más rápido que insertar fila por fila con commit?** Cada commit fuerza escritura a disco (fsync) y cada INSERT se analiza y viaja por separado; COPY evita ambas cosas (`resultado_benchmark.txt`).
9. **Explicá el índice que más ayudó.** `idx_comprobante_cliente_fecha` (FK sin índice): S12 de 83 s a 0,6 s, de 26,6 M páginas leídas a 0,68 M.
10. **¿Por qué `(id_sala, fecha)` y no `(fecha, id_sala)`?** Igualdad primero, rango después; además el prefijo `id_sala` sirve solo (experimento E1).
11. **¿Un caso donde el índice existe y no se usa?** S1: necesita todas las filas, el planificador prefiere Seq Scan; y `tipo_cliente = 'socio'` (85 % de la tabla). BRIN no sirvió: correlación física −0,007.
12. **¿Cuánto cuestan los índices en escritura?** +31 % en la carga de 712 mil filas; +8 % en inserciones sueltas.

## API, seguridad, nube
13. **¿Cómo evitás la inyección SQL?** Parámetros `%s` en toda consulta, nunca concatenación; PostgreSQL valida el tipo (`anada=abc` → 22P02 → 400); `app_rw` no tiene permisos de DDL (`test_inyeccion_sql_no_funciona`).
14. **¿Por qué la API no usa el propietario?** Privilegios mínimos: aunque hubiera una vulnerabilidad no podría `DROP`/`TRUNCATE`/deshabilitar triggers (`test_007_roles_denegados.sql`).
15. **¿Cómo se traduce un error de la base a HTTP?** Por SQLSTATE en `errores.py`: 23505/23503/P0001 → 409, 23514/23502 → 422, 22P02 → 400, 42501 → 403, 40001 → 503 + Retry-After.
16. **¿Dónde están las contraseñas?** Solo en variables de entorno (`007_roles.sql` las lee con `\getenv`, falla si faltan); `.env` está en `.gitignore`.
17. **¿Cómo probaron el backup?** `pg_dump -Fc` y `pg_restore` en una base nueva; mismos conteos de objetos y mismo md5 de tablas clave; hay que volver a correr `007_roles.sql` porque se restaura sin dueños ni permisos.
18. **¿Por qué ese proveedor?** Ver `etapa8_nube.md` (Render Postgres vence a los 30 días; Supabase pausa a la semana; Neon no vence).

## Cambios en vivo que pueden pedirles
- Agregar un CHECK o un índice: `ALTER TABLE … ADD CONSTRAINT …` y mostrar el `EXPLAIN (ANALYZE, BUFFERS)` antes/después.
- Cambiar el porcentaje de descuento de un tipo de cliente: `fn_descuento_cliente` (003) y explicar que no cambia ventas ya hechas (el renglón conserva el % aplicado).
- Agregar un campo al alta de vino: migración nueva + DAL + endpoint + campo en el formulario.
