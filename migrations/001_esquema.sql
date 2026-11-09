-- =====================================================================
-- 001_esquema.sql  ·  TPI Bases de Datos  ·  «Bodegas del Atuel»
-- Etapa 1 (modelado): tipos propios, tablas, claves primarias y foráneas.
-- PostgreSQL 14 o superior. Corre de punta a punta sobre una base vacía.
--
-- Qué NO va acá (se completa en 002_constraints.sql, etapa 2):
--   UNIQUE adicionales, CHECK y DEFAULT.
--
-- Convenciones:
--   * Dinero con NUMERIC(p,s), nunca FLOAT. Fechas con DATE / TIMESTAMP.
--   * Claves sustitutas: INTEGER GENERATED ALWAYS AS IDENTITY.
--     Claves naturales: CUIT (bodega, empleado), (id_finca, nro_parcela).
--   * Identificadores sin ñ ni tildes (campania, anada).
--   * Acciones referenciales:
--       ON DELETE RESTRICT  -> catálogos y movimientos (RN-14).
--       ON DELETE CASCADE   -> filas que no existen sin su cabecera
--                              (renglones, subtipos de cliente, permisos,
--                               análisis, composición, parcelas).
--       ON UPDATE CASCADE   -> solo en claves naturales (CUIT, parcela).
--       ON UPDATE RESTRICT  -> claves sustitutas (nunca se modifican).
-- =====================================================================


-- ---------------------------------------------------------------------
-- Tipos propios
-- ---------------------------------------------------------------------

-- Estado de ingresos y transferencias (RN-10, RN-11).
CREATE TYPE estado_documento AS ENUM ('en_confeccion', 'terminado', 'procesado');

-- CUIT de 11 dígitos, sin guiones.
CREATE DOMAIN cuit_dom AS CHAR(11)
    CHECK (VALUE ~ '^[0-9]{11}$');


-- ---------------------------------------------------------------------
-- Territorio y personal
-- ---------------------------------------------------------------------

CREATE TABLE localidad (
    id_localidad        INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    nombre              VARCHAR(80)  NOT NULL,
    provincia           VARCHAR(60)  NOT NULL,
    cod_postal          VARCHAR(8)   NOT NULL,
    encargado_regional  VARCHAR(100) NOT NULL      -- RN-02: uno por localidad
);

CREATE TABLE sala_venta (
    id_sala       INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    calle         VARCHAR(80)  NOT NULL,
    numero        INTEGER      NOT NULL,
    dia_cierre    VARCHAR(9)   NOT NULL,
    id_localidad  INTEGER      NOT NULL
        REFERENCES localidad (id_localidad) ON DELETE RESTRICT ON UPDATE RESTRICT
);

CREATE TABLE empleado (
    cuit           cuit_dom      PRIMARY KEY,
    nombre         VARCHAR(100)  NOT NULL,
    fecha_ingreso  DATE          NOT NULL,
    salario        NUMERIC(12,2) NOT NULL,
    id_sala        INTEGER       NOT NULL            -- RN-03
        REFERENCES sala_venta (id_sala) ON DELETE RESTRICT ON UPDATE RESTRICT
);


-- ---------------------------------------------------------------------
-- Producción de uva
-- ---------------------------------------------------------------------

CREATE TABLE cepa (
    id_cepa  INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    nombre   VARCHAR(50) NOT NULL,
    tipo     VARCHAR(6)  NOT NULL                    -- tinta | blanca
);

CREATE TABLE finca (
    id_finca             INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    nombre               VARCHAR(80)   NOT NULL,
    superficie_ha        NUMERIC(10,2) NOT NULL,
    nombre_departamento  VARCHAR(60)   NOT NULL,
    provincia            VARCHAR(60)   NOT NULL
);

-- Entidad débil: no existe sin su finca.
CREATE TABLE parcela (
    id_finca         INTEGER       NOT NULL
        REFERENCES finca (id_finca) ON DELETE CASCADE ON UPDATE RESTRICT,
    nro_parcela      INTEGER       NOT NULL,
    superficie       NUMERIC(10,2) NOT NULL,
    anio_plantacion  SMALLINT      NOT NULL,
    id_cepa          INTEGER       NOT NULL           -- RN-04: una sola cepa
        REFERENCES cepa (id_cepa) ON DELETE RESTRICT ON UPDATE RESTRICT,
    PRIMARY KEY (id_finca, nro_parcela)
);

CREATE TABLE bodega (
    cuit          cuit_dom     PRIMARY KEY,
    razon_social  VARCHAR(120) NOT NULL,
    domicilio     VARCHAR(150) NOT NULL
);

CREATE TABLE lote (
    nro_lote       INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    id_finca       INTEGER       NOT NULL,
    nro_parcela    INTEGER       NOT NULL,
    campania       SMALLINT      NOT NULL,            -- UNIQUE (parcela, campania) en 002 (RN-04)
    fecha_cosecha  DATE          NOT NULL,
    kilos          NUMERIC(12,2) NOT NULL,
    cuit_bodega    cuit_dom      NOT NULL
        REFERENCES bodega (cuit) ON DELETE RESTRICT ON UPDATE CASCADE,
    FOREIGN KEY (id_finca, nro_parcela)
        REFERENCES parcela (id_finca, nro_parcela) ON DELETE RESTRICT ON UPDATE CASCADE
);

CREATE TABLE analisis_calidad (
    id_analisis   INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    nro_lote      INTEGER      NOT NULL
        REFERENCES lote (nro_lote) ON DELETE CASCADE ON UPDATE RESTRICT,
    fecha         DATE         NOT NULL,
    grado_brix    NUMERIC(4,1) NOT NULL,
    ph            NUMERIC(3,2) NOT NULL,
    acidez_total  NUMERIC(4,2) NOT NULL              -- g/L
);


-- ---------------------------------------------------------------------
-- Vinos
-- ---------------------------------------------------------------------

CREATE TABLE vino (
    cod_vino     INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    nombre       VARCHAR(80)   NOT NULL,
    tipo         VARCHAR(12)   NOT NULL,              -- tinto | blanco | rosado | espumante
    anada        SMALLINT      NOT NULL,
    volumen_ml   INTEGER       NOT NULL,
    graduacion   NUMERIC(4,2)  NOT NULL,
    precio       NUMERIC(10,2) NOT NULL,              -- RN-01: único para toda la red
    cuit_bodega  cuit_dom      NOT NULL               -- RN-14
        REFERENCES bodega (cuit) ON DELETE RESTRICT ON UPDATE CASCADE
);

-- N:M vino-cepa con atributo. La suma de porcentajes por vino = 100 (RN-05, etapa 2).
CREATE TABLE composicion (
    cod_vino    INTEGER      NOT NULL
        REFERENCES vino (cod_vino) ON DELETE CASCADE ON UPDATE RESTRICT,
    id_cepa     INTEGER      NOT NULL
        REFERENCES cepa (id_cepa) ON DELETE RESTRICT ON UPDATE RESTRICT,
    porcentaje  NUMERIC(5,2) NOT NULL,
    PRIMARY KEY (cod_vino, id_cepa)
);

CREATE TABLE maridaje (
    id_maridaje           INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    nombre                VARCHAR(60)  NOT NULL,
    temperatura_servicio  NUMERIC(4,1) NOT NULL       -- °C
);

CREATE TABLE vino_maridaje (
    cod_vino     INTEGER NOT NULL
        REFERENCES vino (cod_vino) ON DELETE CASCADE ON UPDATE RESTRICT,
    id_maridaje  INTEGER NOT NULL
        REFERENCES maridaje (id_maridaje) ON DELETE RESTRICT ON UPDATE RESTRICT,
    PRIMARY KEY (cod_vino, id_maridaje)
);


-- ---------------------------------------------------------------------
-- Clientes (supertipo + un subtipo por tipo de cliente)
-- ---------------------------------------------------------------------

CREATE TABLE cliente (
    id_cliente           INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    nombre_razon_social  VARCHAR(120) NOT NULL,
    tipo_doc             VARCHAR(10)  NOT NULL,
    nro_doc              VARCHAR(20)  NOT NULL,
    direccion            VARCHAR(150) NOT NULL,
    fecha_alta           DATE         NOT NULL,
    tipo_cliente         VARCHAR(12)  NOT NULL,       -- socio | distribuidor | exportador
    descuento            NUMERIC(5,2) NOT NULL,       -- porcentaje (RN-06)
    id_localidad         INTEGER      NOT NULL
        REFERENCES localidad (id_localidad) ON DELETE RESTRICT ON UPDATE RESTRICT
);

CREATE TABLE socio (
    id_cliente  INTEGER PRIMARY KEY
        REFERENCES cliente (id_cliente) ON DELETE CASCADE ON UPDATE RESTRICT
);

CREATE TABLE distribuidor (
    id_cliente        INTEGER PRIMARY KEY
        REFERENCES cliente (id_cliente) ON DELETE CASCADE ON UPDATE RESTRICT,
    zona_cobertura    VARCHAR(100) NOT NULL,
    nro_habilitacion  VARCHAR(30)  NOT NULL
);

CREATE TABLE exportador (
    id_cliente    INTEGER PRIMARY KEY
        REFERENCES cliente (id_cliente) ON DELETE CASCADE ON UPDATE RESTRICT,
    pais_destino  VARCHAR(60) NOT NULL
);

-- Apunta a EXPORTADOR (no a CLIENTE): solo un exportador tiene permisos (RN-07).
CREATE TABLE permiso_exportacion (
    cod_permiso        INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    id_cliente         INTEGER NOT NULL
        REFERENCES exportador (id_cliente) ON DELETE CASCADE ON UPDATE RESTRICT,
    fecha_emision      DATE    NOT NULL,
    fecha_vencimiento  DATE    NOT NULL
);


-- ---------------------------------------------------------------------
-- Ventas
-- subtotal / descuento / total los calcula la base (RN-08), nunca la API.
--   renglon.descuento = porcentaje; renglon.subtotal = importe neto.
--   comprobante.subtotal = bruto; comprobante.descuento = importe descontado.
-- ---------------------------------------------------------------------

CREATE TABLE comprobante (
    nro_comprobante  INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    fecha            DATE          NOT NULL,
    id_cliente       INTEGER       NOT NULL
        REFERENCES cliente (id_cliente) ON DELETE RESTRICT ON UPDATE RESTRICT,
    id_sala          INTEGER       NOT NULL
        REFERENCES sala_venta (id_sala) ON DELETE RESTRICT ON UPDATE RESTRICT,
    subtotal         NUMERIC(14,2) NOT NULL,
    descuento        NUMERIC(14,2) NOT NULL,
    total            NUMERIC(14,2) NOT NULL
);

CREATE TABLE renglon_comprobante (
    nro_comprobante  INTEGER       NOT NULL
        REFERENCES comprobante (nro_comprobante) ON DELETE CASCADE ON UPDATE RESTRICT,
    cod_vino         INTEGER       NOT NULL
        REFERENCES vino (cod_vino) ON DELETE RESTRICT ON UPDATE RESTRICT,
    cantidad         INTEGER       NOT NULL,
    precio_unitario  NUMERIC(10,2) NOT NULL,          -- precio al momento de la venta
    descuento        NUMERIC(5,2)  NOT NULL,          -- porcentaje aplicado
    subtotal         NUMERIC(14,2) NOT NULL,          -- importe neto del renglón
    PRIMARY KEY (nro_comprobante, cod_vino)
);


-- ---------------------------------------------------------------------
-- Logística: transportistas, ingresos y transferencias
-- ---------------------------------------------------------------------

CREATE TABLE transportista (
    cod_transporte  INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    razon_social    VARCHAR(120) NOT NULL,
    cuit            cuit_dom     NOT NULL,
    email           VARCHAR(120) NOT NULL,
    telefono        VARCHAR(30)  NOT NULL,
    domicilio       VARCHAR(150) NOT NULL
);

CREATE TABLE transportista_localidad (
    cod_transporte  INTEGER NOT NULL
        REFERENCES transportista (cod_transporte) ON DELETE CASCADE ON UPDATE RESTRICT,
    id_localidad    INTEGER NOT NULL
        REFERENCES localidad (id_localidad) ON DELETE RESTRICT ON UPDATE RESTRICT,
    PRIMARY KEY (cod_transporte, id_localidad)
);

CREATE TABLE ingreso (
    cod_ingreso     INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    fecha           DATE             NOT NULL,
    estado          estado_documento NOT NULL,        -- default 'en_confeccion' en 002 (RN-10)
    cod_transporte  INTEGER          NOT NULL
        REFERENCES transportista (cod_transporte) ON DELETE RESTRICT ON UPDATE RESTRICT,
    cuit_bodega     cuit_dom         NOT NULL
        REFERENCES bodega (cuit) ON DELETE RESTRICT ON UPDATE CASCADE
);

CREATE TABLE renglon_ingreso (
    cod_ingreso  INTEGER NOT NULL
        REFERENCES ingreso (cod_ingreso) ON DELETE CASCADE ON UPDATE RESTRICT,
    cod_vino     INTEGER NOT NULL
        REFERENCES vino (cod_vino) ON DELETE RESTRICT ON UPDATE RESTRICT,
    cantidad     INTEGER NOT NULL,
    PRIMARY KEY (cod_ingreso, cod_vino)
);

CREATE TABLE transferencia (
    nro_solicitud     INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    fecha_confeccion  DATE             NOT NULL,      -- la fuerza un trigger (RN-11)
    estado            estado_documento NOT NULL,      -- default 'en_confeccion' en 002 (RN-11)
    id_sala           INTEGER          NOT NULL
        REFERENCES sala_venta (id_sala) ON DELETE RESTRICT ON UPDATE RESTRICT
);

CREATE TABLE renglon_transferencia (
    nro_solicitud  INTEGER NOT NULL
        REFERENCES transferencia (nro_solicitud) ON DELETE CASCADE ON UPDATE RESTRICT,
    cod_vino       INTEGER NOT NULL
        REFERENCES vino (cod_vino) ON DELETE RESTRICT ON UPDATE RESTRICT,
    cantidad       INTEGER NOT NULL,
    PRIMARY KEY (nro_solicitud, cod_vino)
);


-- ---------------------------------------------------------------------
-- Stock
-- ---------------------------------------------------------------------

CREATE TABLE stock_sala (
    id_sala   INTEGER NOT NULL
        REFERENCES sala_venta (id_sala) ON DELETE RESTRICT ON UPDATE RESTRICT,
    cod_vino  INTEGER NOT NULL
        REFERENCES vino (cod_vino) ON DELETE RESTRICT ON UPDATE RESTRICT,
    cantidad  INTEGER NOT NULL,                       -- CHECK (cantidad >= 0) en 002 (RN-09)
    PRIMARY KEY (id_sala, cod_vino)
);

-- Un solo depósito central: no hay tabla DEPOSITO, la clave es el vino.
CREATE TABLE stock_deposito (
    cod_vino  INTEGER PRIMARY KEY
        REFERENCES vino (cod_vino) ON DELETE RESTRICT ON UPDATE RESTRICT,
    cantidad  INTEGER NOT NULL                        -- CHECK (cantidad >= 0) en 002
);


-- ---------------------------------------------------------------------
-- Auditoría de precios (la completa un trigger en la etapa 2, RN-13)
-- ---------------------------------------------------------------------

CREATE TABLE auditoria_precio (
    id_auditoria     INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    cod_vino         INTEGER       NOT NULL
        REFERENCES vino (cod_vino) ON DELETE RESTRICT ON UPDATE RESTRICT,
    precio_anterior  NUMERIC(10,2) NOT NULL,
    precio_nuevo     NUMERIC(10,2) NOT NULL,
    fecha_hora       TIMESTAMP     NOT NULL,
    usuario          VARCHAR(63)   NOT NULL
);
