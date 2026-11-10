# Bodegas del Atuel — TPI Bases de Datos (UTN FRSR, 2026)

Sistema de gestión y distribución de una empresa vitivinícola. La base es PostgreSQL 16 y las reglas de negocio viven dentro de ella (constraints, triggers, funciones y procedimientos). La API (Flask + psycopg 3) y el front (HTML + JavaScript) son capas finas: no calculan totales, descuentos ni stock.

```
migrations/   001 a 009: esquema, constraints, funciones, procedimientos, triggers, vistas, roles, índices, ficha de vino
seed/         catálogos CSV, generador de datos (semilla fija), carga con COPY y 20 consultas de control
tests/        db_tests.sql (87 casos, RN-01 a RN-15), demo de concurrencia, pruebas de roles
consultas/    update.sql, insert.sql, delete.sql, select.sql (U1–U6, I1–I6, D1–D6, S1–S12) y sus resultados
rendimiento/  consultas medidas con EXPLAIN antes y después de los índices, costo de escritura
api/          API REST (Flask), documentación OpenAPI en /docs, 17 pruebas pytest
front/        catálogo, alta de vino, nueva venta, transferencias y reportes
docs/         DER, modelo relacional, trazabilidad, informes por etapa e informe final
```

## Requisitos

- Docker con Docker Compose (en Windows, dentro de WSL o con Docker Desktop).
- Git.

Nada más: PostgreSQL, Python y el servidor web corren dentro de los contenedores.

## Levantar todo (primera vez)

Todos los comandos se corren desde la carpeta del repositorio. En Windows con WSL, abrir Ubuntu y entrar a la carpeta con `cd "/mnt/c/Users/..."`.

**1. Clonar el repositorio**

```bash
git clone https://github.com/agustingarcia32/bodegas-del-atuel.git
cd bodegas-del-atuel
```

**2. Crear el archivo `.env` con las contraseñas**

```bash
cp .env.example .env
nano .env
```

Poner tres contraseñas propias, de 8 caracteres o más. El `.env` está en `.gitignore` y **nunca se sube**. Tampoco hay que escribir contraseñas reales en `.env.example`.

| Variable | Para qué |
|---|---|
| `POSTGRES_PASSWORD` | usuario `postgres`, propietario de la base (migraciones y carga) |
| `APP_RW_PASSWORD` | rol `app_rw`, el que usa la API (lectura y escritura, sin DDL) |
| `APP_RO_PASSWORD` | rol `app_ro`, solo lectura para reportes |

**3. Levantar la base, la API y el front**

```bash
docker compose up -d --build db api front
```

La primera vez, la base aplica sola las migraciones en este orden: 001 a 006, 008, 009 y al final 007 (roles), cuando ya existen todas las tablas y vistas.

**4. Cargar los datos (unas 800.000 filas, tarda menos de un minuto)**

```bash
docker compose --profile carga run --rm carga
```

Genera los datos con la semilla 2026, los carga con el propietario y al final muestra los conteos por tabla y los 20 controles de coherencia. Todos tienen que dar `0 | OK`.

**5. Abrir**

| Qué | Dirección |
|---|---|
| Front | http://localhost:8080 |
| Documentación de la API (Swagger) | http://localhost:8000/docs |
| Estado de la API | http://localhost:8000/salud |
| Base de datos | `localhost:5432`, base `bodegas`, usuario `postgres` |

`/salud` tiene que responder `{"estado":"ok","base":"bodegas","usuario":"app_rw"}`: la API se conecta con el rol de privilegios mínimos, nunca con el propietario.

## Uso diario

Apagar, conservando los datos:

```bash
docker compose stop
```

Volver a prender:

```bash
docker compose start
```

Ver qué contenedores están corriendo:

```bash
docker compose ps
```

Ver los mensajes de la API (útil si algo falla):

```bash
docker compose logs -f api
```

Entrar a la base con `psql`:

```bash
docker compose exec db psql -U postgres -d bodegas
```

Después de cambiar código de la API, reconstruirla:

```bash
docker compose up -d --build api
```

El front se sirve directo desde la carpeta `front/`: alcanza con recargar el navegador.

## Empezar de cero

Borra los contenedores **y todos los datos**. Hace falta, por ejemplo, después de cambiar un archivo de `migrations/`, porque las migraciones solo corren cuando se crea la base.

```bash
docker compose down -v
```

Después se repiten los pasos 3 y 4. La carga no se puede correr dos veces sobre la misma base: primero hay que borrarla así.

### Datos con otra fecha de referencia

Las consultas de "última semana", "último mes" y "último trimestre" usan `CURRENT_DATE`. Los datos se generan con fecha de referencia 2026-11-06; si pasaron muchos días, esas consultas quedan vacías. Para regenerar con la fecha de hoy (después de `docker compose down -v` y del paso 3):

```bash
docker compose --profile carga run --rm carga sh -c "python generar_datos.py --hoy $(date +%F) && python cargar.py"
```

## Pruebas y consultas

Correr las consultas de la sección 8. Las que modifican datos terminan en `ROLLBACK`, así que no cambian la base:

```bash
docker compose exec -T db psql -U postgres -d bodegas < consultas/select.sql
```

Lo mismo con `consultas/update.sql`, `consultas/insert.sql` y `consultas/delete.sql`.

Repetir los 20 controles de coherencia de la carga:

```bash
docker compose exec -T db psql -U postgres -d bodegas < seed/consultas_control.sql
```

| Prueba | Archivo | Resultado de referencia |
|---|---|---|
| Reglas de negocio, 87 casos (base vacía con 001 a 006) | `tests/db_tests.sql` | `tests/resultado_db_tests.txt`: 87 pasan |
| Concurrencia: dos sesiones y la última botella | `tests/demo_concurrencia.sh` | `tests/resultado_concurrencia.txt` |
| Permisos de los roles (conectado como `app_rw` o `app_ro`) | `tests/test_007_roles_denegados.sql` | `docs/trazabilidad.md` |
| API, 17 pruebas contra PostgreSQL real | `api/tests/` | `api/tests/resultado_pytest.txt` |

Las pruebas de `db_tests.sql` y de la API **modifican datos**: correrlas en una base descartable, no en la que tiene la carga completa. Instrucciones en `api/README.md` y `seed/README.md`.

## Backup y restauración

Generar un backup de la base cargada:

```bash
docker compose exec -T db pg_dump -U postgres -Fc bodegas > backup.dump
```

Restaurarlo en una base nueva y volver a aplicar los permisos:

```bash
docker compose exec -T db createdb -U postgres bodegas_restaurada
docker compose exec -T db pg_restore -U postgres -d bodegas_restaurada --no-owner --no-privileges < backup.dump
```

Con `--no-owner --no-privileges` los permisos no se restauran: hay que volver a correr `migrations/007_roles.sql` sobre la base restaurada. Los archivos de backup no se suben al repositorio.

## Si algo falla

| Síntoma | Causa probable | Qué hacer |
|---|---|---|
| `falta POSTGRES_PASSWORD en .env` | no existe el `.env` o está vacío | paso 2 |
| `port is already allocated` | otro programa usa el puerto 5432, 8000 u 8080 | cerrar ese programa (por ejemplo, otro PostgreSQL) |
| El front dice "No se pudo conectar con el servidor" | la API no está corriendo | `docker compose ps` y `docker compose logs api` |
| La carga falla con "duplicate key" | la base ya tenía datos | `docker compose down -v` y repetir los pasos 3 y 4 |
| Reportes de ventas o transportista vacíos | los datos son de otra fecha | regenerar con `--hoy` (ver arriba) |

## Nube

Pasos, comparación de proveedores y checklist de seguridad en `docs/etapa8_nube.md`. URL pública: **(completar al desplegar)**.

## Seguridad

- Las contraseñas solo van en `.env` o en las variables de entorno del proveedor, nunca en el repositorio.
- La API usa `app_rw`, que no puede crear, modificar ni borrar tablas.
- Todas las consultas de la API son parametrizadas (`%s`), nunca texto concatenado.
- `CORS_ORIGIN` limita desde qué dirección se puede llamar a la API.
- La base expone el puerto 5432 solo para trabajar en local. En la nube va con `sslmode=require` y sin el puerto abierto a todo internet.
