-- Se corre CONECTADO COMO app_rw o app_ro (se pasa el rol por la variable rol):
--   psql -U app_rw -d bodegas -v rol=app_rw -f test_007_roles_denegados.sql
--   psql -U app_ro -d bodegas -v rol=app_ro -f test_007_roles_denegados.sql
-- Cada fila es (que se prueba, sentencia, resultado esperado):
--   'OK'    -> tiene que funcionar
--   '42501' -> tiene que fallar por permisos (insufficient_privilege)
-- No usa tablas temporales ni funciones propias, porque estos roles no pueden crearlas.
\set ON_ERROR_STOP on
\set QUIET on

DO $$
DECLARE
    r        record;
    v_estado text;
    v_rol    text := current_user;
    v_fallas int  := 0;
BEGIN
    FOR r IN
        SELECT * FROM (VALUES
            -- lo que ambos roles pueden hacer
            ('ambos', 'leer una tabla',                    'SELECT count(*) FROM vino',                         'OK'),
            ('ambos', 'leer una vista',                    'SELECT count(*) FROM v_stock_total_vino',           'OK'),
            ('ambos', 'usar una funcion de calculo',       'SELECT fn_antiguedad_anios(DATE ''2020-01-01'')',   'OK'),
            -- lo que ninguno puede hacer (esquema, instancia, sistema)
            ('ambos', 'DROP TABLE',                        'DROP TABLE vino',                                   '42501'),
            ('ambos', 'TRUNCATE',                          'TRUNCATE comprobante',                              '42501'),
            ('ambos', 'ALTER TABLE (agregar columna)',     'ALTER TABLE vino ADD COLUMN x int',                 '42501'),
            ('ambos', 'deshabilitar triggers',             'ALTER TABLE renglon_comprobante DISABLE TRIGGER ALL','42501'),
            ('ambos', 'CREATE TABLE en public',            'CREATE TABLE intruso(x int)',                       '42501'),
            ('ambos', 'CREATE FUNCTION en public',         'CREATE FUNCTION f() RETURNS int LANGUAGE sql AS ''SELECT 1''', '42501'),
            ('ambos', 'DROP FUNCTION',                     'DROP FUNCTION fn_stock_sala(integer,integer)',      '42501'),
            ('ambos', 'tablas temporales',                 'CREATE TEMP TABLE t(x int)',                        '42501'),
            ('ambos', 'CREATE ROLE',                       'CREATE ROLE otro',                                  '42501'),
            ('ambos', 'hacerse superusuario',              'ALTER ROLE ' || v_rol || ' SUPERUSER',              '42501'),
            ('ambos', 'SET ROLE al propietario',           'SET ROLE postgres',                                 '42501'),
            ('ambos', 'leer archivos del servidor',        'SELECT pg_read_file(''/etc/passwd'')',              '42501'),
            ('ambos', 'COPY a un archivo del servidor',    'COPY vino TO ''/tmp/vino.csv''',                    '42501'),
            -- 55000 = la vista no admite escrituras (salta antes que el chequeo de permisos)
            ('ambos', 'escribir en una vista',             'INSERT INTO v_stock_total_vino(cod_vino) VALUES (1)', '55000'),
            -- lo que solo app_rw puede
            ('rw',    'INSERT en una tabla',               'INSERT INTO maridaje(nombre,temperatura_servicio) VALUES (''tmp'',10)', 'OK'),
            ('rw',    'UPDATE en una tabla',               'UPDATE maridaje SET temperatura_servicio = 11 WHERE nombre = ''tmp''', 'OK'),
            ('rw',    'DELETE en una tabla',               'DELETE FROM maridaje WHERE nombre = ''tmp''',        'OK'),
            ('rw',    'UPDATE de stock (lo hacen los triggers)', 'UPDATE stock_sala SET cantidad = cantidad',    'OK'),
            ('rw',    'DELETE de stock (no se permite)',   'DELETE FROM stock_sala',                            '42501'),
            ('rw',    'DELETE de stock del deposito',      'DELETE FROM stock_deposito',                        '42501'),
            ('rw',    'UPDATE de la auditoria (no se permite)', 'UPDATE auditoria_precio SET usuario = ''x''',   '42501'),
            ('rw',    'DELETE de la auditoria (no se permite)', 'DELETE FROM auditoria_precio',                 '42501'),
            ('rw',    'leer la auditoria',                 'SELECT count(*) FROM auditoria_precio',             'OK'),
            ('rw',    'llamar a un procedimiento',         'CALL sp_procesar_ingreso(99999)',                   'P0001'),
            -- lo que app_ro no puede
            ('ro',    'INSERT',                            'INSERT INTO maridaje(nombre,temperatura_servicio) VALUES (''tmp'',10)', '42501'),
            ('ro',    'UPDATE',                            'UPDATE vino SET precio = precio',                   '42501'),
            ('ro',    'DELETE',                            'DELETE FROM cliente',                               '42501'),
            ('ro',    'llamar a sp_procesar_ingreso',      'CALL sp_procesar_ingreso(1)',                       '42501'),
            ('ro',    'llamar a sp_procesar_transferencia','CALL sp_procesar_transferencia(1)',                 '42501'),
            ('ro',    'ejecutar una funcion interna del trigger', 'SELECT fn_chequear_suma_composicion(1)',     '42501')
        ) AS t(quien, que, sentencia, esperado)
         WHERE quien = 'ambos'
            OR (quien = 'rw' AND v_rol = 'app_rw')
            OR (quien = 'ro' AND v_rol = 'app_ro')
    LOOP
        BEGIN
            EXECUTE r.sentencia;
            v_estado := 'OK';
        EXCEPTION WHEN OTHERS THEN
            v_estado := SQLSTATE;
        END;

        IF v_estado = r.esperado THEN
            RAISE NOTICE 'PASA   [%] % -> %', v_rol, r.que, v_estado;
        ELSE
            RAISE NOTICE 'FALLA  [%] % -> esperado %, obtenido %', v_rol, r.que, r.esperado, v_estado;
            v_fallas := v_fallas + 1;
        END IF;
    END LOOP;

    RAISE NOTICE '--- % : % caso(s) con resultado inesperado', v_rol, v_fallas;
END $$;
