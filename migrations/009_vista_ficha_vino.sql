-- =====================================================================
-- 009_vista_ficha_vino.sql  ·  Etapa 5 (S9) y pantalla de detalle de la API
-- Una fila por vino: datos, bodega, corte de cepas, maridajes y stock.
-- Cada lista se arma en una subconsulta aparte para que los joins no
-- multipliquen las filas. Despues de crearla, volver a correr 007_roles.sql
-- para darle SELECT a app_rw y app_ro.
-- =====================================================================
CREATE OR REPLACE VIEW v_ficha_vino AS
SELECT v.cod_vino,
       v.nombre,
       v.tipo,
       v.anada,
       v.volumen_ml,
       v.graduacion,
       v.precio,
       b.cuit          AS cuit_bodega,
       b.razon_social  AS bodega,
       (SELECT string_agg(c.nombre || ' ' || trim(trailing '.' FROM trim(trailing '0' FROM co.porcentaje::text)) || '%',
                          ', ' ORDER BY co.porcentaje DESC, c.nombre)
          FROM composicion co JOIN cepa c USING (id_cepa)
         WHERE co.cod_vino = v.cod_vino)                        AS cepas,
       (SELECT string_agg(m.nombre, ', ' ORDER BY m.nombre)
          FROM vino_maridaje vm JOIN maridaje m USING (id_maridaje)
         WHERE vm.cod_vino = v.cod_vino)                        AS maridajes,
       s.stock_deposito,
       s.stock_salas,
       s.stock_total
FROM vino v
JOIN bodega b ON b.cuit = v.cuit_bodega
JOIN v_stock_total_vino s ON s.cod_vino = v.cod_vino;
