-- =====================================================================
-- 002_constraints.sql  ·  TPI Bases de Datos  ·  «Bodegas del Atuel»
-- Etapa 2 (integridad): UNIQUE, CHECK y DEFAULT sobre el esquema de 001.
-- Se aplica DESPUÉS de 001_esquema.sql, sobre una base vacía.
--
-- Ya resueltos en 001 (no se repiten acá):
--   * PRIMARY KEY en todas las tablas.
--   * FOREIGN KEY con ON DELETE / ON UPDATE (RESTRICT en catálogos y
--     movimientos, CASCADE solo en renglones, subtipos, permisos, etc.).
--   * NOT NULL, el ENUM estado_documento y el DOMAIN cuit_dom.
--
-- Criterio de uso de cada herramienta (ver "¿Dónde va cada regla?"):
--   * CHECK  -> valor válido de UNA sola fila, siempre calculable igual.
--   * UNIQUE -> unicidad.
--   * Lo que depende de otras filas, otras tablas o de la fecha actual
--     NO va en un CHECK: va en un trigger (005_triggers.sql).
--     Por eso ningún CHECK usa CURRENT_DATE ni now().
--
-- Todas las constraints tienen nombre explícito para que el mensaje de
-- error sea claro y para poder citarlas en la tabla de trazabilidad.
-- Convención de nombres:  uq_<tabla>_<...>  y  ck_<tabla>_<regla>.
-- =====================================================================


-- ---------------------------------------------------------------------
-- UNIQUE (restricciones adicionales a las claves primarias)
-- ---------------------------------------------------------------------

-- Una localidad no se repite dentro de una provincia.
ALTER TABLE localidad
    ADD CONSTRAINT uq_localidad_nombre_provincia UNIQUE (nombre, provincia);

-- Catálogos: nombre único.
ALTER TABLE cepa
    ADD CONSTRAINT uq_cepa_nombre UNIQUE (nombre);

ALTER TABLE maridaje
    ADD CONSTRAINT uq_maridaje_nombre UNIQUE (nombre);

-- Mismo nombre puede existir con distinta añada o presentación.
ALTER TABLE vino
    ADD CONSTRAINT uq_vino_nombre_anada_volumen UNIQUE (nombre, anada, volumen_ml);

-- RN-04: una parcela se cosecha como máximo una vez por campaña.
ALTER TABLE lote
    ADD CONSTRAINT uq_lote_parcela_campania UNIQUE (id_finca, nro_parcela, campania);

-- Un mismo documento no puede ser dos clientes.
ALTER TABLE cliente
    ADD CONSTRAINT uq_cliente_documento UNIQUE (tipo_doc, nro_doc);

ALTER TABLE distribuidor
    ADD CONSTRAINT uq_distribuidor_habilitacion UNIQUE (nro_habilitacion);

ALTER TABLE transportista
    ADD CONSTRAINT uq_transportista_cuit UNIQUE (cuit);


-- ---------------------------------------------------------------------
-- CHECK
-- ---------------------------------------------------------------------

-- Territorio y personal ------------------------------------------------

ALTER TABLE sala_venta
    ADD CONSTRAINT ck_sala_numero_positivo CHECK (numero > 0),                       -- RN-15
    ADD CONSTRAINT ck_sala_dia_cierre CHECK (dia_cierre IN
        ('lunes','martes','miercoles','jueves','viernes','sabado','domingo'));

ALTER TABLE empleado
    ADD CONSTRAINT ck_empleado_salario_positivo CHECK (salario > 0);                 -- RN-15

-- Producción de uva ----------------------------------------------------

ALTER TABLE cepa
    ADD CONSTRAINT ck_cepa_tipo CHECK (tipo IN ('tinta','blanca'));

ALTER TABLE finca
    ADD CONSTRAINT ck_finca_superficie_positiva CHECK (superficie_ha > 0);           -- RN-15

ALTER TABLE parcela
    ADD CONSTRAINT ck_parcela_nro_positivo CHECK (nro_parcela > 0),
    ADD CONSTRAINT ck_parcela_superficie_positiva CHECK (superficie > 0),            -- RN-15
    ADD CONSTRAINT ck_parcela_anio_plantacion CHECK (anio_plantacion BETWEEN 1900 AND 2100);

ALTER TABLE lote
    ADD CONSTRAINT ck_lote_kilos_positivos CHECK (kilos > 0),                        -- RN-15
    -- Entre columnas: la campaña es el año de la cosecha (desnormalización
    -- controlada, ver informe de normalización, caso 5.3).
    ADD CONSTRAINT ck_lote_campania_es_anio_cosecha
        CHECK (campania = EXTRACT(YEAR FROM fecha_cosecha));

ALTER TABLE analisis_calidad
    ADD CONSTRAINT ck_analisis_brix_positivo CHECK (grado_brix > 0),
    ADD CONSTRAINT ck_analisis_ph_rango CHECK (ph BETWEEN 0 AND 14),
    ADD CONSTRAINT ck_analisis_acidez_positiva CHECK (acidez_total > 0);

-- Vinos ----------------------------------------------------------------

ALTER TABLE vino
    ADD CONSTRAINT ck_vino_tipo CHECK (tipo IN ('tinto','blanco','rosado','espumante')),
    ADD CONSTRAINT ck_vino_anada CHECK (anada BETWEEN 1990 AND 2100),
    ADD CONSTRAINT ck_vino_volumen CHECK (volumen_ml IN (187, 375, 750, 1500, 3000)),
    ADD CONSTRAINT ck_vino_graduacion_rango CHECK (graduacion BETWEEN 5 AND 20),     -- RN-15
    ADD CONSTRAINT ck_vino_precio_positivo CHECK (precio > 0);                       -- RN-01, RN-15

-- La suma por vino = 100 NO se puede verificar fila a fila: es el constraint
-- trigger diferido de 005_triggers.sql (RN-05). Acá solo el rango de la fila.
ALTER TABLE composicion
    ADD CONSTRAINT ck_composicion_porcentaje CHECK (porcentaje > 0 AND porcentaje <= 100);

ALTER TABLE maridaje
    ADD CONSTRAINT ck_maridaje_temperatura CHECK (temperatura_servicio BETWEEN 0 AND 30);

-- Clientes -------------------------------------------------------------

ALTER TABLE cliente
    ADD CONSTRAINT ck_cliente_tipo_doc CHECK (tipo_doc IN ('DNI','CUIT','CUIL','PASAPORTE')),
    ADD CONSTRAINT ck_cliente_tipo CHECK (tipo_cliente IN ('socio','distribuidor','exportador')),
    ADD CONSTRAINT ck_cliente_descuento_rango CHECK (descuento BETWEEN 0 AND 100);   -- RN-06 (rango)

-- RN-07: el vencimiento es posterior a la emisión (CHECK entre columnas).
ALTER TABLE permiso_exportacion
    ADD CONSTRAINT ck_permiso_vencimiento_posterior
        CHECK (fecha_vencimiento > fecha_emision);

-- Ventas ---------------------------------------------------------------

-- RN-08: los importes los calcula la base. Este CHECK entre columnas
-- garantiza que, sea cual sea la forma de escribirlos, quedan coherentes.
ALTER TABLE comprobante
    ADD CONSTRAINT ck_comprobante_subtotal_no_negativo CHECK (subtotal >= 0),
    ADD CONSTRAINT ck_comprobante_descuento_no_negativo CHECK (descuento >= 0),
    ADD CONSTRAINT ck_comprobante_total_no_negativo CHECK (total >= 0),
    ADD CONSTRAINT ck_comprobante_total_coherente CHECK (total = subtotal - descuento);

ALTER TABLE renglon_comprobante
    ADD CONSTRAINT ck_renglon_cant_positiva CHECK (cantidad > 0),                    -- RN-15
    ADD CONSTRAINT ck_renglon_precio_positivo CHECK (precio_unitario > 0),           -- RN-15
    ADD CONSTRAINT ck_renglon_descuento_rango CHECK (descuento BETWEEN 0 AND 100),   -- RN-06 (rango)
    ADD CONSTRAINT ck_renglon_subtotal_no_negativo CHECK (subtotal >= 0);

-- Logística ------------------------------------------------------------

ALTER TABLE transportista
    ADD CONSTRAINT ck_transportista_email
        CHECK (email ~ '^[^@[:space:]]+@[^@[:space:]]+$');

ALTER TABLE renglon_ingreso
    ADD CONSTRAINT ck_renglon_ingreso_cant_positiva CHECK (cantidad > 0);            -- RN-15

ALTER TABLE renglon_transferencia
    ADD CONSTRAINT ck_renglon_transf_cant_positiva CHECK (cantidad > 0);             -- RN-15

-- Stock ----------------------------------------------------------------

ALTER TABLE stock_sala
    ADD CONSTRAINT ck_stock_sala_no_negativo CHECK (cantidad >= 0);                  -- RN-09

ALTER TABLE stock_deposito
    ADD CONSTRAINT ck_stock_deposito_no_negativo CHECK (cantidad >= 0);

-- Auditoría ------------------------------------------------------------

ALTER TABLE auditoria_precio
    ADD CONSTRAINT ck_auditoria_precios_positivos
        CHECK (precio_anterior > 0 AND precio_nuevo > 0),
    -- Entre columnas: solo se audita un cambio real de precio (RN-13).
    ADD CONSTRAINT ck_auditoria_precio_distinto
        CHECK (precio_anterior <> precio_nuevo);


-- ---------------------------------------------------------------------
-- DEFAULT
-- (CURRENT_DATE es válido en un DEFAULT; lo que no se puede es usarlo en
--  un CHECK, porque el resultado cambiaría con el tiempo.)
-- ---------------------------------------------------------------------

ALTER TABLE finca
    ALTER COLUMN provincia SET DEFAULT 'Mendoza';

ALTER TABLE empleado
    ALTER COLUMN fecha_ingreso SET DEFAULT CURRENT_DATE;

ALTER TABLE cliente
    ALTER COLUMN fecha_alta SET DEFAULT CURRENT_DATE;
    -- cliente.descuento NO tiene DEFAULT fijo: depende del tipo de cliente.
    -- Lo completa un trigger BEFORE INSERT con fn_descuento_cliente (RN-06).

ALTER TABLE comprobante
    ALTER COLUMN fecha     SET DEFAULT CURRENT_DATE,
    ALTER COLUMN subtotal  SET DEFAULT 0,                    -- los recalcula el trigger (RN-08)
    ALTER COLUMN descuento SET DEFAULT 0,
    ALTER COLUMN total     SET DEFAULT 0;

-- RN-10: todo documento nace en confección.
ALTER TABLE ingreso
    ALTER COLUMN fecha  SET DEFAULT CURRENT_DATE,
    ALTER COLUMN estado SET DEFAULT 'en_confeccion';

-- RN-11: nace en confección; la fecha actual y su inmutabilidad las fuerza
-- un trigger (005), el DEFAULT es solo comodidad al insertar.
ALTER TABLE transferencia
    ALTER COLUMN fecha_confeccion SET DEFAULT CURRENT_DATE,
    ALTER COLUMN estado           SET DEFAULT 'en_confeccion';

ALTER TABLE stock_sala
    ALTER COLUMN cantidad SET DEFAULT 0;

ALTER TABLE stock_deposito
    ALTER COLUMN cantidad SET DEFAULT 0;

-- RN-13: el trigger de auditoría no necesita informarlos.
ALTER TABLE auditoria_precio
    ALTER COLUMN fecha_hora SET DEFAULT now(),
    ALTER COLUMN usuario    SET DEFAULT current_user;
