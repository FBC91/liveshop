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
    red: "No hay conexión con el servidor. Revisá tu internet y probá de nuevo."
  };

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

  return {SB_URL, SB_KEY, MAX_VIEWERS, rpc, token, setToken, clearToken, esc, money, cleanRoom, shrink, initials};
})();
