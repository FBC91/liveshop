/* LiveShop · consola del vendedor · reportes.
   Resumen (con sugerencias accionables), productos, lives y ofertas. Cada
   numero viene con una accion al lado: los reportes alimentan las ofertas.
   Usa los helpers del script principal recien al llamarse. */
"use strict";

const REPORTES = (function(){
  const SUBS = [["resumen", "Resumen"], ["productos", "Productos"], ["lives", "Mis lives"], ["ofertas", "Ofertas"]];
  const DIAS_SEMANA = ["Lun", "Mar", "Mié", "Jue", "Vie", "Sáb", "Dom"];
  let sub = "resumen";
  let dias = 30;
  let orden = "facturado";
  let prodData = null;
  let resumen = null;

  function init(){
    $("view-reportes").innerHTML =
      '<div class="metrics-head">' +
        '<div class="chips" id="rSubs" role="tablist" aria-label="Reportes">' +
          SUBS.map(([v, t]) => '<button type="button" class="chip" role="tab" data-v="' + v + '" aria-pressed="' + (v === sub) + '">' + t + '</button>').join("") +
        '</div>' +
        '<select id="rRange" aria-label="Período">' +
          '<option value="7">Últimos 7 días</option><option value="30" selected>Últimos 30 días</option>' +
          '<option value="90">Últimos 90 días</option>' +
        '</select>' +
      '</div>' +
      '<div id="rBody"><div class="state-box">Cargando…</div></div>';
    $("rSubs").addEventListener("click", (e) => {
      const b = e.target.closest(".chip");
      if (!b) return;
      sub = b.dataset.v;
      $("rSubs").querySelectorAll(".chip").forEach(c => c.setAttribute("aria-pressed", String(c === b)));
      load();
    });
    $("rRange").addEventListener("change", () => { dias = Number($("rRange").value); load(); });
    $("rBody").addEventListener("click", clickBody);
    $("rBody").addEventListener("keydown", (e) => {
      const tr = e.target.closest("tr[data-k]");
      if (tr && (e.key === "Enter" || e.key === " ")){ e.preventDefault(); ficha(tr.dataset.k); }
    });
    $("infoBox").addEventListener("click", clickFicha);
  }

  function load(){
    $("rBody").innerHTML = '<div class="state-box">Cargando…</div>';
    const f = {resumen:cargarResumen, productos:cargarProductos, lives:cargarLives, ofertas:cargarOfertas}[sub];
    return f().catch(err => { $("rBody").innerHTML = '<div class="state-box">No se pudo cargar el reporte (' + esc(err.message) + ').</div>'; });
  }

  /* ---------- graficos chicos ---------- */

  function barras(serie, key, fmt){
    const max = Math.max(1, ...serie.map(d => Number(d[key]) || 0));
    const corto = iso => { const p = iso.split("-"); return Number(p[2]) + "/" + Number(p[1]); };
    return '<div class="bars" role="img" aria-label="Gráfico de barras por día">' +
        serie.map(d => {
          const v = Number(d[key]) || 0;
          return '<div class="b" title="' + esc(corto(d.dia) + ": " + fmt(v) + (d.ventas != null ? " · " + d.ventas + " ventas" : "")) + '">' +
                 '<span style="height:' + (v / max * 100).toFixed(1) + '%"></span></div>';
        }).join("") +
      '</div>' +
      '<div class="xl"><span>' + esc(corto(serie[0].dia)) + '</span><span>' + esc(corto(serie[Math.floor(serie.length / 2)].dia)) +
        '</span><span>' + esc(corto(serie[serie.length - 1].dia)) + '</span></div>' +
      '<details class="tabla"><summary>Ver como tabla</summary><table class="t"><thead><tr><th>Día</th><th class="n">Ventas</th><th class="n">Facturado</th></tr></thead><tbody>' +
        serie.filter(d => Number(d.ventas)).map(d => '<tr><td>' + esc(d.dia) + '</td><td class="n">' + d.ventas + '</td><td class="n">' + money(d.facturado) + '</td></tr>').join("") +
      '</tbody></table></details>';
  }

  function spark(serie, key){
    const w = 300, h = 60, max = Math.max(1, ...serie.map(d => Number(d[key]) || 0));
    const pts = serie.map((d, i) => (i / Math.max(1, serie.length - 1) * w).toFixed(1) + "," +
                                    (h - 4 - (Number(d[key]) || 0) / max * (h - 8)).toFixed(1)).join(" ");
    return '<svg class="spark" viewBox="0 0 ' + w + ' ' + h + '" preserveAspectRatio="none" role="img" aria-label="Unidades vendidas por semana">' +
      '<polyline points="' + pts + '" fill="none" stroke="#B8862A" stroke-width="2.5" vector-effect="non-scaling-stroke"/></svg>';
  }

  const deCada10 = (a, b) => Number(b) ? Math.round(Number(a) / Number(b) * 10) : 0;

  /* ---------- resumen ---------- */

  function descartadas(){
    try{ return JSON.parse(localStorage.getItem("liveshop_sug_" + CUENTA.usuario)) || {}; }catch(e){ return {}; }
  }
  function descartar(clave){
    const d = descartadas();
    d[clave] = Date.now();
    try{ localStorage.setItem("liveshop_sug_" + CUENTA.usuario, JSON.stringify(d)); }catch(e){}
  }

  async function cargarResumen(){
    resumen = await api("liveshop_reporte_resumen", {p_dias:dias});
    pintarResumen();
  }

  function pintarResumen(){
    const a = resumen.actual, b = resumen.anterior;
    const tk = x => Number(x.ventas) ? Number(x.facturado) / Number(x.ventas) : 0;
    const funnel = [
      ["Entraron a tu sala", a.entradas, null, ""],
      ["Pidieron un producto", a.interesados, a.entradas, "de cada 10 visitas pidieron algo"],
      ["Recibieron link de pago", a.links, null, ""],
      ["Pagaron", a.links_pagados, a.links, "de cada 10 links se pagaron"]
    ];
    const tope = Math.max(1, Number(a.entradas) || 0, Number(a.links) || 0);
    const d = descartadas();
    const semana = Date.now() - 7 * 86400000;
    const sugs = (resumen.sugerencias || []).filter(s => !(d[s.clave] > semana)).slice(0, 3);
    const ICONO = {reponer:"📦", liquidar:"🏷", ultimas:"🔥", precio:"💲", cobrar:"💳"};
    const ACCION = {reponer:"Reponer", liquidar:"Poner en liquidación", ultimas:"Destacar", precio:"Revisar precio", cobrar:"Ver pendientes"};

    $("rBody").innerHTML =
      '<div class="kpis">' +
        kpi("Facturado", money(a.facturado), "", LS.cambio(a.facturado, b.facturado)) +
        kpi("Ventas", a.ventas, "", LS.cambio(a.ventas, b.ventas)) +
        kpi("Ticket promedio", money(tk(a)), "", LS.cambio(tk(a), tk(b))) +
        kpi("Visitas", a.entradas, "personas en tu sala", LS.cambio(a.entradas, b.entradas)) +
      '</div>' +
      '<div class="box"><h3>💡 Para hacer hoy</h3><div class="sub">Lo que más plata mueve según tus números. Cada una se resuelve en dos toques.</div>' +
        (sugs.length ? sugs.map(s =>
          '<div class="sug"><span class="ic" aria-hidden="true">' + (ICONO[s.tipo] || "💡") + '</span>' +
            '<span class="tx">' + esc(s.texto) + (s.tipo === "cobrar" ? "" : '<small>en juego: ' + money(s.monto) + '</small>') + '</span>' +
            '<button type="button" class="btn btn-primary btn-sm" data-sug="' + esc(s.tipo) + '" data-id="' + esc(s.producto_id || "") + '">' + ACCION[s.tipo] + '</button>' +
            '<button type="button" class="x" data-descartar="' + esc(s.clave) + '" aria-label="Descartar por 7 días" title="Descartar por 7 días">✕</button>' +
          '</div>').join("")
          : '<div class="hint">Nada urgente: no hay productos sin stock con pedidos, ni stock quieto, ni links sin cobrar.</div>') +
      '</div>' +
      '<div class="grid2">' +
        '<div class="box"><h3>Facturado por día</h3><div class="sub">Pagos confirmados, hora de Montevideo</div>' +
          barras(resumen.serie, "facturado", money) + '</div>' +
        '<div class="box funnel"><h3>Embudo</h3><div class="sub">Dónde se queda la gente: atraer, convencer o cobrar</div>' +
          funnel.map(([lbl, v, base, txt]) =>
            '<div class="f"><div class="fl"><span>' + lbl + '</span><b>' + (Number(v) || 0) + '</b></div>' +
            '<div class="fb"><span style="width:' + ((Number(v) || 0) / tope * 100).toFixed(1) + '%"></span></div>' +
            (base != null ? '<div class="ratio">' + deCada10(v, base) + " " + txt + '</div>' : "") +
            '</div>').join("") +
        '</div>' +
      '</div>' +
      '<p class="hint">Visitas y pedidos cuentan personas, no clics: quien recarga la página no suma dos veces. ' +
        'El período anterior es el de igual largo justo antes.</p>';
  }

  /* ---------- productos ---------- */

  async function cargarProductos(){
    prodData = await api("liveshop_reporte_productos", {p_dias:dias});
    prodData.productos.forEach(p => { p.facturado = Number(p.facturado); });
    pintarProductos();
  }

  function pintarProductos(){
    const lista = prodData.productos.slice();
    const t = iso => iso ? new Date(iso).getTime() : 0;
    lista.sort({
      facturado:(a, b) => b.facturado - a.facturado || b.unidades - a.unidades,
      pedidos:(a, b) => b.pedidos - a.pedidos,
      quietos:(a, b) => (b.en_catalogo - a.en_catalogo) || t(a.ultima_venta) - t(b.ultima_venta)
    }[orden]);
    const conCosto = lista.some(p => p.ganancia != null);
    const hace = iso => {
      if (!iso) return "nunca";
      const d = Math.floor((Date.now() - new Date(iso)) / 86400000);
      return d === 0 ? "hoy" : d === 1 ? "ayer" : "hace " + d + " días";
    };
    $("rBody").innerHTML =
      '<div class="toolbar"><div class="chips" role="group" aria-label="Ordenar">' +
        [["facturado", "Más vendidos"], ["pedidos", "Más pedidos"], ["quietos", "Más quietos"]].map(([v, tt]) =>
          '<button type="button" class="chip" data-orden="' + v + '" aria-pressed="' + (v === orden) + '">' + tt + '</button>').join("") +
      '</div><span class="spacer"></span><span class="hint">Tocá un producto para ver su historia.</span></div>' +
      '<div class="table-wrap"><table class="t"><thead><tr>' +
        '<th>Producto</th><th class="n">Vendidas</th><th class="n">Facturado</th><th class="n">Pedidos</th>' +
        '<th class="n">De pedido a venta</th><th class="n">Stock</th><th>Última venta</th>' +
        (conCosto ? '<th class="n">Ganancia</th>' : "") +
      '</tr></thead><tbody>' +
        (lista.length ? lista.map(p => {
          const conv = p.pedidos ? deCada10(Math.min(p.unidades, p.pedidos), p.pedidos) + " de 10" : "—";
          const stock = p.en_catalogo ? p.stock + (p.dias_stock != null && p.stock > 0 ? ' <span class="muted">· ~' + p.dias_stock + ' días</span>' : "") : "—";
          return '<tr data-k="' + esc(p.producto_id) + '" tabindex="0">' +
            '<td>' + esc(p.emoji || "📦") + " " + esc(p.nombre) +
              (p.promo_tipo ? ' <span class="pill">' + esc(LS.PROMO_NOMBRE[p.promo_tipo]) + '</span>' : "") +
              (p.en_catalogo ? "" : ' <span class="pill gris">ya no está en el catálogo</span>') +
              (p.en_catalogo && p.stock === 0 ? ' <span class="pill">sin stock</span>' : "") + '</td>' +
            '<td class="n">' + p.unidades + '</td><td class="n">' + money(p.facturado) + '</td>' +
            '<td class="n">' + p.pedidos + '</td><td class="n">' + conv + '</td>' +
            '<td class="n">' + stock + '</td><td>' + esc(hace(p.ultima_venta)) + '</td>' +
            (conCosto ? '<td class="n">' + (p.ganancia == null ? '<span class="muted">sin costo</span>' : money(p.ganancia)) + '</td>' : "") +
          '</tr>';
        }).join("") : '<tr><td colspan="8" class="empty">Todavía no hay productos.</td></tr>') +
      '</tbody></table></div>' +
      '<p class="hint" style="margin-top:.6rem">“De pedido a venta”: de cada 10 veces que tocaron “Lo quiero”, cuántas terminaron en una venta. ' +
        'Si un producto se pide mucho y se vende poco, suele ser el precio, el talle o una duda sin responder.' +
        (conCosto ? "" : " Cargá el costo de tus productos en el catálogo para ver tu ganancia.") + '</p>';
  }

  async function ficha(id){
    if (!prodData) return;
    const p = prodData.productos.find(x => x.producto_id === id);
    if (!p) return;
    abrirInfo('<div class="mh"><h3>' + esc(p.nombre) + '</h3><button type="button" class="close-x" data-cerrar aria-label="Cerrar">✕</button></div>' +
              '<div class="state-box">Cargando historia…</div>');
    let r;
    try{
      r = await api("liveshop_reporte_producto", {p_producto_id:id, p_dias:90});
    }catch(err){
      const box = $("infoBox").querySelector(".state-box");
      if (box) box.textContent = "No se pudo cargar: " + err.message;
      return;
    }
    const enCat = productos.find(x => x.id === id);
    const semVendidas = r.semanas.reduce((a, s) => a + Number(s.unidades), 0);
    abrirInfo(
      '<div class="mh"><h3>' + esc(p.emoji || "📦") + " " + esc(p.nombre) + '</h3><button type="button" class="close-x" data-cerrar aria-label="Cerrar">✕</button></div>' +
      '<div class="kpis" style="margin:0">' +
        kpi("Vendidas", p.unidades, "en " + dias + " días") +
        kpi("Facturado", money(p.facturado), "") +
        kpi("Pedidos", p.pedidos, p.vistas + " vieron la ficha") +
      '</div>' +
      '<div><div class="hint">Unidades por semana · últimas 12 (' + semVendidas + ' en total)</div>' + spark(r.semanas, "unidades") + '</div>' +
      (r.lives.length ? '<div><div class="card-title" style="font-size:.85rem;margin-bottom:.3rem">Se vendió en</div><div class="kv">' +
        r.lives.slice(0, 5).map(l => '<span class="k">' + esc(LS.fecha(l.inicio)) + '</span><span>' + esc(l.titulo || "Live") + ' · ' +
          l.unidades + (l.unidades === 1 ? " unidad" : " unidades") + '</span>').join("") + '</div></div>' : "") +
      '<div><div class="card-title" style="font-size:.85rem;margin-bottom:.3rem">Quiénes lo compraron y a qué precio</div>' +
        (r.ordenes.length ? '<div class="table-wrap"><table class="t"><tbody>' + r.ordenes.slice(0, 10).map(o =>
          '<tr><td>' + esc(LS.fecha(o.created_at)) + '</td><td>' + esc(o.comprador || "—") + '</td>' +
          '<td class="n">' + (Number(o.descuento) ? '<s>' + money(o.precio_lista) + '</s>' : "") + money(o.total) + '</td>' +
          '<td>' + (o.promo_tipo ? '<span class="pill">' + esc(LS.PROMO_NOMBRE[o.promo_tipo]) + '</span>' : "") + '</td>' +
          '<td><span class="estado ' + o.estado + '">' + esc(o.estado) + '</span></td></tr>').join("") + '</tbody></table></div>'
          : '<div class="hint">Sin links de pago en los últimos 90 días.</div>') +
      '</div>' +
      (r.promos.length ? '<div class="hint">Ofertas en 90 días: ' + r.promos.map(x => esc(LS.PROMO_NOMBRE[x.tipo]) +
        (x.pct ? " −" + Number(x.pct) + "%" : "") + " (" + x.vendidas + " vendidas)").join(" · ") + '</div>' : "") +
      (enCat
        ? '<div class="ficha-acts">' +
            '<button type="button" class="btn btn-ghost btn-sm" data-f-act="editar" data-id="' + esc(id) + '">Editar</button>' +
            '<button type="button" class="btn btn-ghost btn-sm" data-f-act="destacar" data-id="' + esc(id) + '"' + (destacado === id ? " disabled" : "") + '>' +
              (destacado === id ? "Destacado" : "Destacar en el live") + '</button>' +
            (promoDe(id) ? "" : '<button type="button" class="btn btn-primary btn-sm" data-f-act="oferta" data-id="' + esc(id) + '">🏷 Poner en oferta</button>') +
          '</div>'
        : '<div class="hint">Este producto ya no está en tu catálogo; sus ventas siguen contando en tus números.</div>')
    );
  }

  function clickFicha(e){
    const b = e.target.closest("button[data-f-act]");
    if (!b) return;
    const id = b.dataset.id;
    cerrarInfo();
    if (b.dataset.fAct === "editar"){ irA("catalog"); editarProducto(id); }
    if (b.dataset.fAct === "destacar"){ destacado = id; saveCatalog(); renderHot(); }
    if (b.dataset.fAct === "oferta"){ irA("catalog"); OFERTAS.abrir([id]); }
  }

  /* ---------- lives ---------- */

  async function cargarLives(){
    const r = await api("liveshop_reporte_lives", {p_dias:dias});
    const max = Math.max(1, ...r.calor.map(c => Number(c.facturado)));
    const celda = (dow, h) => r.calor.find(c => c.dow === dow && c.hora === h);
    const mejor = r.calor.slice().sort((a, b) => Number(b.facturado) - Number(a.facturado))[0];
    let heat = '<div class="heat" role="img" aria-label="Facturado por día de la semana y hora"><span></span>';
    for (let h = 0; h < 24; h++) heat += '<span class="h">' + (h % 3 === 0 ? h : "") + '</span>';
    for (let d = 1; d <= 7; d++){
      heat += '<span>' + DIAS_SEMANA[d - 1] + '</span>';
      for (let h = 0; h < 24; h++){
        const c = celda(d, h);
        const a = c ? 0.15 + Number(c.facturado) / max * 0.85 : 0;
        heat += '<span class="c"' + (c ? ' style="background:rgba(184,134,42,' + a.toFixed(2) + ')" title="' +
          esc(DIAS_SEMANA[d - 1] + " " + h + " h: " + c.ventas + " ventas, " + money(c.facturado)) + '"' : "") + '></span>';
      }
    }
    heat += '</div>';
    $("rBody").innerHTML =
      '<div class="box"><h3>Cuándo te compran</h3><div class="sub">' +
        (mejor ? 'Tu mejor momento: <b>' + DIAS_SEMANA[mejor.dow - 1] + ' de ' + mejor.hora + ' a ' + (mejor.hora + 1) + ' h</b> (' + money(mejor.facturado) + ').' +
                 ' Salí en vivo cerca de ese horario.' : "Todavía no hay ventas en el período.") + '</div>' + heat + '</div>' +
      '<div class="table-wrap"><table class="t"><thead><tr><th>Fecha</th><th>Título</th><th class="n">Duración</th><th class="n">Pico</th>' +
        '<th class="n">Visitas</th><th class="n">Links</th><th class="n">Ventas</th><th class="n">Facturado</th><th>Lo que más vendió</th></tr></thead><tbody>' +
        (r.lives.length ? r.lives.map(l =>
          '<tr><td>' + esc(LS.fecha(l.inicio)) + (l.abierto ? ' <span class="pill">en curso</span>' : "") + '</td>' +
          '<td>' + esc(l.titulo || "Sin título") + '</td><td class="n">' + l.minutos + ' min</td><td class="n">' + l.pico + '</td>' +
          '<td class="n">' + l.entradas + '</td><td class="n">' + l.links + '</td><td class="n">' + l.ventas + '</td>' +
          '<td class="n">' + money(l.facturado) + '</td><td>' + esc(l.estrella || "—") + '</td></tr>').join("")
          : '<tr><td colspan="9" class="empty">Todavía no transmitiste en este período. Cada vez que tocás “Iniciar transmisión”, el live queda registrado acá con lo que vendió.</td></tr>') +
      '</tbody></table></div>';
  }

  /* ---------- ofertas ---------- */

  function duracion(min){
    if (min < 120) return min + " min";
    if (min < 2880) return Math.round(min / 60) + " h";
    return Math.round(min / 1440) + " días";
  }

  async function cargarOfertas(){
    const lista = await api("liveshop_promos", {p_dias:Math.max(dias, 30)});
    $("rBody").innerHTML =
      '<div class="table-wrap"><table class="t"><thead><tr><th>Oferta</th><th>Producto</th><th>Inicio</th><th class="n">Duró</th>' +
        '<th class="n">Vendidas</th><th class="n">Facturado</th><th class="n">Costo del descuento</th><th>Resultado</th></tr></thead><tbody>' +
        (lista.length ? lista.map(x => {
          let res = "—";
          if (x.tipo === "relampago" && x.live_minutos && x.minutos){
            const durante = x.unidades / Math.max(1, x.minutos);
            const resto = (x.live_unidades - x.unidades) / Math.max(1, x.live_minutos - x.minutos);
            res = !x.unidades ? "sin ventas"
                : resto > 0 ? "vendió ×" + (durante / resto).toFixed(1) + " más rápido que el resto del live"
                : "todo lo del live se vendió en la oferta";
          } else if (x.unidades){
            res = money(Number(x.facturado) / x.unidades) + " por venta";
          }
          return '<tr><td><span class="pill' + (x.activa ? "" : " gris") + '">' + esc(LS.PROMO_NOMBRE[x.tipo]) + '</span>' +
              (x.pct ? " −" + Number(x.pct) + "%" : x.precio ? " a " + money(x.precio) : "") + (x.activa ? ' <span class="muted">activa</span>' : "") + '</td>' +
            '<td>' + esc(x.tipo === "cupon" ? "Código " + x.codigo : (x.producto || "—")) + '</td>' +
            '<td>' + esc(LS.fecha(x.inicio)) + '</td><td class="n">' + esc(duracion(Number(x.minutos) || 0)) + '</td>' +
            '<td class="n">' + x.unidades + '</td><td class="n">' + money(x.facturado) + '</td><td class="n">' + money(x.descuento) + '</td>' +
            '<td>' + esc(res) + '</td></tr>';
        }).join("") : '<tr><td colspan="8" class="empty">Todavía no creaste ofertas. Probá una relámpago en tu próximo live o liquidá el stock quieto desde el catálogo.</td></tr>') +
      '</tbody></table></div>' +
      '<p class="hint" style="margin-top:.6rem">Así aprendés qué descuento te conviene: si una oferta vendió apenas más que lo normal, el descuento solo te costó plata.</p>';
  }

  /* ---------- acciones ---------- */

  function clickBody(e){
    const o = e.target.closest("[data-orden]");
    if (o){ orden = o.dataset.orden; pintarProductos(); return; }
    const tr = e.target.closest("tr[data-k]");
    if (tr){ ficha(tr.dataset.k); return; }
    const x = e.target.closest("[data-descartar]");
    if (x){ descartar(x.dataset.descartar); pintarResumen(); return; }
    const s = e.target.closest("[data-sug]");
    if (!s) return;
    const id = s.dataset.id, tipo = s.dataset.sug;
    ANALYTICS.track("liveshop_sugerencia_click", {vendedor:CUENTA.usuario, tipo:tipo});
    if (tipo === "cobrar"){ VENTAS.verPendientes(); return; }
    if (!productos.some(p => p.id === id)){ load(); return; }
    if (tipo === "reponer"){ irA("catalog"); editarProducto(id, "pStock"); }
    else if (tipo === "precio"){ irA("catalog"); editarProducto(id, "pPrice"); }
    else if (tipo === "liquidar"){
      irA("catalog");
      const quietos = (resumen.sugerencias || []).filter(y => y.tipo === "liquidar").map(y => y.producto_id);
      OFERTAS.abrir(quietos.length > 1 ? quietos : [id], {modo:"remanente", pct:30, lote:quietos.length > 1});
    } else if (tipo === "ultimas"){
      destacado = id;
      saveCatalog();
      renderHot();
      descartar("ultimas:" + id);
      pintarResumen();
    }
  }

  return {init, load};
})();
