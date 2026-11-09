-- =====================================================================
-- 005_triggers.sql  ·  Bodegas del Atuel  ·  Etapa 2
-- Va después de 001 a 004. Cada trigger dice arriba qué regla protege.
-- Los errores de negocio son RAISE EXCEPTION (P0001 -> la API responde 409).
-- =====================================================================


-- ---------------------------------------------------------------------
-- RN-06: si el cliente se inserta sin descuento, se completa con el que
-- corresponde a su tipo (10/20/30). Después se puede subir a mano (U6).
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION trg_cliente_descuento() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.descuento IS NULL THEN
        NEW.descuento := fn_descuento_cliente(NEW.tipo_cliente);
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_cliente_descuento
BEFORE INSERT ON cliente
FOR EACH ROW EXECUTE FUNCTION trg_cliente_descuento();


-- ---------------------------------------------------------------------
-- Jerarquía de clientes: un cliente solo puede estar en la tabla de su
-- propio tipo (así nunca queda en dos subtipos), y una vez que tiene fila
-- de subtipo no se le puede cambiar el tipo.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION trg_subtipo_cliente() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
    v_tipo VARCHAR;
BEGIN
    SELECT tipo_cliente INTO v_tipo FROM cliente WHERE id_cliente = NEW.id_cliente;
    IF FOUND AND v_tipo <> TG_ARGV[0] THEN
        RAISE EXCEPTION 'El cliente % es de tipo %, no puede cargarse como %',
            NEW.id_cliente, v_tipo, TG_ARGV[0];
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_socio_tipo BEFORE INSERT OR UPDATE OF id_cliente ON socio
FOR EACH ROW EXECUTE FUNCTION trg_subtipo_cliente('socio');
CREATE TRIGGER trg_distribuidor_tipo BEFORE INSERT OR UPDATE OF id_cliente ON distribuidor
FOR EACH ROW EXECUTE FUNCTION trg_subtipo_cliente('distribuidor');
CREATE TRIGGER trg_exportador_tipo BEFORE INSERT OR UPDATE OF id_cliente ON exportador
FOR EACH ROW EXECUTE FUNCTION trg_subtipo_cliente('exportador');

CREATE OR REPLACE FUNCTION trg_cliente_tipo_fijo() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    IF EXISTS (SELECT 1 FROM socio        WHERE id_cliente = OLD.id_cliente)
    OR EXISTS (SELECT 1 FROM distribuidor WHERE id_cliente = OLD.id_cliente)
    OR EXISTS (SELECT 1 FROM exportador   WHERE id_cliente = OLD.id_cliente) THEN
        RAISE EXCEPTION 'El cliente % ya tiene datos de su tipo (%): no se puede cambiar el tipo',
            OLD.id_cliente, OLD.tipo_cliente;
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_cliente_tipo_fijo
BEFORE UPDATE OF tipo_cliente ON cliente
FOR EACH ROW WHEN (OLD.tipo_cliente IS DISTINCT FROM NEW.tipo_cliente)
EXECUTE FUNCTION trg_cliente_tipo_fijo();


-- ---------------------------------------------------------------------
-- RN-09 (BEFORE) + RN-08: antes de guardar un renglón de venta
--   * INSERT: bloquea la fila de stock de la sala, rechaza si no alcanza,
--     y toma el precio del vino y el descuento del cliente (no se cargan
--     a mano). El subtotal siempre lo calcula la base.
--   * UPDATE: solo se puede cambiar precio/descuento (lo usa U1); el
--     subtotal se recalcula. Comprobante, vino y cantidad no se tocan.
-- El FOR UPDATE es lo que evita que dos ventas simultáneas lean el mismo
-- stock (ver demo de concurrencia).
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION trg_renglon_venta_antes() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
    v_sala    INTEGER;
    v_cliente INTEGER;
    v_stock   INTEGER;
BEGIN
    IF TG_OP = 'UPDATE' THEN
        IF NEW.nro_comprobante <> OLD.nro_comprobante
           OR NEW.cod_vino <> OLD.cod_vino
           OR NEW.cantidad <> OLD.cantidad THEN
            RAISE EXCEPTION 'No se puede cambiar el comprobante, el vino ni la cantidad de un renglón ya cargado (RN-09)';
        END IF;
        NEW.subtotal := fn_subtotal_renglon(NEW.cantidad, NEW.precio_unitario, NEW.descuento);
        RETURN NEW;
    END IF;

    SELECT id_sala, id_cliente INTO v_sala, v_cliente
      FROM comprobante WHERE nro_comprobante = NEW.nro_comprobante;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'El comprobante % no existe', NEW.nro_comprobante;
    END IF;

    PERFORM 1 FROM stock_sala
     WHERE id_sala = v_sala AND cod_vino = NEW.cod_vino
       FOR UPDATE;
    v_stock := fn_stock_sala(v_sala, NEW.cod_vino);

    IF v_stock < NEW.cantidad THEN
        RAISE EXCEPTION 'Stock insuficiente del vino % en la sala % (hay %, se piden %) (RN-09)',
            NEW.cod_vino, v_sala, v_stock, NEW.cantidad;
    END IF;

    SELECT precio    INTO NEW.precio_unitario FROM vino    WHERE cod_vino   = NEW.cod_vino;
    SELECT descuento INTO NEW.descuento       FROM cliente WHERE id_cliente = v_cliente;
    NEW.subtotal := fn_subtotal_renglon(NEW.cantidad, NEW.precio_unitario, NEW.descuento);
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_renglon_valida_stock
BEFORE INSERT OR UPDATE ON renglon_comprobante
FOR EACH ROW EXECUTE FUNCTION trg_renglon_venta_antes();


-- ---------------------------------------------------------------------
-- RN-08 + RN-09 (AFTER): después de guardar el renglón
--   * INSERT: descuenta el stock de la sala.
--   * INSERT/UPDATE/DELETE: recalcula subtotal (bruto), total (neto) y
--     descuento (la diferencia) del comprobante, en un solo UPDATE para
--     que cumpla el CHECK total = subtotal - descuento.
-- Borrar un renglón NO devuelve stock: es historial de ventas (D1).
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION trg_renglon_venta_despues() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
    v_nro INTEGER;
BEGIN
    IF TG_OP = 'DELETE' THEN
        v_nro := OLD.nro_comprobante;
    ELSE
        v_nro := NEW.nro_comprobante;
    END IF;

    IF TG_OP = 'INSERT' THEN
        UPDATE stock_sala s
           SET cantidad = s.cantidad - NEW.cantidad
          FROM comprobante c
         WHERE c.nro_comprobante = NEW.nro_comprobante
           AND s.id_sala  = c.id_sala
           AND s.cod_vino = NEW.cod_vino;
    END IF;

    UPDATE comprobante c
       SET subtotal  = t.bruto,
           total     = t.neto,
           descuento = t.bruto - t.neto
      FROM (SELECT COALESCE(SUM(cantidad * precio_unitario), 0) AS bruto,
                   fn_total_comprobante(v_nro)                  AS neto
              FROM renglon_comprobante
             WHERE nro_comprobante = v_nro) t
     WHERE c.nro_comprobante = v_nro;

    RETURN NULL;
END;
$$;

CREATE TRIGGER trg_renglon_stock_totales
AFTER INSERT OR UPDATE OR DELETE ON renglon_comprobante
FOR EACH ROW EXECUTE FUNCTION trg_renglon_venta_despues();


-- ---------------------------------------------------------------------
-- RN-10 y RN-11: estados de ingreso y transferencia.
-- en_confeccion -> terminado -> procesado, sin retrocesos.
-- terminado -> procesado solo lo hacen los procedimientos sp_procesar_*
-- (activan atuel.procesando), así nadie lo marca "procesado" sin que se
-- mueva el stock. Ojo: es una convención, no seguridad; alguien con acceso
-- SQL podría activar la variable a mano.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION trg_control_estado() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    IF OLD.estado = 'en_confeccion' AND NEW.estado = 'terminado' THEN
        RETURN NEW;
    END IF;

    IF OLD.estado = 'terminado' AND NEW.estado = 'procesado' THEN
        IF COALESCE(current_setting('atuel.procesando', true), '') = 'on' THEN
            RETURN NEW;
        END IF;
        RAISE EXCEPTION 'Un documento solo pasa a procesado con %() (RN-10/RN-11)',
            CASE TG_TABLE_NAME WHEN 'ingreso' THEN 'sp_procesar_ingreso'
                               ELSE 'sp_procesar_transferencia' END;
    END IF;

    RAISE EXCEPTION 'Cambio de estado no permitido en %: % -> % (RN-10/RN-11)',
        TG_TABLE_NAME, OLD.estado, NEW.estado;
END;
$$;

CREATE TRIGGER trg_ingreso_estado
BEFORE UPDATE OF estado ON ingreso
FOR EACH ROW WHEN (OLD.estado IS DISTINCT FROM NEW.estado)
EXECUTE FUNCTION trg_control_estado();

CREATE TRIGGER trg_transferencia_estado
BEFORE UPDATE OF estado ON transferencia
FOR EACH ROW WHEN (OLD.estado IS DISTINCT FROM NEW.estado)
EXECUTE FUNCTION trg_control_estado();


-- ---------------------------------------------------------------------
-- RN-12: un ingreso / transferencia que no está en confección no admite
-- agregar, modificar ni quitar renglones.
-- Excepción para el borrado en cascada (consigna D5, borrar ingresos
-- procesados viejos): cuando se borra el documento, al borrarse sus
-- renglones el documento ya no existe, y ahí se deja pasar. Borrar un
-- renglón suelto de un documento que existe sigue bloqueado.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION trg_bloqueo_renglon_ingreso() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
    v_cod    INTEGER;
    v_estado estado_documento;
BEGIN
    IF TG_OP = 'DELETE' THEN
        v_cod := OLD.cod_ingreso;
    ELSE
        v_cod := NEW.cod_ingreso;
    END IF;

    IF TG_OP = 'UPDATE' AND NEW.cod_ingreso <> OLD.cod_ingreso THEN
        RAISE EXCEPTION 'No se puede mover un renglón a otro ingreso (RN-12)';
    END IF;

    SELECT estado INTO v_estado FROM ingreso WHERE cod_ingreso = v_cod;
    IF FOUND AND v_estado <> 'en_confeccion' THEN
        RAISE EXCEPTION 'El ingreso % está % y no admite cambios en sus renglones (RN-12)',
            v_cod, v_estado;
    END IF;

    IF TG_OP = 'DELETE' THEN
        RETURN OLD;
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_renglon_ingreso_bloqueo
BEFORE INSERT OR UPDATE OR DELETE ON renglon_ingreso
FOR EACH ROW EXECUTE FUNCTION trg_bloqueo_renglon_ingreso();

CREATE OR REPLACE FUNCTION trg_bloqueo_renglon_transferencia() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
    v_nro    INTEGER;
    v_estado estado_documento;
BEGIN
    IF TG_OP = 'DELETE' THEN
        v_nro := OLD.nro_solicitud;
    ELSE
        v_nro := NEW.nro_solicitud;
    END IF;

    IF TG_OP = 'UPDATE' AND NEW.nro_solicitud <> OLD.nro_solicitud THEN
        RAISE EXCEPTION 'No se puede mover un renglón a otra transferencia (RN-12)';
    END IF;

    SELECT estado INTO v_estado FROM transferencia WHERE nro_solicitud = v_nro;
    IF FOUND AND v_estado <> 'en_confeccion' THEN
        RAISE EXCEPTION 'La transferencia % está % y no admite cambios en sus renglones (RN-12)',
            v_nro, v_estado;
    END IF;

    IF TG_OP = 'DELETE' THEN
        RETURN OLD;
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_renglon_transferencia_bloqueo
BEFORE INSERT OR UPDATE OR DELETE ON renglon_transferencia
FOR EACH ROW EXECUTE FUNCTION trg_bloqueo_renglon_transferencia();


-- ---------------------------------------------------------------------
-- RN-11: la fecha de confección de una transferencia es siempre la fecha
-- actual y no se puede modificar. (Va en un trigger porque un CHECK no
-- puede usar CURRENT_DATE.)
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION trg_transferencia_fecha() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    IF TG_OP = 'INSERT' THEN
        NEW.fecha_confeccion := CURRENT_DATE;
    ELSIF NEW.fecha_confeccion IS DISTINCT FROM OLD.fecha_confeccion THEN
        RAISE EXCEPTION 'La fecha de confección de una transferencia no se puede modificar (RN-11)';
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_transferencia_fecha
BEFORE INSERT OR UPDATE ON transferencia
FOR EACH ROW EXECUTE FUNCTION trg_transferencia_fecha();


-- ---------------------------------------------------------------------
-- RN-13: todo cambio de precio de un vino queda en auditoria_precio.
-- La fecha y el usuario salen de los DEFAULT (now() y current_user).
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION trg_vino_auditoria() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO auditoria_precio (cod_vino, precio_anterior, precio_nuevo)
    VALUES (NEW.cod_vino, OLD.precio, NEW.precio);
    RETURN NULL;
END;
$$;

CREATE TRIGGER trg_vino_auditoria
AFTER UPDATE OF precio ON vino
FOR EACH ROW WHEN (OLD.precio IS DISTINCT FROM NEW.precio)
EXECUTE FUNCTION trg_vino_auditoria();


-- ---------------------------------------------------------------------
-- RN-05: los porcentajes de corte de un vino suman 100.
-- Constraint trigger DIFERIDO: se evalúa al hacer COMMIT, porque mientras
-- se cargan las cepas de a una la suma pasa por valores intermedios. Por
-- eso el vino y su composición se cargan en una sola transacción.
-- Un vino sin ninguna cepa cargada no se controla (por ejemplo cuando se
-- borra el vino y se van sus filas en cascada).
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_chequear_suma_composicion(p_vino INTEGER) RETURNS VOID
LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_suma NUMERIC;
BEGIN
    SELECT SUM(porcentaje) INTO v_suma FROM composicion WHERE cod_vino = p_vino;
    IF v_suma IS NOT NULL AND v_suma <> 100 THEN
        RAISE EXCEPTION 'Los porcentajes del vino % suman % y deben sumar 100 (RN-05)', p_vino, v_suma;
    END IF;
END;
$$;

CREATE OR REPLACE FUNCTION trg_composicion_suma() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    IF TG_OP IN ('INSERT', 'UPDATE') THEN
        PERFORM fn_chequear_suma_composicion(NEW.cod_vino);
    END IF;
    IF TG_OP IN ('UPDATE', 'DELETE') THEN
        PERFORM fn_chequear_suma_composicion(OLD.cod_vino);
    END IF;
    RETURN NULL;
END;
$$;

CREATE CONSTRAINT TRIGGER trg_composicion_suma
AFTER INSERT OR UPDATE OR DELETE ON composicion
DEFERRABLE INITIALLY DEFERRED
FOR EACH ROW EXECUTE FUNCTION trg_composicion_suma();
