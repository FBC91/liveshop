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

## 2. Las tres pantallas

El producto son tres páginas. Cada una es una persona distinta en un momento
distinto.

| Pantalla | Quién la usa | Para qué |
|---|---|---|
| `/liveshop/` | El comprador | Ve el video y el catálogo, pregunta, paga |
| `/liveshop/host/` | El vendedor | Transmite, gestiona el catálogo, responde y cobra |
| `/liveshop/pago/` | El comprador | Confirma el pago (simulado) |

---

## 3. El flujo completo

**El vendedor abre su consola.** Carga productos con nombre, precio, stock y una
foto o un emoji. Toca "Salir en vivo" y el navegador le pide permiso para usar la
cámara. Desde ese momento está transmitiendo.

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

### El alojamiento: GitHub Pages

Las tres páginas son archivos HTML que se publican gratis desde GitHub, con el
dominio propio `facundobolani.com`.

*Por qué:* costo cero, y al no haber servidor propio no hay nada que se caiga,
que actualizar ni que asegurar.

### Sin framework

No usa React ni ninguna librería de interfaz. Es HTML, CSS y JavaScript común.

*Por qué:* cada página es un solo archivo que se abre y funciona. No hay proceso
de compilación, ni dependencias que se rompan con el tiempo, ni carpeta de
librerías que pese cientos de megas. Para un producto de tres pantallas, un
framework agregaría más mantenimiento que beneficio.

### Lo que cuesta

Nada. Todo corre en planes gratuitos: GitHub Pages, Supabase, y los servidores
públicos de Google que ayudan a los navegadores a encontrarse.

---

## 5. Decisiones y sus porqués

### Cada visitante tiene su propia sala

Cuando dos personas entran al mismo tiempo, no se cruzan: cada una trabaja en su
propia sala aislada.

*Por qué:* al principio todos caían en una sala compartida. Si dos personas
probaban la demo simultáneamente, compartían vendedor — y peor, si las dos abrían
la consola del vendedor, cada una recibía los mensajes dirigidos a la otra. Con
poco tráfico no se notaba; el día que la demo se comparte en LinkedIn, sí.

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

Cuando nadie está en vivo, el visitante ve un catálogo de ejemplo y un botón para
abrir la consola del vendedor en otra pestaña y probar el flujo completo solo.

*Por qué:* el catálogo real vive en el navegador del vendedor. Sin transmisión
activa, la página quedaba vacía. Como pieza de portfolio eso es fatal: el 99% de
las visitas caen cuando nadie está transmitiendo, y una pantalla vacía no cuenta
nada.

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

### El catálogo vive en el navegador del vendedor

No hay base de datos de productos. Si el vendedor cambia de computadora, carga el
catálogo de nuevo.

*Por qué:* para una demo, guardar productos en una base de datos agrega
complejidad sin mostrar nada nuevo. La decisión sería distinta en un producto real.

---

## 7. Cómo se mide

La demo registra eventos anónimos de uso: cuánta gente entra, cuántos tocan un
producto, cuántos links de pago se mandan, cuántos se pagan, y qué porcentaje de
conexiones de video logran establecerse.

Se ven en la consola del vendedor, pestaña **Métricas**, sección *Uso del demo*,
con ventana de 30 días.

Los números que responde son: ¿alguien entró?, ¿le interesó algún producto?, ¿el
video funciona en el mundo real o falla más de lo esperado?

**Sobre privacidad:** no se guarda ningún dato personal — ni nombres, ni mensajes,
ni direcciones IP. Y la pantalla de métricas solo puede pedir totales ya sumados;
no tiene permiso para leer eventos individuales, ni siquiera anónimos.

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
