-- =====================================================================
-- 003_funciones.sql  ·  TPI Bases de Datos  ·  «Bodegas del Atuel»
-- Etapa 2 (lógica en la base): funciones reutilizables.
-- Se aplica después de 001_esquema.sql y 002_constraints.sql.
--
-- Criterio: una función es el lugar de un cálculo que se usa en varios
-- lugares (triggers, procedimientos, consultas U1/U2, vistas, API).
-- Así el cálculo vive una sola vez y la API no lo recalcula.
--
-- Volatilidad (lo que se declara le dice al planificador qué puede asumir):
--   IMMUTABLE: mismo resultado siempre para los mismos argumentos; no lee
--              tablas ni la fecha actual.
--   STABLE   : dentro de una misma sentencia da el mismo resultado, pero
--              puede depender de datos de tablas o de la fecha actual.
--   Declarar IMMUTABLE una función que lee tablas o usa CURRENT_DATE es
--   un error: un resultado cacheado quedaría desactualizado.
--
-- Funciones:
--   1. fn_descuento_cliente   (IMMUTABLE)  RN-06
--   2. fn_stock_sala          (STABLE)     RN-09
--   3. fn_total_comprobante   (STABLE)     RN-08
--   4. fn_antiguedad_anios    (STABLE)     consignas U2, D3, D4
--   +  fn_subtotal_renglon    (IMMUTABLE)  RN-08 (fórmula del renglón)
-- =====================================================================


-- ---------------------------------------------------------------------
-- 1. fn_descuento_cliente
-- Propósito  : porcentaje de descuento que corresponde a un tipo de cliente.
-- Regla      : RN-06 (socio 10 %, distribuidor 20 %, exportador 30 %).
-- Parámetros : p_tipo VARCHAR -> 'socio' | 'distribuidor' | 'exportador'.
-- Devuelve   : NUMERIC(5,2), un porcentaje (10.00, 20.00 o 30.00).
-- Volatilidad: IMMUTABLE (solo depende del argumento; no lee tablas).
-- Uso        : un trigger BEFORE INSERT en cliente completa
--              cliente.descuento con este valor cuando no se informa.
--              Es el valor POR DEFECTO: la consigna U6 puede subirlo luego
--              para un cliente puntual, por eso cliente.descuento se
--              almacena y no se deduce siempre del tipo.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_descuento_cliente(p_tipo VARCHAR)
RETURNS NUMERIC(5,2)
LANGUAGE plpgsql IMMUTABLE AS $$
BEGIN
    IF p_tipo = 'socio' THEN
        RETURN 10.00;
    ELSIF p_tipo = 'distribuidor' THEN
        RETURN 20.00;
    ELSIF p_tipo = 'exportador' THEN
        RETURN 30.00;
    END IF;

    -- ck_cliente_tipo ya impide otros tipos en la tabla; si alguien llama a
    -- la función con un valor inválido, se avisa en lugar de inventar un
    -- descuento.
    RAISE EXCEPTION 'Tipo de cliente desconocido: %', p_tipo
        USING ERRCODE = 'invalid_parameter_value';
END;
$$;

COMMENT ON FUNCTION fn_descuento_cliente(VARCHAR) IS
    'RN-06. Porcentaje de descuento por defecto según el tipo de cliente. IMMUTABLE.';


-- ---------------------------------------------------------------------
-- 2. fn_stock_sala
-- Propósito  : stock actual de un vino en una sala.
-- Regla      : RN-09 (la usa el trigger que valida la venta).
-- Parámetros : p_sala INTEGER (id_sala), p_vino INTEGER (cod_vino).
-- Devuelve   : INTEGER. Si la sala nunca tuvo ese vino devuelve 0
--              (no hay fila en stock_sala), nunca NULL.
-- Volatilidad: STABLE (lee la tabla stock_sala).
-- Nota       : es una LECTURA. No bloquea la fila: para evitar que dos
--              ventas simultáneas lean el mismo stock, quien necesite
--              consistencia usa SELECT ... FOR UPDATE (ver demo de
--              concurrencia) o el CHECK (cantidad >= 0) como red de
--              seguridad.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_stock_sala(p_sala INTEGER, p_vino INTEGER)
RETURNS INTEGER
LANGUAGE sql STABLE AS $$
    SELECT COALESCE(
        (SELECT cantidad
           FROM stock_sala
          WHERE id_sala = p_sala
            AND cod_vino = p_vino),
        0);
$$;

COMMENT ON FUNCTION fn_stock_sala(INTEGER, INTEGER) IS
    'RN-09. Stock de un vino en una sala; 0 si no hay fila. STABLE.';


-- ---------------------------------------------------------------------
-- +. fn_subtotal_renglon  (auxiliar de fn_total_comprobante)
-- Propósito  : importe NETO de un renglón: cantidad x precio, menos el
--              descuento porcentual, redondeado a 2 decimales.
-- Regla      : RN-08. Concentra la fórmula en un solo lugar para que el
--              trigger, la consigna U1 y la carga masiva calculen igual.
-- Parámetros : p_cantidad INTEGER, p_precio NUMERIC (precio unitario),
--              p_descuento NUMERIC (porcentaje, 0 a 100).
-- Devuelve   : NUMERIC(14,2). NULL si algún argumento es NULL.
-- Volatilidad: IMMUTABLE (cálculo puro sobre sus argumentos).
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_subtotal_renglon(
    p_cantidad  INTEGER,
    p_precio    NUMERIC,
    p_descuento NUMERIC)
RETURNS NUMERIC(14,2)
LANGUAGE sql IMMUTABLE STRICT AS $$
    SELECT ROUND(p_cantidad * p_precio * (100 - p_descuento) / 100, 2)::NUMERIC(14,2);
$$;

COMMENT ON FUNCTION fn_subtotal_renglon(INTEGER, NUMERIC, NUMERIC) IS
    'RN-08. Importe neto de un renglon = cantidad x precio x (1 - descuento/100), redondeado a 2 decimales. IMMUTABLE.';


-- ---------------------------------------------------------------------
-- 3. fn_total_comprobante
-- Propósito  : total de un comprobante: suma de sus renglones con el
--              descuento ya aplicado (importe neto).
-- Regla      : RN-08 (el total no se carga a mano).
-- Parámetros : p_nro INTEGER (nro_comprobante).
-- Devuelve   : NUMERIC (2 decimales). 0 si el comprobante no tiene
--              renglones o no existe, nunca NULL.
-- Volatilidad: STABLE (lee renglon_comprobante).
-- Relación   : el trigger AFTER INSERT del renglón (005) usa este valor
--              para actualizar comprobante.total y deriva
--                subtotal  (bruto)     = SUM(cantidad x precio_unitario)
--                descuento (importe)   = subtotal - total
--              de modo que se cumple ck_comprobante_total_coherente.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_total_comprobante(p_nro INTEGER)
RETURNS NUMERIC
LANGUAGE sql STABLE AS $$
    SELECT COALESCE(SUM(subtotal), 0)
      FROM renglon_comprobante
     WHERE nro_comprobante = p_nro;
$$;

COMMENT ON FUNCTION fn_total_comprobante(INTEGER) IS
    'RN-08. Total de un comprobante = suma de los subtotales netos de sus renglones; 0 si no tiene. STABLE.';


-- ---------------------------------------------------------------------
-- 4. fn_antiguedad_anios
-- Propósito  : años cumplidos completos entre una fecha y hoy.
-- Uso        : consigna U2 (empleados con más de 5 años), D3 (menos de
--              dos años), D4 (clientes dados de alta hace más de 5 años).
-- Parámetros : p_desde DATE (fecha de ingreso, de alta, etc.).
-- Devuelve   : INTEGER, años cumplidos (3 años y 11 meses -> 3).
--              Si la fecha es futura devuelve 0, no un número negativo.
--              Si la fecha es NULL devuelve NULL (STRICT): GREATEST ignora
--              los NULL y sin STRICT daría 0, un dato engañoso.
-- Volatilidad: STABLE, NO IMMUTABLE: depende de CURRENT_DATE, así que el
--              resultado cambia con el tiempo aunque el argumento sea el
--              mismo. Marcarla IMMUTABLE sería incorrecto.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_antiguedad_anios(p_desde DATE)
RETURNS INTEGER
LANGUAGE sql STABLE STRICT AS $$
    SELECT GREATEST(0, EXTRACT(YEAR FROM age(CURRENT_DATE, p_desde))::INTEGER);
$$;

COMMENT ON FUNCTION fn_antiguedad_anios(DATE) IS
    'Anios cumplidos desde una fecha hasta hoy (0 si la fecha es futura). STABLE: usa CURRENT_DATE.';
