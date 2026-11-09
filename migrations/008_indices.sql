-- =====================================================================
-- 008_indices.sql  ·  Bodegas del Atuel  ·  Etapa 4
-- Va después de 001 a 007, con la base ya cargada (se crean más rápido
-- sobre datos que antes de cargar: ver docs/etapa4_indices.md).
-- Cada índice dice a qué consulta ayuda y por qué tiene esa forma.
-- =====================================================================

-- 1) COMPUESTO (id_sala, fecha)   -> S3 y cualquier "ventas de una sala en un período".
--    El orden importa: id_sala va primero porque se filtra con "=" y fecha
--    después porque se filtra con un rango (>=). Con el orden inverso
--    (fecha, id_sala) PostgreSQL tendría que recorrer todas las fechas del
--    rango y filtrar la sala dentro de cada una.
CREATE INDEX IF NOT EXISTS idx_comprobante_sala_fecha
    ON comprobante (id_sala, fecha);

-- 2) CON INCLUDE (fecha) INCLUDE (id_sala, total)  -> S8 (ventas por sala en el trimestre).
--    La consulta solo necesita fecha, id_sala y total: con INCLUDE se leen del
--    índice (Index Only Scan) sin visitar la tabla. id_sala y total no son
--    parte de la clave (no se buscan por ellos), solo viajan en el índice.
CREATE INDEX IF NOT EXISTS idx_comprobante_fecha_cubriente
    ON comprobante (fecha) INCLUDE (id_sala, total);

-- 3) CLAVE FORÁNEA comprobante.id_cliente (+ fecha DESC)  -> historial de un cliente,
--    S12, D4 y D6 (clientes sin compras) y el chequeo de la FK al borrar un cliente.
--    PostgreSQL no indexa las claves foráneas solas. Con fecha DESC el historial
--    sale ya ordenado, sin paso de ordenamiento.
CREATE INDEX IF NOT EXISTS idx_comprobante_cliente_fecha
    ON comprobante (id_cliente, fecha DESC);

-- 4) CLAVE FORÁNEA renglon_comprobante.cod_vino INCLUDE (cantidad)  -> S1, S2, S12.
--    La clave primaria es (nro_comprobante, cod_vino): sirve para buscar por
--    comprobante pero no por vino. Con INCLUDE (cantidad) el ranking de
--    botellas vendidas se resuelve sin tocar la tabla.
CREATE INDEX IF NOT EXISTS idx_renglon_comprobante_vino
    ON renglon_comprobante (cod_vino) INCLUDE (cantidad);

-- 5) PARCIAL  transferencia(id_sala) WHERE estado <> 'procesado'  -> S5 y v_documentos_pendientes.
--    Los pendientes son ~8 % de la tabla y son los únicos que se consultan:
--    el índice es mucho más chico y casi no se actualiza (los procesados no entran).
CREATE INDEX IF NOT EXISTS idx_transferencia_pendientes
    ON transferencia (id_sala) WHERE estado <> 'procesado';

-- 6) DE EXPRESIÓN  lower(nombre_razon_social) con text_pattern_ops  -> búsqueda de
--    clientes por prefijo sin distinguir mayúsculas (pantalla de clientes de la API).
--    Sin text_pattern_ops un LIKE 'garc%' no usa el índice con la collation
--    por defecto de la mayoría de las instalaciones.
CREATE INDEX IF NOT EXISTS idx_cliente_nombre_lower
    ON cliente (lower(nombre_razon_social) text_pattern_ops);

-- 7) CLAVE FORÁNEA stock_sala.cod_vino  -> S6, S9 y v_stock_total_vino (stock de un vino en
--    todas las salas). La PK es (id_sala, cod_vino): sirve por sala, no por vino.
CREATE INDEX IF NOT EXISTS idx_stock_sala_vino
    ON stock_sala (cod_vino);

-- 8) CLAVE FORÁNEA cliente.id_localidad  -> D6 (socios de una localidad) y el chequeo de la FK
--    cuando se intenta borrar una localidad.
CREATE INDEX IF NOT EXISTS idx_cliente_localidad
    ON cliente (id_localidad);

ANALYZE;
