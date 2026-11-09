# Etapa 8 — Despliegue en la nube

> Lo que **no pude hacer desde este entorno**: crear cuentas, desplegar y sacar capturas del panel del proveedor. Lo que sí está hecho y probado: backup/restauración, y todo lo que se despliega (API, front, migraciones, carga). Abajo están los pasos para que ustedes lo hagan y los puntos donde sacar captura.

## 1. Comparación de proveedores (datos consultados en noviembre 2026; verificar antes de elegir)
Nuestra base completa pesa ~80 MB, así que entra en cualquier plan gratuito.

| Proveedor | Almacenamiento gratis | Pausa / vencimiento | Punto débil |
|---|---|---|---|
| **Neon** (Postgres) | 1 GB por proyecto | Se suspende a los 5 min sin uso (se reactiva solo, tarda un instante); 100 CU-horas/mes | Primera consulta tras la pausa es lenta |
| **Supabase** | 500 MB, 2 proyectos | Se pausa tras 1 semana sin actividad; sin backups automáticos | Hay que "despertar" el proyecto a mano si se pausa |
| **Render** (Postgres) | 1 GB | **Vence a los 30 días** (+14 de gracia y se borra); sin backups | Pierde los datos en plena cursada |
| **Aiven** | 1 GB | Se apaga si no se usa y hay que reiniciarlo a mano | Un solo backup |
| Render (web service gratis) | — | Duerme a los 15 min sin tráfico (~1 min en despertar); 750 h/mes | Primera petición lenta |

**Elección recomendada: Neon para la base + Render (Web Service gratis) para la API + Render Static Site o GitHub Pages para el front.**
Motivos: Neon no vence ni pide tarjeta, tiene PostgreSQL estándar (extensiones, `pg_dump`, roles propios), y el 1 GB cubre de sobra nuestros 80 MB. Render Postgres se descarta por el vencimiento de 30 días. Supabase es una alternativa válida, pero la pausa semanal es riesgosa justo antes de la defensa.

Fuentes: [Neon – límites del plan gratis](https://neon.com/faqs/free-plan-limits-and-quotas) · [Supabase – precios](https://supabase.com/pricing.md) · [Render – servicios gratis](https://render.com/docs/free) · [Comparativa de tiers gratuitos](https://selfhost.dev/blog/best-free-postgresql-hosting/)

## 2. Pasos
1. **Crear el proyecto en Neon** (región más cercana, PostgreSQL 16). Copiar la cadena de conexión del propietario (`postgresql://…neon.tech/neondb?sslmode=require`). 📸 captura del panel con el proyecto creado.
2. **Migraciones** (con el rol propietario de Neon; desde la carpeta `migrations/`):
   `psql "<cadena propietario>" -v ON_ERROR_STOP=1 -f 001_esquema.sql` … y así 002 a 006, 008 y 009.
3. **Roles de la aplicación** (la contraseña NO va en el archivo; se pasa por variable de entorno):
   `set APP_RW_PASSWORD=...` y `set APP_RO_PASSWORD=...` (≥ 12 caracteres, distintas), luego `psql "<cadena propietario>" -f 007_roles.sql`. Esto va **después** de crear todas las vistas (006 y 009).
4. **Carga**: la carga desactiva triggers de usuario, por eso se hace con el propietario y con la API apagada:
   `cd seed && python generar_datos.py && set PGHOST=… PGUSER=… PGPASSWORD=… PGDATABASE=neondb PGSSLMODE=require && python cargar.py`; después correr `consultas_control.sql` (20 controles en 0).
5. **API en Render**: New → Web Service → repo → *Root Directory* `api`, *Build* `pip install -r requirements.txt`, *Start* `gunicorn -b 0.0.0.0:$PORT -w 2 --threads 4 app:app`. Variables de entorno:
   - `DATABASE_URL=postgresql://app_rw:<clave>@<host-neon>/neondb?sslmode=require&connect_timeout=15` (**con `connect_timeout=15`**: si Neon estaba suspendida, la primera conexión tarda más que los 5 s por defecto).
   - `CORS_ORIGIN=https://<url-del-front>` (no `*`).
   📸 captura de `https://<api>/docs` y de `/salud` respondiendo.
6. **Front**: editar `front/config.js` → `window.API_URL = "https://<api>.onrender.com"` y publicar la carpeta `front/` (Render Static Site o GitHub Pages). 📸 captura del front funcionando con datos de la nube.
7. **Prueba de humo en la nube**: `/salud` → `usuario: app_rw`; catálogo carga; una venta con stock da 201 y sin stock da 409.

## 3. Backup y restauración (probado)
`pg_dump -Fc` de la base de pruebas → `pg_restore --no-owner --no-privileges` en una base nueva. Resultado real:

| | original | restaurada |
|---|---|---|
| tablas / triggers habilitados / índices / constraints | 29 / 14 / 45 / 112 | 29 / 14 / 45 / 112 |
| md5 de `comprobante`, `vino`, `stock_sala` (contenido completo ordenado) | 2ae1a3b4… / 9186b85a… / 2cfa0496… | idénticos |

Con `--no-owner --no-privileges` no se restauran dueños ni permisos: **después de restaurar hay que volver a correr `007_roles.sql`**. En Neon: `pg_dump "<cadena>" -Fc -f backup.dump` para bajar y `pg_restore -d "<cadena destino>" backup.dump` para subir. El plan gratis de Neon solo guarda 6 h de historial y 1 snapshot manual, así que el backup propio con `pg_dump` es el que cuenta. 📸 captura de la restauración y del conteo de filas.

## 4. Checklist de seguridad
- [ ] La API se conecta con `app_rw` (verificar `/salud`), **nunca** con el propietario ni con un superusuario.
- [ ] Contraseñas solo en variables de entorno del proveedor; `.env` en `.gitignore` (ya está) y ningún secreto en el repo (`grep -ri password` sobre el código no debe mostrar valores).
- [ ] `sslmode=require` en `DATABASE_URL` (cifrado en tránsito).
- [ ] `CORS_ORIGIN` = URL exacta del front, no `*`.
- [ ] Si el proveedor permite lista de IPs permitidas, restringir; en los planes gratis suele no existir: compensar con contraseñas fuertes y rol sin permisos de DDL.
- [ ] `app_ro` para cualquier consulta de solo lectura (reportes, demos).
- [ ] Se probó que `app_rw` no puede `DROP`/`TRUNCATE`/`ALTER`/crear roles (`tests/test_007_roles_denegados.sql`).
- [ ] Rotar las contraseñas después de la defensa y no dejar el servicio público si no hace falta.
- [ ] No subir `seed/salida/` (datos generados) ni dumps con datos al repositorio público.
