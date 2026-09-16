# LiveShop

Demo de *live shopping*: un vendedor transmite en vivo desde su cámara, muestra
productos, y los compradores le preguntan por chat y pagan sin salir de la
transmisión.

Está en vivo en **https://facundobolani.com/liveshop/**

Este documento está escrito para que alguien que no programa entienda qué hace
el producto, cómo funciona por dentro y por qué se tomó cada decisión.

---

## 1. Qué problema resuelve

El live shopping es vender por streaming: alguien muestra productos en vivo y la
gente compra en el momento. Funciona bien porque junta tres cosas que
normalmente están separadas — ver el producto, preguntar, y pagar.

El problema es que en la práctica esas tres cosas viven en lugares distintos. El
vendedor transmite por Instagram, responde por WhatsApp y cobra por
transferencia. Cada salto pierde compradores: el que tiene que abrir otra app
para preguntar, muchas veces no pregunta.

LiveShop mete las tres en la misma pantalla. Ves el video, tocás el producto, se
abre el chat con ese producto ya cargado, y el vendedor te manda un link de pago
ahí mismo.

---

## 2. Las pantallas

El producto son seis vistas. Cada una es una persona distinta en un momento
distinto.

| Pantalla | Quién la usa | Para qué |
|---|---|---|
| `/liveshop/` | El comprador | Ve qué tiendas están en vivo y recorre las demás |
| `/liveshop/?live=<sala>` | El comprador | Ve el video y el catálogo de una tienda, pregunta, paga |
| `/liveshop/vendedor/` | El vendedor | Ingresa o crea su cuenta |
| `/liveshop/host/` | El vendedor | Transmite, gestiona catálogo y cuenta, responde y cobra |
| `/liveshop/admin/` | El administrador | Ve las métricas de todos los vendedores |
| `/liveshop/pago/` | El comprador | Confirma el pago (simulado) |

**Para comprar no hace falta cuenta.** Solo los vendedores y el administrador
ingresan con usuario y contraseña.

### Cuentas de prueba

| Usuario | Contraseña | Qué es |
|---|---|---|
| `Vendedor` | `Vendedor` | Tienda demo pública, con catálogo de ejemplo |
| `admin` | `admin` | Administrador demo: solo ve métricas |

Las dos se restablecen todas las noches y están **protegidas**: no se pueden
borrar ni cambiar su contraseña (ni, en el caso de la tienda demo, su sala). La
tienda demo sí deja editar nombre, foto y catálogo, y tiene un botón para volver
al catálogo de ejemplo.

---

## 3. El flujo completo

**El vendedor ingresa a su consola.** Con la cuenta demo o con una propia que crea
en un minuto. Carga productos con nombre, precio, stock y una foto o un emoji: se
guardan en su cuenta, así que siguen ahí desde cualquier computadora. Toca "Iniciar
transmisión" y el navegador le pide permiso para usar la cámara. Desde ese momento
está transmitiendo.

**El comprador encuentra la tienda.** En la portada de LiveShop aparece arriba,
en *En vivo ahora*. Las tiendas que no están transmitiendo se muestran abajo con
su foto, su nombre y un carrusel de sus productos. El vendedor también puede
pasar directamente el link fijo de su sala.

**El comprador entra al live.** Ve el video, y debajo el catálogo con precios y
stock. El vendedor puede "destacar" un producto y en la pantalla del comprador
aparece marcado como *AHORA* — es el equivalente digital de levantar el producto
frente a la cámara.

**El comprador toca "Lo quiero".** Se abre el chat con ese producto fijado arriba:
miniatura, nombre y precio. El vendedor recibe el mensaje con el producto
adjunto, así que sabe exactamente de qué le están hablando sin preguntar.

**Conversan.** Consultas de talle, color, envío, lo que sea.

**El vendedor manda el link de pago.** Elige el producto de la lista de los que
esa persona consultó, confirma el monto, y le llega al comprador como una
tarjeta con un botón.

**El comprador paga.** Se abre el checkout en otra pestaña. Al confirmar, la
pestaña se cierra sola y lo devuelve a la transmisión, con el pago ya marcado
como acreditado en su chat. El vendedor ve la confirmación al instante y el
stock del producto baja solo.

> El checkout es **simulado**. No se pide ni se procesa ningún dato de tarjeta y
> no se mueve dinero real. Es una demo de portfolio, no una tienda.

---

## 4. Qué herramientas usa y por qué

### El video: WebRTC

WebRTC es una tecnología que ya viene incluida en todos los navegadores y permite
mandar video de una persona a otra **directamente**, sin pasar por un servidor
en el medio. Es lo mismo que usan Google Meet o Zoom por debajo.

*Por qué:* no hay que pagar ni mantener un servidor de video, que es la parte más
cara de cualquier producto de streaming. Y el video viaja más directo, así que
hay menos retraso — en una venta en vivo, que el vendedor conteste con tres
segundos de demora arruina la conversación.

*El costo:* al no haber un servidor en el medio, el vendedor manda una copia del
video a cada espectador desde su propia conexión. Con muchos espectadores, su
internet se satura. Ver la sección de límites.

### La mensajería: Supabase Realtime

Supabase es una plataforma que ofrece base de datos y mensajería en tiempo real.
Acá se usa para dos cosas.

La primera es el **chat y el catálogo**: todo lo que el vendedor y el comprador se
mandan viaja por ahí.

La segunda es menos obvia pero es la que hace posible el video. Para que dos
navegadores se conecten directo, primero tienen que *encontrarse* y ponerse de
acuerdo — como dos personas que quieren hablar por teléfono pero antes necesitan
intercambiar el número. Ese intercambio inicial se llama **señalización**, y
también va por Supabase.

*Por qué:* resuelve las dos necesidades con una sola herramienta, tiene plan
gratuito, y no hay que escribir ni mantener un servidor propio.

### Las cuentas y los datos: la base de Supabase

Vendedores, catálogos, conversaciones y métricas se guardan en la base de datos
de Supabase. La página nunca lee ni escribe las tablas directamente: le pide cada
cosa a una función de la base ("dame mi catálogo", "guardá este producto") que
primero comprueba quién está pidiendo.

*Por qué:* la clave que usa la página es pública — cualquiera puede verla en el
código. Si esa clave pudiera leer las tablas, cualquiera podría leer las
contraseñas o el catálogo de otro vendedor. Con las funciones como única puerta,
cada vendedor solo alcanza lo suyo. Las contraseñas se guardan cifradas de forma
que ni siquiera la base puede devolverlas.

### El alojamiento: GitHub Pages

Las tres páginas son archivos HTML que se publican gratis desde GitHub, con el
dominio propio `facundobolani.com`.

*Por qué:* costo cero, y al no haber servidor propio no hay nada que se caiga,
que actualizar ni que asegurar.

### Sin framework

No usa React ni ninguna librería de interfaz. Es HTML, CSS y JavaScript común.

*Por qué:* cada página es un archivo que se abre y funciona. No hay proceso
de compilación, ni dependencias que se rompan con el tiempo, ni carpeta de
librerías que pese cientos de megas. Para un producto de este tamaño, un
framework agregaría más mantenimiento que beneficio.

La única pieza compartida es `comun.js`: la conexión con la base y los mensajes de
error. Cuatro páginas hablando con las mismas funciones no podían tener cada una
su propia copia sin que tarde o temprano se desincronizaran.

### Lo que cuesta

Nada. Todo corre en planes gratuitos: GitHub Pages, Supabase, y los servidores
públicos de Google que ayudan a los navegadores a encontrarse.

---

## 5. Decisiones y sus porqués

### Cada vendedor tiene una sola sala, con link fijo

La sala es el código del link que el vendedor comparte (`?live=mi-tienda`). Es
siempre la misma: hoy vende zapatillas y mañana remeras, y sus compradores usan
el mismo link. Si quiere, puede cambiar el código desde *Mi cuenta*.

*Por qué:* un link que cambia cada vez obliga a volver a difundirlo en cada
transmisión, que es justamente la fricción que el producto quiere sacar.

### Una cuenta no puede transmitir desde dos lugares a la vez

Si la misma cuenta está abierta en dos pestañas o dispositivos, solo una puede
estar en vivo. La otra ve un aviso, puede editar el catálogo y leer los chats,
pero el botón de transmitir queda bloqueado hasta que la primera termine.

*Por qué:* la cuenta demo es pública, así que dos visitantes la van a usar al
mismo tiempo. Dos transmisiones en la misma sala le mandarían al comprador dos
videos y dos catálogos contradictorios. Antes esto se evitaba dándole a cada
visitante una sala aleatoria; con salas fijas por vendedor, la regla pasa a ser
"una transmisión por cuenta".

### El chat siempre muestra de qué producto se habla

Al tocar "Lo quiero", el producto queda fijado arriba del chat mientras dure la
conversación.

*Por qué:* sin eso, el comprador abre el chat y no sabe por cuál de los cinco
productos estaba preguntando. Del otro lado el problema era peor: la consola
guardaba solo la última consulta, así que si alguien preguntaba por tres
productos, el vendedor le mandaba el link de pago del equivocado y no tenía cómo
darse cuenta. Ahora se guardan todas y el vendedor elige cuál cobrar.

### El botón dice "Lo quiero", no "Comprar"

*Por qué:* el botón no compra nada — abre una conversación. Una palabra que
promete algo que no pasa hace que el usuario desconfíe del resto de la pantalla.

### Si no hay nadie transmitiendo, igual se ve algo

La portada muestra todas las tiendas con un carrusel de sus productos, y entrar a
una tienda que no está en vivo muestra su catálogo real. Si el comprador escribe y
el vendedor se conecta mientras sigue en la página, la consulta le llega.

*Por qué:* como pieza de portfolio, el 99% de las visitas caen cuando nadie está
transmitiendo, y una pantalla vacía no cuenta nada.

### El stock baja cuando alguien paga

*Por qué:* es el detalle que más rápido delata que algo es una maqueta. Pagar y
que el producto siga diciendo "quedan 6" rompe la ilusión de producto real.

### Recargar la página no borra nada

Si el comprador o el vendedor recargan, sus conversaciones y su identidad siguen
ahí.

*Por qué:* antes, recargar convertía al comprador en una persona nueva para el
vendedor y dejaba huérfano el link de pago que le habían mandado. Al vendedor le
borraba todas las conversaciones en curso.

### El checkout devuelve a la transmisión

Al confirmar el pago, la pestaña se cierra sola y el foco vuelve al live.

*Por qué:* antes ofrecía un link "volver al live" que en realidad cargaba una
segunda copia de la transmisión, dejando al comprador con dos pestañas peleando
por la misma identidad. Volver a una pestaña que ya está abierta no es navegar:
es cambiar de pestaña.

---

## 6. Límites conocidos

Están documentados a propósito. Un límite explicado dice más de un producto que
un número inflado.

### Máximo 3 espectadores simultáneos

Como no hay servidor de video, el vendedor manda una copia del video a cada
espectador desde su propia conexión. A calidad HD son unos 2 Mbps por persona:
con 3 espectadores ya son 6 Mbps de subida sostenida, que es lo que da una
conexión hogareña típica.

Subir de ahí no es cuestión de aflojar el número — necesita un tipo de servidor
llamado **SFU**, que recibe el video del vendedor una sola vez y lo reparte. Eso
es infraestructura paga y es, básicamente, otro proyecto.

### El video falla en algunas redes

Entre un 15 y un 20% de las conexiones no logran establecerse, sobre todo en
datos móviles o detrás de routers restrictivos. Es una limitación conocida de las
conexiones directas entre navegadores.

Se resuelve con un servidor **TURN**, que actúa de intermediario cuando la
conexión directa no es posible. Hoy no está puesto porque requiere contratar el
servicio.

Mientras tanto, la falla es elegante: el comprador ve un mensaje explicando qué
pasó, y el chat y la compra siguen funcionando. Se pierde el video, no la venta.

### El catálogo tiene un tope de tamaño

Las fotos de los productos viajan dentro del mensaje del catálogo, y ese mensaje
tiene un límite. La consola avisa cuando se está acercando y sugiere usar emojis
en lugar de fotos.

### La cuenta demo la comparten todos

Cualquier visitante puede vaciarle el catálogo a la tienda demo. Por eso tiene un
botón *Restaurar catálogo demo*, y por eso no se puede borrar ni cambiarle la
contraseña.

### El administrador demo tiene contraseña pública

`admin`/`admin` es a propósito, para que quien evalúa el portfolio pueda ver el
panel. La consecuencia es que las métricas de cualquier vendedor registrado
(visitas y ventas simuladas) son visibles para cualquiera. La pantalla de registro
lo advierte. En un producto real esa cuenta no existiría.

---

## 7. Cómo se mide

Cada vendedor tiene sus propias métricas: entradas a su sala, compradores únicos,
clics en "Lo quiero", mensajes, links de pago, pagos, facturado, conversión,
transmisiones, pico de espectadores y porcentaje de conexiones de video que
funcionaron. Se ven en su consola, pestaña **Métricas**, por hoy, 7, 30 o 90 días.

El **administrador** ve lo mismo para todos los vendedores: los totales
agrupados, la evolución día por día, y una tabla con una fila por vendedor que al
tocarla muestra su detalle.

**Sobre privacidad:** las métricas no guardan nombres ni direcciones IP. Las
conversaciones sí se guardan, porque el vendedor necesita recuperarlas desde otro
dispositivo, pero solo las puede leer ese vendedor: ni el administrador ni otros
vendedores tienen acceso. El administrador solo ve números.

---

## 8. Una nota de mantenimiento

El plan gratuito de Supabase apaga el proyecto si pasan 7 días sin actividad, y
con el proyecto apagado la demo deja de funcionar. Ya pasó una vez.

Hay una tarea automática que le manda una consulta por día para mantenerlo
despierto. Vive en `.github/workflows/keep-supabase-awake.yml`.

---

## 9. Glosario

**WebRTC** — Tecnología incluida en los navegadores que permite mandar video y
audio directamente de una persona a otra, sin servidor en el medio.

**Señalización** — El intercambio inicial que hacen dos navegadores para
encontrarse antes de conectarse directo. Como intercambiar el número de teléfono
antes de llamar.

**STUN** — Servicio que le dice a un navegador cuál es su dirección vista desde
afuera, para que el otro pueda encontrarlo. Es gratis y lo provee Google.

**TURN** — Servidor intermediario que reenvía el video cuando la conexión directa
no es posible. Es de pago y hoy no está.

**SFU** — Servidor que recibe el video del vendedor una vez y lo reparte a todos
los espectadores. Es lo que permitiría escalar más allá de 3.

**Realtime / tiempo real** — Que los mensajes llegan en el momento, sin que la
página tenga que recargarse ni preguntar cada tanto si hay algo nuevo.

**Sala** — Espacio aislado donde ocurre una transmisión. Cada visitante tiene la
suya, así dos personas no se cruzan.
