/* LiveShop · consola del vendedor · ventas.
   Historial de ordenes (pagadas, pendientes, vencidas, anuladas), detalle,
   reenviar o anular links, comprobante, CSV y resumen por mes. Usa los
   helpers del script principal recien al llamarse. */
"use strict";

const VENTAS = (function(){
  const ESTADOS = [["", "Todas"], ["pagada", "Pagadas"], ["pendiente", "Pendientes"], ["vencida", "Vencidas"], ["anulada", "Anuladas"]];
  const NOMBRE_ESTADO = {pagada:"Pagada", pendiente:"Pendiente", vencida:"Vencida", anulada:"Anulada"};
  const st = {dias:30, estado:"", q:"", pagina:0};
  let data = null;
  let qTimer = null;
  let anularArmado = null;

  function init(){
    $("view-ventas").innerHTML =
      '<div class="metrics-head">' +
        '<h2 class="section">Tus ventas</h2>' +
        '<select id="vRange" aria-label="Período">' +
          '<option value="7">Últimos 7 días</option><option value="30" selected>Últimos 30 días</option>' +
          '<option value="90">Últimos 90 días</option><option value="365">Último año</option>' +
        '</select>' +
      '</div>' +
      '<div class="kpis" id="vKpis"><div class="state-box">Cargando…</div></div>' +
      '<div class="toolbar">' +
        '<div class="chips" id="vEstado" role="group" aria-label="Filtrar por estado">' +
          ESTADOS.map(([v, t]) => '<button type="button" class="chip" data-v="' + v + '" aria-pressed="' + (v === "") + '">' + t + '</button>').join("") +
        '</div>' +
        '<input type="search" id="vBuscar" placeholder="🔍 Producto, cliente o referencia" aria-label="Buscar ventas">' +
        '<span class="spacer"></span>' +
        '<button type="button" class="btn btn-ghost btn-sm" id="vCsv">⬇ Exportar CSV</button>' +
      '</div>' +
      '<div class="table-wrap">' +
        '<table class="t"><thead><tr><th>Fecha</th><th>Producto</th><th>Cliente</th><th class="n">Total</th><th>Oferta</th><th>Estado</th></tr></thead>' +
        '<tbody id="vRows"></tbody></table>' +
        '<div class="pager" id="vPager"></div>' +
      '</div>' +
      '<div class="msg-line" id="vCsvMsg"></div>' +
      '<h2 class="section" style="margin-top:1.5rem">Cierre por mes</h2>' +
      '<div class="table-wrap"><table class="t"><thead><tr><th>Mes</th><th class="n">Ventas</th><th class="n">Facturado</th>' +
        '<th class="n">Ticket promedio</th><th class="n">Descuentos otorgados</th></tr></thead><tbody id="vMeses"></tbody></table></div>' +
      '<p class="hint" style="margin-top:.75rem">El comprobante de cada venta no es una factura: el cobro de esta demo es simulado. ' +
        'En un producto real, cada venta pagada emitiría un e-Ticket o e-Factura a través de un proveedor habilitado por DGI.</p>';

    $("vRange").addEventListener("change", () => { st.dias = Number($("vRange").value); st.pagina = 0; load(); });
    $("vEstado").addEventListener("click", (e) => {
      const b = e.target.closest(".chip");
      if (b) filtrarEstado(b.dataset.v);
    });
    $("vBuscar").addEventListener("input", () => {
      clearTimeout(qTimer);
      qTimer = setTimeout(() => { st.q = $("vBuscar").value.trim(); st.pagina = 0; load(); }, 300);
    });
    $("vCsv").addEventListener("click", exportar);
    $("vRows").addEventListener("click", (e) => {
      const tr = e.target.closest("tr[data-k]");
      if (tr) detalle(tr.dataset.k);
    });
    $("vRows").addEventListener("keydown", (e) => {
      const tr = e.target.closest("tr[data-k]");
      if (tr && (e.key === "Enter" || e.key === " ")){ e.preventDefault(); detalle(tr.dataset.k); }
    });
    $("vPager").addEventListener("click", (e) => {
      const b = e.target.closest("button[data-p]");
      if (!b) return;
      st.pagina = Math.max(0, st.pagina + Number(b.dataset.p));
      load();
    });
    $("vKpis").addEventListener("click", (e) => { if (e.target.closest("[data-pend]")) filtrarEstado("pendiente"); });
    $("infoBox").addEventListener("click", accionDetalle);
  }

  function filtrarEstado(v){
    st.estado = v;
    st.pagina = 0;
    $("vEstado").querySelectorAll(".chip").forEach(c => c.setAttribute("aria-pressed", String(c.dataset.v === v)));
    load();
  }

  function verPendientes(){
    irA("ventas");
    filtrarEstado("pendiente");
  }

  async function load(){
    try{
      data = await api("liveshop_ventas", {p_dias:st.dias, p_estado:st.estado || null, p_q:st.q || null, p_pagina:st.pagina, p_por_pagina:20});
    }catch(err){
      $("vKpis").innerHTML = '<div class="state-box">No se pudieron cargar las ventas (' + esc(err.message) + ').</div>';
      return;
    }
    pintar();
  }

  function refrescarSiVisible(){
    if ($("view-ventas").classList.contains("active")) load();
  }

  function pintar(){
    const a = data.actual, b = data.anterior;
    const tk = x => Number(x.ventas) ? Number(x.facturado) / Number(x.ventas) : 0;
    $("vKpis").innerHTML =
      kpi("Facturado", money(a.facturado), "pagos confirmados", LS.cambio(a.facturado, b.facturado)) +
      kpi("Ventas", a.ventas, "", LS.cambio(a.ventas, b.ventas)) +
      kpi("Ticket promedio", money(tk(a)), "por venta", LS.cambio(tk(a), tk(b))) +
      kpi("Pendiente de cobro", money(data.pendientes.monto),
          data.pendientes.cantidad + (data.pendientes.cantidad === 1 ? " link sin pagar" : " links sin pagar"), null,
          data.pendientes.cantidad ? '<button type="button" class="link" data-pend>Ver pendientes →</button>' : "") +
      kpi("Descuentos", money(a.descuentos), "lo que costaron tus ofertas", LS.cambio(a.descuentos, b.descuentos));

    const filas = data.filas;
    if (!filas.length){
      const filtrado = st.estado || st.q;
      $("vRows").innerHTML = '<tr><td colspan="6" class="empty">' + (filtrado
        ? "No hay ventas con ese filtro en este período."
        : "Todavía no vendiste en este período. Cuando mandes un link de pago desde Chats, aparece acá con su estado: pendiente hasta que lo paguen, pagada cuando se confirma.") +
        '</td></tr>';
    } else {
      $("vRows").innerHTML = filas.map(o =>
        '<tr data-k="' + esc(o.ref) + '" tabindex="0">' +
          '<td>' + esc(LS.fecha(o.created_at)) + '</td>' +
          '<td>' + esc(o.concepto) + (o.manual ? ' <span class="pill gris">manual</span>' : "") + '</td>' +
          '<td>' + esc(o.comprador || "—") + '</td>' +
          '<td class="n">' + (Number(o.descuento) ? '<s>' + money(o.precio_lista) + '</s>' : "") + money(o.total) + '</td>' +
          '<td>' + ofertaDe(o) + '</td>' +
          '<td><span class="estado ' + o.estado + '">' + NOMBRE_ESTADO[o.estado] + '</span></td>' +
        '</tr>').join("");
    }
    const desde = data.total_filas ? st.pagina * data.por_pagina + 1 : 0;
    const hasta = Math.min(data.total_filas, (st.pagina + 1) * data.por_pagina);
    $("vPager").innerHTML = '<span>Mostrando ' + desde + '–' + hasta + ' de ' + data.total_filas + '</span>' +
      '<span class="btns"><button type="button" class="btn btn-ghost btn-sm" data-p="-1"' + (st.pagina ? "" : " disabled") + '>← Anteriores</button>' +
      '<button type="button" class="btn btn-ghost btn-sm" data-p="1"' + (hasta < data.total_filas ? "" : " disabled") + '>Siguientes →</button></span>';

    $("vMeses").innerHTML = data.meses.length ? data.meses.map(m => {
      const [y, mm] = m.mes.split("-");
      const largo = new Date(Number(y), Number(mm) - 1, 1).toLocaleDateString("es-UY", {month:"long", year:"numeric"});
      const nombre = largo.charAt(0).toUpperCase() + largo.slice(1);   // "Octubre de 2026", no "Octubre De 2026"
      return '<tr><td>' + esc(nombre) + '</td><td class="n">' + m.ventas + '</td>' +
        '<td class="n">' + money(m.facturado) + '</td><td class="n">' + money(Number(m.facturado) / (m.ventas || 1)) + '</td>' +
        '<td class="n">' + money(m.descuentos) + '</td></tr>';
    }).join("") : '<tr><td colspan="5" class="empty">Sin ventas pagadas en los últimos 12 meses.</td></tr>';
  }

  function ofertaDe(o){
    const t = [];
    if (o.promo_tipo) t.push('<span class="pill">' + esc(LS.PROMO_NOMBRE[o.promo_tipo]) + '</span>');
    if (o.cupon) t.push('<span class="pill">' + esc(o.cupon) + '</span>');
    return t.join(" ") || '<span class="muted">—</span>';
  }

  /* ---------- detalle ---------- */

  function detalle(ref){
    const o = data && data.filas.find(x => x.ref === ref);
    if (!o) return;
    anularArmado = null;
    const b = o.comprador_id ? buyers.get(o.comprador_id) : null;
    const desc = Number(o.descuento) || 0;
    const fila = (k, v) => '<span class="k">' + esc(k) + '</span><span>' + v + '</span>';
    abrirInfo(
      '<div class="mh"><h3>Venta · ref ' + esc(o.ref) + '</h3><span class="estado ' + o.estado + '">' + NOMBRE_ESTADO[o.estado] + '</span>' +
        '<button type="button" class="close-x" data-cerrar aria-label="Cerrar">✕</button></div>' +
      '<div class="desglose">' +
        '<div class="r"><span>' + esc(o.concepto) + '</span><span>' + money(o.precio_lista) + '</span></div>' +
        (desc ? '<div class="r d"><span>' + esc(o.promo_tipo ? LS.PROMO_NOMBRE[o.promo_tipo] : "Descuento") +
                (o.cupon ? " + código " + esc(o.cupon) : "") + '</span><span>−' + money(desc) + '</span></div>' : "") +
        '<div class="r t"><span>Total</span><span>' + money(o.total) + '</span></div>' +
      '</div>' +
      '<div class="kv">' +
        fila("Cliente", esc(o.comprador || "Sin nombre") + (b ? (b.online ? " · en línea" : " · desconectado") : "")) +
        fila("Link creado", esc(LS.fechaLarga(o.created_at))) +
        (o.pagada_at ? fila("Pagado", esc(LS.fechaLarga(o.pagada_at))) : "") +
        (o.estado === "pendiente" && o.vence_at ? fila("Vence en", esc(LS.restante(new Date(o.vence_at) - Date.now()))) : "") +
        (o.live_inicio ? fila("Live", esc(o.live_titulo || "Sin título") + " · " + esc(LS.fecha(o.live_inicio))) : fila("Live", "fuera de una transmisión")) +
        (o.categoria ? fila("Categoría", esc(LS.catNombre(o.categoria))) : "") +
      '</div>' +
      '<div class="msg-line" id="vMsg"></div>' +
      '<div class="ficha-acts">' +
        (b ? '<button type="button" class="btn btn-ghost btn-sm" data-v-act="chat" data-ref="' + esc(o.ref) + '">💬 Ir al chat</button>' : "") +
        (o.estado === "pendiente"
          ? '<button type="button" class="btn btn-primary btn-sm" data-v-act="reenviar" data-ref="' + esc(o.ref) + '"' +
              (b && b.online ? "" : ' disabled title="El comprador no está conectado ahora"') + '>↻ Reenviar link</button>' +
            '<button type="button" class="btn btn-ghost btn-sm" data-v-act="anular" data-ref="' + esc(o.ref) + '">Anular link</button>'
          : "") +
        (o.estado === "pagada"
          ? '<a class="btn btn-ghost btn-sm" href="../pago/comprobante.html?sala=' + encodeURIComponent(ROOM) + '&ref=' +
              encodeURIComponent(o.ref) + '" target="_blank" rel="noopener">🧾 Comprobante</a>' : "") +
      '</div>' +
      (o.estado === "pendiente" && !(b && b.online)
        ? '<div class="hint">Para reenviar el link, el comprador tiene que estar conectado a tu sala. El link original sigue sirviendo hasta que venza.</div>' : "")
    );
  }

  async function accionDetalle(e){
    const btn = e.target.closest("button[data-v-act]");
    if (!btn || !data) return;
    const o = data.filas.find(x => x.ref === btn.dataset.ref);
    if (!o) return;
    const act = btn.dataset.vAct;
    if (act === "chat"){
      cerrarInfo();
      irA("chats");
      activeBuyer = o.comprador_id;
      const b = buyers.get(activeBuyer);
      if (b) b.unread = 0;
      renderBuyers(); renderConv(); paintBadges();
    } else if (act === "reenviar"){
      enviarLink(o.comprador_id, pagoDeOrden(o), true);
      setMsg($("vMsg"), "Link reenviado al chat de " + (o.comprador || "el comprador") + ".", "ok");
    } else if (act === "anular"){
      /* confirmacion en dos toques, sin dialogos del navegador */
      if (anularArmado !== o.ref){
        anularArmado = o.ref;
        btn.textContent = "¿Anular? Tocá de nuevo";
        setTimeout(() => { if (anularArmado === o.ref){ anularArmado = null; btn.textContent = "Anular link"; } }, 4000);
        return;
      }
      anularArmado = null;
      try{
        await api("liveshop_orden_anular", {p_ref:o.ref});
      }catch(err){
        setMsg($("vMsg"), err.message, "err");
        return;
      }
      if (o.comprador_id && buyers.has(o.comprador_id)){
        send("chat", {to:o.comprador_id, from:"host", kind:"text", text:"Anulé el link de pago " + o.ref + ". Si lo querés igual, avisame y te mando uno nuevo."});
      }
      cerrarInfo();
      load();
    }
  }

  /* ---------- CSV ---------- */

  async function exportar(){
    const btn = $("vCsv");
    btn.disabled = true;
    btn.textContent = "Preparando…";
    setMsg($("vCsvMsg"), "");
    try{
      const todo = await api("liveshop_ventas", {p_dias:st.dias, p_estado:st.estado || null, p_q:st.q || null, p_pagina:0, p_por_pagina:5000});
      const d = iso => {
        if (!iso) return "";
        const x = new Date(iso);
        const p = n => String(n).padStart(2, "0");
        return x.getFullYear() + "-" + p(x.getMonth() + 1) + "-" + p(x.getDate()) + " " + p(x.getHours()) + ":" + p(x.getMinutes());
      };
      const n = v => String(Number(v) || 0).replace(".", ",");
      const texto = LS.csv(todo.filas, [
        {titulo:"Fecha", valor:o => d(o.created_at)},
        {titulo:"Referencia", valor:o => o.ref},
        {titulo:"Producto", valor:o => o.concepto},
        {titulo:"Categoría", valor:o => o.categoria ? LS.catNombre(o.categoria) : ""},
        {titulo:"Cliente", valor:o => o.comprador || ""},
        {titulo:"Precio de lista", valor:o => n(o.precio_lista)},
        {titulo:"Descuento", valor:o => n(o.descuento)},
        {titulo:"Total", valor:o => n(o.total)},
        {titulo:"Oferta", valor:o => o.promo_tipo ? LS.PROMO_NOMBRE[o.promo_tipo] : ""},
        {titulo:"Cupón", valor:o => o.cupon || ""},
        {titulo:"Estado", valor:o => NOMBRE_ESTADO[o.estado]},
        {titulo:"Pagada", valor:o => d(o.pagada_at)},
        {titulo:"Live", valor:o => o.live_titulo || ""}
      ]);
      const hoy = new Date().toISOString().slice(0, 10);
      LS.descargar("ventas-" + CUENTA.usuario + "-" + hoy + ".csv", texto);
      setMsg($("vCsvMsg"), todo.filas.length + " ventas exportadas.", "ok");
    }catch(err){
      setMsg($("vCsvMsg"), "No se pudo exportar: " + err.message, "err");
    }
    btn.disabled = false;
    btn.textContent = "⬇ Exportar CSV";
  }

  return {init, load, refrescarSiVisible, verPendientes};
})();
