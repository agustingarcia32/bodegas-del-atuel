-- =====================================================================
-- 004_procedimientos.sql  ·  TPI Bases de Datos  ·  «Bodegas del Atuel»
-- Etapa 2 (lógica en la base): procedimientos transaccionales.
-- Se aplica después de 001, 002 y 003.
--
-- Un procedimiento es el lugar de una operación de VARIOS PASOS que debe
-- ser todo o nada. Los dos de este archivo:
--     sp_procesar_ingreso(cod_ingreso)       RN-10, RN-12
--     sp_procesar_transferencia(nro_solicitud)  RN-11, RN-12
--
-- Transaccionalidad:
--   * Se ejecutan con CALL dentro de la transacción de quien llama. Si
--     cualquier paso lanza una excepción, se revierte TODO lo hecho por el
--     procedimiento: nunca queda un stock a medias. Por eso NO hacen COMMIT
--     ni ROLLBACK propios (el cierre de la transacción es de quien llama:
--     la API o la sesión psql).
--   * Todos los errores de negocio son RAISE EXCEPTION con SQLSTATE P0001
--     (valor por defecto). La API los traduce a 409 Conflict con el
--     mensaje de la regla.
--
-- Concurrencia (nivel de aislamiento por defecto: READ COMMITTED):
--   * El documento se bloquea con SELECT ... FOR UPDATE antes de leer su
--     estado. Si dos sesiones procesan el mismo documento a la vez, la
--     segunda espera, y cuando la primera termina ve estado 'procesado' y
--     falla: un documento no puede impactar dos veces en el stock.
--   * Las filas de stock se bloquean SIEMPRE en el mismo orden (por
--     cod_vino) para que dos transferencias que tocan vinos en común no
--     puedan quedar trabadas en un deadlock.
--
-- Variable de sesión 'atuel.procesando':
--   Estos procedimientos son la ÚNICA vía legítima para pasar un documento
--   de 'terminado' a 'procesado'. Antes del UPDATE de estado activan
--   (solo dentro de la transacción) la variable atuel.procesando = 'on' y
--   luego la apagan. El trigger de control de estados (005_triggers.sql,
--   RN-10 y RN-11) acepta terminado -> procesado únicamente si la variable
--   está activa. Así nadie puede marcar un documento como procesado a mano
--   sin que impacte en el stock.
-- =====================================================================


-- ---------------------------------------------------------------------
-- sp_procesar_ingreso
-- Propósito  : impactar un ingreso terminado en el stock del depósito
--              central y marcarlo como procesado.
-- Reglas     : RN-10 (solo un ingreso terminado impacta; luego pasa a
--              procesado y no retrocede).
-- Parámetros : p_cod_ingreso INTEGER (cod_ingreso).
-- Pasos      : 1) bloquear el ingreso y validar que existe y está
--                 terminado;
--              2) validar que tiene renglones;
--              3) sumar cada vino al stock del depósito (si el vino no
--                 tenía fila, se crea);
--              4) pasar el ingreso a procesado.
-- Errores    : P0001 si no existe, no está terminado o no tiene renglones.
-- Uso        : CALL sp_procesar_ingreso(1);
-- ---------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE sp_procesar_ingreso(p_cod_ingreso INTEGER)
LANGUAGE plpgsql AS $$
DECLARE
    v_estado     estado_documento;
    v_renglones  INTEGER;
BEGIN
    -- 1) Bloqueo del documento: serializa dos procesamientos simultáneos.
    SELECT estado INTO v_estado
      FROM ingreso
     WHERE cod_ingreso = p_cod_ingreso
       FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'El ingreso % no existe (RN-10)', p_cod_ingreso;
    END IF;

    IF v_estado <> 'terminado' THEN
        RAISE EXCEPTION
            'El ingreso % no está terminado (estado actual: %). Solo un ingreso terminado impacta en el depósito (RN-10)',
            p_cod_ingreso, v_estado;
    END IF;

    -- 2) Un ingreso vacío no tiene nada que impactar.
    SELECT count(*) INTO v_renglones
      FROM renglon_ingreso
     WHERE cod_ingreso = p_cod_ingreso;

    IF v_renglones = 0 THEN
        RAISE EXCEPTION 'El ingreso % no tiene renglones: no hay nada que procesar (RN-10)',
            p_cod_ingreso;
    END IF;

    -- 3) Suma al depósito. Si el vino todavía no tenía fila, se crea;
    --    si ya la tenía, se acumula. ORDER BY fija el orden de bloqueo.
    INSERT INTO stock_deposito (cod_vino, cantidad)
    SELECT r.cod_vino, r.cantidad
      FROM renglon_ingreso r
     WHERE r.cod_ingreso = p_cod_ingreso
     ORDER BY r.cod_vino
    ON CONFLICT (cod_vino)
    DO UPDATE SET cantidad = stock_deposito.cantidad + EXCLUDED.cantidad;

    -- 4) Cambio de estado, autorizado para el trigger de estados (005).
    PERFORM set_config('atuel.procesando', 'on', true);
    UPDATE ingreso SET estado = 'procesado' WHERE cod_ingreso = p_cod_ingreso;
    PERFORM set_config('atuel.procesando', 'off', true);
END;
$$;

COMMENT ON PROCEDURE sp_procesar_ingreso(INTEGER) IS
    'RN-10. Suma al deposito los renglones de un ingreso terminado y lo pasa a procesado, todo en una transaccion.';


-- ---------------------------------------------------------------------
-- sp_procesar_transferencia
-- Propósito  : mover stock del depósito central a una sala según una
--              transferencia terminada, y marcarla como procesada.
-- Reglas     : RN-11 (solo una transferencia terminada impacta; no puede
--              procesarse si el depósito no tiene stock suficiente).
-- Parámetros : p_nro_solicitud INTEGER (nro_solicitud).
-- Pasos      : 1) bloquear la transferencia y validar existencia/estado;
--              2) validar que tiene renglones;
--              3) bloquear las filas de stock del depósito (orden fijo);
--              4) verificar que CADA vino existe en el depósito y alcanza
--                 (un vino sin fila cuenta como stock 0);
--              5) descontar del depósito;
--              6) sumar al stock de la sala (se crea la fila si no existía);
--              7) pasar la transferencia a procesada.
-- Errores    : P0001 si no existe, no está terminada, no tiene renglones
--              o el depósito no alcanza (el mensaje lista los vinos que
--              faltan, con lo pedido y lo disponible).
-- Atomicidad : todas las validaciones ocurren ANTES de modificar nada; y
--              si algo igual fallara después, el procedimiento entero se
--              revierte. No queda ningún cambio a medias.
-- Uso        : CALL sp_procesar_transferencia(1234);
--
-- Sobre el ejemplo del anexo A.6 del enunciado: allí, si un vino del
-- renglón no tiene fila en stock_deposito, el UPDATE no descuenta nada y
-- no da error (la sala recibiría botellas sin que salgan del depósito).
-- Acá se resuelve en dos capas: (a) el paso 4 trata la fila inexistente
-- como stock 0 y rechaza la transferencia; (b) tras el UPDATE se compara
-- la cantidad de filas afectadas con la de renglones.
-- ---------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE sp_procesar_transferencia(p_nro_solicitud INTEGER)
LANGUAGE plpgsql AS $$
DECLARE
    v_estado     estado_documento;
    v_sala       INTEGER;
    v_renglones  INTEGER;
    v_faltantes  TEXT;
    v_filas      INTEGER;
BEGIN
    -- 1) Bloqueo del documento y validación de estado.
    SELECT estado, id_sala INTO v_estado, v_sala
      FROM transferencia
     WHERE nro_solicitud = p_nro_solicitud
       FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'La transferencia % no existe (RN-11)', p_nro_solicitud;
    END IF;

    IF v_estado <> 'terminado' THEN
        RAISE EXCEPTION
            'La transferencia % no está terminada (estado actual: %). Solo una transferencia terminada impacta en el stock (RN-11)',
            p_nro_solicitud, v_estado;
    END IF;

    -- 2) Una transferencia vacía no tiene nada que mover.
    SELECT count(*) INTO v_renglones
      FROM renglon_transferencia
     WHERE nro_solicitud = p_nro_solicitud;

    IF v_renglones = 0 THEN
        RAISE EXCEPTION 'La transferencia % no tiene renglones: no hay nada que procesar (RN-11)',
            p_nro_solicitud;
    END IF;

    -- 3) Bloqueo de las filas de stock del depósito, siempre en el mismo
    --    orden (cod_vino) para evitar deadlocks entre transferencias.
    PERFORM d.cod_vino
       FROM stock_deposito d
      WHERE d.cod_vino IN (SELECT r.cod_vino
                             FROM renglon_transferencia r
                            WHERE r.nro_solicitud = p_nro_solicitud)
      ORDER BY d.cod_vino
        FOR UPDATE;

    -- 4) Verificación de stock. LEFT JOIN + COALESCE: un vino sin fila en
    --    el depósito se considera con stock 0 (no se ignora).
    SELECT string_agg(
               format('vino %s (pedido %s, disponible %s)',
                      r.cod_vino, r.cantidad, COALESCE(d.cantidad, 0)),
               '; ' ORDER BY r.cod_vino)
      INTO v_faltantes
      FROM renglon_transferencia r
      LEFT JOIN stock_deposito d ON d.cod_vino = r.cod_vino
     WHERE r.nro_solicitud = p_nro_solicitud
       AND COALESCE(d.cantidad, 0) < r.cantidad;

    IF v_faltantes IS NOT NULL THEN
        RAISE EXCEPTION
            'Stock insuficiente en el depósito para procesar la transferencia %: % (RN-11)',
            p_nro_solicitud, v_faltantes;
    END IF;

    -- 5) Descuento del depósito.
    UPDATE stock_deposito d
       SET cantidad = d.cantidad - r.cantidad
      FROM renglon_transferencia r
     WHERE r.nro_solicitud = p_nro_solicitud
       AND d.cod_vino = r.cod_vino;

    GET DIAGNOSTICS v_filas = ROW_COUNT;
    IF v_filas <> v_renglones THEN
        -- Red de seguridad: no debería ocurrir tras el paso 4.
        RAISE EXCEPTION
            'Inconsistencia al procesar la transferencia %: se actualizaron % filas del depósito y hay % renglones',
            p_nro_solicitud, v_filas, v_renglones;
    END IF;

    -- 6) Suma al stock de la sala (se crea la fila si no existía).
    INSERT INTO stock_sala (id_sala, cod_vino, cantidad)
    SELECT v_sala, r.cod_vino, r.cantidad
      FROM renglon_transferencia r
     WHERE r.nro_solicitud = p_nro_solicitud
     ORDER BY r.cod_vino
    ON CONFLICT (id_sala, cod_vino)
    DO UPDATE SET cantidad = stock_sala.cantidad + EXCLUDED.cantidad;

    -- 7) Cambio de estado, autorizado para el trigger de estados (005).
    PERFORM set_config('atuel.procesando', 'on', true);
    UPDATE transferencia SET estado = 'procesado' WHERE nro_solicitud = p_nro_solicitud;
    PERFORM set_config('atuel.procesando', 'off', true);
END;
$$;

COMMENT ON PROCEDURE sp_procesar_transferencia(INTEGER) IS
    'RN-11. Descuenta del deposito y suma a la sala los renglones de una transferencia terminada, y la pasa a procesada, todo en una transaccion. Rechaza si el deposito no alcanza.';
