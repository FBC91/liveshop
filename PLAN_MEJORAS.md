# LiveShop — Plan de mejoras: reportes, ventas, filtros y ofertas

Plan para sumar valor al **vendedor** (saber qué vende, cuánto factura y qué
hacer después) y al **comprador** (encontrar rápido lo que busca y aprovechar
ofertas reales), sin romper la tesis del producto: *ver, preguntar y pagar en
una sola pantalla*.

- **Fecha:** 13/10/2026
- **Estado:** implementado en la rama `feat/ventas-reportes-ofertas` (fases 0 a 4).
  Falta aplicar la migración en Supabase y publicar. Ver §15 y `HANDOVER.md` Parte VIII.
- **Base:** código actual de `index.html`, `host/index.html`, `pago/index.html`
  y `sql/001_cuentas_vendedor.sql` (modelo de la Parte VII del `HANDOVER.md`)

---

## 0. Resumen

| # | Bloque | Para quién | Qué resuelve | Fase |
|---|---|---|---|---|
| A | **Órdenes** (cimiento de datos) | Ambos | Hoy una venta se pierde si el vendedor cierra la consola, y el monto viaja en la URL | 0 |
| B | **Ventas y facturación** | Vendedor | "¿Qué vendí, a quién, cuándo, y cuánto entró?" | 1 |
| C | **Reportes** | Vendedor | "¿Qué producto funciona, cuál no, y qué hago al respecto?" | 1 → 4 |
| D | **Filtros y búsqueda** | Comprador | Encontrar un artículo sin recorrer todo el catálogo | 2 → 4 |
| E | **Ofertas** (descuento, remanentes, relámpago, cupón) | Ambos | Mover stock quieto y darle al comprador un motivo para comprar *ahora* | 3 → 4 |

**La idea que une todo:** cada número que ve el vendedor tiene que venir con una
acción posible al lado. "12 personas pidieron la mochila y no hay stock" no es
un dato, es un botón de *reponer*. "Este reloj no se movió en 30 días" es un
botón de *poner en liquidación*. Los reportes alimentan las ofertas, y las
ofertas generan ventas que vuelven a los reportes.

```
   Reportes ──detecta──▶ stock quieto / demanda sin stock
      ▲                              │
      │                         sugiere
   registra                          ▼
      │                         Ofertas (remanente, relámpago)
   Ventas ◀──convierte── Comprador filtra "En oferta" y paga
```

---

## 1. Diagnóstico: qué hay hoy y qué falta

### 1.1 Lo que ya existe y se reutiliza

- Métricas por vendedor (`liveshop_metricas`): entradas, compradores únicos,
  interés, mensajes, links, pagos, facturado, pico, éxito de video.
- Panel admin con serie diaria (`liveshop_metricas_admin`).
- Pago idempotente por `ref` que descuenta stock en la base.
- Catálogo en Postgres (hasta 40 productos) que viaja a los compradores en el
  mensaje `state`.

### 1.2 Huecos que bloquean lo que se pide

| Hueco | Dónde | Consecuencia |
|---|---|---|
| El evento `interes` no guarda **qué producto** | `index.html:1065`, tabla `liveshop_eventos` | Imposible saber "lo más pedido" |
| `liveshop_pagos` guarda solo `producto_id` y `monto` | `sql/001_cuentas_vendedor.sql:83` | Si el producto se borra o se renombra, el historial queda con un id huérfano. No hay comprador ni concepto |
| El pago lo registra **la consola** al recibir `paid` | `host/index.html:906` | Si el vendedor cerró la pestaña antes de que el comprador pague, la venta no existe para la base |
| El monto viaja en la URL del checkout | `pago/index.html:141` | El comprador puede cambiarlo. Con descuentos esto empeora |
| Productos sin categoría ni descripción | `liveshop_productos` | No hay base para filtros |
| No existe "un live" como entidad | Solo el evento `transmision` | No se puede responder "¿qué live vendió más?" |
| Días agregados en UTC | `liveshop_metricas_admin` | Una venta a las 22:00 de Montevideo cae en el día siguiente |
| La cuenta demo no tiene historia | `liveshop__seed_catalogo` | Cualquier reporte nuevo se vería vacío para quien llega del portfolio |

El último punto es tan importante como los demás: el 99% de las visitas llegan
con la cuenta `Vendedor`. Si sus reportes están en cero, la funcionalidad no
existe a los ojos de un reclutador. **Toda fase incluye datos demo.**

---

## 2. Principios de UX (aplican a todo el plan)

**Vendedor**

1. **Manos ocupadas.** Mientras transmite, el vendedor habla a cámara. Toda
   acción en vivo (destacar, oferta relámpago) se hace en 1–2 toques, sin teclear.
2. **Número + acción.** Ningún indicador sin un "¿y ahora qué?" al lado.
3. **Lenguaje llano.** No "conversión 38%" sino "de cada 10 links que mandaste,
   4 se pagaron". El término técnico va en el tooltip, no en el título.
4. **Comparar siempre.** Un número suelto no dice nada; "↑ 20% vs. los 30 días
   anteriores" sí.
5. **Estados vacíos que enseñan.** "Todavía no vendiste. Cuando mandes tu primer
   link de pago, acá vas a ver…" en vez de una tabla vacía.

**Comprador**

1. **Mobile primero.** Filtros en chips con scroll horizontal, nunca un panel
   lateral que tape el video.
2. **El video no se tapa.** Filtros, fichas y ofertas viven debajo o encima del
   catálogo, no sobre la transmisión (salvo el banner de oferta relámpago, que es
   el objetivo).
3. **Urgencia honesta.** "Quedan 2" solo si quedan 2. El contador de una oferta
   termina cuando la oferta termina en la base. Nada de relojes que se reinician.
4. **Sin cuenta.** Todo lo nuevo (favoritos, mis compras) funciona sin registro.

**Accesibilidad:** chips como `<button aria-pressed>`, contadores con
`aria-live="polite"` que anuncian cada minuto (no cada segundo), y
`prefers-reduced-motion` desactiva pulsos y animaciones de oferta.

---

## 3. Bloque A — Órdenes: el cimiento (Fase 0)

Todo lo de ventas, facturación, historial, links abandonados y descuentos
necesita una sola tabla que represente **una venta de punta a punta**. Hoy eso
está repartido entre el chat (en el navegador), un evento `link_pago` y una fila
en `liveshop_pagos` que solo existe si la consola estaba abierta.

### 3.1 Flujo nuevo

```
Vendedor toca "Enviar link"            Comprador abre el checkout
          │                                       │
liveshop_orden_crear(token, …)        liveshop_orden_ver(sala, ref)
  · calcula precio en el servidor       · devuelve concepto y monto DE LA BASE
    (lista − promo vigente)               (la URL solo lleva sala + ref)
  · guarda snapshot: producto,                    │
    comprador, precio lista, descuento  liveshop_orden_pagar(sala, ref)
  · estado = 'pendiente'                  · estado = 'pagada', descuenta stock
  · devuelve ref                          · idempotente, aunque la consola esté cerrada
          │                                       │
          └──── broadcast al chat ────────────────┘ broadcast `paid` (como hoy, para la UI)
```

**Por qué el precio lo calcula el servidor:** con descuentos, el precio correcto
depende de qué promo está vigente *en el momento de crear el link*. Si lo arma el
navegador del vendedor o viaja en la URL, cualquiera de las dos puntas lo altera.

**Qué no cambia:** el pago sigue siendo simulado. `liveshop_orden_pagar` es
público porque el checkout no tiene token; en un producto real lo reemplaza el
webhook de Mercado Pago. Se documenta igual que hoy (riesgo "confirmación
falsificable", HANDOVER §22), pero ahora **el monto ya no es adulterable**.

**"Otro concepto…"** (el monto manual que ya existe en el modal) se mantiene:
la orden se guarda con `producto_id = null` y `manual = true`, y los reportes por
producto la excluyen.

### 3.2 Lives como entidad

Al tocar *Iniciar transmisión*, la consola llama `liveshop_live_iniciar` y
recibe un `live_id`; al terminar, `liveshop_live_terminar` guarda fin y pico.
Cada orden creada durante el live lleva ese `live_id`. Si la pestaña se cierra
sin terminar, el live queda abierto y se cierra solo al iniciar el siguiente (o
por cron a las 6 h).

### 3.3 Criterios de aceptación — Fase 0

- [ ] Un pago hecho con la consola cerrada queda registrado y descuenta stock.
- [ ] Cambiar `monto` en la URL del checkout no cambia lo cobrado.
- [ ] Borrar un producto no borra ni deja sin nombre sus ventas pasadas.
- [ ] `interes` guarda `producto_id`.
- [ ] Las ventas viejas de `liveshop_pagos` aparecen en `liveshop_ordenes`.
- [ ] Todo lo existente (métricas, admin, stock en vivo) sigue funcionando igual.

---

## 4. Bloque B — Ventas y facturación (Fase 1)

Nueva pestaña **💰 Ventas** en la consola.

### 4.1 Pantalla

```
┌─ Ventas ───────────────────────────────────────── [Últimos 30 días ▾] ─┐
│  Facturado         Ventas        Ticket promedio     Pendiente de cobro │
│  $ 48.300          21            $ 2.300             $ 6.900 (3 links)  │
│  ↑ 18% vs. ant.    ↑ 5           ↓ 4%                [Ver pendientes]   │
├─────────────────────────────────────────────────────────────────────────┤
│ [Todas] [Pagadas] [Pendientes] [Vencidas]   🔍 Buscar producto o cliente │
├─────────────────────────────────────────────────────────────────────────┤
│ 12/10 21:14  Auriculares wireless  Lucía    $ 1.840  −20% ⚡  ● Pagada    │
│ 12/10 21:09  Reloj minimalista     Martín   $ 7.500          ○ Pendiente │
│ 11/10 19:50  Lentes de sol         Comprador A3F2 $ 1.800    ● Pagada    │
│ …                                                                        │
├─────────────────────────────────────────────────────────────────────────┤
│ [⬇ Exportar CSV]                                    Mostrando 1–20 de 21 │
└─────────────────────────────────────────────────────────────────────────┘
```

### 4.2 Funcionalidades

| Funcionalidad | Valor para el vendedor | Detalle |
|---|---|---|
| **Historial de ventas** | Saber qué vendió y a quién sin revisar chats | Tabla paginada (20), filtros por estado, rango y búsqueda. Orden por fecha desc. |
| **Detalle de orden** | Resolver un reclamo ("yo te pagué") en segundos | Panel lateral: producto, precio lista, descuento aplicado y cuál promo, comprador, live en que se vendió, ref, horas de creado/pagado, botón *Ir al chat*. |
| **Pendientes de cobro** | Recuperar ventas que se iban a perder | Links sin pagar. Botón **Reenviar** (vuelve a mandar la tarjeta al chat si el comprador sigue conectado) y **Anular**. A las 24 h pasan a *Vencida*. |
| **Comprobante** | Darle algo formal al cliente | HTML imprimible (`pago/comprobante.html?sala&ref`), con *Imprimir / Guardar PDF* del navegador. Lo puede abrir el comprador desde la pantalla de éxito y el vendedor desde el detalle. Leyenda fija: *"Comprobante de compra — no válido como factura"*. |
| **Exportar CSV** | Pasarle los números al contador o a una planilla | Generado en el navegador a partir de la RPC; columnas: fecha, ref, producto, categoría, comprador, precio lista, descuento, total, estado, live. Separador `;` y BOM UTF-8 para que Excel en español lo abra bien. |
| **Resumen mensual** | Cierre de mes sin cuentas a mano | Fila por mes: ventas, facturado, ticket promedio, descuentos otorgados. |

### 4.3 Sobre "facturación" fiscal

En Uruguay la factura válida es el **CFE** (e-Factura / e-Ticket de DGI), que
se emite a través de un proveedor habilitado. Eso implica RUT del emisor,
certificado y contrato con el proveedor: **fuera de alcance de la demo**, igual
que el cobro real (HANDOVER §4).

Lo que sí deja preparado este plan: la orden guarda todo lo que un CFE
necesitaría (concepto, precio unitario, descuento, total, fecha), y el detalle
tiene un campo opcional "RUT / razón social del cliente" para cuando aplique.
Conectar un proveedor sería agregar una llamada al pasar a `pagada`.

### 4.4 Criterios de aceptación — Fase 1 (ventas)

- [ ] Una venta aparece en el historial ≤ 2 s después del pago, sin recargar.
- [ ] Los totales de *Ventas* coinciden con los de *Reportes* y con el admin.
- [ ] El CSV abre en Excel con tildes y montos correctos.
- [ ] Un link reenviado no duplica la orden (misma `ref`).
- [ ] La cuenta demo muestra ~30 días de ventas al entrar.

---

## 5. Bloque C — Reportes (Fase 1 y Fase 4)

La pestaña **📈 Métricas** pasa a llamarse **📈 Reportes** y se organiza en tres
sub-vistas: *Resumen*, *Productos* y *Mis lives*.

### 5.1 Resumen (Fase 1)

```
┌─ Resumen ──────────────────────────────────── [Últimos 30 días ▾] ─┐
│ Facturado $ 48.300 ↑18%   Ventas 21 ↑5   Ticket $ 2.300 ↓4%         │
│                                                                     │
│ ▁▂▂▅▃▁▁▇▆▂▁▁▃█▅▂  ventas por día  (barras = facturado, línea = 7d)  │
│                                                                     │
│ Embudo                                                              │
│ Entraron        ████████████████████████  320                       │
│ Pidieron        ██████████                 96   (3 de cada 10)      │
│ Recibieron link ████                       34                       │
│ Pagaron         ███                        21   (6 de cada 10 links)│
│                                                                     │
│ 💡 Para hacer hoy                                                   │
│ · 12 personas pidieron "Mochila impermeable" y está sin stock → [Reponer] │
│ · "Reloj minimalista" no se vende hace 34 días → [Poner en liquidación]   │
│ · Tenés 3 links sin pagar por $ 6.900 → [Ver pendientes]            │
└─────────────────────────────────────────────────────────────────────┘
```

- **KPIs con comparación** contra el período anterior de igual largo.
- **Gráfico diario** en zona horaria `America/Montevideo`.
- **Embudo** entrada → interés → link → pago. Es el gráfico más útil para un
  vendedor de live: dice si el problema es atraer gente, convencerla o cobrarle.
- **"Para hacer hoy"**: hasta 3 sugerencias, cada una con un botón que lleva a
  la acción (ver reglas en §5.4). Es el puente entre reportes y ofertas.

### 5.2 Productos (Fase 1)

Ranking con pestañas de orden; una fila por producto:

| Columna | Pregunta que responde |
|---|---|
| Unidades vendidas / facturado | ¿Qué es lo **más vendido**? |
| Pedidos ("Lo quiero") | ¿Qué es lo **más deseado**? |
| De pedido a venta | ¿Qué atrae pero no cierra? (precio, talle, dudas) |
| Stock actual / días de stock | ¿Cuándo se me acaba al ritmo actual? |
| Última venta | ¿Qué está quieto? |
| Descuento otorgado | ¿Cuánto me costaron las promos de este producto? |

Tocar una fila abre la **ficha histórica del producto**:

- Ventas por semana (sparkline) y en qué lives se vendió.
- Historial de precio y promos aplicadas (sale de las órdenes, no hace falta
  tabla extra: cada orden guarda precio lista y descuento).
- Quiénes lo compraron (nombres de chat) y ventas pendientes.
- Acciones: *Editar*, *Destacar en el próximo live*, *Poner en oferta*.

**Margen (opcional):** campo `costo` en el producto, visible solo en la consola.
Si está cargado, el ranking agrega "ganancia" y la sugerencia de liquidación no
propone un precio por debajo del costo. Si no está, no se muestra nada.

### 5.3 Mis lives (Fase 4)

Una fila por transmisión: fecha, duración, título, pico de espectadores,
entradas, ventas, facturado, producto estrella. Responde la pregunta que más le
importa a quien vende en vivo: **¿qué live funcionó y por qué?** Al lado, un
mapa simple de calor *día de semana × hora* con facturado, para elegir cuándo
salir en vivo.

### 5.4 Reglas de las sugerencias

Todas configurables como constantes en SQL; valores iniciales:

| Sugerencia | Regla | Acción |
|---|---|---|
| Reponer | stock = 0 y ≥ 3 pedidos en 14 días | Abre edición con foco en stock |
| Liquidar (remanente) | stock > 0, sin ventas en 30 días, producto con ≥ 14 días de antigüedad | Crea oferta *remanente* con % sugerido |
| Últimas unidades | stock ≤ 3 y ≥ 1 venta en 7 días | Ofrece destacarlo en el próximo live |
| Revisar precio | ≥ 5 pedidos y 0 ventas en 14 días | Abre edición con foco en precio |
| Cobrar pendientes | links pendientes > 0 | Abre *Ventas → Pendientes* |

Máximo 3 a la vez, ordenadas por plata en juego. Cada una se puede descartar
por 7 días.

### 5.5 Durante el live

En la vista *Transmisión*, debajo de los KPIs actuales, una tira **"Ahora en tu
live"**: los 3 productos más pedidos en los últimos 10 minutos, con botón
*Destacar* al lado. Es el reporte que el vendedor puede usar sin dejar de
hablar a cámara.

### 5.6 Criterios de aceptación — Reportes

- [ ] Cada KPI muestra comparación con el período anterior.
- [ ] El ranking de productos incluye productos borrados (marcados "ya no está
      en el catálogo") para que el histórico cierre con el facturado.
- [ ] Cada sugerencia lleva a una pantalla donde la acción se completa en ≤ 2 toques.
- [ ] Sin datos, cada sección explica qué va a aparecer y cómo generarlo.

---

## 6. Bloque D — Filtros y búsqueda para el comprador (Fase 2 y Fase 4)

### 6.1 Categorías: lista fija, no texto libre

Se agrega `categoria` al producto con una **lista cerrada** de rubros:

`Ropa · Calzado · Accesorios · Tecnología · Hogar · Belleza · Deportes · Niños · Otros`

**Por qué cerrada:** si cada vendedor escribe la suya ("remeras", "Remeras",
"tops"), el filtro entre tiendas del directorio no funciona y los chips de la
sala se llenan de duplicados. Nueve opciones alcanzan para un catálogo de 40
productos. Se elige con un `<select>` en el formulario del producto; default
`Otros`.

También se agrega `descripcion` (hasta 280 caracteres) para la ficha.

### 6.2 En la sala (Fase 2)

```
┌──────────── video ────────────┐
│                               │
└───────────────────────────────┘
 🔍 Buscar en esta tienda…
 [Todo] [⚡ Ofertas 3] [Ropa 8] [Calzado 4] [Accesorios 6] →
 Ordenar: [Destacados ▾]     ☐ Solo con stock
 ─────────────────────────────────
 ┌────┐ ┌────┐ ┌────┐
 │ 👟 │ │ 🎧 │ │ ⌚ │   …
```

- **Búsqueda** por nombre y descripción, sin tildes ni mayúsculas, con
  debounce de 150 ms.
- **Chips de categoría** con contador; solo aparecen las categorías que la
  tienda usa. Si la tienda usa una sola, la fila de chips no se muestra.
- **Chip ⚡ Ofertas** primero cuando hay alguna promo vigente.
- **Ordenar:** Destacados (orden del vendedor, el destacado arriba) · Menor
  precio · Mayor precio · Mayor descuento.
- **Solo con stock**, activado por defecto si hay más de 4 agotados.
- Todo es **en el navegador**: el catálogo ya llega completo en `state` y tiene
  como máximo 40 productos. Cero consultas extra.
- El filtro elegido se guarda en `sessionStorage` y en la URL
  (`?live=x&cat=calzado`) para que el link se pueda compartir.
- Sin resultados: "No hay nada con *'campera'* en esta tienda. [Ver todo]".
- **Cuando el vendedor destaca un producto** que el filtro actual oculta, se
  muestra igual arriba con la marca AHORA: lo que se muestra en cámara nunca
  queda escondido.

### 6.3 Ficha de producto (Fase 2)

Tocar la imagen (no el botón) abre una hoja inferior en mobile / modal en
desktop con foto grande, descripción, precio (tachado si hay oferta), stock,
cuántos se vendieron hoy en esta tienda (si ≥ 2) y **Lo quiero**. Evento
`vista_producto` para que el vendedor vea qué se mira y no se pide.

### 6.4 Mis compras y favoritos (Fase 2)

- **Mis compras:** cada pago confirmado se guarda en `localStorage`
  (`liveshop_compras`: ref, sala, producto, monto, fecha). Botón en la cabecera
  de la sala y del directorio que lista las compras con link al comprobante. Sin
  cuenta, persiste en ese navegador; se avisa en la propia pantalla.
- **Favoritos:** corazón en la tarjeta, en `localStorage`. En el directorio,
  una tienda con favoritos sube y muestra "Tenés 2 guardados acá". Cuando un
  favorito entra en oferta, la tarjeta del directorio lo indica.

### 6.5 En el directorio (Fase 4)

- **Buscador global** "Buscá un artículo en todas las tiendas" → RPC
  `liveshop_buscar(q, categoria, solo_ofertas)` que devuelve productos con su
  tienda (máx. 40 resultados, sin fotos pesadas: miniatura ya reducida).
  Resultado agrupado: **primero las tiendas en vivo**, porque ahí se puede
  comprar ya.
- **Chips de categoría** globales que filtran tanto *En vivo ahora* como
  *Tiendas*.
- **Sección "Ofertas ahora"** encima de *Tiendas*: carrusel de productos con
  promo vigente de cualquier tienda, ordenados por fin más próximo.
- Requiere sacar las fotos del JSON del directorio (riesgo bajo ya documentado
  en HANDOVER §22). Mientras no exista Storage, la búsqueda devuelve emoji o
  miniatura de ≤ 8 KB.

### 6.6 Criterios de aceptación — Comprador

- [ ] Filtrar 40 productos responde sin demora perceptible en un celular medio.
- [ ] El link con `?cat=` abre la sala ya filtrada.
- [ ] El producto destacado por el vendedor es visible con cualquier filtro.
- [ ] Navegable entero con teclado; chips anuncian estado con `aria-pressed`.
- [ ] Mis compras sobrevive a cerrar y abrir el navegador.

---

## 7. Bloque E — Ofertas especiales (Fase 3 y Fase 4)

Cuatro tipos, todos guardados en una tabla `liveshop_promos` y aplicados por el
servidor al crear la orden.

| Tipo | Para qué sirve | Quién la crea | Duración típica |
|---|---|---|---|
| **Descuento** | Promo común: "20% en calzado esta semana" | Vendedor, desde el catálogo | Días |
| **Remanente** | Liquidar últimas unidades o stock quieto | Vendedor, desde una sugerencia o el catálogo | Hasta agotar stock |
| **⚡ Relámpago** | Generar pico de ventas durante el live | Vendedor, en vivo, 2 toques | 5–15 min, opcional tope de unidades |
| **Cupón del live** (Fase 4) | Premiar a quien está mirando: el vendedor dice el código en cámara | Vendedor, al iniciar el live | Lo que dure el live |

**Por qué no combos ni 2×1:** el producto no tiene carrito (decisión de
HANDOVER §4). Un pack se resuelve cargándolo como un producto más ("Pack 2
remeras"). Se evita reabrir esa decisión.

### 7.1 Reglas de negocio

1. **Una promo por producto a la vez**; no se apilan. Si se intenta crear una
   segunda, se ofrece reemplazar la vigente. El cupón es la única excepción y
   se aplica sobre el precio ya rebajado, con un tope total de 50%.
2. **El precio final lo calcula la base** (`liveshop__precio`) al crear la
   orden. El link de pago respeta el precio con el que se creó aunque la promo
   termine un minuto después: el comprador no pierde el descuento por tardar en
   pagar (vence con el link, a las 24 h).
3. **Tope de unidades:** si la relámpago tiene "solo 5", al venderse la quinta
   la promo se cierra sola y el `state` se re-emite.
4. **Piso:** si el producto tiene `costo`, la UI avisa cuando el precio con
   descuento queda por debajo. Avisa, no bloquea: liquidar a pérdida a veces es
   la decisión correcta.
5. **Precio anterior real:** el tachado es siempre el precio de lista vigente,
   nunca uno inventado.

### 7.2 UX del vendedor

**Crear una oferta (catálogo):** botón *🏷 Poner en oferta* en cada tarjeta.

```
┌─ Oferta: Reloj minimalista ($ 7.500) ──────────────┐
│ Tipo      (•) Descuento  ( ) Liquidación            │
│ Descuento [10%] [20%] [30%] [50%]  o  $ [______]    │
│ Hasta     [Hoy] [7 días] [Hasta agotar] [Fecha…]    │
│                                                     │
│ Así lo ve el comprador:                             │
│   ⌚ Reloj minimalista   $ 7.500  $ 6.000  −20%      │
│                                                     │
│                  [Cancelar]  [Publicar oferta]      │
└─────────────────────────────────────────────────────┘
```

- Vista previa con la tarjeta real del comprador.
- En la lista del catálogo, filtro **"En oferta"** y una etiqueta en cada
  producto con el tiempo restante; botón *Terminar oferta*.
- **Liquidación en lote** desde la sugerencia de remanentes: lista con los
  productos detectados preseleccionados y un único % para todos.

**Relámpago (en vivo):** en la vista *Transmisión*, junto al producto
destacado:

```
 Destacado ahora: 🎧 Auriculares wireless  $ 2.300
 [⚡ Oferta relámpago]
     → [10%] [20%] [30%]   ·   [5 min] [10 min] [15 min]   ·   Unidades: [Todas ▾]
     → [¡Lanzar!]
```

Dos toques con valores por defecto (20%, 10 min). Mientras corre, la consola
muestra el contador y las unidades vendidas, y un botón *Terminar ya*.

### 7.3 UX del comprador

- **Tarjeta:** precio tachado + precio final + insignia `−20%`. Liquidación
  agrega "Últimas unidades" si stock ≤ 3.
- **Relámpago:** banner sobre el borde inferior del video (no tapa la cara del
  vendedor) con el producto, el precio y un contador `09:41`, más el botón
  **Lo quiero**. El contador se calcula con el `fin` de la base corregido por
  la diferencia de reloj (la RPC devuelve `now()` del servidor). Al terminar,
  el banner dice "Terminó la oferta" 5 segundos y desaparece.
- **Chat:** el mensaje automático "Hola, quiero comprar…" incluye "(con 20% off)"
  para que el vendedor sepa qué precio esperaba el comprador.
- **Checkout:** desglose *Precio $ 2.300 · Oferta relámpago −$ 460 · Total
  $ 1.840*. En Fase 4, campo "¿Tenés un código del live?".

### 7.4 Medición de las ofertas

En *Reportes → Productos* y en el detalle de cada promo: unidades vendidas con
la promo, facturado, descuento otorgado en $, y ventas por minuto durante la
relámpago vs. el resto del live. Así el vendedor aprende qué % le conviene.

### 7.5 Criterios de aceptación — Ofertas

- [ ] Lanzar una relámpago toma ≤ 2 toques y llega a los compradores en ≤ 1 s.
- [ ] Un link creado durante la promo se cobra con descuento aunque se pague
      después de que termine (dentro de las 24 h).
- [ ] Al agotarse el tope de unidades, la promo se cierra para todos.
- [ ] No se pueden tener dos promos activas sobre el mismo producto.
- [ ] El contador del comprador no se desfasa más de 1 s del de la consola.

---

## 8. Modelo de datos — `sql/002_ventas_reportes_ofertas.sql`

Idempotente, como la 001. Mismo modelo de acceso: RLS sin políticas, todo por
funciones `SECURITY DEFINER`, helpers `liveshop__*` sin `EXECUTE` para `anon`.

```sql
-- Productos: categoria, descripcion, costo (privado)
alter table liveshop_productos
  add column if not exists categoria   text not null default 'otros'
      check (categoria in ('ropa','calzado','accesorios','tecnologia','hogar',
                           'belleza','deportes','ninos','otros')),
  add column if not exists descripcion text check (char_length(descripcion) <= 280),
  add column if not exists costo       numeric(12,2) check (costo >= 0),
  add column if not exists creado_at   timestamptz not null default now();
-- creado_at debe sobrevivir al "borrar e insertar" de liveshop_catalogo_guardar:
-- la funcion se reescribe para preservarlo (y el costo) por id.

-- Eventos: a que producto se refiere
alter table liveshop_eventos add column if not exists producto_id text;
-- y se suma el tipo 'vista_producto' al check

-- Lives
create table if not exists liveshop_lives(
  id          uuid primary key default gen_random_uuid(),
  vendedor_id uuid not null references liveshop_vendedores(id) on delete cascade,
  titulo      text,
  inicio      timestamptz not null default now(),
  fin         timestamptz,
  pico        int not null default 0
);

-- Promos
create table if not exists liveshop_promos(
  id           uuid primary key default gen_random_uuid(),
  vendedor_id  uuid not null references liveshop_vendedores(id) on delete cascade,
  tipo         text not null check (tipo in ('descuento','remanente','relampago','cupon')),
  producto_id  text,                         -- null solo para cupon (toda la tienda)
  pct          numeric(5,2) check (pct > 0 and pct < 100),
  precio       numeric(12,2) check (precio >= 0),  -- precio fijo alternativo al pct
  codigo       text check (codigo ~ '^[A-Z0-9]{3,16}$'),
  inicio       timestamptz not null default now(),
  fin          timestamptz,                  -- null = hasta agotar stock
  max_unidades int check (max_unidades > 0),
  vendidas     int not null default 0,
  live_id      uuid references liveshop_lives(id) on delete set null,
  terminada_at timestamptz,
  check ((pct is null) <> (precio is null))
);
-- una promo de producto activa por producto
create unique index if not exists liveshop_promos_activa_uq
  on liveshop_promos(vendedor_id, producto_id)
  where terminada_at is null and tipo <> 'cupon';

-- Ordenes: reemplaza a liveshop_pagos
create table if not exists liveshop_ordenes(
  vendedor_id     uuid not null references liveshop_vendedores(id) on delete cascade,
  ref             text not null check (ref ~ '^[A-Z0-9]{8,24}$'),
  estado          text not null default 'pendiente'
                    check (estado in ('pendiente','pagada','anulada','vencida')),
  producto_id     text,
  producto_nombre text not null,           -- snapshot
  categoria       text,                    -- snapshot
  comprador_id    text,
  comprador       text,                    -- nombre que dio en el chat
  precio_lista    numeric(12,2) not null,
  descuento       numeric(12,2) not null default 0,
  total           numeric(12,2) not null check (total >= 0),
  promo_id        uuid references liveshop_promos(id) on delete set null,
  promo_tipo      text,                    -- snapshot, sobrevive al borrado de la promo
  live_id         uuid references liveshop_lives(id) on delete set null,
  manual          boolean not null default false,
  cliente_fiscal  text,                    -- RUT / razon social opcional
  demo            boolean not null default false,
  created_at      timestamptz not null default now(),
  pagada_at       timestamptz,
  primary key (vendedor_id, ref)
);
create index if not exists liveshop_ordenes_fecha_idx
  on liveshop_ordenes(vendedor_id, estado, created_at);

-- Migracion de datos: liveshop_pagos -> liveshop_ordenes (estado 'pagada',
-- producto_nombre desde el catalogo actual o '(producto borrado)').
-- liveshop_pagos queda de solo lectura una version y despues se elimina.
```

**Ref:** pasa de un código corto a 10 caracteres aleatorios (`[A-Z0-9]`), porque
ahora el checkout la usa para leer la orden sin token. Las refs viejas que no
cumplan el formato se migran con un prefijo de relleno.

**Zona horaria:** toda agregación por día usa
`(created_at at time zone 'America/Montevideo')::date`. Se corrige también la
serie del admin.

### 8.1 Funciones

| Función | Acceso | Qué hace |
|---|---|---|
| `liveshop__precio(vendedor, producto, codigo?)` | helper | Precio lista, promo vigente, descuento y total |
| `liveshop_orden_crear(token, comprador_id, comprador, producto_id, concepto?, monto?)` | vendedor | Crea orden pendiente con snapshot. Monto solo se acepta si es manual |
| `liveshop_orden_ver(sala, ref)` | público | Concepto, desglose y estado para el checkout |
| `liveshop_orden_pagar(sala, ref, codigo?)` | público | Marca pagada, descuenta stock, suma `vendidas` a la promo y la cierra si llega al tope. Idempotente |
| `liveshop_orden_anular(token, ref)` | vendedor | Solo pendientes |
| `liveshop_ventas(token, desde, hasta, estado, q, pagina)` | vendedor | Historial paginado + totales del filtro |
| `liveshop_reporte_resumen(token, dias)` | vendedor | KPIs actuales y período anterior, serie diaria, embudo, sugerencias |
| `liveshop_reporte_productos(token, dias)` | vendedor | Ranking por producto, incluye borrados |
| `liveshop_reporte_lives(token, dias)` | vendedor | Una fila por live + matriz día × hora |
| `liveshop_live_iniciar(token, titulo)` / `liveshop_live_terminar(token, live_id, pico)` | vendedor | Ciclo del live |
| `liveshop_promo_crear(token, …)` / `liveshop_promo_terminar(token, id)` | vendedor | ABM de promos con las reglas de §7.1 |
| `liveshop_buscar(q, categoria, solo_ofertas)` | público | Búsqueda entre tiendas (Fase 4) |
| `liveshop_sala` / `liveshop_directorio` | público | Se extienden: cada producto trae `categoria`, `descripcion`, `precio_lista`, `precio`, `promo{tipo,fin,restantes}` y la sala trae `ahora` del servidor. Nunca `costo` |
| `liveshop_metricas` | vendedor | Se mantiene, ahora leyendo `liveshop_ordenes` |

### 8.2 Impacto en el mensaje `state`

Cada producto suma ~120 bytes (categoría, promo) más la descripción (≤ 280).
Con 40 productos son ≤ 16 KB más sobre un tope de ~256 KB dominado por las
fotos: sin riesgo. `checkPayload()` sigue avisando igual.

---

## 9. Datos demo

Nueva función `liveshop__seed_historial(vendedor_id)`, llamada desde
`liveshop__reset_demo()` (diario, ya programado con `pg_cron`):

- Asigna categorías y descripciones al catálogo de ejemplo.
- Genera ~12 lives en los últimos 30 días (más los jueves y domingos a la
  noche, para que el mapa de calor cuente algo), con ~60 órdenes pagadas, 5
  pendientes y 4 vencidas; eventos de entrada/interés coherentes con el embudo.
- Deja **a propósito** un caso para cada sugerencia: la mochila sin stock y con
  pedidos, el reloj quieto hace 30 días, 3 links pendientes.
- Una promo de descuento vigente y una relámpago histórica, para que *Ofertas*
  y la medición tengan contenido.
- Todo con `demo = true`: el admin puede excluirlas con un toggle, y el reset
  las borra y regenera sin tocar ventas reales hechas por visitantes ese día.
- Determinista (semilla fija por día) para que dos visitantes vean lo mismo.

---

## 10. Cambios en la interfaz, por archivo

| Archivo | Cambios |
|---|---|
| `host/index.html` | Tabs: Transmisión · Catálogo · Chats · **Ventas** · **Reportes** · Mi cuenta. Formulario de producto con categoría, descripción y costo. Botón *Poner en oferta*. Tira "Ahora en tu live" y lanzador de relámpago en Transmisión. El modal de pago llama `liveshop_orden_crear` y muestra el desglose |
| `index.html` | Barra de búsqueda/chips/orden en la sala. Ficha de producto. Precio tachado y banner relámpago. Mis compras y favoritos. (Fase 4) buscador global y "Ofertas ahora" en el directorio |
| `pago/index.html` | Lee la orden con `liveshop_orden_ver`, paga con `liveshop_orden_pagar`, muestra desglose. Pantalla de éxito con *Ver comprobante* y guardado en Mis compras |
| `pago/comprobante.html` | Nuevo. Comprobante imprimible |
| `admin/index.html` | Totales desde `liveshop_ordenes`, toggle "excluir datos demo", columna de descuentos otorgados |
| `comun.js` | `CATEGORIAS`, `fmtPct`, `fmtCountdown`, `toCSV`, `normalizar()` (sin tildes) y mensajes de los nuevos códigos `LS:` |

Si `host/index.html` (hoy ~1.700 líneas) supera las ~2.500, separar
`host/reportes.js` y `host/ventas.js` como scripts clásicos (sin build), igual
que `comun.js`.

---

## 11. Fases y orden de trabajo

| Fase | Contenido | Tamaño | Depende de | Valor visible |
|---|---|---|---|---|
| **0** | Migración 002 (órdenes, lives, eventos con producto, categorías), checkout lee de la base, seed demo básico | M | — | Bajo, pero cierra los huecos de §1.2 |
| **1** | Pestaña Ventas completa + Reportes *Resumen* y *Productos* + sugerencias + comprobante | L | 0 | **Alto para el vendedor** |
| **2** | Filtros, búsqueda y orden en la sala + ficha + Mis compras + favoritos | M | 0 (categoría) | **Alto para el comprador** |
| **3** | Ofertas: descuento, remanente (con sugerencias de Fase 1) y relámpago | L | 0, 1 | Alto para ambos; la mejor pieza para mostrar en video del portfolio |
| **4** | Directorio con búsqueda global y "Ofertas ahora", cupón del live, *Mis lives* y mapa de calor | M | 2, 3 | Medio |

**Recomendación:** si hay que recortar, Fase 0 → 3 (relámpago) → 1 → 2. La
oferta relámpago es lo más propio del live shopping —no existe igual en un
e-commerce común— y es lo que mejor se luce en una demo de 60 segundos. Pero
sin Fase 0 no tiene cómo cobrar el precio rebajado de forma segura.

Cada fase cierra con: commit de la migración, verificación (§12), actualización
de `HANDOVER.md` (nueva parte) y de `README.md`.

---

## 12. Verificación

Siguiendo el método de la Parte VII (PGlite con `anon`/`authenticated` reales +
jsdom con las páginas reales):

**SQL**
- Migración aplicada dos veces sin error; datos de `liveshop_pagos` presentes en
  `liveshop_ordenes`.
- `anon` no lee `costo` por ninguna RPC pública.
- `liveshop_orden_pagar` dos veces = una venta y un descuento de stock.
- Monto manual rechazado cuando hay `producto_id`.
- Precio con promo vigente / vencida / agotada; no se apilan promos; cupón con
  tope 50%.
- Relámpago con tope de 3 unidades se cierra en la tercera venta.
- Agregación por día en hora de Montevideo (venta a las 23:30 local cae en el
  día correcto).
- Reportes de un vendedor nunca incluyen datos de otro.
- `liveshop__seed_historial` deja exactamente los casos de §9.

**Páginas**
- Pago con la consola cerrada aparece en Ventas al reabrirla.
- Filtros: búsqueda sin tildes, chips, orden, `?cat=` en la URL, destacado
  visible con filtro activo.
- Relámpago: lanzar en consola → banner en comprador → link con descuento →
  pago después del fin → total con descuento.
- CSV con BOM y separador `;`.
- Navegación por teclado de chips, ficha y modal de oferta.

**A mano tras instalar:** video real entre dos navegadores con una relámpago
corriendo, y el comprobante impreso a PDF en Chrome y Safari mobile.

---

## 13. Cómo medir si funcionó

| Indicador | Fuente | Señal de éxito |
|---|---|---|
| Visitantes que abren Ventas o Reportes con la cuenta demo | `analytics_events` (`liveshop_tab_ventas`, `liveshop_tab_reportes`) | > 40% de los que entran a la consola |
| Clics en sugerencias | evento `liveshop_sugerencia_click` | ≥ 1 por cada 5 aperturas de Reportes |
| Uso de filtros en sala | `liveshop_filtro` | > 25% de las entradas a una sala con ≥ 8 productos |
| Relámpagos lanzadas | `liveshop_relampago` | Al menos una por cada 3 lives |
| De link a pago | órdenes | No baja respecto de hoy (el checkout nuevo no agrega fricción) |

Ninguno guarda datos personales, igual que la analítica actual.

---

## 14. Fuera de alcance y riesgos

**Fuera de alcance (a propósito):** cobro real, factura electrónica (CFE),
carrito y combos, notificaciones push ("avisame cuando haya stock" o "cuando
salga en vivo": requieren contacto del comprador o service worker con
suscripción), cuentas de comprador, recomendaciones personalizadas.

**Riesgos:**

- **Medio — el checkout público puede marcar como pagada cualquier orden si se
  conoce la `ref`.** Mitigado con refs aleatorias de 10 caracteres; la solución
  real es el webhook del procesador. Se documenta junto al riesgo existente.
- **Medio — catálogo "borrar e insertar".** Al agregar `creado_at` y `costo`,
  `liveshop_catalogo_guardar` debe preservarlos por `id`; si no, cada guardado
  "rejuvenece" los productos y rompe la regla de stock quieto. Cubierto por test.
- **Bajo — reloj del comprador.** El contador usa el `ahora` del servidor; si la
  pestaña queda dormida, se resincroniza al volver (`visibilitychange`).
- **Bajo — peso de la consola.** Ver §10: separar scripts si crece demasiado.
- **Bajo — datos demo confundidos con reales.** Marca `demo` + toggle en admin.

---

## 15. Estado de la implementación (13/10/2026)

Las cinco fases están hechas y verificadas: 103 checks de SQL, 107 de páginas y una pasada visual en Chrome (desktop y mobile)
(ver `HANDOVER.md` §36). La consola se separó en `host/ofertas.js`,
`host/ventas.js` y `host/reportes.js`, como preveía el §10.

**Diferencias con lo planeado:**

- **Campo "RUT / razón social del cliente"** (§4.3): no se agregó. Sin un proveedor
  de facturación electrónica conectado no tiene uso, y sumaba un campo más al
  checkout.
- **"Cuántos se vendieron hoy" en la ficha** (§6.3): no se agregó. Pedía una
  consulta pública más por producto, y con los volúmenes de la demo casi siempre
  mostraría 0 o 1.
- **Reloj del comprador** (§14): en vez de resincronizar con `visibilitychange`, se
  resincroniza con cada `state` del vendedor y con cada lectura de la sala, del
  directorio o de las ofertas. La diferencia con el servidor no cambia si la
  pestaña duerme, así que alcanza.
- **"Ofertas ahora"** (§6.5): grilla en vez de carrusel, igual que los resultados
  de búsqueda, para que se pueda recorrer con teclado sin animación.
- **Filtros de la sala** (§6.2): se muestran a partir de 5 productos; con menos,
  estorban más de lo que ayudan.
- **Tope de unidades de la relámpago** (§7.1): se cuenta al pagar, no al crear el
  link. Quien recibió el link durante la oferta paga el precio rebajado aunque el
  tope ya se haya alcanzado.
- **Reset diario** (§9): además de la historia, restaura el catálogo de la tienda
  demo; las sugerencias dependen de sus productos.

**Pendiente:** aplicar `sql/002_ventas_reportes_ofertas.sql` en Supabase,
publicar el frontend y repetir el flujo a mano en navegadores reales (aspecto
visual en mobile y desktop, video real).
