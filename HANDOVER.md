# LiveShop — Documento de traspaso completo

Todo lo necesario para responder cualquier consulta sobre este proyecto: de
negocio, de producto, de arquitectura, de operación o de código.

Si sos una persona nueva en el proyecto, leé primero el `README.md` de esta
misma carpeta — explica el producto en lenguaje llano. Este documento es la
referencia exhaustiva.

- **Producción:** https://facundobolani.com/liveshop/
- **Repositorio:** https://github.com/FBC91/liveshop (repo propio con GitHub Pages; antes vivía en la carpeta `liveshop/` de FBC91.github.io)
- **Ruta local:** `C:\Users\facun\liveshop\`
- **Último estado documentado:** ventas, reportes, filtros y ofertas, 13 de octubre de 2026 (ver Parte VIII)
- **Autor:** Facundo Bolani

> **Cambio de modelo (16/09/2026).** LiveShop pasó de "sin cuentas, catálogo en el
> navegador, sala aleatoria por visitante" a "cuentas de vendedor, datos en
> Postgres, una sala fija por vendedor, directorio de lives y panel de admin".
> La **Parte VII** describe el modelo nuevo y manda sobre cualquier sección
> anterior que la contradiga.
>
> **Ventas, reportes y ofertas (13/10/2026).** Las ventas pasan a ser órdenes en
> la base (`liveshop_ordenes`), el precio lo calcula la base, el checkout ya no
> recibe el monto por URL, y se suman pestañas de Ventas y Reportes, ofertas
> (descuento, liquidación, relámpago, cupón) y filtros para el comprador. La
> **Parte VIII** manda sobre las anteriores. El plan que lo motivó está en
> `PLAN_MEJORAS.md`.

---

# PARTE I — NEGOCIO Y PRODUCTO

## 1. Qué es y para qué existe

LiveShop es una demo funcional de *live shopping*: comercio por transmisión en
vivo. Un vendedor transmite desde su cámara, muestra productos, y los
compradores preguntan por chat y pagan sin salir de la transmisión.

**Su propósito real es ser una pieza de portfolio.** No busca usuarios ni
ingresos. Busca que alguien que evalúa a Facundo — un reclutador, un cliente
potencial, un socio — entienda en menos de un minuto que sabe construir un
producto completo y tomar decisiones defendibles.

Esa distinción gobierna todas las decisiones del proyecto. Cuando hubo que
elegir entre "más funcionalidad" y "que un desconocido entienda esto rápido",
siempre ganó lo segundo.

## 2. El problema de negocio que ilustra

El live shopping funciona porque junta tres momentos que la compra online tiene
separados: ver el producto, evacuar la duda, y pagar. En China es un canal de
venta masivo. En Latinoamérica crece pero de forma improvisada.

La improvisación tiene una forma concreta: el vendedor transmite por Instagram,
responde consultas por WhatsApp y cobra por transferencia bancaria. Tres
herramientas, tres saltos.

Cada salto es una fuga. El comprador que tiene que salir de la transmisión,
abrir otra app y escribir a un número, muchas veces no lo hace. Y el vendedor
que atiende veinte conversaciones en WhatsApp sin saber a qué producto se
refiere cada una, pierde ventas por confusión.

LiveShop muestra cómo se ve ese flujo cuando ocurre en una sola pantalla.

## 3. Los dos usuarios

**El vendedor.** Un emprendedor o una tienda chica que ya vende por redes.
Necesita transmitir, mostrar productos con precio y stock, atender varias
conversaciones a la vez sin perderse, y cobrar. Su miedo es la fricción: si la
herramienta es complicada, vuelve a Instagram.

**El comprador.** Alguien que llegó a la transmisión y tiene una duda que lo
frena. Su necesidad es preguntar sin perder el hilo de lo que está viendo, y
pagar sin sentir que salta a un sitio desconocido.

## 4. Qué se decidió NO hacer, y por qué

Un producto se define tanto por lo que descarta como por lo que incluye.

**Sin cobro real.** El checkout es simulado: no se piden ni se procesan datos de
tarjeta. Integrar Mercado Pago exigiría cuenta de comercio, credenciales,
webhooks y un backend para recibirlos. Nada de eso demuestra una capacidad
adicional en una demo, y sí agregaría riesgo real de manejar dinero ajeno.

**Sin cuentas de comprador.** El comprador nunca se registra: un formulario entre
el visitante y la compra mataría la mayoría de las visitas. *(Hasta el 16/09/2026
tampoco había cuentas de vendedor; ahora sí las hay, con una cuenta demo pública
para que el visitante no tenga que registrarse. Ver Parte VII.)*

**Sin carrito ni cantidades.** Una consulta es por un producto. El carrito es un
patrón resuelto del e-commerce tradicional y no aporta nada a la tesis de este
producto, que es la conversación en vivo.

**Sin Supabase Auth.** Las cuentas de vendedor usan tablas y funciones propias,
no el sistema de autenticación de Supabase: ese sistema exige email, y dar de alta
o baja usuarios necesita la clave de servicio, que no puede viajar al navegador.

**Sin moderación de chat ni antifraude.** Son necesarios en producción real,
irrelevantes en una demo de portfolio.

## 5. Qué habría que hacer para volverlo un producto real

En orden de importancia:

1. **Cobro real.** Integración con Mercado Pago o Stripe, con webhook y backend
   que confirme los pagos. Hoy la confirmación la manda el propio navegador del
   comprador, lo que en producción sería trivialmente falsificable.
2. **Servidor de video (SFU).** Sin esto el techo son 3 espectadores. Es el
   límite duro que impide cualquier uso comercial.
3. **Persistencia real.** Catálogo, conversaciones y pedidos en base de datos,
   no en el navegador.
4. **Cuentas de vendedor.** Sin login, cualquiera puede abrir cualquier consola.
5. **Servidor TURN.** Para cerrar el 15-20% de conexiones de video que fallan.

Los puntos 1 y 2 son los que separan una demo de un producto que cobra dinero.

---

# PARTE II — ARQUITECTURA TÉCNICA

## 6. Panorama general

Tres páginas HTML autocontenidas, sin build, sin framework, sin backend propio.

| Archivo | Tamaño | Rol |
|---|---|---|
| `liveshop/index.html` | ~42 KB | Vista del comprador |
| `liveshop/host/index.html` | ~54 KB | Consola del vendedor |
| `liveshop/pago/index.html` | ~10 KB | Checkout simulado |

Cada archivo lleva su HTML, su CSS y su JavaScript adentro. La única dependencia
externa es la librería de Supabase, cargada por CDN.

**Por qué sin framework:** para tres pantallas, React agregaría un paso de
compilación, un árbol de dependencias que envejece, y una carpeta de librerías
de cientos de megas. El costo de mantenimiento superaría el beneficio. Además,
que cada página sea un archivo que se abre y funciona es en sí mismo parte de lo
que la demo muestra.

## 7. Cómo viaja el video: WebRTC

El video va **punto a punto** entre el navegador del vendedor y el de cada
comprador. No pasa por ningún servidor.

Para conectarse, dos navegadores necesitan primero encontrarse e intercambiar
información sobre cómo alcanzarse. Ese intercambio se llama **señalización** y
en este proyecto viaja por Supabase (ver sección siguiente).

La secuencia es:

1. El comprador entra y anuncia su presencia (`hello`).
2. El vendedor, si está transmitiendo, crea una conexión y manda una **oferta**
   (`signal` / `offer`).
3. El comprador responde con una **respuesta** (`signal` / `answer`).
4. Ambos intercambian **candidatos ICE** (`signal` / `ice`): las distintas
   direcciones por las que podrían alcanzarse.
5. Si alguna funciona, el video empieza a fluir directamente.

Se usan los servidores **STUN** públicos de Google, que solo le dicen a cada
navegador cuál es su dirección vista desde afuera. No hay **TURN**, que sería el
intermediario para cuando la conexión directa es imposible.

**La topología es en malla:** el vendedor abre una conexión independiente por
cada espectador y manda una copia del video a cada uno. Esto es lo que impone el
límite de 3 espectadores (sección 15).

## 8. Cómo viajan los mensajes: Supabase Realtime

Todo lo que no es video va por un canal de Supabase Realtime llamado
`liveshop:<sala>`. Se usan dos mecanismos.

**Broadcast** — mensajes dirigidos. Los eventos son:

| Evento | Dirección | Contenido |
|---|---|---|
| `hello` | comprador → vendedor | Anuncia que entró un comprador |
| `state` | vendedor → comprador | Título, catálogo, producto destacado, si está en vivo |
| `signal` | ambas | Negociación WebRTC: `offer`, `answer`, `ice`, `bye`, `leave`, `full` |
| `chat` | ambas | Mensajes: `text`, `buy`, `payment`, `system` |
| `paid` | checkout → ambos | Confirmación de pago |

El ruteo es por convención: cada mensaje lleva un campo `to`. El vendedor
escucha los que van a `"host"`; cada comprador, los que llevan su identificador.

**Presence** — quién está conectado. Cada participante se registra con un rol
(`host` o `buyer`). De ahí salen el contador de espectadores, la detección de si
hay vendedor en línea, y el estado en línea/desconectado de cada comprador.

> **Detalle crítico:** el canal debe declarar `presence: { enabled: true }`. Sin
> ese flag, Supabase acepta el registro pero nunca emite eventos de presencia.
> Esto causó el bug más grave del proyecto (sección 12.1).

## 9. Dónde vive cada dato

| Dato | Dónde | Alcance |
|---|---|---|
| Cuentas de vendedor y admin | `liveshop_vendedores` (Postgres) | Permanente |
| Catálogo, título, destacado | `liveshop_productos` + `liveshop_vendedores` | Permanente, por vendedor |
| Sala del vendedor | columna `sala` de `liveshop_vendedores` | Fija; la cambia el vendedor |
| Conversaciones | `liveshop_conversaciones` | Por vendedor, últimas 100 |
| Métricas | `liveshop_eventos` + `liveshop_pagos` | Por vendedor |
| Sesión del vendedor | token en `localStorage` (`liveshop_token`); hash en `liveshop_sesiones` | 7 días |
| Quién está en vivo | presencia del canal `liveshop:lobby` | Mientras dure la transmisión |
| Identidad y nombre del comprador | `sessionStorage` | Dura lo que la pestaña |
| Aviso de pago entre pestañas | `localStorage` | Efímero |

**Por qué `sessionStorage` del lado del comprador:** cada pestaña es un
comprador distinto. Si fuera `localStorage`, dos pestañas del mismo navegador
compartirían identidad y colisionarían en la sala.

## 10. El modelo de salas

Cada vendedor tiene **una sola sala, fija**: un código único (por defecto, su
usuario) que forma su link público `/liveshop/?live=<sala>`. El vendedor puede
cambiar el código desde *Mi cuenta*; el link viejo deja de funcionar.

*(Modelo anterior, reemplazado: cada visitante generaba una sala aleatoria tipo
`s7als01` y la pasaba a la consola por URL. Aislaba visitantes, pero no permite
un link estable por tienda ni un directorio.)*

El riesgo que el modelo aleatorio evitaba — dos personas operando la misma sala —
reaparece con la cuenta demo compartida. Se resuelve con la regla "una transmisión
por cuenta" (sección 26).

## 11. Modo demo

Si a los 3 segundos el vendedor de la sala no está conectado, o si el canal de
tiempo real falla, el comprador ve el **catálogo guardado de ese vendedor** (leído
de la base con `liveshop_sala`) y un aviso de que no está transmitiendo. En la sala
de la cuenta demo, el aviso ofrece entrar como vendedor.

**Por qué existe:** el 99% de las visitas a un portfolio llegan cuando nadie está
transmitiendo; una sala vacía no cuenta nada.

*(Antes se mostraba un catálogo de ejemplo fijo, la constante `SEED`, duplicado en
dos páginas. Ya no existe en el frontend: el catálogo de ejemplo vive solo en la
función SQL `liveshop__seed_catalogo`.)*

---

# PARTE III — HISTORIA DEL TRABAJO

## 12. Estado inicial y qué se encontró

El proyecto existía como commit `a6880d6` pero **nunca se había subido** y
**nunca había funcionado**. Además, el proyecto de Supabase estaba pausado, lo
que también tenía caída la demo de Hotelia.

### 12.1 El bug que impedía todo: presencia deshabilitada

**Síntoma:** el video nunca se establecía.

**Causa raíz:** el canal no declaraba `presence: { enabled: true }`. Las
versiones actuales del Realtime de Supabase aceptan el registro de presencia y
devuelven `ok`, pero no emiten ningún evento si falta ese flag.

**Por qué era fatal:** la consola del vendedor usa la presencia para saber qué
compradores siguen conectados. Con el estado siempre vacío, marcaba a todos como
desconectados en la primera sincronización y cerraba sus conexiones de video.
Cada comprador era desconectado apenas entraba.

**Cómo se detectó:** ejecutando el protocolo real contra el Supabase de
producción desde Node. El registro devolvía `ok` pero el estado de presencia
volvía vacío. Se confirmó la causa probando el mismo código con el flag agregado.

**Corrección:** commit `8e54e0e`.

### 12.2 El hueco de producto: la demo estaba vacía

**Síntoma:** cualquier visitante veía una grilla vacía y "Esperando al
vendedor…".

**Causa:** el catálogo vivía solo en el navegador del vendedor.

**Corrección:** modo demo con catálogo semilla (sección 11). Commit `8e54e0e`.

### 12.3 Infraestructura: Supabase se apaga solo

**Síntoma:** el proyecto de Supabase estaba pausado y la demo no funcionaba.

**Causa:** el plan gratuito apaga proyectos tras 7 días sin actividad.

**Corrección:** se restauró el proyecto y se agregó una tarea programada de
GitHub Actions que le manda una consulta diaria. Commit `17e5b09`.

## 13. Revisión de producto y las once mejoras

Después de que la demo funcionara, se hizo una evaluación con criterio de
producto. El criterio de priorización fue: *¿esto rompe la experiencia de un
desconocido que llega desde el portfolio?*

### P0 — Rompían la demo

**Sala compartida entre visitantes.** Todos caían en la sala `"demo"`. Dos
personas probando simultáneamente compartían vendedor; si ambas abrían la
consola, cada una recibía los mensajes dirigidos al vendedor de la otra. Se
corrigió con el modelo de salas de la sección 10.

**Chat sin contexto de producto.** Al tocar el botón se abría el chat sin
indicar por cuál producto. Se agregó una barra fija con miniatura, nombre y
precio.

**El vendedor cobraba el producto equivocado.** La consola guardaba solo la
última consulta (`lastProduct`). Un comprador que preguntaba por tres productos
recibía el link de pago del último, y el vendedor no tenía forma de notarlo.
Ahora se acumulan todas las consultas y el modal de pago tiene un selector.

**El chat se borraba al conectarse el vendedor.** `exitDemoMode()` limpiaba el
cuerpo del chat. Ahora conserva los mensajes y reenvía la consulta pendiente.

### P1 — Rompían la ilusión de producto real

**El botón decía "Comprar" y no compraba.** Pasó a "Lo quiero".

**El stock no bajaba al pagar.** Ahora se descuenta y se rebota el catálogo
actualizado a todos los compradores.

**Recargar perdía todo.** El comprador se convertía en una persona nueva y su
link de pago quedaba huérfano; el vendedor perdía todas las conversaciones.
Ahora ambas identidades y el estado persisten.

**La consola no avisaba mensajes nuevos.** Se agregó un tono corto y el título
de la pestaña parpadeando.

### P2 — Escala y medición

**Límite de espectadores de 6 a 3.** Ver sección 15.

**Métricas de uso.** Ver sección 17.

**Nombre del comprador.** Se pide dentro del chat, sin bloquear la entrada.

Todo esto es el commit `4b8ae25`.

## 14. El bug del retorno tras pagar

**Síntoma reportado:** después de pagar, no volvía correctamente a la
transmisión.

**Dos causas encadenadas:**

La primera: el link de la tarjeta de pago llevaba `rel="noopener"`, y además
`target="_blank"` ya implica *noopener* en los navegadores actuales. La pestaña
del checkout no tenía referencia a la pestaña del live y no podía devolverle el
foco.

La segunda, más grave: la pantalla de éxito ofrecía un link "volver al live"
apuntando a `/liveshop/` **sin la sala**. Al navegar ahí, la pestaña del checkout
cargaba una segunda vista del live y, al heredar el `sessionStorage` de la
pestaña que la abrió, revivía la misma identidad de comprador. El resultado eran
dos pestañas reclamando el mismo comprador en la misma sala, con colisión de
presencia y conexiones duplicadas.

**Corrección:** el checkout se abre por script con nombre fijo, lo que conserva
la referencia a la pestaña de origen y evita acumular pestañas. Al confirmarse
el pago, devuelve el foco y se cierra. Si el navegador bloquea el cierre, muestra
un aviso en lugar de un link — navegar sería justamente el bug. El link solo
aparece cuando no hay pestaña de origen, y en ese caso ya lleva la sala.

De paso se eliminó una dependencia de `CSS.escape` en el marcado del pago: una
excepción ahí dejaba al comprador sin ver nunca su pago confirmado.

Commit `8cc2518`.

## 15. La decisión del límite de espectadores

Se bajó de 6 a 3.

**El razonamiento:** en topología de malla, el vendedor manda una copia del video
a cada espectador desde su propia conexión. A 720p son unos 2 Mbps por
espectador. Con 6 son 12 Mbps de subida sostenida, más de lo que da una conexión
hogareña típica en la región. El resultado no habría sido "6 espectadores": habría
sido video degradado o cortado para los 6.

**Por qué se documenta en la interfaz:** el texto de la consola explica la
topología y aclara que escalar más allá requiere un SFU, no más ancho de banda.
Un límite explicado comunica criterio técnico. Un número inflado que falla en la
práctica comunica lo contrario.

---

# PARTE IV — INFRAESTRUCTURA Y OPERACIÓN

## 16. Servicios y costos

| Servicio | Uso | Plan | Costo |
|---|---|---|---|
| GitHub Pages | Alojamiento de las tres páginas | Gratuito | $0 |
| Supabase | Realtime + tabla de analítica | Gratuito | $0 |
| STUN de Google | Descubrimiento de direcciones | Público | $0 |
| GitHub Actions | Tarea diaria anti-pausa | Gratuito | $0 |

**Costo total de operación: cero.**

**Proyecto de Supabase:** `myebxfostbafuogfymqa`, región `us-west-1`, nombre
"HotelIA". Está compartido con la demo de Hotelia — si se pausa o se rompe,
**caen las dos demos**.

**Dominio:** `facundobolani.com`, con certificado HTTPS gestionado por GitHub.

## 17. Analítica

**Tabla:** `public.analytics_events` en Supabase. Compartida con Hotelia; los
eventos de LiveShop se distinguen por el prefijo `liveshop_`.

**Eventos que se registran:**

`liveshop_join` · `liveshop_host_open` · `liveshop_go_live` ·
`liveshop_stop_live` · `liveshop_buy_click` · `liveshop_paylink_sent` ·
`liveshop_paylink_received` · `liveshop_paid` · `liveshop_webrtc_ok` ·
`liveshop_webrtc_fallback` · `liveshop_demo_mode`

**Cómo se leen:** por la función `public.liveshop_overview(days)`, que devuelve
solo totales agregados.

**Por qué una función y no lectura directa:** para mostrar métricas habría que
darle permiso de lectura al rol anónimo sobre la tabla, lo que haría públicos
todos los eventos individuales. La función es `SECURITY DEFINER`: lee la tabla
con permisos elevados pero solo devuelve sumas. Se verificó que la lectura
directa de la tabla sigue devolviendo vacío.

**Qué no se guarda:** ningún dato personal. Ni nombres, ni contenido de
mensajes, ni direcciones IP.

## 18. La tarea anti-pausa

Archivo: `.github/workflows/keep-supabase-awake.yml` (en el repo FBC91.github.io, no en este)

Corre todos los días a las 06:17 UTC y hace una consulta a la API de Supabase.
También se puede ejecutar a mano desde la pestaña Actions del repositorio.

Si falla, es señal de que el proyecto se pausó o cambió la clave. Falla ruidosa a
propósito: un ping silencioso que no avisa no sirve de nada.

**Nota:** subir este archivo requiere que el token de GitHub tenga el permiso
`workflow`, además de `repo`.

## 19. Despliegue

No hay proceso de build. Se edita el HTML, se commitea y se hace push a `main`.
GitHub Pages reconstruye el sitio en uno o dos minutos.

Para verificar que un cambio llegó a producción, se puede consultar el estado de
la última construcción con la API de GitHub y confirmar que el hash del commit
coincida.

## 20. Sobre las claves

La clave de Supabase que aparece en el código es la **clave anónima**, diseñada
para viajar en el navegador. No es un secreto: cualquiera que abra el código
fuente de la página la ve. Su seguridad depende de las políticas de acceso de la
base, no de ocultarla.

Las políticas actuales sobre `analytics_events` permiten insertar pero **no
leer**. Por eso las métricas van por la función de agregados.

**Advertencia histórica:** el repositorio tuvo tokens personales de GitHub
incrustados en la URL del remoto, lo que los dejaba escritos en `.git/config`.
Se limpió el remoto y la autenticación ahora usa el almacén de credenciales del
sistema. **Los tokens viejos deberían revocarse** en la configuración de GitHub
si no se hizo ya.

---

# PARTE V — CALIDAD Y VERIFICACIÓN

## 21. Cómo se verificó cada cosa

No hay suite de tests en el repositorio. La verificación se hizo con scripts
temporales, que se describen acá para que se puedan reconstruir.

**Protocolo completo contra el Supabase real.** Un script en Node que simula
vendedor, comprador y checkout como tres clientes independientes, y verifica
diez pasos: entrada del comprador, envío del catálogo, oferta y respuesta de
video, chat en ambas direcciones, link de pago, confirmación vista por las dos
puntas, y presencia en ambos sentidos. Los diez pasaron.

**Carga real de las páginas.** Ambas páginas cargadas en un DOM simulado con
Supabase y WebRTC falsos, ejercitando los caminos nuevos: render del catálogo,
clic en producto, aparición de la barra de contexto con el producto correcto,
pedido de nombre, alta del comprador en la consola, las consultas apareciendo en
el selector de pago, y la pestaña de métricas.

**Aislamiento de salas.** Tres instancias en paralelo verificando que dos
visitantes obtienen salas distintas, que se respeta la sala de la URL, y que los
tres links de la página la propagan.

**Ciclo de pago.** Verificación de que el checkout se abre por script con la sala
correcta, que la tarjeta queda marcada como pagada, que el chat se abre solo,
que se devuelve el foco a la pestaña de origen y que la pestaña del checkout se
cierra.

**Chequeos estáticos.** Validación de sintaxis de todo el JavaScript, y
verificación de que cada elemento referenciado por el código existe en el HTML.

**Lo que NO se verificó automáticamente:** el video real entre dos navegadores
con cámaras reales. Se confirmó manualmente por el autor con un segundo
participante, y quedó registro en la analítica (eventos `liveshop_webrtc_ok`).

## 22. Riesgos conocidos

**Alto — dependencia compartida.** El proyecto de Supabase es el mismo que usa
Hotelia. Si se pausa, se borra o se agota su cuota, caen las dos demos.

**Medio — credenciales demo públicas.** `admin`/`admin` deja ver las métricas
(visitas y facturación simulada) de todos los vendedores registrados. Es
intencional para el portfolio y se advierte en el registro, pero en un producto
real esa cuenta no debe existir.

**Medio — el catálogo se reemplaza completo.** Guardar el catálogo borra e
inserta todos los productos. Si entre dos guardados se registra un pago, el stock
descontado puede pisarse con el valor viejo. La ventana es de menos de un
segundo y solo con dos consolas de la misma cuenta editando a la vez.

**Medio — confirmación de pago falsificable.** La confirmación la emite el
navegador del comprador. En una demo sin dinero real es irrelevante; en
producción sería una vulnerabilidad crítica.

**Bajo — el límite de tamaño del catálogo.** Las fotos viajan dentro del mensaje
de estado, que tiene un tope cercano a 256 KB. La consola avisa antes de
llegar, pero si alguien ignora el aviso, los compradores dejan de recibir el
catálogo.

**Bajo — peso del directorio.** `liveshop_directorio` devuelve hasta 48 tiendas
con 10 productos cada una, fotos incluidas como data URL. Con muchas tiendas con
fotos, la portada se vuelve pesada. La mejora es mover las fotos a Supabase
Storage.

## 23. Trabajo pendiente

**Aplicar `sql/002_ventas_reportes_ofertas.sql` en Supabase ANTES de publicar el
frontend de la Parte VIII** (ver §35). Si la 001 tampoco está aplicada, va
primero.

**Aplicar `sql/001_cuentas_vendedor.sql` en Supabase ANTES de publicar el
frontend nuevo.** Sin esas tablas y funciones, las páginas nuevas no cargan
catálogos, no permiten login y el directorio queda vacío. Ver sección 28.

**TURN.** Lo único del plan de mejoras que quedó sin hacer, porque requiere
contratar el servicio. Cerraría el 15-20% de conexiones de video que fallan.
Metered.ca tiene un nivel gratuito de 50 GB al mes. Las credenciales van en la
constante `TURN_SERVERS`, que está vacía y preparada en las dos páginas.

**Revocar los tokens viejos de GitHub** (ver sección 20).

---

# PARTE VI — PREGUNTAS ANTICIPADAS

**¿Por qué no usaste un framework?**
Ver sección 6. Para tres pantallas el mantenimiento superaría el beneficio, y
que cada página sea autocontenida es parte de lo que la demo muestra.

**¿Por qué WebRTC y no un servicio de streaming?**
Costo cero y menor latencia. En una venta en vivo, tres segundos de retraso
arruinan la conversación. El precio es el límite de 3 espectadores.

**¿Por qué solo 3 espectadores?**
Ver sección 15. Es el límite honesto de la topología en malla sobre una conexión
hogareña. Subirlo sin un SFU daría video roto, no más espectadores.

**¿Cómo escalarías esto?**
Un SFU: el vendedor manda el video una sola vez al servidor y este lo reparte.
Cambia el costo de infraestructura de cero a un gasto mensual, que es
exactamente el punto en el que esto deja de ser una demo.

**¿El pago es real?**
No. Ver sección 4.

**¿Qué pasa si se cae Supabase?**
Se cae el chat, el catálogo y la señalización del video. La página carga y entra
en modo demo con el catálogo de ejemplo, en lugar de quedar en blanco.

**¿Guardás datos personales?**
No. Ver sección 17.

**¿Cuánto cuesta operarlo?**
Cero. Ver sección 16.

**¿Cuál fue el bug más difícil?**
El de presencia (sección 12.1). Difícil porque no daba error: el registro
devolvía `ok`, el chat funcionaba y solo el video fallaba, lo que empujaba a
buscar el problema en WebRTC cuando estaba en la configuración del canal de
mensajería.

**¿Cómo sabés que funciona si no hay tests en el repo?**
Ver sección 21. La verificación se hizo con scripts contra el entorno real, no
con mocks del propio código. Un test suite permanente sería lo correcto para un
producto en evolución; para una demo cerrada, la verificación puntual documentada
es proporcional.

---

# PARTE VII — CUENTAS DE VENDEDOR (septiembre 2026)

## 24. Qué cambió

| Antes | Ahora |
|---|---|
| Sin login; cualquiera abría la consola | Vendedores con usuario y contraseña; el comprador sigue sin cuenta |
| Catálogo y chats en `localStorage` | En Postgres, por vendedor, desde cualquier dispositivo |
| Sala aleatoria por visitante | Una sala fija por vendedor, con link público y código editable |
| Portada = una sala | Portada = directorio: *En vivo ahora* + tiendas con carrusel de productos |
| Métricas globales del demo | Métricas por vendedor + panel de admin con totales y detalle |

Páginas nuevas: `vendedor/` (login y registro) y `admin/` (métricas). Archivo
compartido nuevo: `comun.js` (config de Supabase, cliente RPC, mensajes de error,
helpers). Migración: `sql/001_cuentas_vendedor.sql`.

## 25. Cuentas y la marca "protegido"

- **Registro público.** Cualquiera crea su cuenta de vendedor. Usuario de 3 a 24
  caracteres (`a-z0-9_-`), no se puede cambiar. Contraseña de 6 a 72, guardada con
  bcrypt (`crypt` + `gen_salt('bf')`).
- **Cada vendedor gestiona solo su cuenta:** nombre, foto, código de sala,
  contraseña (pide la actual y cierra las demás sesiones) y borrado (pide la
  contraseña y escribir el usuario; borra en cascada catálogo, chats y métricas).
- **Cuentas demo:** `Vendedor`/`Vendedor` (rol vendedor) y `admin`/`admin` (rol admin).
- **`protegido`** es una columna booleana que tienen en `true` solo esas dos
  cuentas. Las funciones de la base, no la interfaz, rechazan con
  `LS:cuenta_protegida`: borrar la cuenta, cambiar la contraseña y cambiar la
  sala. Sí se permite editar nombre, foto y catálogo. La tienda demo además puede
  llamar a `liveshop_catalogo_restaurar_demo`.
- **Reset diario:** `liveshop__reset_demo()` vuelve a poner las contraseñas
  públicas y la marca de protegida. Lo programa `pg_cron` a las 06:17 UTC dentro de
  la misma migración. Si `pg_cron` no está habilitado, la migración lo avisa con
  un `NOTICE` y el resto funciona igual.
- **Usuarios reservados:** `admin`, `administrador`, `root`, `soporte`,
  `liveshop`, `vendedor`.

## 26. Una transmisión por cuenta

La consola publica su presencia en la sala con `{role:"host", live, since, hostId}`.

- Si otra consola de la misma cuenta está en vivo, esta queda **pasiva**: no
  responde `hello`, no emite `state`, no cuenta mensajes en métricas, y el botón de
  transmitir queda deshabilitado con un aviso. Sí ve chats y edita el catálogo.
- `goLive` vuelve a chequear después del permiso de cámara, que puede tardar.
- Si dos consolas salen en vivo casi a la vez, en el siguiente `sync` la que tiene
  `since` mayor se baja sola y lo avisa.
- Los pagos se registran por `ref` con `on conflict do nothing`: aunque dos
  consolas reciban el mismo `paid`, el stock baja una sola vez.

## 27. Directorio y lobby

- Canal de presencia global `liveshop:lobby`. La consola, solo mientras transmite,
  hace `track({sala, usuario, nombre, titulo, viewers, max, since})` y `untrack`
  al cortar. Si se cierra la pestaña, Supabase la saca sola.
- La portada escucha el lobby y cruza con `liveshop_directorio()` (hasta 48
  tiendas, 10 productos cada una) para las fotos. Si aparece en vivo una sala que
  no está en la lista (tienda recién creada), recarga el directorio, como máximo
  cada 15 s.
- Carrusel: la pista contiene la lista dos veces y se desplaza −50% en loop. Se
  pausa con hover. Con `prefers-reduced-motion` pasa a una fila con scroll manual
  sin duplicados.

## 28. Base de datos: modelo de acceso e instalación

**Modelo.** Todas las tablas `liveshop_*` tienen RLS activo y **ninguna
política**, y se les revocan permisos a `anon` y `authenticated`. La única puerta
son funciones `SECURITY DEFINER`:

| Pública (sin token) | Con token de vendedor | Solo admin |
|---|---|---|
| `liveshop_registrar`, `liveshop_login`, `liveshop_directorio`, `liveshop_sala`, `liveshop_evento` | `liveshop_yo`, `liveshop_logout`, `liveshop_cuenta_editar`, `liveshop_cuenta_borrar`, `liveshop_catalogo_guardar`, `liveshop_catalogo_restaurar_demo`, `liveshop_conversaciones_guardar`, `liveshop_evento_host`, `liveshop_pago_registrar`, `liveshop_metricas` | `liveshop_metricas_admin` |

Los helpers `liveshop__*` (doble guion bajo) no tienen permiso de ejecución para
`anon`. Es crítico: `liveshop__cuenta` devuelve la fila con el hash y
`liveshop__reset_demo` resetea cuentas. El bloque final de permisos los revoca
explícitamente, porque Supabase da `EXECUTE` a `anon` sobre toda función nueva.

- **Tokens:** 32 bytes aleatorios; en la base se guarda solo su SHA-256. Vencen a
  los 7 días.
- **Límite de intentos:** login, 8 fallos cada 15 minutos por IP+usuario (con la
  IP incluida, un visitante no bloquea la cuenta demo para los demás). Registro, 5
  por hora por IP. La IP sale de `cf-connecting-ip` o `x-forwarded-for` de
  `request.headers`.
- **Errores:** las funciones fallan con `LS:<codigo>`; login y registro devuelven
  `{ok:false, error}` para que el intento fallido quede grabado (un `raise`
  desharía el insert del limitador). `comun.js` traduce los códigos a mensajes.
- **Métricas:** eventos del comprador (`entrada`, `interes`, `video_ok`,
  `video_falla`) son públicos y se asocian por sala. `entrada` y `video_ok` se
  deduplican por sesión cada 30 minutos. Los eventos del vendedor (`transmision`,
  `mensaje`, `link_pago`, `pico`) y los pagos requieren token. El facturado sale de
  `liveshop_pagos`, no de eventos. `analytics_events` y `liveshop_overview` siguen
  funcionando igual que antes, para el uso global del demo.

**Instalación.** La sesión de trabajo no tenía acceso de escritura a Supabase:
solo la clave anónima, que no ejecuta SQL. Pasos:

1. Supabase → proyecto `myebxfostbafuogfymqa` → SQL Editor → pegar y ejecutar
   `liveshop/sql/001_cuentas_vendedor.sql` completo. Es idempotente.
2. Si aparece el `NOTICE` de `pg_cron`: Database → Extensions → habilitar
   `pg_cron` y volver a ejecutar el último bloque `do $$ … cron.schedule … $$`.
3. Recién después, hacer push del frontend a `main`.

## 29. Cómo se verificó

Sin acceso a Supabase, se verificó contra un Postgres real embebido (PGlite, con
pgcrypto), con los mismos roles `anon` y `authenticated`:

- **SQL (57 checks):** la migración aplicada dos veces (idempotencia); `anon` no
  lee ni escribe tablas ni ejecuta helpers; login demo y admin; cuentas
  protegidas; registro con validaciones y usuarios reservados; aislamiento de
  catálogo, stock y chats entre vendedores; catálogo inválido que no borra el
  anterior; pago idempotente y stock que no baja de 0; métricas por vendedor y de
  admin; cambio de contraseña que cierra otras sesiones; borrado en cascada;
  límite de intentos por IP; reset diario.
- **Páginas (50 checks):** las cinco páginas reales cargadas en jsdom, con las RPC
  contra ese Postgres y un bus de Realtime en memoria compartido entre ventanas.
  Cubre login y registro; boot de consola; producto persistido; directorio con
  carrusel; live que aparece y desaparece del directorio; segunda consola
  bloqueada y habilitada al cortar la primera; comprador que recibe estado,
  consulta con producto, conversación persistida, link de pago, pago que descuenta
  stock una sola vez y catálogo actualizado; sala inexistente; restaurar demo;
  cambio de perfil y de sala, con rechazo de sala ajena; panel admin con totales,
  gráfico, tabla y detalle; vendedor común rechazado en admin; borrado de cuenta;
  token vencido. Sin errores de JavaScript.

**No verificado:** el comportamiento contra el Supabase real (encabezados de IP,
`pg_cron`, permisos por defecto del proyecto) y el video entre dos navegadores
reales. Conviene repetir el flujo a mano después de instalar.

---

# PARTE VIII — VENTAS, REPORTES Y OFERTAS (octubre 2026)

## 30. Qué cambió

| Antes | Ahora |
|---|---|
| La consola armaba el link de pago con el monto y lo mandaba por URL al checkout | La base crea una **orden** (`liveshop_orden_crear`) con el precio de lista menos la promo vigente; el checkout lee la orden (`liveshop_orden_ver`) y la paga (`liveshop_orden_pagar`) |
| El pago lo registraba la consola al recibir `paid`: con la pestaña cerrada, la venta se perdía | El pago se registra desde el checkout; el broadcast `paid` solo actualiza las pantallas |
| `liveshop_pagos` con `producto_id` y `monto` | `liveshop_ordenes` con copia del producto, comprador, precio de lista, descuento, promo, cupón, live y estado (`pendiente`, `pagada`, `anulada`, `vencida` a las 24 h). Los pagos viejos se migran |
| El evento `interes` no decía qué producto | `interes` y el nuevo `vista_producto` guardan `producto_id` |
| Un live era solo un evento `transmision` | `liveshop_lives`: inicio, fin, pico; cada orden sabe en qué live se creó |
| Pestaña Métricas con contadores | Pestañas **Ventas** (`host/ventas.js`) y **Reportes** (`host/reportes.js`) |
| Sin ofertas | `liveshop_promos`: descuento, remanente (liquidación), relámpago y cupón (`host/ofertas.js`) |
| Productos sin categoría | Categoría de una lista cerrada, descripción (≤280) y costo privado |
| Catálogo de la sala sin filtros | Búsqueda, categorías, orden, "solo con stock", ficha, favoritos y Mis compras; en el directorio, búsqueda entre tiendas y "Ofertas ahora" |
| Días en UTC | Días en `America/Montevideo` |

Archivos nuevos: `sql/002_ventas_reportes_ofertas.sql`, `host/ofertas.js`,
`host/ventas.js`, `host/reportes.js`, `pago/comprobante.html`. Los tres módulos de
la consola son scripts clásicos (sin build) que se cargan antes del script
principal y usan sus helpers recién cuando se los llama.

## 31. Precios y promos: las reglas

- **El precio que se cobra lo calcula siempre la base** (`liveshop__aplicar`:
  `round(lista × (100 − pct) / 100)` o el precio fijo). El navegador usa la misma
  fórmula (`LS.aplicar`) solo para mostrar.
- **Una promo de producto abierta por producto** (índice único parcial). Crear
  otra con `p_reemplazar` cierra la anterior; sin él, `LS:promo_existente`.
- **El link respeta el precio con que se creó**, aunque la promo termine antes de
  que se pague (el link vence a las 24 h).
- **Tope de unidades** de la relámpago: se cuenta al pagar; al llegar, la promo se
  cierra sola. Links creados durante la promo y pagados después del tope igual
  pagan el precio rebajado: es una decisión, para no cambiarle el precio a quien
  ya tenía el link.
- **Cupón:** atado al live (`live_id`), se cierra al terminar la transmisión (o al
  iniciar la siguiente si la pestaña se cerró sin terminar). Se aplica sobre el
  precio ya rebajado, con tope total de 50% sobre el de lista.
- **Promos vencidas** quedan con `terminada_at` nulo hasta que alguna función de
  la consola las cierra (`liveshop__cerrar_promos`); todas las lecturas usan
  `liveshop__promo_vigente`, así que nunca se muestran ni se aplican.
- **Costo** nunca sale por una función pública: `liveshop__catalogo_json` solo lo
  incluye con `p_privado`, y la consola lo saca del `state` que transmite.

## 32. Funciones nuevas

| Pública (sin token) | Con token de vendedor |
|---|---|
| `liveshop_orden_ver`, `liveshop_orden_pagar`, `liveshop_ofertas`, `liveshop_buscar` | `liveshop_orden_crear`, `liveshop_orden_estado`, `liveshop_orden_anular`, `liveshop_ventas`, `liveshop_reporte_resumen`, `liveshop_reporte_productos`, `liveshop_reporte_producto`, `liveshop_reporte_lives`, `liveshop_promo_crear`, `liveshop_promo_terminar`, `liveshop_promos`, `liveshop_live_iniciar`, `liveshop_live_terminar` |

Reescritas: `liveshop_yo` (suma `promos` y `ahora`), `liveshop_sala` (suma
`ahora`; productos con precio final, de lista y promo), `liveshop_directorio`,
`liveshop_catalogo_guardar` (categoría, descripción, costo; conserva
`creado_at`; cierra la promo de un producto borrado), `liveshop_evento` (cuarto
parámetro opcional `p_producto_id`), `liveshop_evento_host` (el pico también va al
live abierto), `liveshop_metricas` y `liveshop_metricas_admin` (leen de órdenes;
la de admin suma `p_sin_demo` y `descuentos`), `liveshop_pago_registrar` (queda
por compatibilidad con consolas viejas en caché), `liveshop__reset_demo` y
`liveshop_catalogo_restaurar_demo` (restauran catálogo e historia).

**Firmas que cambiaron:** se borran `liveshop_evento(text,text,text)`,
`liveshop_metricas_admin(text,int)` y `liveshop__metricas(timestamptz)`. Si alguien
vuelve a correr la 001, las recrea y PostgREST encuentra dos candidatas: **después
de la 001 siempre hay que volver a correr la 002.**

## 33. Sugerencias de Reportes

`liveshop__sugerencias` devuelve hasta 6, ordenadas por plata en juego; la consola
muestra 3 y cada una se puede descartar 7 días (en `localStorage`,
`liveshop_sug_<usuario>`).

| Tipo | Regla | Acción en la consola |
|---|---|---|
| `reponer` | stock 0 y ≥ 3 pedidos en 14 días | Edita el producto con el foco en el stock |
| `liquidar` | stock > 0, ≥ 14 días de alta, sin venta en 30 días, sin promo | Abre la oferta en modo liquidación (en lote si hay varios) |
| `ultimas` | stock 1–3 y ≥ 1 venta en 7 días | Lo destaca |
| `precio` | ≥ 5 pedidos y 0 ventas en 14 días | Edita el producto con el foco en el precio |
| `cobrar` | hay links pendientes | Abre Ventas filtrado por pendientes |

## 34. Historia de ejemplo

`liveshop__seed_historial` (la llaman el reset diario y "Restaurar catálogo
demo") borra y regenera todo lo marcado `demo` de la tienda demo: ~20 lives en 60
días (jueves y domingos a la noche, más algunos sueltos), entradas, pedidos,
vistas, órdenes pagadas y vencidas, una relámpago con su resultado, un descuento
vigente en lentes, el reloj quieto hace 34 días, la mochila agotada con pedidos,
la campera que se pide y no se vende y 3 links pendientes de hoy. Usa una semilla
fija por día: dos visitantes ven lo mismo. Las ventas reales de visitantes en la
cuenta demo no se tocan. El catálogo demo pasa a tener 8 productos con categoría,
descripción y costo, y se restaura en el reset diario.

## 35. Instalación

1. Supabase → proyecto `myebxfostbafuogfymqa` → SQL Editor → pegar y ejecutar
   `sql/002_ventas_reportes_ofertas.sql` completo. Requiere la 001 aplicada. Es
   idempotente.
2. Recién después, publicar el frontend (merge a `main`). Un frontend nuevo con la
   base vieja falla al crear links de pago y al abrir Ventas/Reportes; la base nueva
   con el frontend viejo sigue funcionando (por eso el orden).
3. Links de pago enviados antes del cambio (sin orden en la base) dejan de poder
   pagarse: el checkout dice que no encuentra el link y pide uno nuevo.

## 36. Cómo se verificó

Mismo método que la Parte VII, con PGlite y jsdom:

- **SQL (103 checks):** migración sobre una base con pagos viejos (se migran) y
  aplicada dos veces; `anon` no lee tablas nuevas ni ejecuta helpers; firmas viejas
  siguen respondiendo; órdenes (precio de la base, manual, inexistente, de otra
  sala, pago idempotente, anulada, vencida a las 24 h, stock que no baja de 0);
  promos (rangos, no se apilan, reemplazo, precio respetado después del fin, tope
  que cierra la relámpago, vencida que no bloquea, cupón con tope 50%, cupón que
  muere con el live); live colgado que se cierra a las 6 h; eventos con producto y
  deduplicados; producto borrado que cierra su promo y sigue en el ranking;
  ganancia con y sin costo; ventas (totales iguales a métricas, paginado,
  búsqueda sin tildes, filtro, export, meses, aislamiento entre vendedores); día de
  Montevideo; sugerencias y lives de la demo; determinismo de la historia; venta
  real que sobrevive al reset; admin con y sin demo; búsqueda y ofertas públicas
  sin costo.
- **Páginas (107 checks):** consola, sala del comprador, checkout, comprobante,
  directorio y admin cargados a la vez con un bus de Realtime compartido. Recorre:
  filtros, búsqueda, orden, ficha, favoritos; salir en vivo, lanzar relámpago,
  banner con cuenta regresiva en el comprador, pedido en "Ahora en tu live", cupón,
  link de pago con desglose y sin monto en la URL, pago con cupón, stock que baja,
  orden con live y cupón en la base; pago con la consola cerrada; URL manipulada;
  comprobante e impresión; Ventas (KPIs, detalle, pendientes, anular en dos
  toques, CSV, búsqueda); Reportes (sugerencias y sus acciones, ranking, ficha,
  lives, mapa de calor, resultado de ofertas); oferta con aviso de costo, filtro
  "en oferta", liquidación en lote; producto nuevo con categoría y costo que no
  llega al comprador; terminar el live cierra el cupón; Mis compras; directorio
  con búsqueda, categoría, ofertas y guardados; `?p=` que abre la ficha; admin sin
  demo. Sin errores de JavaScript.
- **Pasada visual en Chrome (21 capturas, desktop 1360 px y mobile 390 px):** las
  mismas páginas con la RPC respondida desde PGlite y Realtime sobre
  `BroadcastChannel`, con cámara falsa. Corrigió: el reparto del descuento entre
  cupón y relámpago en el reporte de ofertas (columna `descuento_cupon`), la
  duración de las promos activas, "Octubre De 2026", el orden del directorio
  (ofertas debajo del live), el banner relámpago sobre el aviso de "no está
  transmitiendo" y las sugerencias apretadas en mobile. Sin errores de consola.

**No verificado:** contra el Supabase real, Safari/Firefox y el video real entre
dos personas.

## 37. Riesgos nuevos

- **Medio — el checkout es público:** quien conozca una ref puede marcarla como
  pagada. Las refs son 10 caracteres hexadecimales aleatorios. La solución real es
  el webhook del procesador de pagos.
- **Medio — catálogo "borrar e insertar":** sigue igual que en la §22; ahora
  conserva `creado_at` y el costo por id.
- **Bajo — reloj del comprador:** los contadores usan la hora del servidor que
  llega con la sala y con cada `state`.
- **Bajo — el reset diario restaura el catálogo de la tienda demo:** lo que un
  visitante le haya cargado se pierde a las 06:17 UTC.

---

# Glosario

**WebRTC** — Tecnología de los navegadores para mandar video y audio
directamente entre dos personas, sin servidor en el medio.

**Señalización** — El intercambio inicial que hacen dos navegadores para
encontrarse antes de conectarse directo.

**STUN** — Servicio que le dice a un navegador cuál es su dirección vista desde
afuera. Gratuito, provisto por Google.

**TURN** — Servidor intermediario que reenvía el video cuando la conexión directa
es imposible. De pago; hoy no está.

**SFU** — Servidor que recibe el video del emisor una sola vez y lo reparte a
todos los espectadores. Lo que permitiría escalar más allá de 3.

**Malla** — Topología donde el emisor abre una conexión por cada espectador.

**Broadcast** — Mensaje que se envía a todos los participantes de un canal.

**Presence** — Mecanismo que informa quién está conectado a un canal.

**Candidato ICE** — Cada una de las direcciones posibles por las que un navegador
podría ser alcanzado.

**RLS** — Reglas que definen qué filas de una tabla puede ver o modificar cada
tipo de usuario.

**SECURITY DEFINER** — Función de base de datos que se ejecuta con los permisos
de quien la creó, no de quien la llama. Permite exponer resultados agregados sin
dar acceso a los datos crudos.

**`localStorage` / `sessionStorage`** — Almacenamiento del navegador. El primero
persiste indefinidamente; el segundo dura lo que la pestaña.
