# Recorrido automatico del front con navegador real (Playwright). Las rutas/variables PG* son las del entorno de prueba: adaptarlas.
import subprocess, sys, os, time
from playwright.sync_api import sync_playwright
env = dict(os.environ, PYTHONPATH="/home/claude/testtools", PGHOST="/var/lib/postgresql/tpi_test", PGPORT="5544",
           PGDATABASE="bodegas_api", PGUSER="app_rw", CORS_ORIGIN="http://localhost:8080")
api = subprocess.Popen([sys.executable, "-m", "flask", "--app", "app", "run", "--port", "8000"], cwd="/home/claude/db/api", env=env,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
web = subprocess.Popen([sys.executable, "-m", "http.server", "8080", "-d", "/home/claude/db/front"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
time.sleep(2.5)
out = os.environ["OUT"]
try:
    with sync_playwright() as p:
        b = p.chromium.launch(); pg = b.new_page(viewport={"width": 1000, "height": 800})
        errs = []; pg.on("pageerror", lambda e: errs.append(str(e))); pg.on("console", lambda m: m.type == "error" and errs.append(m.text))
        def shot(n): pg.screenshot(path=f"{out}/{n}.png")
        pg.goto("http://localhost:8080/#/catalogo"); pg.wait_for_selector("table"); print("catalogo filas:", pg.locator("tbody tr").count()); shot("1_catalogo")
        pg.fill("input[name=q]", "' OR 1=1 --"); pg.click("text=Filtrar"); pg.wait_for_selector(".vacio"); print("inyeccion:", pg.inner_text(".vacio"))
        pg.fill("input[name=q]", ""); pg.fill("input[name=anada]", "abc"); pg.click("text=Filtrar"); pg.wait_for_selector(".msg.error"); print("anada abc ->", pg.inner_text(".msg"))
        pg.fill("input[name=anada]", ""); pg.click("text=Filtrar"); pg.wait_for_selector("table"); pg.click("tbody tr a"); pg.wait_for_selector("h3:text('Trazabilidad')"); print("ficha:", pg.inner_text("h2")); shot("2_ficha")
        pg.goto("http://localhost:8080/#/vino-nuevo"); pg.wait_for_selector("input[name=nombre]")
        pg.fill("input[name=nombre]", f"Vino E2E {int(time.time())}"); pg.fill("input[name=anada]", "2022"); pg.fill("input[name=graduacion]", "13.5"); pg.fill("input[name=precio]", "9000")
        pg.locator(".p").nth(0).fill("70"); pg.locator(".p").nth(1).fill("20"); pg.locator("select.c").nth(1).select_option(index=1)
        pg.click("text=Guardar vino"); pg.wait_for_selector(".msg.error"); print("porcentajes 90 ->", pg.inner_text(".msg")); shot("3_alta_error")
        pg.locator(".p").nth(1).fill("30"); pg.click("text=Guardar vino"); pg.wait_for_selector("h3:text('Trazabilidad')"); print("alta ok ->", pg.inner_text("h2"))
        pg.goto("http://localhost:8080/#/venta"); pg.wait_for_selector("input[name=id_cliente]"); pg.fill("input[name=id_cliente]", "1"); pg.fill(".q", "99999")
        pg.click("text=Registrar venta"); pg.wait_for_selector(".msg.error"); print("sin stock ->", pg.inner_text(".msg")); shot("4_venta_error")
        pg.fill(".q", "1"); pg.click("text=Registrar venta"); pg.wait_for_selector("#res .tarjeta"); print("venta:", pg.inner_text("#res").replace("\n", " | ")[:200]); shot("4_venta_ok")
        pg.goto("http://localhost:8080/#/transferencias"); pg.wait_for_selector("#nueva"); pg.click("text=Crear transferencia"); pg.wait_for_selector("#add")
        pg.click("#ter"); pg.wait_for_selector("#pro", timeout=3000) if False else None
        pg.wait_for_selector("#pro"); print("terminada; estado:", pg.inner_text(".tarjeta h3"))
        pg.click("#pro"); pg.wait_for_selector(".msg.ok, .msg.error"); print("procesar (sin renglones) ->", pg.inner_text(".msg")); shot("5_transferencias")
        pg.goto("http://localhost:8080/#/reportes"); pg.wait_for_selector("#top table"); pg.wait_for_selector("#tr table"); shot("6_reportes"); print("reportes ok")
        pg.set_viewport_size({"width": 390, "height": 800}); pg.goto("http://localhost:8080/#/catalogo"); pg.wait_for_selector("table"); shot("7_movil")
        pg.goto("http://localhost:8080/#/nada"); print("ruta mala:", pg.inner_text(".vacio"))
        print("errores de consola/JS:", errs); b.close()
finally:
    api.terminate(); web.terminate()
