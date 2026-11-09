"""
db.py - conexion a PostgreSQL con psycopg 3 y un pool simple.
La configuracion sale de variables de entorno (las mismas que usa psql):
PGHOST, PGPORT, PGDATABASE, PGUSER, PGPASSWORD (o DATABASE_URL). Nunca se escriben en el codigo.
La API se conecta con el rol app_rw, que no es propietario ni superusuario.
"""
import contextlib
import os
import queue

import psycopg
from psycopg.rows import dict_row


def _conectar():
    url = os.environ.get("DATABASE_URL", "")
    return psycopg.connect(url, row_factory=dict_row, connect_timeout=5,
                           application_name="bodegas-api")


class Pool:
    """Pool minimo y seguro para hilos: una cola de conexiones abiertas."""

    def __init__(self, tamanio=None):
        self.tamanio = tamanio or int(os.environ.get("DB_POOL_SIZE", "5"))
        self._cola = queue.LifoQueue()
        self._creadas = 0
        self._candado = __import__("threading").Lock()

    def _tomar(self):
        try:
            return self._cola.get_nowait()
        except queue.Empty:
            pass
        with self._candado:
            if self._creadas < self.tamanio:
                self._creadas += 1
                try:
                    return _conectar()
                except Exception:
                    self._creadas -= 1
                    raise
        return self._cola.get(timeout=10)       # espera una conexion libre

    def _devolver(self, conn):
        if conn.closed:
            with self._candado:
                self._creadas -= 1
        else:
            self._cola.put(conn)

    @contextlib.contextmanager
    def transaccion(self):
        """BEGIN implicito en la primera sentencia; COMMIT al salir bien, ROLLBACK si hay error.
        Un error en el COMMIT (por ejemplo el trigger diferido de RN-05) tambien se propaga."""
        conn = self._tomar()
        try:
            with conn.cursor() as cur:
                yield cur
            conn.commit()
        except BaseException:
            if not conn.closed:
                conn.rollback()
            raise
        finally:
            self._devolver(conn)

    def cerrar(self):
        while not self._cola.empty():
            self._cola.get_nowait().close()


pool = Pool()
