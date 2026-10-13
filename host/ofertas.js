/* LiveShop · consola del vendedor · ofertas.
   Descuento y liquidacion (desde el catalogo), relampago y cupon (en vivo).
   Usa los helpers y el estado del script principal de host/index.html ($, api,
   productos, promos, live, LIVE_ID...) recien cuando se lo llama, por eso se
   carga antes que el. */
"use strict";

const OFERTAS = (function(){
  const PCTS = [10, 20, 30, 40, 50];

  // estado del modal
  let sel = [];            // productos elegidos
  let lote = false;        // modo "liquidar varios": lista con casillas
  let modo = "descuento";
  let pct = 20;
  let precioFijo = null;
  let hasta = "7d";

  // estado de los paneles en vivo
  const flash = {id:null, pct:20, min:10, max:""};
  const cup = {codigo:"LIVE10", pct:10};

  function init(){
    $("promoScrim").addEventListener("click", (e) => { if (e.target === $("promoScrim")) cerrar(); });
    $("promoForm").addEventListener("submit", publicar);
    $("promoForm").addEventListener("click", clickModal);
    $("promoForm").addEventListener("input", inputModal);
    $("flashBody").addEventListener("click", clickFlash);
    $("flashBody").addEventListener("change", (e) => {
      if (e.target.id === "flashProd") flash.id = e.target.value;
      if (e.target.id === "flashMax") flash.max = e.target.value;
    });
    $("cuponBody").addEventListener("click", clickCupon);
    $("cuponBody").addEventListener("submit", (e) => { e.preventDefault(); activarCupon(); });
    setInterval(tick, 1000);
  }

  const vigente = x => LS.promoVigente(promoPublica(x));
  const chips = (grupo, valores, actual, fmt) =>
    '<div class="chips" data-g="' + grupo + '" role="group">' + valores.map(v =>
      '<button type="button" class="chip" data-v="' + esc(String(v)) + '" aria-pressed="' + (String(v) === String(actual)) + '">' +
      esc(fmt ? fmt(v) : String(v)) + '</button>').join("") + '</div>';

  /* ---------- modal: descuento / liquidacion ---------- */

  function abrir(ids, op){
    op = op || {};
    lote = !!op.lote;
    sel = (ids || []).slice();
    modo = op.modo || "descuento";
    pct = op.pct || 20;
    precioFijo = null;
    hasta = modo === "remanente" ? "agotar" : "7d";
    pintar();
    $("promoScrim").classList.add("open");
  }

  function cerrar(){ $("promoScrim").classList.remove("open"); }

  function finElegido(){
    if (hasta === "agotar") return null;
    if (hasta === "hoy"){ const d = new Date(LS.reloj.now()); d.setHours(23, 59, 0, 0); return d; }
    if (hasta === "7d") return new Date(LS.reloj.now() + 7 * 86400000);
    const v = $("promoFecha") && $("promoFecha").value;
    return v ? new Date(v) : null;
  }

  function pintar(){
    const elegidos = sel.map(id => productos.find(p => p.id === id)).filter(Boolean);
    const uno = !lote && elegidos.length === 1 ? elegidos[0] : null;
    const candidatos = productos.filter(p => p.stock > 0);
    const conPromo = elegidos.filter(p => promoDe(p.id));
    const final = p => precioFijo != null && uno ? Math.min(precioFijo, p.precio) : LS.aplicar(p.precio, pct, null);
    const bajo = elegidos.filter(p => p.costo != null && final(p) < p.costo);

    const prev = uno
      ? '<div class="ofprev"><span class="em" aria-hidden="true">' + esc(uno.emoji || "📦") + '</span>' +
          '<span class="n">' + esc(uno.nombre) + '<br><s>' + money(uno.precio) + '</s><b>' + money(final(uno)) + '</b></span>' +
          '<span class="pct">' + (modo === "remanente" ? "LIQUIDACIÓN" : "−" + Math.round((1 - final(uno) / (uno.precio || 1)) * 100) + "%") + '</span></div>'
      : '<div class="ofprev"><span class="em" aria-hidden="true">🏷</span><span class="n">' + elegidos.length +
          (elegidos.length === 1 ? " producto" : " productos") + ' con −' + pct + '%</span>' +
          '<span class="pct">' + (modo === "remanente" ? "LIQUIDACIÓN" : "OFERTA") + '</span></div>';

    $("promoForm").innerHTML =
      '<div class="mh"><h3>' + (uno ? "Oferta: " + esc(uno.nombre) + " (" + money(uno.precio) + ")" : "Liquidar stock") + '</h3>' +
        '<button type="button" class="close-x" data-cerrar aria-label="Cerrar">✕</button></div>' +
      (lote
        ? '<div class="field"><label>Productos</label><div class="lote">' +
            (candidatos.length ? candidatos.map(p =>
              '<label><input type="checkbox" data-lote="' + esc(p.id) + '"' + (sel.includes(p.id) ? " checked" : "") + '> ' +
              esc(p.emoji || "📦") + " " + esc(p.nombre) + ' <span class="hint">· ' + money(p.precio) + ' · stock ' + p.stock +
              (promoDe(p.id) ? " · ya en oferta" : "") + '</span></label>').join("")
              : '<div class="hint">No hay productos con stock.</div>') +
          '</div></div>'
        : "") +
      '<div class="field"><label>Tipo</label>' +
        chips("modo", ["descuento", "remanente"], modo, v => v === "descuento" ? "Descuento" : "Liquidación") +
        '<div class="hint">' + (modo === "remanente"
          ? "Para últimas unidades o stock que no se mueve. El comprador lo ve como “Liquidación”."
          : "Una promo común con fecha de fin. El comprador ve el precio tachado.") + '</div></div>' +
      '<div class="field"><label>Descuento</label>' +
        chips("pct", PCTS, precioFijo == null ? pct : "", v => v + "%") +
        (uno ? '<div class="hint" style="margin-top:.35rem">o precio fijo: <input id="promoPrecio" type="number" min="1" step="1" style="width:110px;display:inline-block" value="' +
               (precioFijo == null ? "" : precioFijo) + '" placeholder="$" aria-label="Precio fijo de oferta"></div>' : "") +
      '</div>' +
      '<div class="field"><label>Hasta</label>' +
        chips("hasta", ["hoy", "7d", "agotar", "fecha"], hasta,
              v => ({hoy:"Hoy", "7d":"7 días", agotar:"Hasta agotar", fecha:"Fecha…"})[v]) +
        (hasta === "fecha" ? '<input id="promoFecha" type="datetime-local" style="margin-top:.4rem" aria-label="Fecha de fin">' : "") +
      '</div>' +
      '<div class="field"><label>Así lo ve el comprador</label>' + prev + '</div>' +
      (conPromo.length ? '<div class="note">' + (conPromo.length === 1 && uno ? "Este producto ya tiene una oferta: se reemplaza."
                          : conPromo.length + " de los elegidos ya tienen oferta: se reemplaza.") + '</div>' : "") +
      (bajo.length ? '<div class="warn">⚠ Con este descuento ' + bajo.map(p => "“" + esc(p.nombre) + "” queda en " + money(final(p)) +
                     " y su costo es " + money(p.costo)).join("; ") + '. Podés publicarla igual: liquidar a pérdida a veces conviene.</div>' : "") +
      '<div class="msg-line" id="promoMsg"></div>' +
      '<div class="row"><button type="button" class="btn btn-ghost" data-cerrar>Cancelar</button>' +
        '<button class="btn btn-primary" type="submit"' + (elegidos.length ? "" : " disabled") + '>Publicar oferta</button></div>';
  }

  function clickModal(e){
    if (e.target.closest("[data-cerrar]")){ cerrar(); return; }
    const chip = e.target.closest(".chip");
    if (!chip) return;
    const g = chip.parentElement.dataset.g, v = chip.dataset.v;
    if (g === "modo"){ modo = v; if (v === "remanente" && hasta === "7d") hasta = "agotar"; }
    if (g === "pct"){ pct = Number(v); precioFijo = null; }
    if (g === "hasta") hasta = v;
    pintar();
  }

  function inputModal(e){
    if (e.target.dataset.lote){
      const id = e.target.dataset.lote;
      sel = e.target.checked ? sel.concat(id) : sel.filter(x => x !== id);
      pintar();
    } else if (e.target.id === "promoPrecio"){
      const v = Number(e.target.value);
      precioFijo = v > 0 ? v : null;
      const pos = e.target.selectionStart;
      pintar();
      const inp = $("promoPrecio");
      if (inp){ inp.focus(); try{ inp.setSelectionRange(pos, pos); }catch(err){} }
    }
  }

  async function publicar(e){
    e.preventDefault();
    const ids = sel.filter(id => productos.some(p => p.id === id));
    if (!ids.length) return;
    const fin = finElegido();
    if (hasta === "fecha" && (!fin || fin.getTime() <= LS.reloj.now())){
      setMsg($("promoMsg"), "Elegí una fecha futura.", "err");
      return;
    }
    setMsg($("promoMsg"), "Publicando…");
    try{
      promos = await api("liveshop_promo_crear", {
        p_tipo:modo, p_productos:ids, p_pct:precioFijo == null ? pct : null, p_precio:precioFijo,
        p_fin:fin ? fin.toISOString() : null, p_reemplazar:true
      });
    }catch(err){
      setMsg($("promoMsg"), err.message, "err");
      return;
    }
    cerrar();
    aplicar(ids.length === 1 ? "Oferta publicada: los compradores ya ven el precio nuevo." : ids.length + " ofertas publicadas.");
  }

  async function terminar(id){
    try{
      promos = await api("liveshop_promo_terminar", {p_id:id});
      aplicar("Oferta terminada.");
    }catch(err){
      setCatStatus(err.message, "err");
    }
  }

  async function recargar(){
    try{
      const yo = await api("liveshop_yo");
      promos = yo.promos || [];
      LS.reloj.sync(yo.ahora);
      aplicar();
    }catch(err){}
  }

  /* todo cambio de promos se refleja en el catalogo, los paneles y los compradores */
  function aplicar(texto){
    checkPayload(); broadcastState(); renderProds(); render();
    if (texto) setCatStatus(texto, "ok");
  }

  /* ---------- en vivo: relampago y cupon ---------- */

  function render(){ renderFlash(); renderCupon(); }

  function renderFlash(){
    const box = $("flashBody");
    const activa = promos.find(x => x.tipo === "relampago" && vigente(x));
    if (activa){
      const p = productos.find(x => x.id === activa.producto_id);
      box.innerHTML =
        '<div class="flash-run" aria-live="polite">' +
          '<div><div class="lb">' + esc(p ? p.nombre : "Producto") + ' · −' + Number(activa.pct || 0) + '%</div>' +
          '<div class="cd" data-fin="' + esc(activa.fin) + '">' + esc(LS.restante(new Date(activa.fin) - LS.reloj.now())) + '</div></div>' +
          '<div style="flex:1;font-size:.78rem">' + activa.vendidas + (activa.vendidas === 1 ? " vendida" : " vendidas") +
            (activa.max_unidades ? " de " + activa.max_unidades : "") + '</div>' +
          '<button type="button" class="btn btn-danger btn-sm" data-flash="fin" data-id="' + esc(activa.id) + '">Terminar ya</button>' +
        '</div>' +
        '<div class="hint">Los compradores ven la cuenta regresiva sobre el video.</div>';
      return;
    }
    if (!live){
      box.innerHTML = '<div class="hint">Disponible mientras transmitís: un descuento de pocos minutos sobre el producto que estás ' +
                      'mostrando, con cuenta regresiva para los compradores. Se lanza en dos toques.</div>';
      return;
    }
    const conStock = productos.filter(p => p.stock > 0);
    if (!conStock.length){ box.innerHTML = '<div class="hint">No hay productos con stock para ofertar.</div>'; return; }
    if (!conStock.some(p => p.id === flash.id)) flash.id = conStock.some(p => p.id === destacado) ? destacado : conStock[0].id;
    box.innerHTML =
      '<div class="field"><label for="flashProd">Producto</label><select id="flashProd">' +
        conStock.map(p => '<option value="' + esc(p.id) + '"' + (p.id === flash.id ? " selected" : "") + '>' +
                          esc(p.nombre) + ' · ' + money(p.precio) + '</option>').join("") + '</select></div>' +
      '<div class="field"><label>Descuento</label>' + chips("fpct", [10, 20, 30], flash.pct, v => v + "%") + '</div>' +
      '<div class="field"><label>Duración</label>' + chips("fmin", [5, 10, 15], flash.min, v => v + " min") + '</div>' +
      '<div class="field"><label for="flashMax">Unidades</label><select id="flashMax">' +
        ["", "3", "5", "10"].map(v => '<option value="' + v + '"' + (v === flash.max ? " selected" : "") + '>' +
                                      (v ? "Solo " + v : "Todas las que haya") + '</option>').join("") + '</select></div>' +
      '<button type="button" class="btn btn-primary" data-flash="go">⚡ Lanzar oferta relámpago</button>' +
      '<div class="msg-line" id="flashMsg"></div>';
  }

  async function clickFlash(e){
    const chip = e.target.closest(".chip");
    if (chip){
      const g = chip.parentElement.dataset.g;
      if (g === "fpct") flash.pct = Number(chip.dataset.v);
      if (g === "fmin") flash.min = Number(chip.dataset.v);
      renderFlash();
      return;
    }
    const b = e.target.closest("button[data-flash]");
    if (!b) return;
    if (b.dataset.flash === "fin"){ terminar(b.dataset.id); return; }
    b.disabled = true;
    setMsg($("flashMsg"), "Lanzando…");
    try{
      promos = await api("liveshop_promo_crear", {
        p_tipo:"relampago", p_productos:[flash.id], p_pct:flash.pct, p_minutos:flash.min,
        p_max_unidades:flash.max ? Number(flash.max) : null, p_live_id:LIVE_ID, p_reemplazar:true
      });
    }catch(err){
      b.disabled = false;
      setMsg($("flashMsg"), err.message, "err");
      return;
    }
    /* lo que se oferta es lo que se muestra: queda destacado para los compradores */
    destacado = flash.id;
    queueCatalogSave();
    aplicar();
    ANALYTICS.track("liveshop_relampago", {vendedor:CUENTA.usuario, pct:flash.pct, min:flash.min});
  }

  function renderCupon(){
    const box = $("cuponBody");
    const activo = promos.find(x => x.tipo === "cupon" && vigente(x));
    if (activo){
      box.innerHTML =
        '<div class="cupon-on"><div class="code">' + esc(activo.codigo) + '</div>' +
          '<div style="font-size:.8rem;margin-top:.2rem">−' + Number(activo.pct) + '% en toda la tienda · usado ' + activo.vendidas +
          (activo.vendidas === 1 ? " vez" : " veces") + '</div></div>' +
        '<div class="hint">Decilo en cámara: los compradores lo cargan al pagar. Vence cuando terminás la transmisión.</div>' +
        '<button type="button" class="btn btn-ghost btn-sm" data-cup="fin" data-id="' + esc(activo.id) + '">Desactivar cupón</button>';
      return;
    }
    if (!live){
      box.innerHTML = '<div class="hint">Premiá a quien te está mirando: un código que decís en cámara y vale solo mientras ' +
                      'dura el live. Se suma a las ofertas hasta un máximo de 50% de descuento.</div>';
      return;
    }
    box.innerHTML =
      '<form id="cuponForm"><div class="field"><label for="cupCodigo">Código</label>' +
        '<div class="cupon-row"><input id="cupCodigo" maxlength="16" value="' + esc(cup.codigo) + '"></div></div>' +
      '<div class="field"><label>Descuento</label>' + chips("cpct", [5, 10, 15, 20], cup.pct, v => v + "%") + '</div>' +
      '<button class="btn btn-primary" type="submit">🎟 Activar cupón</button>' +
      '<div class="msg-line" id="cupMsg"></div></form>';
  }

  function clickCupon(e){
    const chip = e.target.closest(".chip");
    if (chip){
      cup.codigo = ($("cupCodigo") && $("cupCodigo").value) || cup.codigo;
      cup.pct = Number(chip.dataset.v);
      renderCupon();
      return;
    }
    const b = e.target.closest("button[data-cup]");
    if (b) terminar(b.dataset.id);
  }

  async function activarCupon(){
    const codigo = $("cupCodigo").value.trim().toUpperCase().replace(/[^A-Z0-9]/g, "");
    cup.codigo = codigo;
    if (!/^[A-Z0-9]{3,16}$/.test(codigo)){
      setMsg($("cupMsg"), "El código va de 3 a 16 letras o números, sin espacios.", "err");
      return;
    }
    try{
      promos = await api("liveshop_promo_crear", {p_tipo:"cupon", p_pct:cup.pct, p_codigo:codigo,
                                                  p_live_id:LIVE_ID, p_reemplazar:true});
    }catch(err){
      setMsg($("cupMsg"), err.message, "err");
      return;
    }
    render();
  }

  /* ---------- reloj ---------- */

  /* Cada segundo: actualiza las cuentas regresivas visibles y, si alguna promo
     vencio, la saca y le avisa a los compradores con el catalogo nuevo. */
  function tick(){
    document.querySelectorAll("[data-fin]").forEach(el => {
      el.textContent = LS.restante(new Date(el.dataset.fin) - LS.reloj.now());
    });
    const antes = promos.length;
    promos = promos.filter(vigente);
    if (promos.length !== antes) aplicar();
  }

  return {init, abrir, terminar, recargar, render};
})();
