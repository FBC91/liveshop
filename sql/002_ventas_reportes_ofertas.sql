-- =============================================================================
-- LiveShop · 002 · ventas, reportes y ofertas
--
-- Requiere 001_cuentas_vendedor.sql. Se ejecuta completo en el SQL editor de
-- Supabase y es idempotente. Si alguna vez se vuelve a correr la 001, hay que
-- correr esta despues: la 001 reescribe funciones que esta extiende.
--
-- Que agrega:
--   · liveshop_ordenes: una venta de punta a punta (link enviado -> pagado), con
--     copia del producto, del comprador y del precio. Reemplaza a liveshop_pagos.
--     El precio lo calcula la base y el checkout lo lee de aca, no de la URL, y
--     el pago queda registrado aunque la consola del vendedor este cerrada.
--   · liveshop_lives: cada transmision como entidad, para medir que live vendio.
--   · liveshop_promos: descuento, remanente (liquidacion), relampago y cupon.
--   · categoria, descripcion y costo en los productos.
--   · producto en los eventos de interes, y el evento vista_producto.
--   · reportes del vendedor, historial de ventas, busqueda entre tiendas.
--   · historia de ejemplo para la cuenta demo, regenerada cada dia.
--
-- Mismo modelo de acceso que la 001: RLS sin politicas, todo por funciones
-- SECURITY DEFINER, y los helpers liveshop__* sin EXECUTE para anon.
-- =============================================================================

-- ----------------------------------------------------------------------------
-- Tablas
-- ----------------------------------------------------------------------------

alter table public.liveshop_productos add column if not exists categoria   text not null default 'otros';
alter table public.liveshop_productos add column if not exists descripcion text;
alter table public.liveshop_productos add column if not exists costo       numeric(12,2);
alter table public.liveshop_productos add column if not exists creado_at   timestamptz not null default now();

do $$
begin
  alter table public.liveshop_productos add constraint liveshop_productos_categoria_check
    check (categoria in ('ropa','calzado','accesorios','tecnologia','hogar','belleza','deportes','ninos','otros'));
exception when duplicate_object then null;
end $$;
do $$
begin
  alter table public.liveshop_productos add constraint liveshop_productos_descripcion_check
    check (descripcion is null or char_length(descripcion) <= 280);
exception when duplicate_object then null;
end $$;
do $$
begin
  alter table public.liveshop_productos add constraint liveshop_productos_costo_check
    check (costo is null or costo >= 0);
exception when duplicate_object then null;
end $$;

alter table public.liveshop_eventos add column if not exists producto_id text;
alter table public.liveshop_eventos add column if not exists demo boolean not null default false;
alter table public.liveshop_eventos drop constraint if exists liveshop_eventos_tipo_check;
alter table public.liveshop_eventos add constraint liveshop_eventos_tipo_check check (tipo in
  ('entrada','interes','vista_producto','video_ok','video_falla','transmision','mensaje','link_pago','pico'));
create index if not exists liveshop_eventos_producto_idx
  on public.liveshop_eventos(vendedor_id, producto_id, created_at) where producto_id is not null;

create table if not exists public.liveshop_lives(
  id          uuid primary key default gen_random_uuid(),
  vendedor_id uuid not null references public.liveshop_vendedores(id) on delete cascade,
  titulo      text check (char_length(titulo) <= 60),
  inicio      timestamptz not null default now(),
  fin         timestamptz,
  pico        int not null default 0,
  demo        boolean not null default false
);
create index if not exists liveshop_lives_vendedor_idx on public.liveshop_lives(vendedor_id, inicio);

create table if not exists public.liveshop_promos(
  id           uuid primary key default gen_random_uuid(),
  vendedor_id  uuid not null references public.liveshop_vendedores(id) on delete cascade,
  tipo         text not null check (tipo in ('descuento','remanente','relampago','cupon')),
  producto_id  text,                                  -- null solo en cupon (toda la tienda)
  pct          numeric(5,2) check (pct > 0 and pct < 100),
  precio       numeric(12,2) check (precio >= 0),     -- precio fijo, alternativo al pct
  codigo       text check (codigo ~ '^[A-Z0-9]{3,16}$'),
  inicio       timestamptz not null default now(),
  fin          timestamptz,                           -- null = hasta agotar stock
  max_unidades int check (max_unidades > 0),
  vendidas     int not null default 0,
  live_id      uuid references public.liveshop_lives(id) on delete set null,
  terminada_at timestamptz,
  demo         boolean not null default false,
  created_at   timestamptz not null default now(),
  check ((pct is null) <> (precio is null)),
  check ((tipo = 'cupon') = (producto_id is null)),
  check ((tipo = 'cupon') = (codigo is not null))
);
-- una sola promo de producto abierta por producto: no se apilan
create unique index if not exists liveshop_promos_abierta_uq
  on public.liveshop_promos(vendedor_id, producto_id) where terminada_at is null and tipo <> 'cupon';
create unique index if not exists liveshop_promos_cupon_uq
  on public.liveshop_promos(vendedor_id, codigo) where terminada_at is null and tipo = 'cupon';

create table if not exists public.liveshop_ordenes(
  vendedor_id     uuid not null references public.liveshop_vendedores(id) on delete cascade,
  ref             text not null check (ref ~ '^[A-Z0-9-]{3,24}$'),
  estado          text not null default 'pendiente' check (estado in ('pendiente','pagada','anulada','vencida')),
  producto_id     text,
  producto_nombre text not null check (char_length(producto_nombre) between 1 and 60),
  categoria       text,
  comprador_id    text check (char_length(comprador_id) <= 64),
  comprador       text check (char_length(comprador) <= 40),
  precio_lista    numeric(12,2) not null check (precio_lista >= 0),
  descuento       numeric(12,2) not null default 0 check (descuento >= 0),
  total           numeric(12,2) not null check (total >= 0),
  promo_id        uuid references public.liveshop_promos(id) on delete set null,
  promo_tipo      text,                 -- copia: sobrevive al borrado de la promo
  cupon           text,
  live_id         uuid references public.liveshop_lives(id) on delete set null,
  manual          boolean not null default false,
  demo            boolean not null default false,
  created_at      timestamptz not null default now(),
  pagada_at       timestamptz,
  primary key (vendedor_id, ref)
);
create index if not exists liveshop_ordenes_creada_idx on public.liveshop_ordenes(vendedor_id, created_at);
create index if not exists liveshop_ordenes_pagada_idx on public.liveshop_ordenes(vendedor_id, pagada_at) where estado = 'pagada';

do $$
declare t text;
begin
  foreach t in array array['liveshop_lives','liveshop_promos','liveshop_ordenes']
  loop
    execute format('alter table public.%I enable row level security', t);
    execute format('revoke all on table public.%I from public', t);
    if exists (select 1 from pg_roles where rolname = 'anon') then
      execute format('revoke all on table public.%I from anon', t);
    end if;
    if exists (select 1 from pg_roles where rolname = 'authenticated') then
      execute format('revoke all on table public.%I from authenticated', t);
    end if;
  end loop;
end $$;

-- Las ventas viejas pasan a ordenes. liveshop_pagos queda de solo lectura.
insert into public.liveshop_ordenes(vendedor_id, ref, estado, producto_id, producto_nombre, categoria,
                                    precio_lista, descuento, total, manual, created_at, pagada_at)
select pg.vendedor_id, pg.ref, 'pagada', pg.producto_id,
       left(coalesce(pr.nombre, case when pg.producto_id is null then 'Compra en el live' else '(producto borrado)' end), 60),
       pr.categoria, pg.monto, 0, pg.monto, pg.producto_id is null, pg.created_at, pg.created_at
  from public.liveshop_pagos pg
  left join public.liveshop_productos pr on pr.vendedor_id = pg.vendedor_id and pr.id = pg.producto_id
on conflict do nothing;

-- Firmas que cambian: se borran las viejas para que PostgREST no encuentre dos
-- candidatas con los mismos parametros por nombre.
drop function if exists public.liveshop_evento(text, text, text);
drop function if exists public.liveshop_metricas_admin(text, int);
drop function if exists public.liveshop__metricas(timestamptz);

-- ----------------------------------------------------------------------------
-- Helpers
-- ----------------------------------------------------------------------------

create or replace function public.liveshop__norm(p text) returns text
language sql immutable set search_path = public, extensions, pg_temp as $$
  select translate(lower(coalesce(p, '')), 'áéíóúüñàèìòù', 'aeiouunaeiou')
$$;

create or replace function public.liveshop__dia(p timestamptz) returns date
language sql stable set search_path = public, extensions, pg_temp as $$
  select (p at time zone 'America/Montevideo')::date
$$;

create or replace function public.liveshop__promo_vigente(x public.liveshop_promos) returns boolean
language sql stable set search_path = public, extensions, pg_temp as $$
  select x.terminada_at is null and x.inicio <= now()
     and (x.fin is null or x.fin > now())
     and (x.max_unidades is null or x.vendidas < x.max_unidades)
$$;

create or replace function public.liveshop__aplicar(p_lista numeric, p_pct numeric, p_precio numeric) returns numeric
language sql immutable set search_path = public, extensions, pg_temp as $$
  select case when p_pct is not null then round(p_lista * (100 - p_pct) / 100)
              when p_precio is not null then least(p_precio, p_lista)
              else p_lista end
$$;

-- promo de producto vigente (o null)
create or replace function public.liveshop__promo_de(p_vendedor uuid, p_producto text) returns public.liveshop_promos
language sql stable set search_path = public, extensions, pg_temp as $$
  select x.* from liveshop_promos x
   where x.vendedor_id = p_vendedor and x.producto_id = p_producto and x.tipo <> 'cupon'
     and liveshop__promo_vigente(x)
   order by x.inicio desc
   limit 1
$$;

-- Cierra las promos que vencieron por tiempo o por tope: si quedaran abiertas,
-- el indice unico no dejaria crear otra sobre el mismo producto.
create or replace function public.liveshop__cerrar_promos(p_vendedor uuid) returns void
language sql set search_path = public, extensions, pg_temp as $$
  update liveshop_promos
     set terminada_at = case when fin is not null and fin <= now() then fin else now() end
   where vendedor_id = p_vendedor and terminada_at is null
     and ((fin is not null and fin <= now()) or (max_unidades is not null and vendidas >= max_unidades));
$$;

create or replace function public.liveshop__vencer(p_vendedor uuid) returns void
language sql set search_path = public, extensions, pg_temp as $$
  update liveshop_ordenes set estado = 'vencida'
   where vendedor_id = p_vendedor and estado = 'pendiente' and created_at < now() - interval '24 hours';
$$;

-- Catalogo en JSON. Publico: precio = precio final (con promo), precio_lista y
-- la promo vigente; nunca el costo. Privado (consola): precio = precio de lista
-- y costo; las promos viajan aparte.
create or replace function public.liveshop__catalogo_json(p_vendedor uuid, p_limite int default null,
                                                          p_privado boolean default false) returns jsonb
language sql stable set search_path = public, extensions, pg_temp as $$
  select coalesce(jsonb_agg(
           jsonb_build_object('id', p.id, 'nombre', p.nombre, 'stock', p.stock, 'emoji', p.emoji, 'img', p.img,
                              'categoria', p.categoria, 'descripcion', p.descripcion)
           || case when p_privado
                then jsonb_build_object('precio', p.precio, 'costo', p.costo, 'creado_at', p.creado_at)
                else jsonb_build_object(
                       'precio', liveshop__aplicar(p.precio, pr.pct, pr.precio),
                       'precio_lista', p.precio,
                       'promo', case when pr.id is null then null else jsonb_build_object(
                                  'id', pr.id, 'tipo', pr.tipo, 'pct', pr.pct, 'fin', pr.fin,
                                  'restantes', case when pr.max_unidades is null then null
                                                    else pr.max_unidades - pr.vendidas end) end)
              end
           order by p.orden), '[]'::jsonb)
    from (select * from liveshop_productos
           where vendedor_id = p_vendedor
           order by orden
           limit p_limite) p
    left join lateral (select * from liveshop__promo_de(p_vendedor, p.id)) pr on pr.id is not null
$$;

create or replace function public.liveshop__promos_json(p_vendedor uuid) returns jsonb
language sql stable set search_path = public, extensions, pg_temp as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'id', x.id, 'tipo', x.tipo, 'producto_id', x.producto_id, 'pct', x.pct, 'precio', x.precio,
           'codigo', x.codigo, 'inicio', x.inicio, 'fin', x.fin, 'max_unidades', x.max_unidades,
           'vendidas', x.vendidas, 'live_id', x.live_id) order by x.inicio), '[]'::jsonb)
    from liveshop_promos x
   where x.vendedor_id = p_vendedor and liveshop__promo_vigente(x)
$$;

create or replace function public.liveshop__orden_json(o public.liveshop_ordenes) returns jsonb
language sql stable set search_path = public, extensions, pg_temp as $$
  select jsonb_build_object(
    'ref', o.ref, 'estado', o.estado, 'producto_id', o.producto_id, 'concepto', o.producto_nombre,
    'categoria', o.categoria, 'comprador_id', o.comprador_id, 'comprador', o.comprador,
    'precio_lista', o.precio_lista, 'descuento', o.descuento, 'total', o.total,
    'promo_tipo', o.promo_tipo, 'cupon', o.cupon, 'live_id', o.live_id, 'manual', o.manual,
    'created_at', o.created_at, 'pagada_at', o.pagada_at,
    'vence_at', case when o.estado = 'pendiente' then o.created_at + interval '24 hours' end)
$$;

-- Descuento extra de un cupon sobre una orden. El total nunca baja de la mitad
-- del precio de lista sumando todas las promos.
create or replace function public.liveshop__cupon(p_vendedor uuid, o public.liveshop_ordenes, p_codigo text)
returns table(promo_id uuid, codigo text, extra numeric)
language plpgsql stable set search_path = public, extensions, pg_temp as $$
declare c liveshop_promos; cod text := upper(trim(coalesce(p_codigo, '')));
begin
  if cod = '' then return; end if;
  select x.* into c from liveshop_promos x
   where x.vendedor_id = p_vendedor and x.tipo = 'cupon' and x.codigo = cod and liveshop__promo_vigente(x)
   limit 1;
  if not found then
    raise exception 'LS:cupon_invalido' using errcode = 'P0001';
  end if;
  promo_id := c.id;
  codigo := c.codigo;
  extra := greatest(0, least(round(o.total * c.pct / 100),
                             round(o.precio_lista * 0.5) - o.descuento));
  return next;
end $$;

-- ----------------------------------------------------------------------------
-- Catalogo (reescritas de la 001)
-- ----------------------------------------------------------------------------

create or replace function public.liveshop_catalogo_guardar(p_token text, p_productos jsonb, p_titulo text, p_destacado text)
returns void language plpgsql security definer set search_path = public, extensions, pg_temp as $$
declare v liveshop_vendedores; viejos jsonb;
begin
  v := liveshop__cuenta(p_token);
  if v.rol <> 'vendedor' then
    raise exception 'LS:solo_vendedores' using errcode = 'P0001';
  end if;
  if jsonb_typeof(p_productos) is distinct from 'array' then
    raise exception 'LS:catalogo_invalido' using errcode = 'P0001';
  end if;
  if jsonb_array_length(p_productos) > 40 then
    raise exception 'LS:catalogo_grande' using errcode = 'P0001';
  end if;

  -- la fecha de alta sobrevive al "borrar e insertar": sin esto cada guardado
  -- rejuvenece el catalogo y la regla de stock quieto nunca se cumple
  select jsonb_object_agg(id, creado_at) into viejos from liveshop_productos where vendedor_id = v.id;

  begin
    delete from liveshop_productos where vendedor_id = v.id;
    insert into liveshop_productos(vendedor_id, id, nombre, precio, stock, emoji, img, orden,
                                   categoria, descripcion, costo, creado_at)
    select v.id, e->>'id', left(trim(e->>'nombre'), 50),
           greatest(0, (e->>'precio')::numeric),
           greatest(0, floor((e->>'stock')::numeric))::int,
           nullif(e->>'emoji', ''), nullif(e->>'img', ''), (o - 1)::int,
           coalesce(nullif(e->>'categoria', ''), 'otros'),
           nullif(left(trim(coalesce(e->>'descripcion', '')), 280), ''),
           case when nullif(e->>'costo', '') is null then null else greatest(0, (e->>'costo')::numeric) end,
           coalesce((viejos->>(e->>'id'))::timestamptz, now())
      from jsonb_array_elements(p_productos) with ordinality as t(e, o);
  exception when check_violation or not_null_violation or unique_violation
                 or invalid_text_representation or numeric_value_out_of_range then
    raise exception 'LS:catalogo_invalido' using errcode = 'P0001';
  end;

  -- una promo de un producto borrado no tiene sentido abierta
  update liveshop_promos x set terminada_at = now()
   where x.vendedor_id = v.id and x.terminada_at is null and x.tipo <> 'cupon'
     and not exists (select 1 from liveshop_productos p where p.vendedor_id = v.id and p.id = x.producto_id);

  update liveshop_vendedores
     set titulo = coalesce(left(nullif(trim(p_titulo), ''), 60), 'LiveShop'),
         destacado = case when exists (select 1 from liveshop_productos
                                        where vendedor_id = v.id and id = p_destacado)
                          then p_destacado end,
         updated_at = now()
   where id = v.id;
end $$;

create or replace function public.liveshop__seed_catalogo(p_vendedor uuid) returns void
language sql set search_path = public, extensions, pg_temp as $$
  delete from liveshop_productos where vendedor_id = p_vendedor;
  insert into liveshop_productos(vendedor_id, id, nombre, precio, stock, emoji, orden, categoria, descripcion, costo, creado_at) values
    (p_vendedor, 'seed-1', 'Zapatillas urbanas',   4900,  6, '👟', 0, 'calzado',    'Suela de goma, plantilla acolchada. Talles 36 al 44.', 2600, now() - interval '75 days'),
    (p_vendedor, 'seed-2', 'Auriculares wireless', 2300,  9, '🎧', 1, 'tecnologia', 'Bluetooth 5.3, 30 horas de batería con el estuche.', 1100, now() - interval '75 days'),
    (p_vendedor, 'seed-3', 'Reloj minimalista',    7500,  3, '⌚', 2, 'accesorios', 'Caja de acero de 40 mm, malla de cuero. Resistente al agua.', 4200, now() - interval '75 days'),
    (p_vendedor, 'seed-4', 'Mochila impermeable',  3200,  0, '🎒', 3, 'accesorios', '25 litros, compartimento acolchado para notebook de 15".', 1500, now() - interval '75 days'),
    (p_vendedor, 'seed-5', 'Lentes de sol',        1800, 12, '🕶️', 4, 'accesorios', 'Protección UV400, armazón liviano.', 700, now() - interval '75 days'),
    (p_vendedor, 'seed-6', 'Campera de jean',      3900,  4, '🧥', 5, 'ropa',       'Jean rígido lavado claro, corte clásico. Talles S a XL.', 2100, now() - interval '75 days'),
    (p_vendedor, 'seed-7', 'Remera oversize',      1200, 15, '👕', 6, 'ropa',       'Algodón peinado 24/1. Blanca, negra y gris.', 450, now() - interval '75 days'),
    (p_vendedor, 'seed-8', 'Botella térmica',      1500,  7, '🧴', 7, 'hogar',      'Acero inoxidable, 750 ml. Frío 24 h, calor 12 h.', 600, now() - interval '75 days');
  update liveshop_vendedores
     set titulo = 'LiveShop', destacado = 'seed-2', updated_at = now()
   where id = p_vendedor;
$$;

-- ----------------------------------------------------------------------------
-- Lectura (reescritas de la 001)
-- ----------------------------------------------------------------------------

create or replace function public.liveshop_yo(p_token text) returns jsonb
language plpgsql security definer set search_path = public, extensions, pg_temp as $$
declare v liveshop_vendedores;
begin
  v := liveshop__cuenta(p_token);
  perform liveshop__cerrar_promos(v.id);
  return jsonb_build_object(
    'cuenta', liveshop__cuenta_json(v),
    'productos', liveshop__catalogo_json(v.id, null, true),
    'promos', liveshop__promos_json(v.id),
    'ahora', now(),
    'conversaciones', (
      select coalesce(jsonb_agg(jsonb_build_object('id', c.comprador_id, 'datos', c.datos) order by c.updated_at), '[]'::jsonb)
        from (select * from liveshop_conversaciones
               where vendedor_id = v.id
               order by updated_at desc
               limit 100) c));
end $$;

create or replace function public.liveshop_directorio() returns jsonb
language sql stable security definer set search_path = public, extensions, pg_temp as $$
  select coalesce(jsonb_agg(x.j order by x.upd desc), '[]'::jsonb)
    from (select v.updated_at as upd,
                 jsonb_build_object('usuario', v.usuario, 'nombre', v.nombre, 'foto', v.foto,
                                    'sala', v.sala, 'titulo', v.titulo,
                                    'productos', liveshop__catalogo_json(v.id, 10)) as j
            from liveshop_vendedores v
           where v.rol = 'vendedor'
           order by v.updated_at desc
           limit 48) x
$$;

create or replace function public.liveshop_sala(p_sala text) returns jsonb
language sql stable security definer set search_path = public, extensions, pg_temp as $$
  select jsonb_build_object('usuario', v.usuario, 'nombre', v.nombre, 'foto', v.foto, 'sala', v.sala,
                            'titulo', v.titulo, 'destacado', v.destacado, 'ahora', now(),
                            'productos', liveshop__catalogo_json(v.id))
    from liveshop_vendedores v
   where v.rol = 'vendedor' and v.sala = lower(trim(coalesce(p_sala, '')))
$$;

-- Productos de varias tiendas en el formato del directorio. Las fotos pesadas
-- no viajan: con muchas tiendas la respuesta se volveria enorme.
create or replace function public.liveshop__producto_tienda_json(p public.liveshop_productos, v public.liveshop_vendedores,
                                                                 pr public.liveshop_promos) returns jsonb
language sql stable set search_path = public, extensions, pg_temp as $$
  select jsonb_build_object(
    'id', p.id, 'nombre', p.nombre, 'stock', p.stock, 'emoji', p.emoji,
    'img', case when char_length(coalesce(p.img, '')) <= 40000 then p.img end,
    'categoria', p.categoria, 'descripcion', p.descripcion,
    'precio', liveshop__aplicar(p.precio, pr.pct, pr.precio), 'precio_lista', p.precio,
    'promo', case when pr.id is null then null else jsonb_build_object(
               'id', pr.id, 'tipo', pr.tipo, 'pct', pr.pct, 'fin', pr.fin,
               'restantes', case when pr.max_unidades is null then null else pr.max_unidades - pr.vendidas end) end,
    'tienda', jsonb_build_object('usuario', v.usuario, 'nombre', v.nombre, 'sala', v.sala,
                                 'foto', case when char_length(coalesce(v.foto, '')) <= 40000 then v.foto end))
$$;

create or replace function public.liveshop_ofertas() returns jsonb
language sql stable security definer set search_path = public, extensions, pg_temp as $$
  select jsonb_build_object('ahora', now(), 'productos', coalesce(jsonb_agg(x.j order by x.fin nulls last, x.ini desc), '[]'::jsonb))
    from (select liveshop__producto_tienda_json(p, v, pr) as j, pr.fin, pr.inicio as ini
            from liveshop_promos pr
            join liveshop_productos p on p.vendedor_id = pr.vendedor_id and p.id = pr.producto_id
            join liveshop_vendedores v on v.id = pr.vendedor_id and v.rol = 'vendedor'
           where pr.tipo <> 'cupon' and liveshop__promo_vigente(pr) and p.stock > 0
           order by pr.fin nulls last, pr.inicio desc
           limit 24) x
$$;

create or replace function public.liveshop_buscar(p_q text, p_categoria text default null, p_solo_ofertas boolean default false)
returns jsonb language sql stable security definer set search_path = public, extensions, pg_temp as $$
  with q as (select liveshop__norm(trim(left(coalesce(p_q, ''), 40))) as t,
                    nullif(trim(coalesce(p_categoria, '')), '') as cat)
  select jsonb_build_object('ahora', now(), 'productos', coalesce(jsonb_agg(x.j order by x.rango, x.nombre), '[]'::jsonb))
    from (select liveshop__producto_tienda_json(p, v, pr) as j, p.nombre,
                 case when liveshop__norm(p.nombre) like q.t || '%' then 0
                      when pr.id is not null then 1 else 2 end as rango
            from q, liveshop_productos p
            join liveshop_vendedores v on v.id = p.vendedor_id and v.rol = 'vendedor'
            left join lateral (select * from liveshop__promo_de(p.vendedor_id, p.id)) pr on pr.id is not null
           where (char_length(q.t) >= 2 or q.cat is not null or p_solo_ofertas)
             and (q.t = '' or liveshop__norm(p.nombre) like '%' || q.t || '%'
                           or liveshop__norm(p.descripcion) like '%' || q.t || '%')
             and (q.cat is null or p.categoria = q.cat)
             and (not coalesce(p_solo_ofertas, false) or pr.id is not null)
           order by 3, p.nombre
           limit 40) x
$$;

-- ----------------------------------------------------------------------------
-- Lives
-- ----------------------------------------------------------------------------

create or replace function public.liveshop__cerrar_lives(p_vendedor uuid) returns void
language plpgsql set search_path = public, extensions, pg_temp as $$
begin
  -- una pestaña cerrada sin "terminar" deja el live abierto: se le pone un fin
  -- razonable y se cierran sus cupones, que solo valen mientras dura el live
  update liveshop_promos set terminada_at = now()
   where vendedor_id = p_vendedor and tipo = 'cupon' and terminada_at is null
     and live_id in (select id from liveshop_lives where vendedor_id = p_vendedor and fin is null);
  update liveshop_lives set fin = least(now(), inicio + interval '6 hours')
   where vendedor_id = p_vendedor and fin is null;
end $$;

create or replace function public.liveshop_live_iniciar(p_token text, p_titulo text) returns jsonb
language plpgsql security definer set search_path = public, extensions, pg_temp as $$
declare v liveshop_vendedores; l liveshop_lives;
begin
  v := liveshop__cuenta(p_token);
  if v.rol <> 'vendedor' then
    raise exception 'LS:solo_vendedores' using errcode = 'P0001';
  end if;
  perform liveshop__cerrar_lives(v.id);
  insert into liveshop_lives(vendedor_id, titulo)
  values (v.id, left(nullif(trim(coalesce(p_titulo, '')), ''), 60))
  returning * into l;
  return jsonb_build_object('id', l.id, 'inicio', l.inicio);
end $$;

create or replace function public.liveshop_live_terminar(p_token text, p_live_id uuid, p_pico int default 0) returns void
language plpgsql security definer set search_path = public, extensions, pg_temp as $$
declare v liveshop_vendedores;
begin
  v := liveshop__cuenta(p_token);
  update liveshop_promos set terminada_at = now()
   where vendedor_id = v.id and tipo = 'cupon' and terminada_at is null and live_id = p_live_id;
  update liveshop_lives set fin = now(), pico = greatest(pico, least(coalesce(p_pico, 0), 1000))
   where id = p_live_id and vendedor_id = v.id and fin is null;
end $$;

-- ----------------------------------------------------------------------------
-- Eventos (reescritas de la 001)
-- ----------------------------------------------------------------------------

create or replace function public.liveshop_evento(p_sala text, p_tipo text, p_sesion text, p_producto_id text default null)
returns void language plpgsql security definer set search_path = public, extensions, pg_temp as $$
declare vid uuid; ses text := left(coalesce(p_sesion, ''), 64); pid text;
begin
  if p_tipo not in ('entrada', 'interes', 'vista_producto', 'video_ok', 'video_falla') then return; end if;
  select id into vid from liveshop_vendedores where rol = 'vendedor' and sala = lower(trim(coalesce(p_sala, '')));
  if vid is null then return; end if;
  -- solo se acepta un producto que exista en ese catalogo
  if p_tipo in ('interes', 'vista_producto') then
    select id into pid from liveshop_productos where vendedor_id = vid and id = p_producto_id;
    if p_tipo = 'vista_producto' and pid is null then return; end if;
  end if;
  -- un refresh no cuenta como otra entrada, ni volver a abrir la misma ficha
  if p_tipo in ('entrada', 'video_ok', 'vista_producto') and exists (
       select 1 from liveshop_eventos
        where vendedor_id = vid and tipo = p_tipo and sesion = ses
          and producto_id is not distinct from pid
          and created_at > now() - interval '30 minutes') then
    return;
  end if;
  insert into liveshop_eventos(vendedor_id, tipo, sesion, producto_id) values (vid, p_tipo, ses, pid);
end $$;

create or replace function public.liveshop_evento_host(p_token text, p_tipo text, p_valor numeric) returns void
language plpgsql security definer set search_path = public, extensions, pg_temp as $$
declare v liveshop_vendedores; val numeric := least(greatest(coalesce(p_valor, 1), 0), 10000000);
begin
  v := liveshop__cuenta(p_token);
  if v.rol <> 'vendedor' or p_tipo not in ('transmision', 'mensaje', 'link_pago', 'pico') then return; end if;
  insert into liveshop_eventos(vendedor_id, tipo, valor) values (v.id, p_tipo, val);
  if p_tipo = 'pico' then
    update liveshop_lives set pico = greatest(pico, least(val, 1000)::int)
     where vendedor_id = v.id and fin is null;
  end if;
end $$;

-- ----------------------------------------------------------------------------
-- Ordenes
-- ----------------------------------------------------------------------------

create or replace function public.liveshop_orden_crear(p_token text, p_comprador_id text, p_comprador text,
                                                       p_producto_id text, p_concepto text default null,
                                                       p_monto numeric default null, p_live_id uuid default null)
returns jsonb language plpgsql security definer set search_path = public, extensions, pg_temp as $$
declare
  v liveshop_vendedores; p liveshop_productos; pr liveshop_promos; o liveshop_ordenes;
  r text := upper(substr(encode(gen_random_bytes(8), 'hex'), 1, 10));
  lid uuid; tot numeric;
begin
  v := liveshop__cuenta(p_token);
  if v.rol <> 'vendedor' then
    raise exception 'LS:solo_vendedores' using errcode = 'P0001';
  end if;
  select id into lid from liveshop_lives where id = p_live_id and vendedor_id = v.id;

  if nullif(p_producto_id, '') is not null then
    select * into p from liveshop_productos where vendedor_id = v.id and id = p_producto_id;
    if not found then
      raise exception 'LS:producto_inexistente' using errcode = 'P0001';
    end if;
    -- el precio lo decide la base con la promo vigente ahora: ni la consola ni
    -- la URL del checkout pueden cambiarlo
    pr := liveshop__promo_de(v.id, p.id);
    tot := liveshop__aplicar(p.precio, pr.pct, pr.precio);
    insert into liveshop_ordenes(vendedor_id, ref, producto_id, producto_nombre, categoria, comprador_id, comprador,
                                 precio_lista, descuento, total, promo_id, promo_tipo, live_id)
    values (v.id, r, p.id, p.nombre, p.categoria, left(p_comprador_id, 64), left(nullif(trim(p_comprador), ''), 40),
            p.precio, p.precio - tot, tot, pr.id, pr.tipo, lid)
    returning * into o;
  else
    if char_length(trim(coalesce(p_concepto, ''))) not between 1 and 60
       or coalesce(p_monto, 0) <= 0 or p_monto > 9999999999 then
      raise exception 'LS:orden_invalida' using errcode = 'P0001';
    end if;
    insert into liveshop_ordenes(vendedor_id, ref, producto_nombre, comprador_id, comprador,
                                 precio_lista, total, manual, live_id)
    values (v.id, r, trim(p_concepto), left(p_comprador_id, 64), left(nullif(trim(p_comprador), ''), 40),
            round(p_monto, 2), round(p_monto, 2), true, lid)
    returning * into o;
  end if;
  return liveshop__orden_json(o);
end $$;

-- Publica: el checkout no tiene token. Devuelve lo minimo para mostrar el pago
-- y el comprobante.
create or replace function public.liveshop_orden_ver(p_sala text, p_ref text, p_codigo text default null) returns jsonb
language plpgsql security definer set search_path = public, extensions, pg_temp as $$
declare v liveshop_vendedores; o liveshop_ordenes; ccod text; cext numeric;
begin
  select * into v from liveshop_vendedores where rol = 'vendedor' and sala = lower(trim(coalesce(p_sala, '')));
  if not found then
    raise exception 'LS:orden_inexistente' using errcode = 'P0001';
  end if;
  perform liveshop__vencer(v.id);
  select * into o from liveshop_ordenes where vendedor_id = v.id and ref = upper(trim(coalesce(p_ref, '')));
  if not found then
    raise exception 'LS:orden_inexistente' using errcode = 'P0001';
  end if;
  if o.estado = 'pendiente' and nullif(trim(coalesce(p_codigo, '')), '') is not null then
    select x.codigo, x.extra into ccod, cext from liveshop__cupon(v.id, o, p_codigo) x;
  end if;
  return jsonb_build_object(
    'ref', o.ref, 'estado', o.estado, 'concepto', o.producto_nombre, 'producto_id', o.producto_id,
    'precio_lista', o.precio_lista, 'descuento', o.descuento, 'total', o.total,
    'promo_tipo', o.promo_tipo, 'cupon', o.cupon, 'comprador', o.comprador,
    'created_at', o.created_at, 'pagada_at', o.pagada_at,
    'vence_at', case when o.estado = 'pendiente' then o.created_at + interval '24 hours' end,
    'tienda', jsonb_build_object('nombre', v.nombre, 'usuario', v.usuario, 'sala', v.sala),
    'con_cupon', case when ccod is null then null
                      else jsonb_build_object('codigo', ccod, 'extra', cext, 'total', o.total - cext) end);
end $$;

-- Publica e idempotente: pagar dos veces la misma ref es una sola venta y un
-- solo descuento de stock. En un producto real esto lo dispara el webhook del
-- procesador de pagos, no el navegador del comprador.
create or replace function public.liveshop_orden_pagar(p_sala text, p_ref text, p_codigo text default null) returns jsonb
language plpgsql security definer set search_path = public, extensions, pg_temp as $$
declare v liveshop_vendedores; o liveshop_ordenes; cid uuid; ccod text; cext numeric; st int; pmax int; pvend int;
begin
  select * into v from liveshop_vendedores where rol = 'vendedor' and sala = lower(trim(coalesce(p_sala, '')));
  if not found then
    raise exception 'LS:orden_inexistente' using errcode = 'P0001';
  end if;
  perform liveshop__vencer(v.id);
  select * into o from liveshop_ordenes where vendedor_id = v.id and ref = upper(trim(coalesce(p_ref, ''))) for update;
  if not found then
    raise exception 'LS:orden_inexistente' using errcode = 'P0001';
  end if;
  if o.estado = 'pagada' then
    select stock into st from liveshop_productos where vendedor_id = v.id and id = o.producto_id;
    return jsonb_build_object('duplicado', true, 'estado', o.estado, 'ref', o.ref, 'total', o.total,
                              'producto_id', o.producto_id, 'stock', st);
  end if;
  if o.estado <> 'pendiente' then
    raise exception 'LS:orden_cerrada' using errcode = 'P0001';
  end if;

  if nullif(trim(coalesce(p_codigo, '')), '') is not null then
    select x.promo_id, x.codigo, x.extra into cid, ccod, cext from liveshop__cupon(v.id, o, p_codigo) x;
    update liveshop_promos set vendidas = vendidas + 1 where id = cid;
  end if;

  update liveshop_ordenes
     set estado = 'pagada', pagada_at = now(),
         descuento = descuento + coalesce(cext, 0), total = total - coalesce(cext, 0),
         cupon = coalesce(ccod, cupon)
   where vendedor_id = v.id and ref = o.ref
   returning * into o;

  if o.producto_id is not null then
    update liveshop_productos set stock = stock - 1
     where vendedor_id = v.id and id = o.producto_id and stock > 0
     returning stock into st;
    if st is null then
      select stock into st from liveshop_productos where vendedor_id = v.id and id = o.producto_id;
    end if;
  end if;

  -- el tope de unidades de una promo se cuenta al pagar; al llegar, se cierra
  if o.promo_id is not null then
    update liveshop_promos set vendidas = vendidas + 1
     where id = o.promo_id
     returning max_unidades, vendidas into pmax, pvend;
    if pmax is not null and pvend >= pmax then
      update liveshop_promos set terminada_at = coalesce(terminada_at, now()) where id = o.promo_id;
    end if;
  end if;

  return jsonb_build_object('duplicado', false, 'estado', o.estado, 'ref', o.ref, 'total', o.total,
                            'producto_id', o.producto_id, 'stock', st);
end $$;

create or replace function public.liveshop_orden_estado(p_token text, p_ref text) returns jsonb
language plpgsql security definer set search_path = public, extensions, pg_temp as $$
declare v liveshop_vendedores; o liveshop_ordenes; st int;
begin
  v := liveshop__cuenta(p_token);
  perform liveshop__cerrar_promos(v.id);
  select * into o from liveshop_ordenes where vendedor_id = v.id and ref = upper(trim(coalesce(p_ref, '')));
  if not found then
    raise exception 'LS:orden_inexistente' using errcode = 'P0001';
  end if;
  select stock into st from liveshop_productos where vendedor_id = v.id and id = o.producto_id;
  return liveshop__orden_json(o) || jsonb_build_object('stock', st, 'promos', liveshop__promos_json(v.id));
end $$;

create or replace function public.liveshop_orden_anular(p_token text, p_ref text) returns jsonb
language plpgsql security definer set search_path = public, extensions, pg_temp as $$
declare v liveshop_vendedores; o liveshop_ordenes;
begin
  v := liveshop__cuenta(p_token);
  perform liveshop__vencer(v.id);
  update liveshop_ordenes set estado = 'anulada'
   where vendedor_id = v.id and ref = upper(trim(coalesce(p_ref, ''))) and estado = 'pendiente'
   returning * into o;
  if not found then
    raise exception 'LS:orden_cerrada' using errcode = 'P0001';
  end if;
  return liveshop__orden_json(o);
end $$;

-- Compatibilidad con la consola anterior a la 002 (que registraba el pago al
-- recibir el aviso). Si la orden ya existe no hace nada; si no, la crea pagada.
create or replace function public.liveshop_pago_registrar(p_token text, p_ref text, p_producto_id text, p_monto numeric)
returns jsonb language plpgsql security definer set search_path = public, extensions, pg_temp as $$
declare v liveshop_vendedores; p liveshop_productos; st int; r text := upper(coalesce(p_ref, ''));
begin
  v := liveshop__cuenta(p_token);
  if r !~ '^[A-Z0-9-]{3,24}$' then
    raise exception 'LS:ref_invalida' using errcode = 'P0001';
  end if;
  select * into p from liveshop_productos where vendedor_id = v.id and id = p_producto_id;
  if exists (select 1 from liveshop_ordenes where vendedor_id = v.id and ref = r) then
    return jsonb_build_object('duplicado', true, 'stock', p.stock);
  end if;
  insert into liveshop_ordenes(vendedor_id, ref, estado, producto_id, producto_nombre, categoria,
                               precio_lista, total, manual, pagada_at)
  values (v.id, r, 'pagada', p.id, coalesce(p.nombre, 'Compra en el live'), p.categoria,
          least(greatest(coalesce(p_monto, 0), 0), 9999999999), least(greatest(coalesce(p_monto, 0), 0), 9999999999),
          p.id is null, now());
  update liveshop_productos set stock = stock - 1
   where vendedor_id = v.id and id = p_producto_id and stock > 0
   returning stock into st;
  return jsonb_build_object('duplicado', false, 'stock', coalesce(st, p.stock));
end $$;

-- ----------------------------------------------------------------------------
-- Promos
-- ----------------------------------------------------------------------------

create or replace function public.liveshop_promo_crear(p_token text, p_tipo text, p_productos text[] default null,
                                                       p_pct numeric default null, p_precio numeric default null,
                                                       p_minutos int default null, p_fin timestamptz default null,
                                                       p_max_unidades int default null, p_codigo text default null,
                                                       p_live_id uuid default null, p_reemplazar boolean default false)
returns jsonb language plpgsql security definer set search_path = public, extensions, pg_temp as $$
declare
  v liveshop_vendedores; p liveshop_productos; actual liveshop_promos;
  fin timestamptz; lid uuid; pid text; cod text;
begin
  v := liveshop__cuenta(p_token);
  if v.rol <> 'vendedor' then
    raise exception 'LS:solo_vendedores' using errcode = 'P0001';
  end if;
  if p_tipo not in ('descuento', 'remanente', 'relampago', 'cupon')
     or (p_pct is null) = (p_precio is null)
     or (p_pct is not null and p_pct not between 1 and 90)
     or (p_max_unidades is not null and p_max_unidades not between 1 and 1000) then
    raise exception 'LS:promo_invalida' using errcode = 'P0001';
  end if;
  perform liveshop__cerrar_promos(v.id);
  select id into lid from liveshop_lives where id = p_live_id and vendedor_id = v.id;

  if p_tipo = 'relampago' then
    if p_minutos is null or p_minutos not between 1 and 60 then
      raise exception 'LS:promo_invalida' using errcode = 'P0001';
    end if;
    fin := now() + make_interval(mins => p_minutos);
  else
    if p_fin is not null and p_fin <= now() then
      raise exception 'LS:promo_invalida' using errcode = 'P0001';
    end if;
    fin := p_fin;
  end if;

  if p_tipo = 'cupon' then
    cod := upper(trim(coalesce(p_codigo, '')));
    if cod !~ '^[A-Z0-9]{3,16}$' or p_pct is null or p_pct not between 5 and 50 then
      raise exception 'LS:cupon_invalido' using errcode = 'P0001';
    end if;
    select * into actual from liveshop_promos
     where vendedor_id = v.id and tipo = 'cupon' and codigo = cod and terminada_at is null;
    if found then
      if not p_reemplazar then
        raise exception 'LS:promo_existente' using errcode = 'P0001';
      end if;
      update liveshop_promos set terminada_at = now() where id = actual.id;
    end if;
    insert into liveshop_promos(vendedor_id, tipo, pct, codigo, fin, live_id)
    values (v.id, 'cupon', p_pct, cod, fin, lid);
    return liveshop__promos_json(v.id);
  end if;

  if coalesce(array_length(p_productos, 1), 0) not between 1 and 40 then
    raise exception 'LS:promo_invalida' using errcode = 'P0001';
  end if;
  foreach pid in array p_productos loop
    select * into p from liveshop_productos where vendedor_id = v.id and id = pid;
    if not found then
      raise exception 'LS:producto_inexistente' using errcode = 'P0001';
    end if;
    if p_precio is not null and p_precio >= p.precio then
      raise exception 'LS:promo_invalida' using errcode = 'P0001';
    end if;
    select * into actual from liveshop_promos
     where vendedor_id = v.id and producto_id = pid and tipo <> 'cupon' and terminada_at is null;
    if found then
      if not p_reemplazar then
        raise exception 'LS:promo_existente' using errcode = 'P0001';
      end if;
      update liveshop_promos set terminada_at = now() where id = actual.id;
    end if;
    insert into liveshop_promos(vendedor_id, tipo, producto_id, pct, precio, fin, max_unidades, live_id)
    values (v.id, p_tipo, pid, p_pct, p_precio, fin, p_max_unidades, lid);
  end loop;
  return liveshop__promos_json(v.id);
end $$;

create or replace function public.liveshop_promo_terminar(p_token text, p_id uuid) returns jsonb
language plpgsql security definer set search_path = public, extensions, pg_temp as $$
declare v liveshop_vendedores;
begin
  v := liveshop__cuenta(p_token);
  update liveshop_promos set terminada_at = now()
   where id = p_id and vendedor_id = v.id and terminada_at is null;
  perform liveshop__cerrar_promos(v.id);
  return liveshop__promos_json(v.id);
end $$;

-- Historial de promos con su resultado: unidades, facturado y lo que costaron.
create or replace function public.liveshop_promos(p_token text, p_dias int default 30) returns jsonb
language plpgsql security definer set search_path = public, extensions, pg_temp as $$
declare v liveshop_vendedores; d int := least(greatest(coalesce(p_dias, 30), 1), 365);
begin
  v := liveshop__cuenta(p_token);
  perform liveshop__cerrar_promos(v.id);
  return (
    select coalesce(jsonb_agg(jsonb_build_object(
             'id', x.id, 'tipo', x.tipo, 'producto_id', x.producto_id,
             'producto', coalesce(p.nombre, (select o.producto_nombre from liveshop_ordenes o
                                              where o.promo_id = x.id limit 1)),
             'pct', x.pct, 'precio', x.precio, 'codigo', x.codigo, 'inicio', x.inicio, 'fin', x.fin,
             'terminada_at', x.terminada_at, 'max_unidades', x.max_unidades, 'vendidas', x.vendidas,
             'activa', liveshop__promo_vigente(x),
             'unidades', m.unidades, 'facturado', m.facturado, 'descuento', m.descuento,
             'minutos', round(extract(epoch from (coalesce(x.terminada_at, x.fin, now()) - x.inicio)) / 60),
             'live_minutos', case when l.id is not null then
                round(extract(epoch from (coalesce(l.fin, least(now(), l.inicio + interval '6 hours')) - l.inicio)) / 60) end,
             'live_unidades', case when l.id is not null then
                (select count(*) from liveshop_ordenes o
                  where o.vendedor_id = v.id and o.live_id = l.id and o.estado = 'pagada') end)
           order by x.inicio desc), '[]'::jsonb)
      from liveshop_promos x
      left join liveshop_productos p on p.vendedor_id = x.vendedor_id and p.id = x.producto_id
      left join liveshop_lives l on l.id = x.live_id
      left join lateral (
        select count(*) filter (where o.estado = 'pagada') as unidades,
               coalesce(sum(o.total) filter (where o.estado = 'pagada'), 0) as facturado,
               coalesce(sum(o.descuento) filter (where o.estado = 'pagada'), 0) as descuento
          from liveshop_ordenes o
         where o.vendedor_id = v.id and (o.promo_id = x.id or (x.tipo = 'cupon' and o.cupon = x.codigo
                                                                and o.pagada_at >= x.inicio
                                                                and o.pagada_at <= coalesce(x.terminada_at, now())))
      ) m on true
     where x.vendedor_id = v.id
       and (x.inicio >= now() - make_interval(days => d) or liveshop__promo_vigente(x)));
end $$;

-- ----------------------------------------------------------------------------
-- Ventas
-- ----------------------------------------------------------------------------

create or replace function public.liveshop__kpis(p_vendedor uuid, p_desde timestamptz, p_hasta timestamptz) returns jsonb
language sql stable set search_path = public, extensions, pg_temp as $$
  select jsonb_build_object(
    'facturado',  coalesce((select sum(total) from liveshop_ordenes where vendedor_id = p_vendedor and estado = 'pagada'
                              and pagada_at >= p_desde and pagada_at < p_hasta), 0),
    'ventas',     (select count(*) from liveshop_ordenes where vendedor_id = p_vendedor and estado = 'pagada'
                     and pagada_at >= p_desde and pagada_at < p_hasta),
    'descuentos', coalesce((select sum(descuento) from liveshop_ordenes where vendedor_id = p_vendedor and estado = 'pagada'
                              and pagada_at >= p_desde and pagada_at < p_hasta), 0),
    'links',      (select count(*) from liveshop_ordenes where vendedor_id = p_vendedor
                     and created_at >= p_desde and created_at < p_hasta),
    'links_pagados', (select count(*) from liveshop_ordenes where vendedor_id = p_vendedor and estado = 'pagada'
                        and created_at >= p_desde and created_at < p_hasta),
    'entradas',   (select count(distinct sesion) from liveshop_eventos where vendedor_id = p_vendedor and tipo = 'entrada'
                     and created_at >= p_desde and created_at < p_hasta),
    'interesados', (select count(distinct sesion) from liveshop_eventos where vendedor_id = p_vendedor and tipo = 'interes'
                      and created_at >= p_desde and created_at < p_hasta),
    'pedidos',    (select count(*) from liveshop_eventos where vendedor_id = p_vendedor and tipo = 'interes'
                     and created_at >= p_desde and created_at < p_hasta))
$$;

create or replace function public.liveshop_ventas(p_token text, p_dias int default 30, p_estado text default null,
                                                  p_q text default null, p_pagina int default 0, p_por_pagina int default 20)
returns jsonb language plpgsql security definer set search_path = public, extensions, pg_temp as $$
declare
  v liveshop_vendedores;
  d int := least(greatest(coalesce(p_dias, 30), 1), 365);
  desde timestamptz := now() - make_interval(days => d);
  pp int := least(greatest(coalesce(p_por_pagina, 20), 1), 5000);
  pg int := greatest(coalesce(p_pagina, 0), 0);
  q text := liveshop__norm(trim(left(coalesce(p_q, ''), 40)));
  est text := nullif(trim(coalesce(p_estado, '')), '');
begin
  v := liveshop__cuenta(p_token);
  perform liveshop__vencer(v.id);
  return (
    with f as (
      select o.* from liveshop_ordenes o
       where o.vendedor_id = v.id and o.created_at >= desde
         and (est is null or o.estado = est)
         and (q = '' or liveshop__norm(o.producto_nombre) like '%' || q || '%'
                     or liveshop__norm(o.comprador) like '%' || q || '%'
                     or lower(o.ref) like '%' || q || '%')
    )
    select jsonb_build_object(
      'dias', d, 'pagina', pg, 'por_pagina', pp,
      'total_filas', (select count(*) from f),
      'filas', (select coalesce(jsonb_agg(liveshop__orden_json(x) || jsonb_build_object(
                                  'live_titulo', l.titulo, 'live_inicio', l.inicio)
                                order by x.created_at desc), '[]'::jsonb)
                  from (select * from f order by created_at desc offset pg * pp limit pp) x
                  left join liveshop_lives l on l.id = x.live_id),
      'actual', liveshop__kpis(v.id, desde, now() + interval '1 second'),
      'anterior', liveshop__kpis(v.id, desde - make_interval(days => d), desde),
      'pendientes', (select jsonb_build_object('cantidad', count(*), 'monto', coalesce(sum(total), 0))
                       from liveshop_ordenes where vendedor_id = v.id and estado = 'pendiente'),
      'meses', (select coalesce(jsonb_agg(jsonb_build_object('mes', m.mes, 'ventas', m.ventas, 'facturado', m.facturado,
                                                              'descuentos', m.descuentos) order by m.mes desc), '[]'::jsonb)
                  from (select to_char(liveshop__dia(pagada_at), 'YYYY-MM') as mes, count(*) as ventas,
                               sum(total) as facturado, sum(descuento) as descuentos
                          from liveshop_ordenes
                         where vendedor_id = v.id and estado = 'pagada'
                           and pagada_at >= date_trunc('month', now()) - interval '11 months'
                         group by 1) m)));
end $$;

-- ----------------------------------------------------------------------------
-- Reportes
-- ----------------------------------------------------------------------------

create or replace function public.liveshop__sugerencias(p_vendedor uuid) returns jsonb
language sql stable set search_path = public, extensions, pg_temp as $$
  with prod as (
    select p.*,
           (select count(*) from liveshop_eventos e where e.vendedor_id = p.vendedor_id and e.tipo = 'interes'
              and e.producto_id = p.id and e.created_at >= now() - interval '14 days') as pedidos14,
           (select count(*) from liveshop_ordenes o where o.vendedor_id = p.vendedor_id and o.estado = 'pagada'
              and o.producto_id = p.id and o.pagada_at >= now() - interval '14 days') as ventas14,
           (select count(*) from liveshop_ordenes o where o.vendedor_id = p.vendedor_id and o.estado = 'pagada'
              and o.producto_id = p.id and o.pagada_at >= now() - interval '7 days') as ventas7,
           (select max(o.pagada_at) from liveshop_ordenes o where o.vendedor_id = p.vendedor_id and o.estado = 'pagada'
              and o.producto_id = p.id) as ultima,
           (liveshop__promo_de(p.vendedor_id, p.id)).id as promo_id
      from liveshop_productos p
     where p.vendedor_id = p_vendedor
  ), s as (
    select 'reponer' as tipo, id as producto_id, nombre, pedidos14 * precio as monto,
           pedidos14 || ' pedidos de "' || nombre || '" en 2 semanas y está sin stock' as texto
      from prod where stock = 0 and pedidos14 >= 3
    union all
    select 'liquidar', id, nombre, stock * precio * 0.5,
           '"' || nombre || '" no se vende hace ' ||
           floor(extract(epoch from (now() - coalesce(ultima, creado_at))) / 86400)::int || ' días (' || stock || ' en stock)'
      from prod
     where stock > 0 and creado_at <= now() - interval '14 days' and promo_id is null
       and (ultima is null or ultima < now() - interval '30 days')
    union all
    select 'ultimas', id, nombre, stock * precio,
           'Quedan ' || stock || ' de "' || nombre || '" y se está vendiendo: destacalo en el próximo live'
      from prod where stock between 1 and 3 and ventas7 >= 1
    union all
    select 'precio', id, nombre, pedidos14 * precio * 0.3,
           '"' || nombre || '" tuvo ' || pedidos14 || ' pedidos y ninguna venta en 2 semanas: revisá el precio'
      from prod where stock > 0 and pedidos14 >= 5 and ventas14 = 0
    union all
    select 'cobrar', null, null, sum(total),
           'Tenés ' || count(*) || case when count(*) = 1 then ' link sin pagar' else ' links sin pagar' end
             || ' por $ ' || replace(to_char(sum(total), 'FM999,999,999'), ',', '.')
      from liveshop_ordenes where vendedor_id = p_vendedor and estado = 'pendiente'
    having count(*) > 0
  )
  select coalesce(jsonb_agg(jsonb_build_object('clave', tipo || ':' || coalesce(producto_id, ''), 'tipo', tipo,
                                               'producto_id', producto_id, 'producto', nombre, 'monto', round(monto),
                                               'texto', texto) order by monto desc), '[]'::jsonb)
    from (select * from s order by monto desc limit 6) s
$$;

create or replace function public.liveshop_reporte_resumen(p_token text, p_dias int default 30) returns jsonb
language plpgsql security definer set search_path = public, extensions, pg_temp as $$
declare
  v liveshop_vendedores;
  d int := least(greatest(coalesce(p_dias, 30), 1), 365);
  desde timestamptz := now() - make_interval(days => d);
  hoy date := liveshop__dia(now());
begin
  v := liveshop__cuenta(p_token);
  perform liveshop__vencer(v.id);
  perform liveshop__cerrar_promos(v.id);
  return jsonb_build_object(
    'dias', d,
    'actual', liveshop__kpis(v.id, desde, now() + interval '1 second'),
    'anterior', liveshop__kpis(v.id, desde - make_interval(days => d), desde),
    'serie', (select coalesce(jsonb_agg(jsonb_build_object('dia', to_char(g.dia, 'YYYY-MM-DD'),
                                                           'ventas', coalesce(x.ventas, 0),
                                                           'facturado', coalesce(x.facturado, 0)) order by g.dia), '[]'::jsonb)
                from generate_series(hoy - (d - 1), hoy, interval '1 day') as g(dia)
                left join (select liveshop__dia(pagada_at) as dia, count(*) as ventas, sum(total) as facturado
                             from liveshop_ordenes
                            where vendedor_id = v.id and estado = 'pagada' and pagada_at >= desde - interval '1 day'
                            group by 1) x on x.dia = g.dia::date),
    'sugerencias', liveshop__sugerencias(v.id));
end $$;

create or replace function public.liveshop_reporte_productos(p_token text, p_dias int default 30) returns jsonb
language plpgsql security definer set search_path = public, extensions, pg_temp as $$
declare
  v liveshop_vendedores;
  d int := least(greatest(coalesce(p_dias, 30), 1), 365);
  desde timestamptz := now() - make_interval(days => d);
begin
  v := liveshop__cuenta(p_token);
  return (
    with ids as (
      select id as producto_id from liveshop_productos where vendedor_id = v.id
      union
      select producto_id from liveshop_ordenes
       where vendedor_id = v.id and producto_id is not null and estado = 'pagada' and pagada_at >= desde
    ), r as (
      select i.producto_id,
             p.id is not null as en_catalogo,
             coalesce(p.nombre, (select o.producto_nombre from liveshop_ordenes o
                                  where o.vendedor_id = v.id and o.producto_id = i.producto_id
                                  order by o.created_at desc limit 1)) as nombre,
             coalesce(p.categoria, (select o.categoria from liveshop_ordenes o
                                     where o.vendedor_id = v.id and o.producto_id = i.producto_id
                                     order by o.created_at desc limit 1)) as categoria,
             p.emoji, p.stock, p.precio, p.costo, p.orden,
             (liveshop__promo_de(v.id, i.producto_id)).tipo as promo_tipo,
             coalesce(ov.unidades, 0) as unidades, coalesce(ov.facturado, 0) as facturado,
             coalesce(ov.descuento, 0) as descuento,
             (select count(*) from liveshop_eventos e where e.vendedor_id = v.id and e.tipo = 'interes'
                and e.producto_id = i.producto_id and e.created_at >= desde) as pedidos,
             (select count(*) from liveshop_eventos e where e.vendedor_id = v.id and e.tipo = 'vista_producto'
                and e.producto_id = i.producto_id and e.created_at >= desde) as vistas,
             (select max(o.pagada_at) from liveshop_ordenes o where o.vendedor_id = v.id and o.estado = 'pagada'
                and o.producto_id = i.producto_id) as ultima_venta,
             (select count(*) from liveshop_ordenes o where o.vendedor_id = v.id and o.estado = 'pendiente'
                and o.producto_id = i.producto_id) as pendientes
        from ids i
        left join liveshop_productos p on p.vendedor_id = v.id and p.id = i.producto_id
        left join lateral (
          select count(*) as unidades, sum(o.total) as facturado, sum(o.descuento) as descuento
            from liveshop_ordenes o
           where o.vendedor_id = v.id and o.producto_id = i.producto_id and o.estado = 'pagada' and o.pagada_at >= desde
        ) ov on true
    )
    select jsonb_build_object('dias', d, 'productos', coalesce(jsonb_agg(jsonb_build_object(
             'producto_id', producto_id, 'en_catalogo', en_catalogo, 'nombre', nombre, 'categoria', categoria,
             'emoji', emoji, 'stock', stock, 'precio', precio, 'costo', costo, 'promo_tipo', promo_tipo,
             'unidades', unidades, 'facturado', facturado, 'descuento', descuento,
             'ganancia', case when costo is not null then facturado - costo * unidades end,
             'pedidos', pedidos, 'vistas', vistas, 'ultima_venta', ultima_venta, 'pendientes', pendientes,
             'dias_stock', case when unidades > 0 and stock is not null then round(stock / (unidades::numeric / d)) end)
           order by facturado desc, pedidos desc, orden nulls last), '[]'::jsonb))
      from r);
end $$;

create or replace function public.liveshop_reporte_producto(p_token text, p_producto_id text, p_dias int default 90) returns jsonb
language plpgsql security definer set search_path = public, extensions, pg_temp as $$
declare
  v liveshop_vendedores;
  d int := least(greatest(coalesce(p_dias, 90), 7), 365);
  hoy date := liveshop__dia(now());
begin
  v := liveshop__cuenta(p_token);
  return jsonb_build_object(
    'producto_id', p_producto_id,
    'semanas', (select coalesce(jsonb_agg(jsonb_build_object('semana', to_char(g.s, 'YYYY-MM-DD'),
                                                             'unidades', coalesce(x.unidades, 0),
                                                             'facturado', coalesce(x.facturado, 0)) order by g.s), '[]'::jsonb)
                  from generate_series(date_trunc('week', hoy) - interval '11 weeks', date_trunc('week', hoy), interval '1 week') g(s)
                  left join (select date_trunc('week', liveshop__dia(pagada_at)) as s, count(*) as unidades, sum(total) as facturado
                               from liveshop_ordenes
                              where vendedor_id = v.id and producto_id = p_producto_id and estado = 'pagada'
                              group by 1) x on x.s = g.s),
    'lives', (select coalesce(jsonb_agg(jsonb_build_object('id', l.id, 'titulo', l.titulo, 'inicio', l.inicio,
                                                           'unidades', x.unidades) order by l.inicio desc), '[]'::jsonb)
                from (select live_id, count(*) as unidades from liveshop_ordenes
                       where vendedor_id = v.id and producto_id = p_producto_id and estado = 'pagada' and live_id is not null
                         and pagada_at >= now() - make_interval(days => d)
                       group by 1) x
                join liveshop_lives l on l.id = x.live_id),
    'ordenes', (select coalesce(jsonb_agg(liveshop__orden_json(o) order by o.created_at desc), '[]'::jsonb)
                  from (select * from liveshop_ordenes
                         where vendedor_id = v.id and producto_id = p_producto_id
                           and created_at >= now() - make_interval(days => d)
                         order by created_at desc limit 30) o),
    'promos', (select coalesce(jsonb_agg(jsonb_build_object('tipo', x.tipo, 'pct', x.pct, 'precio', x.precio,
                                                            'inicio', x.inicio, 'fin', coalesce(x.terminada_at, x.fin),
                                                            'vendidas', x.vendidas) order by x.inicio desc), '[]'::jsonb)
                 from liveshop_promos x
                where x.vendedor_id = v.id and x.producto_id = p_producto_id
                  and x.inicio >= now() - make_interval(days => d)));
end $$;

create or replace function public.liveshop_reporte_lives(p_token text, p_dias int default 30) returns jsonb
language plpgsql security definer set search_path = public, extensions, pg_temp as $$
declare
  v liveshop_vendedores;
  d int := least(greatest(coalesce(p_dias, 30), 1), 365);
  desde timestamptz := now() - make_interval(days => d);
begin
  v := liveshop__cuenta(p_token);
  return jsonb_build_object(
    'dias', d,
    'lives', (select coalesce(jsonb_agg(jsonb_build_object(
                'id', l.id, 'titulo', l.titulo, 'inicio', l.inicio, 'fin', l.fin_ef, 'abierto', l.fin is null,
                'minutos', round(extract(epoch from (l.fin_ef - l.inicio)) / 60), 'pico', l.pico,
                'entradas', (select count(distinct e.sesion) from liveshop_eventos e
                              where e.vendedor_id = v.id and e.tipo = 'entrada'
                                and e.created_at >= l.inicio and e.created_at <= l.fin_ef),
                'links', (select count(*) from liveshop_ordenes o where o.vendedor_id = v.id and o.live_id = l.id),
                'ventas', (select count(*) from liveshop_ordenes o where o.vendedor_id = v.id and o.live_id = l.id
                             and o.estado = 'pagada'),
                'facturado', (select coalesce(sum(o.total), 0) from liveshop_ordenes o
                               where o.vendedor_id = v.id and o.live_id = l.id and o.estado = 'pagada'),
                'estrella', (select o.producto_nombre from liveshop_ordenes o
                              where o.vendedor_id = v.id and o.live_id = l.id and o.estado = 'pagada'
                              group by o.producto_nombre order by count(*) desc, sum(o.total) desc limit 1))
              order by l.inicio desc), '[]'::jsonb)
                from (select x.*, coalesce(x.fin, least(now(), x.inicio + interval '6 hours')) as fin_ef
                        from liveshop_lives x
                       where x.vendedor_id = v.id and x.inicio >= desde) l),
    'calor', (select coalesce(jsonb_agg(jsonb_build_object('dow', c.dow, 'hora', c.hora, 'ventas', c.ventas,
                                                           'facturado', c.facturado)), '[]'::jsonb)
                from (select extract(isodow from (pagada_at at time zone 'America/Montevideo'))::int as dow,
                             extract(hour from (pagada_at at time zone 'America/Montevideo'))::int as hora,
                             count(*) as ventas, sum(total) as facturado
                        from liveshop_ordenes
                       where vendedor_id = v.id and estado = 'pagada' and pagada_at >= desde
                       group by 1, 2) c));
end $$;

-- ----------------------------------------------------------------------------
-- Metricas (reescritas: el facturado sale de liveshop_ordenes)
-- ----------------------------------------------------------------------------

create or replace function public.liveshop__resumen_vendedores(p_desde timestamptz, p_sin_demo boolean default false)
returns table(vendedor_id uuid, entradas bigint, compradores bigint, interes bigint,
              video_ok bigint, video_falla bigint, transmisiones bigint, mensajes bigint,
              links bigint, monto_links numeric, pico numeric, pagos bigint, facturado numeric, descuentos numeric)
language sql stable set search_path = public, extensions, pg_temp as $$
  select v.id,
         count(e.id) filter (where e.tipo = 'entrada'),
         count(distinct e.sesion) filter (where e.tipo = 'entrada'),
         count(e.id) filter (where e.tipo = 'interes'),
         count(e.id) filter (where e.tipo = 'video_ok'),
         count(e.id) filter (where e.tipo = 'video_falla'),
         count(e.id) filter (where e.tipo = 'transmision'),
         count(e.id) filter (where e.tipo = 'mensaje'),
         count(e.id) filter (where e.tipo = 'link_pago'),
         coalesce(sum(e.valor) filter (where e.tipo = 'link_pago'), 0),
         coalesce(max(e.valor) filter (where e.tipo = 'pico'), 0),
         (select count(*) from liveshop_ordenes o where o.vendedor_id = v.id and o.estado = 'pagada'
             and o.pagada_at >= p_desde and not (p_sin_demo and o.demo)),
         (select coalesce(sum(o.total), 0) from liveshop_ordenes o where o.vendedor_id = v.id and o.estado = 'pagada'
             and o.pagada_at >= p_desde and not (p_sin_demo and o.demo)),
         (select coalesce(sum(o.descuento), 0) from liveshop_ordenes o where o.vendedor_id = v.id and o.estado = 'pagada'
             and o.pagada_at >= p_desde and not (p_sin_demo and o.demo))
    from liveshop_vendedores v
    left join liveshop_eventos e on e.vendedor_id = v.id and e.created_at >= p_desde and not (p_sin_demo and e.demo)
   where v.rol = 'vendedor'
   group by v.id
$$;

create or replace function public.liveshop_metricas(p_token text, p_dias int) returns jsonb
language plpgsql security definer set search_path = public, extensions, pg_temp as $$
declare v liveshop_vendedores; d int := least(greatest(coalesce(p_dias, 30), 1), 365);
begin
  v := liveshop__cuenta(p_token);
  return (select to_jsonb(m) - 'vendedor_id' || jsonb_build_object('dias', d)
            from liveshop__resumen_vendedores(now() - make_interval(days => d)) m
           where m.vendedor_id = v.id);
end $$;

create or replace function public.liveshop_metricas_admin(p_token text, p_dias int, p_sin_demo boolean default false) returns jsonb
language plpgsql security definer set search_path = public, extensions, pg_temp as $$
declare
  v liveshop_vendedores;
  d int := least(greatest(coalesce(p_dias, 30), 1), 365);
  desde timestamptz := now() - make_interval(days => d);
  hoy date := liveshop__dia(now());
  sd boolean := coalesce(p_sin_demo, false);
begin
  v := liveshop__cuenta(p_token);
  if v.rol <> 'admin' then
    raise exception 'LS:solo_admin' using errcode = 'P0001';
  end if;

  return (
    with m as (
      select ve.usuario, ve.nombre, ve.sala, ve.created_at, x.*
        from liveshop__resumen_vendedores(desde, sd) x
        join liveshop_vendedores ve on ve.id = x.vendedor_id
    )
    select jsonb_build_object(
      'dias', d,
      'sin_demo', sd,
      'totales', (select jsonb_build_object(
                    'vendedores',    count(*),
                    'activos',       count(*) filter (where entradas + transmisiones + links + pagos > 0),
                    'entradas',      coalesce(sum(entradas), 0),
                    'compradores',   coalesce(sum(compradores), 0),
                    'interes',       coalesce(sum(interes), 0),
                    'video_ok',      coalesce(sum(video_ok), 0),
                    'video_falla',   coalesce(sum(video_falla), 0),
                    'transmisiones', coalesce(sum(transmisiones), 0),
                    'mensajes',      coalesce(sum(mensajes), 0),
                    'links',         coalesce(sum(links), 0),
                    'monto_links',   coalesce(sum(monto_links), 0),
                    'pico',          coalesce(max(pico), 0),
                    'pagos',         coalesce(sum(pagos), 0),
                    'facturado',     coalesce(sum(facturado), 0),
                    'descuentos',    coalesce(sum(descuentos), 0))
                  from m),
      'vendedores', (select coalesce(jsonb_agg(to_jsonb(m) - 'vendedor_id'
                                               order by m.facturado desc, m.entradas desc, m.usuario), '[]'::jsonb)
                       from m),
      'serie', (select coalesce(jsonb_agg(jsonb_build_object(
                          'dia', to_char(g.dia, 'YYYY-MM-DD'),
                          'entradas', coalesce(en.n, 0),
                          'pagos', coalesce(pa.n, 0),
                          'facturado', coalesce(pa.f, 0))
                        order by g.dia), '[]'::jsonb)
                  from generate_series(hoy - (d - 1), hoy, interval '1 day') as g(dia)
                  left join (select liveshop__dia(created_at) as dia, count(*) as n from liveshop_eventos
                              where tipo = 'entrada' and created_at >= desde - interval '1 day' and not (sd and demo)
                              group by 1) en on en.dia = g.dia::date
                  left join (select liveshop__dia(pagada_at) as dia, count(*) as n, sum(total) as f from liveshop_ordenes
                              where estado = 'pagada' and pagada_at >= desde - interval '1 day' and not (sd and demo)
                              group by 1) pa on pa.dia = g.dia::date)
    ));
end $$;

-- ----------------------------------------------------------------------------
-- Historia de ejemplo para la cuenta demo
-- ----------------------------------------------------------------------------
-- Quien llega desde el portfolio entra con la cuenta Vendedor: si sus reportes
-- estuvieran en cero, las funcionalidades no existirian a sus ojos. Se genera
-- con una semilla fija por dia (dos visitantes ven lo mismo) y deja a proposito
-- un caso para cada sugerencia: la mochila sin stock y con pedidos, el reloj
-- quieto, la campera que se pide y no se vende, links sin cobrar. Todo queda
-- marcado demo: el reset lo borra y lo regenera sin tocar ventas reales.

create or replace function public.liveshop__seed_historial(p_vendedor uuid) returns void
language plpgsql set search_path = public, extensions, pg_temp as $$
declare
  hoy date := liveshop__dia(now());
  nombres text[] := array['Lucía','Martín','Sofía','Joaquín','Valentina','Mateo','Camila','Agustín','Florencia',
                          'Nicolás','Micaela','Santiago','Paula','Diego','Carolina','Federico','Rocío','Bruno'];
  titulos text[] := array['Novedades de la semana','Liquidación de temporada','Jueves de accesorios',
                          'Domingo de ofertas','Nueva colección','Preguntas y respuestas'];
  dd int; dia date; ini timestamptz; dur int; lid uuid; ult uuid; n int; i int; k int; seq int := 0;
  ses text; pid text; picks text[]; p liveshop_productos; t timestamptz; pagada boolean;
  promo_lentes uuid; promo_rel uuid; pr_id uuid; pr_tipo text; tot numeric; nom text; cid text;
begin
  perform setseed(((extract(doy from hoy)::int * 7919) % 1000) / 1000.0);

  delete from liveshop_ordenes where vendedor_id = p_vendedor and demo;
  delete from liveshop_eventos where vendedor_id = p_vendedor and demo;
  delete from liveshop_promos  where vendedor_id = p_vendedor and demo;
  delete from liveshop_lives   where vendedor_id = p_vendedor and demo;
  -- las promos que dejaron visitantes en la cuenta demo se cierran
  update liveshop_promos set terminada_at = now() where vendedor_id = p_vendedor and terminada_at is null;

  -- descuento vigente en lentes desde hace 2 dias
  insert into liveshop_promos(vendedor_id, tipo, producto_id, pct, inicio, fin, demo)
  values (p_vendedor, 'descuento', 'seed-5', 20, now() - interval '2 days', now() + interval '5 days', true)
  returning id into promo_lentes;

  for dd in reverse 60..1 loop
    dia := hoy - dd;
    continue when not (extract(dow from dia) in (0, 4) or dd % 9 = 0);

    ini := ((dia + time '20:00') + make_interval(mins => (random() * 40)::int)) at time zone 'America/Montevideo';
    dur := 55 + (random() * 45)::int;
    insert into liveshop_lives(vendedor_id, titulo, inicio, fin, pico, demo)
    values (p_vendedor, titulos[1 + (random() * (array_length(titulos, 1) - 1))::int], ini,
            ini + make_interval(mins => dur), 1 + (random() * 2)::int, true)
    returning id into lid;
    ult := lid;
    insert into liveshop_eventos(vendedor_id, tipo, valor, created_at, demo) values
      (p_vendedor, 'transmision', 1, ini, true),
      (p_vendedor, 'pico', 1 + (random() * 2)::int, ini + interval '10 minutes', true);

    -- que productos se piden y se venden en este live
    picks := array['seed-2','seed-2','seed-2','seed-2','seed-1','seed-1','seed-1','seed-5','seed-5','seed-5',
                   'seed-7','seed-7','seed-7','seed-7','seed-8','seed-8'];
    if dd > 14 then picks := picks || array['seed-6','seed-6']; end if;
    if dd > 18 then picks := picks || array['seed-4','seed-4','seed-4']; end if;

    -- el ultimo mes vende un poco mas que el anterior
    n := 12 + (random() * 16)::int + case when dd <= 30 then 6 else 0 end;
    for i in 1..n loop
      ses := 'demo-' || substr(lid::text, 1, 8) || '-' || i;
      insert into liveshop_eventos(vendedor_id, tipo, sesion, created_at, demo)
      values (p_vendedor, 'entrada', ses, ini + make_interval(secs => random() * dur * 60), true);
      if random() < 0.35 then
        insert into liveshop_eventos(vendedor_id, tipo, sesion, producto_id, created_at, demo)
        values (p_vendedor, 'interes', ses, picks[1 + floor(random() * array_length(picks, 1))::int],
                ini + make_interval(secs => random() * dur * 60), true);
      end if;
      if random() < 0.25 then
        insert into liveshop_eventos(vendedor_id, tipo, sesion, producto_id, created_at, demo)
        values (p_vendedor, 'vista_producto', ses, picks[1 + floor(random() * array_length(picks, 1))::int],
                ini + make_interval(secs => random() * dur * 60), true);
      end if;
    end loop;

    k := 2 + (random() * 3)::int + case when dd <= 30 then 1 else 0 end;
    for i in 1..k loop
      seq := seq + 1;
      pid := picks[1 + floor(random() * array_length(picks, 1))::int];
      select * into p from liveshop_productos where vendedor_id = p_vendedor and id = pid;
      continue when not found;
      t := ini + make_interval(secs => random() * dur * 60);
      pagada := random() < 0.72;
      pr_id := null; pr_tipo := null; tot := p.precio;
      if pid = 'seed-5' and t >= now() - interval '2 days' then
        pr_id := promo_lentes; pr_tipo := 'descuento'; tot := round(p.precio * 0.8);
      end if;
      nom := nombres[1 + floor(random() * array_length(nombres, 1))::int];
      cid := 'demo-c-' || seq;
      insert into liveshop_ordenes(vendedor_id, ref, estado, producto_id, producto_nombre, categoria, comprador_id,
                                   comprador, precio_lista, descuento, total, promo_id, promo_tipo, live_id, demo,
                                   created_at, pagada_at)
      values (p_vendedor, 'D' || to_char(dia, 'YYMMDD') || lpad(seq::text, 3, '0'),
              case when pagada then 'pagada' else 'vencida' end, p.id, p.nombre, p.categoria, cid, nom,
              p.precio, p.precio - tot, tot, pr_id, pr_tipo, lid, true, t,
              case when pagada then t + make_interval(mins => 1 + (random() * 7)::int) end);
      insert into liveshop_eventos(vendedor_id, tipo, valor, created_at, demo)
      values (p_vendedor, 'link_pago', tot, t, true),
             (p_vendedor, 'mensaje', 1, t - interval '2 minutes', true),
             (p_vendedor, 'mensaje', 1, t - interval '1 minute', true);
    end loop;
  end loop;

  -- oferta relampago en el ultimo live: auriculares al 20%, tope 5, se vendieron 3
  if ult is not null then
    select inicio into ini from liveshop_lives where id = ult;
    insert into liveshop_promos(vendedor_id, tipo, producto_id, pct, inicio, fin, max_unidades, vendidas,
                                live_id, terminada_at, demo, created_at)
    values (p_vendedor, 'relampago', 'seed-2', 20, ini + interval '20 minutes', ini + interval '30 minutes', 5, 3,
            ult, ini + interval '30 minutes', true, ini + interval '20 minutes')
    returning id into promo_rel;
    for i in 1..3 loop
      seq := seq + 1;
      t := ini + interval '21 minutes' + make_interval(mins => i * 2);
      insert into liveshop_ordenes(vendedor_id, ref, estado, producto_id, producto_nombre, categoria, comprador_id,
                                   comprador, precio_lista, descuento, total, promo_id, promo_tipo, live_id, demo,
                                   created_at, pagada_at)
      values (p_vendedor, 'D' || to_char(liveshop__dia(ini), 'YYMMDD') || lpad(seq::text, 3, '0'), 'pagada',
              'seed-2', 'Auriculares wireless', 'tecnologia', 'demo-c-' || seq,
              nombres[1 + floor(random() * array_length(nombres, 1))::int],
              2300, 460, 1840, promo_rel, 'relampago', ult, true, t, t + interval '1 minute');
    end loop;
  end if;

  -- el reloj: una sola venta hace 34 dias, despues nada
  seq := seq + 1;
  t := ((hoy - 34) + time '20:40') at time zone 'America/Montevideo';
  insert into liveshop_ordenes(vendedor_id, ref, estado, producto_id, producto_nombre, categoria, comprador_id,
                               comprador, precio_lista, descuento, total, demo, created_at, pagada_at)
  values (p_vendedor, 'D' || to_char(hoy - 34, 'YYMMDD') || lpad(seq::text, 3, '0'), 'pagada', 'seed-3',
          'Reloj minimalista', 'accesorios', 'demo-c-' || seq, 'Martín', 7500, 0, 7500, true, t, t + interval '3 minutes');

  -- la mochila se agoto y la siguen pidiendo; la campera se pide y no se vende
  for i in 1..12 loop
    insert into liveshop_eventos(vendedor_id, tipo, sesion, producto_id, created_at, demo)
    values (p_vendedor, 'interes', 'demo-m-' || i, 'seed-4', now() - make_interval(secs => random() * 10 * 86400), true);
  end loop;
  for i in 1..7 loop
    insert into liveshop_eventos(vendedor_id, tipo, sesion, producto_id, created_at, demo)
    values (p_vendedor, 'interes', 'demo-j-' || i, 'seed-6', now() - make_interval(secs => random() * 12 * 86400), true);
  end loop;

  -- tres links de hoy sin pagar
  foreach pid in array array['seed-6','seed-1','seed-8'] loop
    seq := seq + 1;
    select * into p from liveshop_productos where vendedor_id = p_vendedor and id = pid;
    continue when not found;
    t := now() - make_interval(mins => 30 + (random() * 900)::int);
    insert into liveshop_ordenes(vendedor_id, ref, estado, producto_id, producto_nombre, categoria, comprador_id,
                                 comprador, precio_lista, descuento, total, demo, created_at)
    values (p_vendedor, 'D' || to_char(hoy, 'YYMMDD') || lpad(seq::text, 3, '0'), 'pendiente', p.id, p.nombre,
            p.categoria, 'demo-c-' || seq, nombres[1 + floor(random() * array_length(nombres, 1))::int],
            p.precio, 0, p.precio, true, t);
  end loop;
end $$;

-- Reset diario de la cuenta demo (reescrita de la 001): ademas de las
-- contrasenas, vuelve el catalogo de ejemplo y regenera la historia.
create or replace function public.liveshop__reset_demo() returns void
language plpgsql set search_path = public, extensions, pg_temp as $$
declare vid uuid;
begin
  select id into vid from liveshop_vendedores where usuario = 'vendedor';
  if vid is null then
    update liveshop_vendedores set sala = left(sala, 19) || '-' || substr(md5(random()::text), 1, 4)
     where sala = 'vendedor';
    insert into liveshop_vendedores(usuario, pass_hash, nombre, sala, rol, protegido)
    values ('vendedor', crypt('Vendedor', gen_salt('bf', 8)), 'Vendedor', 'vendedor', 'vendedor', true)
    returning id into vid;
  else
    update liveshop_vendedores
       set pass_hash = crypt('Vendedor', gen_salt('bf', 8)), protegido = true, rol = 'vendedor'
     where id = vid;
  end if;
  perform liveshop__seed_catalogo(vid);
  perform liveshop__seed_historial(vid);

  insert into liveshop_vendedores(usuario, pass_hash, nombre, sala, rol, protegido)
  values ('admin', crypt('admin', gen_salt('bf', 8)), 'Administrador', null, 'admin', true)
  on conflict (usuario) do update
     set pass_hash = excluded.pass_hash, rol = 'admin', protegido = true, sala = null;
end $$;

create or replace function public.liveshop_catalogo_restaurar_demo(p_token text) returns jsonb
language plpgsql security definer set search_path = public, extensions, pg_temp as $$
declare v liveshop_vendedores;
begin
  v := liveshop__cuenta(p_token);
  if not v.protegido or v.rol <> 'vendedor' then
    raise exception 'LS:solo_demo' using errcode = 'P0001';
  end if;
  perform liveshop__seed_catalogo(v.id);
  perform liveshop__seed_historial(v.id);
  update liveshop_vendedores set nombre = 'Vendedor', foto = null where id = v.id returning * into v;
  return jsonb_build_object('cuenta', liveshop__cuenta_json(v), 'productos', liveshop__catalogo_json(v.id, null, true),
                            'promos', liveshop__promos_json(v.id));
end $$;

-- ----------------------------------------------------------------------------
-- Permisos (mismo bloque que la 001, para las funciones nuevas)
-- ----------------------------------------------------------------------------

do $$
declare f regprocedure; r text;
begin
  for f in select p.oid::regprocedure from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'public' and p.proname like 'liveshop%'
              and p.proname <> 'liveshop_overview'
  loop
    execute format('revoke all on function %s from public', f);
    foreach r in array array['anon', 'authenticated'] loop
      if exists (select 1 from pg_roles where rolname = r) then
        execute format('revoke all on function %s from %I', f, r);
        if f::text not like 'liveshop\_\_%' then
          execute format('grant execute on function %s to %I', f, r);
        end if;
      end if;
    end loop;
  end loop;
end $$;

-- ----------------------------------------------------------------------------
-- Datos iniciales
-- ----------------------------------------------------------------------------

select public.liveshop__reset_demo();

notify pgrst, 'reload schema';
