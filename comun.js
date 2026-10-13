/* LiveShop · codigo compartido por comprador, consola, login y admin.
   Hasta las cuentas de vendedor cada pagina era autocontenida; con cuatro paginas
   hablando con las mismas funciones de la base, duplicar la config y el manejo de
   errores en cada una iba a terminar como el SEED duplicado: desincronizado. */
"use strict";

window.LS = (function(){
  const SB_URL = "https://myebxfostbafuogfymqa.supabase.co";
  const SB_KEY = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Im15ZWJ4Zm9zdGJhZnVvZ2Z5bXFhIiwicm9sZSI6ImFub24iLCJpYXQiOjE3Nzk4MjAyMjAsImV4cCI6MjA5NTM5NjIyMH0.ZkIJvOa_bvRX3hlwKWyEuy3CI2hOxEYau2ojbCQacJY";
  const TOKEN_KEY = "liveshop_token";
  const MAX_VIEWERS = 3;

  const MENSAJES = {
    credenciales: "Usuario o contraseña incorrectos.",
    demasiados_intentos: "Demasiados intentos. Esperá unos minutos y probá de nuevo.",
    usuario_invalido: "El usuario debe tener entre 3 y 24 caracteres: letras, números, guion o guion bajo.",
    usuario_tomado: "Ese usuario ya existe.",
    password_invalida: "La contraseña debe tener entre 6 y 72 caracteres.",
    password_actual: "La contraseña actual no es correcta.",
    sesion_invalida: "Tu sesión venció. Volvé a ingresar.",
    cuenta_protegida: "Esta es una cuenta demo pública: no se puede borrar ni cambiar su contraseña o su sala.",
    nombre_invalido: "El nombre no puede quedar vacío.",
    foto_invalida: "La foto es demasiado pesada o no es una imagen.",
    sala_invalida: "El código de sala debe tener entre 3 y 24 caracteres: letras minúsculas, números o guion.",
    sala_tomada: "Ese código de sala ya lo usa otro vendedor.",
    catalogo_invalido: "Hay un producto con datos inválidos (nombre, precio o stock).",
    catalogo_grande: "El catálogo admite hasta 40 productos.",
    solo_vendedores: "Esta acción es solo para cuentas de vendedor.",
    solo_admin: "Esta sección es solo para el administrador.",
    solo_demo: "Solo la cuenta demo puede restaurar el catálogo de ejemplo.",
    ref_invalida: "Referencia de pago inválida.",
    producto_inexistente: "Ese producto ya no está en el catálogo.",
    orden_invalida: "Completá el concepto y un monto mayor a cero.",
    orden_inexistente: "No encontramos ese link de pago. Pedile al vendedor que te lo reenvíe.",
    orden_cerrada: "Este link de pago ya no está disponible (venció o fue anulado). Pedile uno nuevo al vendedor.",
    cupon_invalido: "Ese código no existe o ya no está vigente.",
    promo_invalida: "Revisá la oferta: el descuento va de 1% a 90% y el precio de oferta tiene que ser menor al de lista.",
    promo_existente: "Ese producto ya tiene una oferta activa.",
    red: "No hay conexión con el servidor. Revisá tu internet y probá de nuevo."
  };

  /* Lista cerrada: si cada vendedor escribiera la suya ("remeras", "Remeras",
     "tops"), los filtros entre tiendas no funcionarian. */
  const CATEGORIAS = [
    {id:"ropa", nombre:"Ropa"}, {id:"calzado", nombre:"Calzado"}, {id:"accesorios", nombre:"Accesorios"},
    {id:"tecnologia", nombre:"Tecnología"}, {id:"hogar", nombre:"Hogar"}, {id:"belleza", nombre:"Belleza"},
    {id:"deportes", nombre:"Deportes"}, {id:"ninos", nombre:"Niños"}, {id:"otros", nombre:"Otros"}
  ];
  const catNombre = id => (CATEGORIAS.find(c => c.id === id) || CATEGORIAS[CATEGORIAS.length - 1]).nombre;
  const PROMO_NOMBRE = {descuento:"Oferta", remanente:"Liquidación", relampago:"Oferta relámpago", cupon:"Cupón del live"};

  function fail(code, raw){
    const err = new Error(MENSAJES[code] || raw || code);
    err.code = code;
    return err;
  }

  /* Todas las lecturas y escrituras pasan por funciones de Postgres: las tablas no
     tienen politicas para el rol anonimo. Los errores de negocio llegan como
     "LS:<codigo>" (raise) o como {ok:false, error} (login y registro). */
  async function rpc(fn, args){
    let r;
    try{
      r = await fetch(SB_URL + "/rest/v1/rpc/" + fn, {
        method:"POST",
        headers:{"Content-Type":"application/json", apikey:SB_KEY, Authorization:"Bearer " + SB_KEY},
        body:JSON.stringify(args || {})
      });
    }catch(e){
      throw fail("red");
    }
    const text = await r.text();
    let data = null;
    try{ data = text ? JSON.parse(text) : null; }catch(e){ data = null; }
    if (!r.ok){
      const raw = (data && (data.message || data.hint)) || ("HTTP " + r.status);
      const m = /LS:([a-z_]+)/.exec(raw);
      throw fail(m ? m[1] : "http_" + r.status, raw);
    }
    if (data && data.ok === false) throw fail(data.error);
    return data;
  }

  function token(){
    try{ return localStorage.getItem(TOKEN_KEY) || ""; }catch(e){ return ""; }
  }
  function setToken(t){
    try{ localStorage.setItem(TOKEN_KEY, t); }catch(e){}
  }
  function clearToken(){
    try{ localStorage.removeItem(TOKEN_KEY); }catch(e){}
  }

  const esc = s => String(s ?? "").replace(/[&<>"']/g, c =>
    ({"&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;","'":"&#39;"}[c]));
  const money = n => "$ " + new Intl.NumberFormat("es-UY",{maximumFractionDigits:0}).format(Number(n)||0);
  const cleanRoom = v => String(v || "").toLowerCase().replace(/[^a-z0-9-]/g,"").slice(0,24);

  /* Las fotos viajan como data URL (en la base y en el broadcast del catalogo),
     asi que se achican antes de guardarlas. */
  function shrink(file, max, quality){
    return new Promise((resolve, reject) => {
      const img = new Image();
      const url = URL.createObjectURL(file);
      img.onload = () => {
        const scale = Math.min(1, max / Math.max(img.width, img.height));
        const c = document.createElement("canvas");
        c.width = Math.round(img.width * scale);
        c.height = Math.round(img.height * scale);
        c.getContext("2d").drawImage(img, 0, 0, c.width, c.height);
        URL.revokeObjectURL(url);
        resolve(c.toDataURL("image/jpeg", quality || 0.6));
      };
      img.onerror = () => { URL.revokeObjectURL(url); reject(new Error("bad image")); };
      img.src = url;
    });
  }

  function initials(nombre){
    const parts = String(nombre || "?").trim().split(/\s+/);
    return ((parts[0] || "?")[0] + (parts[1] ? parts[1][0] : "")).toUpperCase();
  }

  /* Sin tildes ni mayusculas, para buscar "telefono" y encontrar "Teléfono". */
  const norm = s => String(s || "").toLowerCase().normalize("NFD").replace(/[̀-ͯ]/g, "");

  /* Reloj del servidor. Los contadores de las ofertas usan el fin que guarda la
     base: si cada navegador usara su propia hora, dos compradores verian
     terminar la misma oferta en momentos distintos. */
  const reloj = {
    offset:0,
    sync(iso){ const t = new Date(iso).getTime(); if (t) this.offset = t - Date.now(); },
    now(){ return Date.now() + this.offset; }
  };

  /* Misma regla que liveshop__aplicar en la base. Solo sirve para mostrar: el
     precio que se cobra lo calcula siempre la base al crear la orden. */
  function aplicar(lista, pct, precio){
    lista = Number(lista) || 0;
    if (pct != null) return Math.round(lista * (100 - Number(pct)) / 100);
    if (precio != null) return Math.min(Number(precio), lista);
    return lista;
  }
  function promoVigente(promo){
    return !!promo && (!promo.fin || new Date(promo.fin).getTime() > reloj.now()) &&
           (promo.restantes == null || Number(promo.restantes) > 0);
  }
  /* Producto publico (sala/directorio): precio = final, precio_lista = original */
  function precioActual(p){
    return promoVigente(p.promo) ? Number(p.precio) : Number(p.precio_lista != null ? p.precio_lista : p.precio);
  }
  function pctPromo(p){
    const lista = Number(p.precio_lista) || 0;
    if (!promoVigente(p.promo) || !lista) return 0;
    return Math.round((1 - Number(p.precio) / lista) * 100);
  }

  /* "09:41" bajo una hora, "2 h 05 min" bajo un dia, "3 días" despues */
  function restante(ms){
    if (ms <= 0) return "0:00";
    const s = Math.floor(ms / 1000);
    if (s < 3600) return Math.floor(s / 60) + ":" + String(s % 60).padStart(2, "0");
    if (s < 86400) return Math.floor(s / 3600) + " h " + String(Math.floor(s % 3600 / 60)).padStart(2, "0") + " min";
    const d = Math.round(s / 86400);
    return d + (d === 1 ? " día" : " días");
  }

  const fecha = iso => {
    const d = new Date(iso);
    return d.toLocaleDateString("es-UY", {day:"2-digit", month:"2-digit"}) + " " +
           d.toLocaleTimeString("es-UY", {hour:"2-digit", minute:"2-digit"});
  };
  const fechaLarga = iso => new Date(iso).toLocaleString("es-UY",
    {day:"numeric", month:"long", year:"numeric", hour:"2-digit", minute:"2-digit"});

  /* Variacion contra el periodo anterior: un numero suelto no dice nada. */
  function cambio(actual, anterior){
    const a = Number(actual) || 0, b = Number(anterior) || 0;
    if (!b) return a ? {txt:"nuevo", dir:"up"} : {txt:"sin cambios", dir:"eq"};
    const p = Math.round((a - b) / b * 100);
    if (p === 0) return {txt:"= que antes", dir:"eq"};
    return {txt:(p > 0 ? "↑ " : "↓ ") + Math.abs(p) + "%", dir:p > 0 ? "up" : "down"};
  }

  /* CSV para Excel en español: separador ";" y BOM para que respete las tildes. */
  function csv(filas, columnas){
    const q = v => {
      const s = v == null ? "" : String(v);
      return /[";\n\r]/.test(s) ? '"' + s.replace(/"/g, '""') + '"' : s;
    };
    return "﻿" + [columnas.map(c => q(c.titulo)).join(";")]
      .concat(filas.map(f => columnas.map(c => q(c.valor(f))).join(";"))).join("\r\n");
  }
  function descargar(nombre, texto, tipo){
    const url = URL.createObjectURL(new Blob([texto], {type:tipo || "text/csv;charset=utf-8"}));
    const a = document.createElement("a");
    a.href = url; a.download = nombre;
    document.body.appendChild(a); a.click(); a.remove();
    setTimeout(() => URL.revokeObjectURL(url), 1000);
  }

  /* El comprador no tiene cuenta: sus compras y favoritos viven en este
     navegador. Se avisa en pantalla. */
  function leer(k, def){ try{ return JSON.parse(localStorage.getItem(k)) || def; }catch(e){ return def; } }
  function guardar(k, v){ try{ localStorage.setItem(k, JSON.stringify(v)); }catch(e){} }
  const compras = {
    listar(){ return leer("liveshop_compras", []); },
    agregar(c){
      const lista = this.listar().filter(x => !(x.ref === c.ref && x.sala === c.sala));
      lista.unshift(c);
      guardar("liveshop_compras", lista.slice(0, 50));
    }
  };
  const favs = {
    todos(){ return leer("liveshop_favs", {}); },
    de(sala){ return this.todos()[sala] || []; },
    tiene(sala, id){ return this.de(sala).includes(id); },
    alternar(sala, id){
      const t = this.todos();
      const l = t[sala] || [];
      t[sala] = l.includes(id) ? l.filter(x => x !== id) : l.concat(id).slice(-40);
      if (!t[sala].length) delete t[sala];
      guardar("liveshop_favs", t);
      return t[sala] ? t[sala].includes(id) : false;
    }
  };

  return {SB_URL, SB_KEY, MAX_VIEWERS, CATEGORIAS, PROMO_NOMBRE, rpc, token, setToken, clearToken, esc, money,
          cleanRoom, shrink, initials, catNombre, norm, reloj, aplicar, promoVigente, precioActual, pctPromo,
          restante, fecha, fechaLarga, cambio, csv, descargar, compras, favs};
})();
