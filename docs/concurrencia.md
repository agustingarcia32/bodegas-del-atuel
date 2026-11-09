# Demo de concurrencia (Etapa 2)

Script: `tests/demo_concurrencia.sh`. Salida real guardada en `tests/resultado_concurrencia.txt`. Nivel de aislamiento: READ COMMITTED (el de PostgreSQL por defecto).

## 1. La última botella
Dos clientes compran a la vez la última botella de una sala (stock 1). El trigger `trg_renglon_valida_stock` hace `SELECT … FOR UPDATE` sobre la fila de `stock_sala`: la segunda sesión espera a que la primera termine y, cuando la lee, ve stock 0.

```
sesion B: ERROR:  Stock insuficiente del vino 1 en la sala 1 (hay 0, se piden 1) (RN-09)
stock final: 0  (nunca negativo)
ventas del vino: 1  (solo una se concreta)
```
Sin el `FOR UPDATE` las dos sesiones leerían stock 1 y las dos intentarían restar: la segunda chocaría contra el CHECK `ck_stock_sala_no_negativo` (error 23514). Por eso el stock nunca queda negativo, pero el mensaje sería el genérico del CHECK y no el de la regla. El `FOR UPDATE` mejora el mensaje y el comportamiento; el CHECK es la red de seguridad.

## 2. El mismo ingreso procesado dos veces
`sp_procesar_ingreso` bloquea el ingreso con `FOR UPDATE`. La segunda sesión espera, y al entrar ya lo ve `procesado`:

```
sesion B: ERROR:  El ingreso 1 no está terminado (estado actual: procesado). Solo un ingreso terminado impacta en el depósito (RN-10)
deposito antes: 0, despues: 100  (+100 una sola vez)
```

## Para el informe
Las capturas de pantalla las tienen que sacar ustedes corriendo `demo_concurrencia.sh` en su máquina (o con dos terminales `psql` y los pasos a mano). Esta salida sirve de referencia de lo que tiene que dar.
