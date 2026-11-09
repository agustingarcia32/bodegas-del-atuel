-- =====================================================================
-- 007_roles.sql  ·  Bodegas del Atuel  ·  Etapa 2
-- Va después de 001 a 006 y se corre con el PROPIETARIO (el mismo usuario
-- que corrió las migraciones).
--
-- Los 3 roles:
--   propietario : el que crea y modifica el esquema (migraciones, carga
--                 masiva, deshabilitar triggers). Ya existe: no se crea acá.
--   app_rw      : el que usa la API. Lee y escribe datos; NO puede tocar
--                 el esquema.
--   app_ro      : solo lectura, para reportes.
--
-- Las contraseñas NO están en este archivo: se leen de variables de
-- entorno (APP_RW_PASSWORD y APP_RO_PASSWORD, mínimo 8 caracteres).
--   Local:   APP_RW_PASSWORD=xxx APP_RO_PASSWORD=yyy psql -d bodegas -f 007_roles.sql
--   Docker:  las pasa docker-compose.yml en "environment" y las lee psql.
-- Si falta alguna, el script se corta con un mensaje y no crea nada.
-- Se puede correr varias veces: si el rol ya existe, solo cambia lo que
-- corresponde (contraseña y privilegios).
--
-- Si más adelante agregan tablas o funciones, hay que volver a correr
-- este archivo para darles permisos.
-- =====================================================================

\set ON_ERROR_STOP on

\getenv app_rw_password APP_RW_PASSWORD
\getenv app_ro_password APP_RO_PASSWORD

\if :{?app_rw_password}
\else
  DO $$ BEGIN RAISE EXCEPTION 'Falta la variable de entorno APP_RW_PASSWORD'; END $$;
\endif
\if :{?app_ro_password}
\else
  DO $$ BEGIN RAISE EXCEPTION 'Falta la variable de entorno APP_RO_PASSWORD'; END $$;
\endif

SELECT (length(:'app_rw_password') < 8 OR length(:'app_ro_password') < 8) AS password_corta \gset
\if :password_corta
  DO $$ BEGIN RAISE EXCEPTION 'APP_RW_PASSWORD y APP_RO_PASSWORD deben tener al menos 8 caracteres'; END $$;
\endif


-- ---------------------------------------------------------------------
-- Crear los roles (o actualizarlos si ya existen).
-- Ninguno es superusuario ni puede crear bases ni otros roles.
-- ---------------------------------------------------------------------
SELECT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'app_rw') AS rw_existe \gset
\if :rw_existe
  ALTER ROLE app_rw WITH LOGIN PASSWORD :'app_rw_password' NOSUPERUSER NOCREATEDB NOCREATEROLE;
\else
  CREATE ROLE app_rw LOGIN PASSWORD :'app_rw_password' NOSUPERUSER NOCREATEDB NOCREATEROLE;
\endif

SELECT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'app_ro') AS ro_existe \gset
\if :ro_existe
  ALTER ROLE app_ro WITH LOGIN PASSWORD :'app_ro_password' NOSUPERUSER NOCREATEDB NOCREATEROLE;
\else
  CREATE ROLE app_ro LOGIN PASSWORD :'app_ro_password' NOSUPERUSER NOCREATEDB NOCREATEROLE;
\endif


-- ---------------------------------------------------------------------
-- 1) Sacar lo que viene dado a "cualquiera" (PUBLIC)
-- ---------------------------------------------------------------------
DO $$
BEGIN
    EXECUTE format('REVOKE ALL ON DATABASE %I FROM PUBLIC', current_database());
END $$;

REVOKE ALL ON SCHEMA public FROM PUBLIC;
REVOKE ALL ON ALL TABLES    IN SCHEMA public FROM PUBLIC;
REVOKE ALL ON ALL SEQUENCES IN SCHEMA public FROM PUBLIC;
REVOKE ALL ON ALL ROUTINES  IN SCHEMA public FROM PUBLIC;


-- ---------------------------------------------------------------------
-- 2) Poder conectarse y entrar al esquema
-- ---------------------------------------------------------------------
DO $$
BEGIN
    EXECUTE format('GRANT CONNECT ON DATABASE %I TO app_rw, app_ro', current_database());
END $$;

GRANT USAGE ON SCHEMA public TO app_rw, app_ro;


-- ---------------------------------------------------------------------
-- 3) app_rw (la API)
--    * Lee todo (tablas y vistas).
--    * Escribe en las tablas (no en las vistas).
--    * Excepciones: el stock se mueve por INSERT/UPDATE (lo hacen los
--      triggers y sp_procesar_*, que corren con los permisos de quien los
--      llama), pero nunca se borran filas de stock; y la auditoría de
--      precios solo se puede leer y agregar, no modificar ni borrar.
--    * Ejecuta funciones y procedimientos (los triggers llaman a las
--      funciones con los permisos de quien dispara el trigger).
--    * No tiene TRUNCATE, ni CREATE, ni ALTER, ni DROP, ni puede
--      deshabilitar triggers: eso es del propietario.
-- ---------------------------------------------------------------------
GRANT SELECT ON ALL TABLES IN SCHEMA public TO app_rw;

DO $$
DECLARE
    t text;
BEGIN
    FOR t IN SELECT tablename FROM pg_tables WHERE schemaname = 'public' LOOP
        EXECUTE format('GRANT INSERT, UPDATE, DELETE ON public.%I TO app_rw', t);
    END LOOP;
END $$;

REVOKE DELETE         ON stock_sala, stock_deposito FROM app_rw;
REVOKE UPDATE, DELETE ON auditoria_precio           FROM app_rw;

GRANT EXECUTE ON ALL ROUTINES IN SCHEMA public TO app_rw;


-- ---------------------------------------------------------------------
-- 4) app_ro (reportes): solo SELECT, y las funciones de cálculo.
--    No puede llamar a los procedimientos sp_procesar_*.
-- ---------------------------------------------------------------------
GRANT SELECT ON ALL TABLES IN SCHEMA public TO app_ro;

GRANT EXECUTE ON FUNCTION
    fn_antiguedad_anios(DATE),
    fn_stock_sala(INTEGER, INTEGER),
    fn_total_comprobante(INTEGER),
    fn_descuento_cliente(VARCHAR),
    fn_subtotal_renglon(INTEGER, NUMERIC, NUMERIC)
TO app_ro;
