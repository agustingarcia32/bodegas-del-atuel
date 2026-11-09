// Front sin calculos de negocio: todo importe, descuento, stock y estado viene de la API.
const $ = (s, r = document) => r.querySelector(s);
const vista = $("#vista");
const esc = (t) => String(t ?? "").replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));
const dinero = (n) => Number(n).toLocaleString("es-AR", { style: "currency", currency: "ARS" });

function aviso(texto, tipo = "error") {
  const d = $("#aviso");
  d.innerHTML = texto ? `<div class="msg ${tipo}">${esc(texto)}</div>` : "";
  if (tipo === "ok" && texto) setTimeout(() => { if (d.textContent === texto) d.innerHTML = ""; }, 4000);
}

async function api(ruta, opciones = {}) {
  let r;
  try {
    r = await fetch(window.API_URL + ruta, {
      headers: { "Content-Type": "application/json" }, ...opciones,
      body: opciones.body ? JSON.stringify(opciones.body) : undefined,
    });
  } catch (e) {
    throw new Error("No se pudo conectar con el servidor. Verificá que la API esté en marcha.");
  }
  if (r.status === 204) return null;
  const datos = await r.json().catch(() => ({}));
  if (!r.ok) {
    const e = datos.error || {};
    throw new Error(e.mensaje || `Error ${r.status}`);
  }
  return datos;
}

// Ejecuta una accion mostrando el error de la API si falla y bloqueando el boton mientras tanto.
async function accion(boton, fn) {
  if (boton) boton.disabled = true;
  aviso("");
  try { return await fn(); }
  catch (e) { aviso(e.message); }
  finally { if (boton) boton.disabled = false; }
}

const opciones = (lista, valor, texto, vacio) =>
  (vacio ? `<option value="">${esc(vacio)}</option>` : "") +
  lista.map((x) => `<option value="${esc(x[valor])}">${esc(typeof texto === "function" ? texto(x) : x[texto])}</option>`).join("");

const tabla = (cols, filas, vacio = "Sin resultados") =>
  filas.length
    ? `<table><thead><tr>${cols.map((c) => `<th class="${c.num ? "num" : ""}">${esc(c.t)}</th>`).join("")}</tr></thead><tbody>${
        filas.map((f) => `<tr>${cols.map((c) => `<td class="${c.num ? "num" : ""}">${c.h ? c.h(f) : esc(f[c.k])}</td>`).join("")}</tr>`).join("")
      }</tbody></table>`
    : `<p class="vacio">${esc(vacio)}</p>`;

// ------------------------------------------------------------- 1. Catalogo
async function catalogo() {
  const [cepas, bodegas] = await Promise.all([api("/cepas"), api("/bodegas")]);
  vista.innerHTML = `<h2>Catálogo de vinos</h2>
  <form class="filtros" id="f">
    <label>Buscar<input name="q" placeholder="nombre"></label>
    <label>Tipo<select name="tipo"><option value="">Todos</option><option>tinto</option><option>blanco</option><option>rosado</option><option>espumante</option></select></label>
    <label>Cepa<select name="cepa">${opciones(cepas, "id_cepa", "nombre", "Todas")}</select></label>
    <label>Bodega<select name="bodega">${opciones(bodegas, "cuit", "razon_social", "Todas")}</select></label>
    <label>Añada<input name="anada" size="5" inputmode="numeric"></label>
    <button>Filtrar</button></form>
  <div id="lista">Cargando…</div>`;
  let pagina = 1;
  const cargar = async () => {
    const p = new URLSearchParams({ pagina, por_pagina: 15 });
    new FormData($("#f")).forEach((v, k) => v && p.set(k, v));
    const r = await accion(null, () => api("/vinos?" + p));
    if (!r) { $("#lista").innerHTML = ""; return; }
    const paginas = Math.max(1, Math.ceil(r.total / r.por_pagina));
    $("#lista").innerHTML = tabla([
      { t: "Vino", h: (v) => `<a href="#/vino/${v.cod_vino}">${esc(v.nombre)}</a>` },
      { t: "Tipo", k: "tipo" }, { t: "Añada", k: "anada" }, { t: "Bodega", k: "bodega" },
      { t: "Precio", num: 1, h: (v) => dinero(v.precio) }], r.datos, "No hay vinos con esos filtros") +
      `<div class="paginas"><button class="sec" id="ant" ${pagina <= 1 ? "disabled" : ""}>‹</button>
       <span>Página ${pagina} de ${paginas} · ${r.total} vinos</span>
       <button class="sec" id="sig" ${pagina >= paginas ? "disabled" : ""}>›</button></div>`;
    $("#ant").onclick = () => { pagina--; cargar(); };
    $("#sig").onclick = () => { pagina++; cargar(); };
  };
  $("#f").onsubmit = (e) => { e.preventDefault(); pagina = 1; cargar(); };
  cargar();
}

// ------------------------------------------------------------- 2. Ficha del vino
async function ficha(cod) {
  const v = await api("/vinos/" + cod);
  const t = await api("/reportes/trazabilidad/" + cod);
  vista.innerHTML = `<p><a href="#/catalogo">‹ Volver al catálogo</a></p>
  <div class="tarjeta"><h2>${esc(v.nombre)} ${esc(v.anada)}</h2>
    <p>${esc(v.tipo)} · ${esc(v.volumen_ml)} ml · ${esc(v.graduacion)}° · Bodega ${esc(v.bodega)}</p>
    <p><strong>${dinero(v.precio)}</strong> · Stock total: ${esc(v.stock_total)} u.</p></div>
  <h3>Composición</h3>${tabla([{ t: "Cepa", k: "cepa" }, { t: "%", num: 1, k: "porcentaje" }], v.composicion)}
  <h3>Maridajes</h3>${v.maridajes_detalle.length ? "<p>" + v.maridajes_detalle.map((m) => esc(m.nombre)).join(", ") + "</p>" : '<p class="vacio">Sin maridajes cargados</p>'}
  <h3>Historial de precio</h3>${tabla([{ t: "Fecha", h: (a) => esc(String(a.fecha_hora).slice(0, 10)) }, { t: "Anterior", num: 1, h: (a) => dinero(a.precio_anterior) }, { t: "Nuevo", num: 1, h: (a) => dinero(a.precio_nuevo) }], v.historial_precio, "Sin cambios de precio")}
  <h3>Trazabilidad</h3>
  <h4>Lotes de uva</h4>${tabla(Object.keys(t.lotes[0] || {}).map((k) => ({ t: k, k })), t.lotes, "Sin lotes")}
  <h4>Ingresos al depósito</h4>${tabla(Object.keys(t.ingresos[0] || {}).map((k) => ({ t: k, k })), t.ingresos, "Sin ingresos")}`;
}

// ------------------------------------------------------------- 3. Alta de vino
async function vinoNuevo() {
  const [cepas, bodegas, maridajes] = await Promise.all([api("/cepas"), api("/bodegas"), api("/maridajes")]);
  const filaCepa = () => `<div class="fila cepa"><label>Cepa<select class="c">${opciones(cepas, "id_cepa", "nombre")}</select></label>
    <label>%<input class="p" size="4" inputmode="decimal"></label><button type="button" class="sec quitar">Quitar</button></div>`;
  vista.innerHTML = `<h2>Alta de vino</h2><form id="f">
  <div class="fila"><label>Nombre<input name="nombre" required></label>
  <label>Tipo<select name="tipo"><option>tinto</option><option>blanco</option><option>rosado</option><option>espumante</option></select></label>
  <label>Añada<input name="anada" size="5" required></label><label>Volumen (ml)<input name="volumen_ml" value="750" size="5"></label>
  <label>Graduación<input name="graduacion" size="4" required></label><label>Precio<input name="precio" size="8" required></label></div>
  <div class="fila"><label>Bodega<select name="cuit_bodega">${opciones(bodegas, "cuit", "razon_social")}</select></label></div>
  <h3>Corte (composición)</h3><div id="cepas">${filaCepa()}${filaCepa()}</div>
  <button type="button" class="sec" id="mas">+ cepa</button>
  <h3>Maridajes</h3><div class="fila">${maridajes.map((m) => `<label style="flex-direction:row"><input type="checkbox" class="m" value="${m.id_maridaje}">${esc(m.nombre)}</label>`).join("")}</div>
  <p><button>Guardar vino</button></p></form>`;
  const quitar = () => document.querySelectorAll(".quitar").forEach((b) => (b.onclick = () => b.parentElement.remove()));
  quitar();
  $("#mas").onclick = () => { $("#cepas").insertAdjacentHTML("beforeend", filaCepa()); quitar(); };
  $("#f").onsubmit = (e) => {
    e.preventDefault();
    const f = Object.fromEntries(new FormData(e.target));
    const cuerpo = {
      nombre: f.nombre, tipo: f.tipo, anada: f.anada, volumen_ml: f.volumen_ml, graduacion: f.graduacion,
      precio: f.precio, cuit_bodega: f.cuit_bodega,
      composicion: [...document.querySelectorAll(".cepa")].map((r) => ({ id_cepa: r.querySelector(".c").value, porcentaje: r.querySelector(".p").value })),
      maridajes: [...document.querySelectorAll(".m:checked")].map((c) => c.value),
    };
    accion(e.submitter, async () => {
      const r = await api("/vinos", { method: "POST", body: cuerpo });
      aviso("Vino guardado", "ok");
      location.hash = "#/vino/" + r.cod_vino;
    });
  };
}

// ------------------------------------------------------------- 4. Nueva venta
async function venta() {
  const [salas, vinos] = await Promise.all([api("/salas"), api("/vinos?por_pagina=100")]);
  vista.innerHTML = `<h2>Nueva venta</h2><form id="f">
  <div class="fila"><label>Nº de cliente<input name="id_cliente" size="8" required inputmode="numeric"></label>
  <label>Sala<select name="id_sala">${opciones(salas, "id_sala", (s) => `${s.nombre} (${s.localidad})`)}</select></label></div>
  <h3>Renglones</h3><div id="rengs"></div><button type="button" class="sec" id="mas">+ renglón</button>
  <p><button>Registrar venta</button></p></form><div id="res"></div>`;
  const reng = () => `<div class="fila reng"><label>Vino<select class="v">${opciones(vinos.datos, "cod_vino", (v) => `${v.nombre} ${v.anada}`)}</select></label>
    <label>Cantidad<input class="q" value="1" size="4" inputmode="numeric"></label><button type="button" class="sec quitar">Quitar</button></div>`;
  const quitar = () => document.querySelectorAll(".quitar").forEach((b) => (b.onclick = () => b.parentElement.remove()));
  $("#rengs").innerHTML = reng(); quitar();
  $("#mas").onclick = () => { $("#rengs").insertAdjacentHTML("beforeend", reng()); quitar(); };
  $("#f").onsubmit = (e) => {
    e.preventDefault();
    const f = Object.fromEntries(new FormData(e.target));
    const renglones = [...document.querySelectorAll(".reng")].map((r) => ({ cod_vino: r.querySelector(".v").value, cantidad: r.querySelector(".q").value }));
    accion(e.submitter, async () => {
      const c = await api("/comprobantes", { method: "POST", body: { id_cliente: f.id_cliente, id_sala: f.id_sala, renglones } });
      aviso("Venta registrada", "ok");
      $("#res").innerHTML = `<div class="tarjeta"><h3>Comprobante Nº ${esc(c.nro_comprobante)}</h3>` +
        tabla([{ t: "Vino", k: "vino" }, { t: "Cant.", num: 1, k: "cantidad" }, { t: "Precio", num: 1, h: (r) => dinero(r.precio_unitario) }, { t: "Desc. %", num: 1, k: "descuento_pct" },
               { t: "Subtotal", num: 1, h: (r) => dinero(r.subtotal) }], c.renglones) +
        `<p>Subtotal ${dinero(c.subtotal)} · Descuento ${dinero(c.descuento)} · <strong>Total ${dinero(c.total)}</strong></p></div>`;
    });
  };
}

// ------------------------------------------------------------- 5. Transferencias
async function transferencias() {
  const [salas, vinos] = await Promise.all([api("/salas"), api("/vinos?por_pagina=100")]);
  vista.innerHTML = `<h2>Transferencias depósito → salas</h2>
  <form class="fila" id="nueva"><label>Sala destino<select name="id_sala">${opciones(salas, "id_sala", (s) => `${s.nombre} (${s.localidad})`)}</select></label>
  <button>Crear transferencia</button></form>
  <div class="filtros"><label>Estado<select id="est"><option value="">Todos</option><option>en_confeccion</option><option>terminado</option><option>procesado</option></select></label></div>
  <div id="lista"></div><div id="det"></div>`;
  const lista = async () => {
    const e = $("#est").value;
    const r = await accion(null, () => api("/transferencias?por_pagina=10" + (e ? "&estado=" + e : "")));
    if (!r) return;
    $("#lista").innerHTML = tabla([{ t: "Nº", h: (t) => `<a href="#" data-n="${t.nro_solicitud}">${t.nro_solicitud}</a>` },
      { t: "Sala", k: "id_sala" }, { t: "Estado", h: (t) => `<span class="estado">${esc(t.estado)}</span>` }], r.datos);
    document.querySelectorAll("[data-n]").forEach((a) => (a.onclick = (ev) => { ev.preventDefault(); detalle(a.dataset.n); }));
  };
  const detalle = async (n) => {
    const t = await accion(null, () => api("/transferencias/" + n));
    if (!t) return;
    const abierta = t.estado === "en_confeccion";
    $("#det").innerHTML = `<div class="tarjeta"><h3>Transferencia ${esc(t.nro_solicitud)} <span class="estado">${esc(t.estado)}</span></h3>
      ${tabla([{ t: "Vino", k: "vino" }, { t: "Cantidad", num: 1, k: "cantidad" }], t.renglones, "Sin renglones")}
      ${abierta ? `<div class="fila"><label>Vino<select id="v">${opciones(vinos.datos, "cod_vino", (v) => `${v.nombre} ${v.anada}`)}</select></label>
        <label>Cantidad<input id="q" value="6" size="4"></label><button id="add" class="sec">Agregar renglón</button></div>` : ""}
      <div class="fila">${t.estado === "en_confeccion" ? '<button id="ter">Terminar</button>' : ""}${t.estado === "terminado" ? '<button id="pro">Procesar (descuenta del depósito)</button>' : ""}</div></div>`;
    const recargar = async () => { await detalle(n); await lista(); };
    if ($("#add")) $("#add").onclick = (ev) => accion(ev.target, async () => { await api(`/transferencias/${n}/renglones`, { method: "POST", body: { cod_vino: $("#v").value, cantidad: $("#q").value } }); await recargar(); });
    if ($("#ter")) $("#ter").onclick = (ev) => accion(ev.target, async () => { await api(`/transferencias/${n}/terminar`, { method: "POST" }); await recargar(); });
    if ($("#pro")) $("#pro").onclick = (ev) => accion(ev.target, async () => { await api(`/transferencias/${n}/procesar`, { method: "POST" }); aviso("Transferencia procesada", "ok"); await recargar(); });
  };
  $("#nueva").onsubmit = (e) => { e.preventDefault(); accion(e.submitter, async () => { const t = await api("/transferencias", { method: "POST", body: { id_sala: new FormData(e.target).get("id_sala") } }); await lista(); await detalle(t.nro_solicitud); }); };
  $("#est").onchange = lista;
  lista();
}

// ------------------------------------------------------------- 6. Reportes
async function reportes() {
  const salas = await api("/salas");
  vista.innerHTML = `<h2>Reportes</h2><div class="tarjeta"><h3>Vinos más vendidos</h3><div id="top">Cargando…</div></div>
  <div class="tarjeta"><h3>Ventas por sala (último trimestre)</h3><div id="vs">Cargando…</div></div>
  <div class="tarjeta"><h3>Vinos sin stock en una sala (con stock en depósito)</h3>
    <div class="fila"><label>Sala<select id="sala">${opciones(salas, "id_sala", (s) => `${s.nombre} (${s.localidad})`)}</select></label><button id="ver">Ver</button></div><div id="ss"></div></div>
  <div class="tarjeta"><h3>Transportista más activo (último mes)</h3><div id="tr">Cargando…</div></div>`;
  const generica = (datos) => tabla(Object.keys(datos[0] || {}).map((k) => ({ t: k.replace(/_/g, " "), k })), datos);
  const poner = (sel, ruta) => api(ruta).then((d) => ($(sel).innerHTML = generica(d))).catch((e) => ($(sel).innerHTML = `<p class="vacio">${esc(e.message)}</p>`));
  poner("#top", "/reportes/top-vinos?limite=10"); poner("#vs", "/reportes/ventas-por-sala"); poner("#tr", "/reportes/transportista-activo");
  $("#ver").onclick = (ev) => accion(ev.target, async () => ($("#ss").innerHTML = generica(await api("/reportes/vinos-sin-stock?id_sala=" + $("#sala").value))));
}

// ------------------------------------------------------------- ruteo
const rutas = [[/^#\/catalogo$/, catalogo], [/^#\/vino\/(\d+)$/, ficha], [/^#\/vino-nuevo$/, vinoNuevo],
               [/^#\/venta$/, venta], [/^#\/transferencias$/, transferencias], [/^#\/reportes$/, reportes]];
async function navegar() {
  const h = location.hash || "#/catalogo";
  document.querySelectorAll("nav a").forEach((a) => a.classList.toggle("activo", h.startsWith(a.getAttribute("href"))));
  for (const [re, fn] of rutas) {
    const m = h.match(re);
    if (m) { vista.innerHTML = "Cargando…"; try { await fn(...m.slice(1)); } catch (e) { vista.innerHTML = ""; aviso(e.message); } return; }
  }
  vista.innerHTML = '<p class="vacio">Pantalla inexistente. <a href="#/catalogo">Ir al catálogo</a></p>';
}
window.addEventListener("hashchange", () => { aviso(""); navegar(); });
navegar();
