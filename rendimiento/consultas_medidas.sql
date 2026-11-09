-- consultas_medidas.sql - Etapa 4. Una consulta por bloque, separadas por una linea "-- @Qn titulo".
-- Los valores concretos (sala 7, vino 123, bodega 5) son del dataset de la semilla 2026.

-- @Q1 S8 - Ventas por sala en el ultimo trimestre
SELECT s.id_sala, s.calle || ' ' || s.numero AS sala, SUM(c.total) AS ventas
FROM comprobante c JOIN sala_venta s USING (id_sala)
WHERE c.fecha >= CURRENT_DATE - INTERVAL '3 months'
GROUP BY s.id_sala, s.calle, s.numero
ORDER BY ventas DESC;

-- @Q2 S3 - Clientes de cada tipo que compraron en la sala 7 en la ultima semana
SELECT k.tipo_cliente, COUNT(DISTINCT c.id_cliente) AS clientes
FROM comprobante c JOIN cliente k USING (id_cliente)
WHERE c.id_sala = 7 AND c.fecha >= CURRENT_DATE - 7
GROUP BY k.tipo_cliente;

-- @Q3 S1 - Top 10 de vinos mas vendidos
SELECT v.cod_vino, v.nombre, SUM(r.cantidad) AS botellas
FROM renglon_comprobante r JOIN vino v USING (cod_vino)
GROUP BY v.cod_vino, v.nombre
ORDER BY botellas DESC
LIMIT 10;

-- @Q4 S12 - Clientes que compraron todos los vinos de la bodega 5 (division relacional)
SELECT k.id_cliente
FROM cliente k
WHERE NOT EXISTS (
    SELECT 1 FROM vino v
    WHERE v.cuit_bodega = (SELECT cuit FROM bodega ORDER BY cuit OFFSET 4 LIMIT 1)
      AND NOT EXISTS (
        SELECT 1 FROM comprobante c JOIN renglon_comprobante r USING (nro_comprobante)
        WHERE c.id_cliente = k.id_cliente AND r.cod_vino = v.cod_vino));

-- @Q5 Historial de compras de un cliente (pantalla de la API)
SELECT c.nro_comprobante, c.fecha, c.total
FROM comprobante c
WHERE c.id_cliente = 4321
ORDER BY c.fecha DESC;

-- @Q6 S5 - Salas con menos transferencias pendientes
SELECT id_sala, COUNT(*) AS pendientes
FROM transferencia
WHERE estado <> 'procesado'
GROUP BY id_sala
ORDER BY pendientes ASC, id_sala
LIMIT 5;

-- @Q7 Busqueda de clientes por nombre (prefijo, sin distinguir mayusculas)
SELECT id_cliente, nombre_razon_social
FROM cliente
WHERE lower(nombre_razon_social) LIKE 'garc%'
ORDER BY nombre_razon_social
LIMIT 20;

-- @Q8 S4 - Top 5 de salas que pidieron mas del vino 123 por transferencias en los ultimos 15 dias
SELECT t.id_sala, SUM(rt.cantidad) AS pedido
FROM transferencia t JOIN renglon_transferencia rt USING (nro_solicitud)
WHERE rt.cod_vino = 123 AND t.fecha_confeccion >= CURRENT_DATE - 15
GROUP BY t.id_sala
ORDER BY pedido DESC
LIMIT 5;
