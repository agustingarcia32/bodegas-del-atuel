# Etapa 5 — Consultas SQL

Archivos: `consultas/update.sql`, `insert.sql`, `delete.sql`, `select.sql`. Las sentencias que modifican datos corren dentro de `BEGIN … ROLLBACK` con control previo y posterior; la salida real está en `consultas/resultado_*.txt`. Base: semilla 2026, fecha de referencia 2026-11-07, índices de 008 y vista de 009.

## Modificación (U) — filas afectadas
| Cód. | Estrategia | Filas | Observación |
|---|---|---:|---|
| U1 | CTE que calcula bruto y neto por comprobante con `fn_descuento_cliente` + `fn_subtotal_renglon`, y `UPDATE … FROM` solo donde difiere | 1.000 | La prueba "rompe" antes 1.000 comprobantes (sin descuento); tras U1 quedan 0 mal. Opera sobre el comprobante, como pide la consigna; los renglones conservan el % aplicado al vender |
| U2 | `fn_antiguedad_anios(fecha_ingreso) > 5` | 92 | Masa salarial 130,76 M → 146,94 M (+12,4 %: no todos suben) |
| U3 | subconsulta escalar razón social → CUIT | 19 | El trigger RN-13 escribió 19 filas en `auditoria_precio` (894 → 913) |
| U4 | un `UPDATE` con `CASE` | 14 | 8 lunes y 6 miércoles pasan a 6 y 8. El CASE usa el valor original de cada fila |
| U5 | CTE con `LEFT JOIN` (cuenta vinos sin ventas), `ORDER BY ventas, cod_vino LIMIT 10` | 10 | 10 filas más en la auditoría |
| U6 | `GROUP BY … HAVING COUNT(*) > 3` | 258 | De 982 exportadores, 258 pasan de 30 % a 35 % |

## Inserción (I)
| Cód. | Estrategia | Resultado |
|---|---|---|
| I1 | `LEFT JOIN` desde transportista a los ingresos del trimestre, el de menos envíos; `ON CONFLICT DO NOTHING` | 1 fila: transportista 16 cubre ahora General Alvear (118 → 119 coberturas) |
| I2 | CTE de escritura: crea el maridaje solo si `EXISTS` un tinto ≥ 14° y lo asocia | 1 maridaje + 170 asociaciones |
| I3 | comprobante + 3 renglones solo con vino y cantidad; trigger valida stock, pone precio/descuento/subtotal y descuenta stock | 3 renglones; subtotal 129.000, descuento 12.900 (socio 10 %), total 116.100 = `fn_total_comprobante` |
| I4 / I5 | `INSERT` simple (la sala toma la localidad por subconsulta) | 40 → 41 bodegas; sala id 61 |
| I6 | CTE de escritura: cabecera `en_confeccion` con la bodega del vino + renglón de 120 | 1 ingreso (3.001) y el depósito sigue igual (1.284) hasta procesarlo |

## Borrado (D)
| Cód. | Estrategia | Filas | Observación |
|---|---|---:|---|
| D1 | `DELETE … USING cliente` (socios, > 5 años) | 11.055 comprobantes | Arrastra 41.423 renglones por `ON DELETE CASCADE` (562.295 → 520.872). El stock no se repone a propósito |
| D2 | doble `NOT EXISTS` | 1 | Las 12 cepas del dataset están en uso (FK `RESTRICT`); la prueba agrega una libre |
| D3 | subconsulta de salas de la localidad + antigüedad < 2 | 2 (de 6 empleados) | La sala no se borra: tiene ventas y stock (RESTRICT) |
| D4 | `NOT EXISTS` de compras + alta > 5 años | 192 | Fila de `socio` por cascada |
| D5 | `estado = 'procesado' AND fecha < CURRENT_DATE - 365` | 2.327 ingresos | Cascada a 6.831 renglones; el trigger RN-12 lo permite porque la cabecera ya no existe. El depósito no se revierte (2.030.346 antes y después) |
| D6 | igual que D4 con localidad | 18 | |

## Consultas (S)
| Cód. | Técnica | Resultado destacado |
|---|---|---|
| S1 | agregación + `ORDER BY … LIMIT 10` | 1.º: Reserva Pinot Noir del Pedemonte, 5.445 botellas |
| S2 | división por `HAVING COUNT(DISTINCT sala) = total de salas` | 12 vinos (los "estrella" del generador) |
| S3 | `COUNT(DISTINCT)` por tipo, sala 7, 7 días | 7 socios |
| S4 | transferencias de 15 días, vino 116 | 2 salas (80 y 21 botellas): hay menos de 5 |
| S5 | `LEFT JOIN` para contar ceros + mínimo | salas 9 y 56 (0 pendientes) |
| S6 | `NOT EXISTS` contra stock_sala | 15 mostrados (límite) |
| S7 | `FETCH FIRST 1 ROW WITH TIES` | Transporte Santa Rosa, 14 ingresos |
| S8 | `SUM(total)` por sala, trimestre | sala 18 (Güemes 547) con $31,76 M |
| S9 | vista `v_ficha_vino` | 0,12 ms; plan con Index Scan y 2 subplanes |
| S10 | CTE + subconsulta correlacionada | 1.495 de 3.000 lotes rinden menos que el promedio de su finca y campaña; 350 ms |
| S11 | `RANK() OVER (PARTITION BY sala …)` y suma acumulada | 49 ms; el acumulado de la sala 1 llega a $565 M |
| S12 | doble `NOT EXISTS` / anti-join | (a) 0 clientes para esa bodega: ninguno compró los ~20 vinos; la prueba con una bodega de 2 vinos devuelve al cliente que compró ambos y no al que compró uno; (b) 414 clientes sin tintos (359 socios) |

## Triggers y constraints observados
- U3 y U5 disparan la auditoría de precios; I3 dispara validación de stock, cálculo de importes y actualización de totales; D1 y D5 disparan los triggers de renglones por cascada.
- Se corrigió en el camino: I6 creaba dos ingresos porque «Tradición Malbec del Cañón» 750 ml existe en dos añadas; ahora toma la más nueva.
- S10 tarda 350 ms por las 3.000 subconsultas correlacionadas (es lo que pide la consigna). Una alternativa equivalente: `AVG(kg_por_ha) OVER (PARTITION BY id_finca, campania)`, que recorre una sola vez.
- Parámetros: se cambian donde dice `PARAMETRO` (sala 7, vino 123 / 116, 'Bodega Piedra Colorada', 'Guaymallén', 'Uspallata', 'General Alvear').
