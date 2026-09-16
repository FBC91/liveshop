-- =============================================================================
-- LiveShop · cuentas de vendedor, catalogo, conversaciones y metricas
--
-- Se ejecuta completo en el SQL editor de Supabase (proyecto myebxfostbafuogfymqa).
-- Es idempotente: se puede volver a correr sin romper datos.
--
-- Modelo de acceso: la pagina solo tiene la clave anonima, que es publica. Por eso
-- las tablas tienen RLS activo y NINGUNA politica: el rol anon no puede leer ni
-- escribir nada directo. Todo pasa por funciones SECURITY DEFINER que validan el
-- token de sesion y devuelven solo lo que corresponde (nunca hashes).
--
-- Errores: las funciones fallan con mensajes 'LS:<codigo>'. Login y registro, en
-- cambio, devuelven {ok:false, error} para que el intento fallido quede grabado
-- (un raise desharia el insert del limitador de intentos).
-- =============================================================================

create extension if not exists pgcrypto;   -- en Supabase ya vive en el schema extensions

-- ----------------------------------------------------------------------------
-- Tablas
-- ----------------------------------------------------------------------------

create table if not exists public.liveshop_vendedores(
  id          uuid primary key default gen_random_uuid(),
  usuario     text not null unique check (usuario ~ '^[a-z0-9_-]{3,24}$'),
  pass_hash   text not null,
  nombre      text not null check (char_length(nombre) between 1 and 40),
  foto        text check (foto is null or (char_length(foto) <= 150000 and foto like 'data:image/%')),
  -- la sala es el codigo del link publico (?live=<sala>); el admin no tiene
  sala        text unique check (sala is null or sala ~ '^[a-z0-9-]{3,24}$'),
  rol         text not null default 'vendedor' check (rol in ('vendedor','admin')),
  -- cuentas demo publicas: no se borran ni cambian contrasena, usuario o sala
  protegido   boolean not null default false,
  titulo      text not null default 'LiveShop' check (char_length(titulo) <= 60),
  destacado   text,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  check (rol = 'admin' or sala is not null)
);

create table if not exists public.liveshop_productos(
  vendedor_id uuid not null references public.liveshop_vendedores(id) on delete cascade,
  id          text not null check (id ~ '^[A-Za-z0-9_-]{1,40}$'),
  nombre      text not null check (char_length(nombre) between 1 and 50),
  precio      numeric(12,2) not null check (precio >= 0),
  stock       integer not null check (stock >= 0),
  emoji       text check (char_length(emoji) <= 16),
  img         text check (img is null or (char_length(img) <= 80000 and img like 'data:image/%')),
  orden       integer not null default 0,
  primary key (vendedor_id, id)
);

-- se guarda el hash del token, no el token: un volcado de la tabla no sirve para entrar
create table if not exists public.liveshop_sesiones(
  token_hash  text primary key,
  vendedor_id uuid not null references public.liveshop_vendedores(id) on delete cascade,
  created_at  timestamptz not null default now(),
  expires_at  timestamptz not null default now() + interval '7 days'
);
create index if not exists liveshop_sesiones_vendedor_idx on public.liveshop_sesiones(vendedor_id);

create table if not exists public.liveshop_conversaciones(
  vendedor_id  uuid not null references public.liveshop_vendedores(id) on delete cascade,
  comprador_id text not null check (char_length(comprador_id) between 1 and 64),
  datos        jsonb not null,
  updated_at   timestamptz not null default now(),
  primary key (vendedor_id, comprador_id)
);

create table if not exists public.liveshop_eventos(
  id          bigint generated always as identity primary key,
  vendedor_id uuid not null references public.liveshop_vendedores(id) on delete cascade,
  tipo        text not null check (tipo in
                ('entrada','interes','video_ok','video_falla','transmision','mensaje','link_pago','pico')),
  valor       numeric not null default 1,
  sesion      text,
  created_at  timestamptz not null default now()
);
create index if not exists liveshop_eventos_vendedor_idx on public.liveshop_eventos(vendedor_id, created_at);

-- la ref es unica por vendedor: si dos consolas de la misma cuenta reciben el
-- mismo aviso de pago, el stock baja una sola vez
create table if not exists public.liveshop_pagos(
  vendedor_id uuid not null references public.liveshop_vendedores(id) on delete cascade,
  ref         text not null check (ref ~ '^[A-Z0-9-]{3,24}$'),
  producto_id text,
  monto       numeric(12,2) not null check (monto >= 0),
  created_at  timestamptz not null default now(),
  primary key (vendedor_id, ref)
);
create index if not exists liveshop_pagos_fecha_idx on public.liveshop_pagos(vendedor_id, created_at);

create table if not exists public.liveshop_intentos(
  clave       text not null,
  created_at  timestamptz not null default now()
);
create index if not exists liveshop_intentos_idx on public.liveshop_intentos(clave, created_at);

do $$
declare t text;
begin
  foreach t in array array['liveshop_vendedores','liveshop_productos','liveshop_sesiones',
                           'liveshop_conversaciones','liveshop_eventos','liveshop_pagos','liveshop_intentos']
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

-- ----------------------------------------------------------------------------
-- Helpers internos (sin permiso de ejecucion para anon: ver el final)
-- ----------------------------------------------------------------------------

create or replace function public.liveshop__ip() returns text
language plpgsql stable set search_path = public, extensions, pg_temp as $$
declare h jsonb;
begin
  begin
    h := nullif(current_setting('request.headers', true), '')::jsonb;
  exception when others then
    h := null;
  end;
  return coalesce(nullif(h->>'cf-connecting-ip',''),
                  nullif(trim(split_part(coalesce(h->>'x-forwarded-for',''), ',', 1)),''),
                  nullif(h->>'x-real-ip',''),
                  'sin-ip');
end $$;

create or replace function public.liveshop__limite(p_clave text, p_max int, p_ventana interval) returns void
language plpgsql set search_path = public, extensions, pg_temp as $$
begin
  delete from liveshop_intentos where created_at < now() - interval '1 day';
  if (select count(*) from liveshop_intentos
       where clave = p_clave and created_at > now() - p_ventana) >= p_max then
    raise exception 'LS:demasiados_intentos' using errcode = 'P0001';
  end if;
end $$;

create or replace function public.liveshop__hash_token(p_token text) returns text
language sql immutable set search_path = public, extensions, pg_temp as $$
  select encode(digest(coalesce(p_token,''), 'sha256'), 'hex')
$$;

create or replace function public.liveshop__sesion_nueva(p_vendedor uuid) returns text
language plpgsql set search_path = public, extensions, pg_temp as $$
declare t text := encode(gen_random_bytes(32), 'hex');
begin
  delete from liveshop_sesiones where expires_at < now();
  insert into liveshop_sesiones(token_hash, vendedor_id) values (liveshop__hash_token(t), p_vendedor);
  return t;
end $$;

create or replace function public.liveshop__cuenta(p_token text) returns public.liveshop_vendedores
language plpgsql set search_path = public, extensions, pg_temp as $$
declare v liveshop_vendedores;
begin
  select ve.* into v
    from liveshop_sesiones s join liveshop_vendedores ve on ve.id = s.vendedor_id
   where s.token_hash = liveshop__hash_token(p_token) and s.expires_at > now();
  if not found then
    raise exception 'LS:sesion_invalida' using errcode = 'P0001';
  end if;
  return v;
end $$;

create or replace function public.liveshop__cuenta_json(v public.liveshop_vendedores) returns jsonb
language sql stable set search_path = public, extensions, pg_temp as $$
  select jsonb_build_object('usuario', v.usuario, 'nombre', v.nombre, 'foto', v.foto, 'sala', v.sala,
                            'rol', v.rol, 'protegido', v.protegido, 'titulo', v.titulo,
                            'destacado', v.destacado)
$$;

create or replace function public.liveshop__productos_json(p_vendedor uuid, p_limite int default null) returns jsonb
language sql stable set search_path = public, extensions, pg_temp as $$
  select coalesce(jsonb_agg(jsonb_build_object('id', p.id, 'nombre', p.nombre, 'precio', p.precio,
                                               'stock', p.stock, 'emoji', p.emoji, 'img', p.img)
                            order by p.orden), '[]'::jsonb)
    from (select * from liveshop_productos
           where vendedor_id = p_vendedor
           order by orden
           limit p_limite) p
$$;

create or replace function public.liveshop__seed_catalogo(p_vendedor uuid) returns void
language sql set search_path = public, extensions, pg_temp as $$
  delete from liveshop_productos where vendedor_id = p_vendedor;
  insert into liveshop_productos(vendedor_id, id, nombre, precio, stock, emoji, orden) values
    (p_vendedor, 'seed-1', 'Zapatillas urbanas',   4900,  6, '👟', 0),
    (p_vendedor, 'seed-2', 'Auriculares wireless', 2300,  9, '🎧', 1),
    (p_vendedor, 'seed-3', 'Reloj minimalista',    7500,  3, '⌚', 2),
    (p_vendedor, 'seed-4', 'Mochila impermeable',  3200,  0, '🎒', 3),
    (p_vendedor, 'seed-5', 'Lentes de sol',        1800, 12, '🕶️', 4);
  update liveshop_vendedores
     set titulo = 'LiveShop', destacado = 'seed-2', updated_at = now()
   where id = p_vendedor;
$$;

-- Cuentas demo. Corre al instalar y todos los dias (pg_cron): vuelve a poner las
-- contrasenas publicas y la marca de protegida, por si alguien toco la base a mano.
create or replace function public.liveshop__reset_demo() returns void
language plpgsql set search_path = public, extensions, pg_temp as $$
declare vid uuid;
begin
  select id into vid from liveshop_vendedores where usuario = 'vendedor';
  if vid is null then
    -- si alguien ocupo la sala 'vendedor' antes de instalar, se la liberamos a la demo
    update liveshop_vendedores set sala = left(sala, 19) || '-' || substr(md5(random()::text), 1, 4)
     where sala = 'vendedor';
    insert into liveshop_vendedores(usuario, pass_hash, nombre, sala, rol, protegido)
    values ('vendedor', crypt('Vendedor', gen_salt('bf', 8)), 'Vendedor', 'vendedor', 'vendedor', true)
    returning id into vid;
    perform liveshop__seed_catalogo(vid);
  else
    update liveshop_vendedores
       set pass_hash = crypt('Vendedor', gen_salt('bf', 8)), protegido = true, rol = 'vendedor'
     where id = vid;
  end if;

  insert into liveshop_vendedores(usuario, pass_hash, nombre, sala, rol, protegido)
  values ('admin', crypt('admin', gen_salt('bf', 8)), 'Administrador', null, 'admin', true)
  on conflict (usuario) do update
     set pass_hash = excluded.pass_hash, rol = 'admin', protegido = true, sala = null;
end $$;

create or replace function public.liveshop__metricas(p_desde timestamptz)
returns table(vendedor_id uuid, entradas bigint, compradores bigint, interes bigint,
              video_ok bigint, video_falla bigint, transmisiones bigint, mensajes bigint,
              links bigint, monto_links numeric, pico numeric, pagos bigint, facturado numeric)
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
         (select count(*) from liveshop_pagos p where p.vendedor_id = v.id and p.created_at >= p_desde),
         (select coalesce(sum(p.monto), 0) from liveshop_pagos p where p.vendedor_id = v.id and p.created_at >= p_desde)
    from liveshop_vendedores v
    left join liveshop_eventos e on e.vendedor_id = v.id and e.created_at >= p_desde
   where v.rol = 'vendedor'
   group by v.id
$$;

-- ----------------------------------------------------------------------------
-- Cuentas
-- ----------------------------------------------------------------------------

create or replace function public.liveshop_registrar(p_usuario text, p_password text, p_nombre text)
returns jsonb language plpgsql security definer set search_path = public, extensions, pg_temp as $$
declare
  u text := lower(trim(coalesce(p_usuario, '')));
  n text := left(trim(coalesce(p_nombre, '')), 40);
  s text;
  clave text := 'registro:' || liveshop__ip();
  v liveshop_vendedores;
begin
  perform liveshop__limite(clave, 5, interval '1 hour');
  if u !~ '^[a-z0-9_-]{3,24}$' then
    return jsonb_build_object('ok', false, 'error', 'usuario_invalido');
  end if;
  if u in ('admin', 'administrador', 'root', 'soporte', 'liveshop', 'vendedor')
     or exists (select 1 from liveshop_vendedores where usuario = u) then
    return jsonb_build_object('ok', false, 'error', 'usuario_tomado');
  end if;
  if char_length(coalesce(p_password, '')) not between 6 and 72 then
    return jsonb_build_object('ok', false, 'error', 'password_invalida');
  end if;
  if n = '' then n := u; end if;

  s := left(regexp_replace(u, '[^a-z0-9-]', '-', 'g'), 24);
  while exists (select 1 from liveshop_vendedores where sala = s) loop
    s := left(regexp_replace(u, '[^a-z0-9-]', '-', 'g'), 19) || '-' || substr(md5(random()::text), 1, 4);
  end loop;

  begin
    insert into liveshop_vendedores(usuario, pass_hash, nombre, sala)
    values (u, crypt(p_password, gen_salt('bf', 8)), n, s)
    returning * into v;
  exception when unique_violation then
    return jsonb_build_object('ok', false, 'error', 'usuario_tomado');
  end;

  insert into liveshop_intentos(clave) values (clave);
  return jsonb_build_object('ok', true, 'token', liveshop__sesion_nueva(v.id), 'cuenta', liveshop__cuenta_json(v));
end $$;

create or replace function public.liveshop_login(p_usuario text, p_password text)
returns jsonb language plpgsql security definer set search_path = public, extensions, pg_temp as $$
declare
  u text := lower(trim(coalesce(p_usuario, '')));
  -- la clave incluye la IP: sin eso, 8 intentos fallidos de un visitante
  -- bloquearian la cuenta demo para todos los demas
  clave text := 'login:' || liveshop__ip() || ':' || u;
  v liveshop_vendedores;
begin
  perform liveshop__limite(clave, 8, interval '15 minutes');
  select * into v from liveshop_vendedores where usuario = u;
  if not found or v.pass_hash <> crypt(coalesce(p_password, ''), v.pass_hash) then
    insert into liveshop_intentos(clave) values (clave);
    return jsonb_build_object('ok', false, 'error', 'credenciales');
  end if;
  return jsonb_build_object('ok', true, 'token', liveshop__sesion_nueva(v.id), 'cuenta', liveshop__cuenta_json(v));
end $$;

create or replace function public.liveshop_logout(p_token text) returns void
language sql security definer set search_path = public, extensions, pg_temp as $$
  delete from liveshop_sesiones where token_hash = liveshop__hash_token(p_token);
$$;

create or replace function public.liveshop_yo(p_token text) returns jsonb
language plpgsql security definer set search_path = public, extensions, pg_temp as $$
declare v liveshop_vendedores;
begin
  v := liveshop__cuenta(p_token);
  return jsonb_build_object(
    'cuenta', liveshop__cuenta_json(v),
    'productos', liveshop__productos_json(v.id),
    'conversaciones', (
      select coalesce(jsonb_agg(jsonb_build_object('id', c.comprador_id, 'datos', c.datos) order by c.updated_at), '[]'::jsonb)
        from (select * from liveshop_conversaciones
               where vendedor_id = v.id
               order by updated_at desc
               limit 100) c));
end $$;

-- p_cambios admite: nombre, foto ('' la quita), sala, password_actual + password_nueva
create or replace function public.liveshop_cuenta_editar(p_token text, p_cambios jsonb) returns jsonb
language plpgsql security definer set search_path = public, extensions, pg_temp as $$
declare
  v liveshop_vendedores;
  c jsonb := coalesce(p_cambios, '{}'::jsonb);
  txt text;
begin
  v := liveshop__cuenta(p_token);

  if c ? 'nombre' then
    txt := left(trim(coalesce(c->>'nombre', '')), 40);
    if txt = '' then raise exception 'LS:nombre_invalido' using errcode = 'P0001'; end if;
    update liveshop_vendedores set nombre = txt where id = v.id;
  end if;

  if c ? 'foto' then
    txt := nullif(c->>'foto', '');
    if txt is not null and (char_length(txt) > 150000 or txt not like 'data:image/%') then
      raise exception 'LS:foto_invalida' using errcode = 'P0001';
    end if;
    update liveshop_vendedores set foto = txt where id = v.id;
  end if;

  if c ? 'sala' then
    if v.protegido or v.rol <> 'vendedor' then
      raise exception 'LS:cuenta_protegida' using errcode = 'P0001';
    end if;
    txt := lower(trim(coalesce(c->>'sala', '')));
    if txt !~ '^[a-z0-9-]{3,24}$' then
      raise exception 'LS:sala_invalida' using errcode = 'P0001';
    end if;
    if exists (select 1 from liveshop_vendedores where sala = txt and id <> v.id) then
      raise exception 'LS:sala_tomada' using errcode = 'P0001';
    end if;
    update liveshop_vendedores set sala = txt where id = v.id;
  end if;

  if c ? 'password_nueva' then
    if v.protegido then
      raise exception 'LS:cuenta_protegida' using errcode = 'P0001';
    end if;
    if v.pass_hash <> crypt(coalesce(c->>'password_actual', ''), v.pass_hash) then
      raise exception 'LS:password_actual' using errcode = 'P0001';
    end if;
    txt := coalesce(c->>'password_nueva', '');
    if char_length(txt) not between 6 and 72 then
      raise exception 'LS:password_invalida' using errcode = 'P0001';
    end if;
    update liveshop_vendedores set pass_hash = crypt(txt, gen_salt('bf', 8)) where id = v.id;
    -- cambiar la contrasena cierra las otras sesiones abiertas de la cuenta
    delete from liveshop_sesiones where vendedor_id = v.id and token_hash <> liveshop__hash_token(p_token);
  end if;

  update liveshop_vendedores set updated_at = now() where id = v.id returning * into v;
  return liveshop__cuenta_json(v);
end $$;

create or replace function public.liveshop_cuenta_borrar(p_token text, p_password text) returns void
language plpgsql security definer set search_path = public, extensions, pg_temp as $$
declare v liveshop_vendedores;
begin
  v := liveshop__cuenta(p_token);
  if v.protegido then
    raise exception 'LS:cuenta_protegida' using errcode = 'P0001';
  end if;
  if v.pass_hash <> crypt(coalesce(p_password, ''), v.pass_hash) then
    raise exception 'LS:password_actual' using errcode = 'P0001';
  end if;
  delete from liveshop_vendedores where id = v.id;   -- cascada: catalogo, sesiones, chats, metricas
end $$;

-- ----------------------------------------------------------------------------
-- Catalogo
-- ----------------------------------------------------------------------------

create or replace function public.liveshop_catalogo_guardar(p_token text, p_productos jsonb, p_titulo text, p_destacado text)
returns void language plpgsql security definer set search_path = public, extensions, pg_temp as $$
declare v liveshop_vendedores;
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

  begin
    delete from liveshop_productos where vendedor_id = v.id;
    insert into liveshop_productos(vendedor_id, id, nombre, precio, stock, emoji, img, orden)
    select v.id, e->>'id', left(trim(e->>'nombre'), 50),
           greatest(0, (e->>'precio')::numeric),
           greatest(0, floor((e->>'stock')::numeric))::int,
           nullif(e->>'emoji', ''), nullif(e->>'img', ''), (o - 1)::int
      from jsonb_array_elements(p_productos) with ordinality as t(e, o);
  exception when check_violation or not_null_violation or unique_violation
                 or invalid_text_representation or numeric_value_out_of_range then
    raise exception 'LS:catalogo_invalido' using errcode = 'P0001';
  end;

  update liveshop_vendedores
     set titulo = coalesce(left(nullif(trim(p_titulo), ''), 60), 'LiveShop'),
         destacado = case when exists (select 1 from liveshop_productos
                                        where vendedor_id = v.id and id = p_destacado)
                          then p_destacado end,
         updated_at = now()
   where id = v.id;
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
  update liveshop_vendedores set nombre = 'Vendedor', foto = null where id = v.id returning * into v;
  return jsonb_build_object('cuenta', liveshop__cuenta_json(v), 'productos', liveshop__productos_json(v.id));
end $$;

-- ----------------------------------------------------------------------------
-- Lectura publica (compradores)
-- ----------------------------------------------------------------------------

create or replace function public.liveshop_directorio() returns jsonb
language sql stable security definer set search_path = public, extensions, pg_temp as $$
  select coalesce(jsonb_agg(x.j order by x.upd desc), '[]'::jsonb)
    from (select v.updated_at as upd,
                 jsonb_build_object('usuario', v.usuario, 'nombre', v.nombre, 'foto', v.foto,
                                    'sala', v.sala, 'titulo', v.titulo,
                                    'productos', liveshop__productos_json(v.id, 10)) as j
            from liveshop_vendedores v
           where v.rol = 'vendedor'
           order by v.updated_at desc
           limit 48) x
$$;

create or replace function public.liveshop_sala(p_sala text) returns jsonb
language sql stable security definer set search_path = public, extensions, pg_temp as $$
  select jsonb_build_object('usuario', v.usuario, 'nombre', v.nombre, 'foto', v.foto, 'sala', v.sala,
                            'titulo', v.titulo, 'destacado', v.destacado,
                            'productos', liveshop__productos_json(v.id))
    from liveshop_vendedores v
   where v.rol = 'vendedor' and v.sala = lower(trim(coalesce(p_sala, '')))
$$;

-- ----------------------------------------------------------------------------
-- Conversaciones
-- ----------------------------------------------------------------------------

create or replace function public.liveshop_conversaciones_guardar(p_token text, p_lista jsonb) returns void
language plpgsql security definer set search_path = public, extensions, pg_temp as $$
declare v liveshop_vendedores;
begin
  v := liveshop__cuenta(p_token);
  if jsonb_typeof(p_lista) is distinct from 'array' or jsonb_array_length(p_lista) > 50 then
    raise exception 'LS:conversaciones_invalidas' using errcode = 'P0001';
  end if;

  insert into liveshop_conversaciones(vendedor_id, comprador_id, datos, updated_at)
  select distinct on (e->>'id') v.id, left(e->>'id', 64), e->'datos', now()
    from jsonb_array_elements(p_lista) e
   where coalesce(e->>'id', '') <> ''
     and jsonb_typeof(e->'datos') = 'object'
     and length((e->'datos')::text) <= 300000
  on conflict (vendedor_id, comprador_id) do update
     set datos = excluded.datos, updated_at = now();

  delete from liveshop_conversaciones
   where vendedor_id = v.id
     and comprador_id not in (select comprador_id from liveshop_conversaciones
                               where vendedor_id = v.id
                               order by updated_at desc
                               limit 100);
end $$;

-- ----------------------------------------------------------------------------
-- Metricas
-- ----------------------------------------------------------------------------

-- Eventos del comprador: publicos, sin token. Solo tipos que no mueven plata.
create or replace function public.liveshop_evento(p_sala text, p_tipo text, p_sesion text) returns void
language plpgsql security definer set search_path = public, extensions, pg_temp as $$
declare vid uuid; ses text := left(coalesce(p_sesion, ''), 64);
begin
  if p_tipo not in ('entrada', 'interes', 'video_ok', 'video_falla') then return; end if;
  select id into vid from liveshop_vendedores where rol = 'vendedor' and sala = lower(trim(coalesce(p_sala, '')));
  if vid is null then return; end if;
  -- un refresh no cuenta como otra entrada
  if p_tipo in ('entrada', 'video_ok') and exists (
       select 1 from liveshop_eventos
        where vendedor_id = vid and tipo = p_tipo and sesion = ses
          and created_at > now() - interval '30 minutes') then
    return;
  end if;
  insert into liveshop_eventos(vendedor_id, tipo, sesion) values (vid, p_tipo, ses);
end $$;

-- Eventos del vendedor: con token.
create or replace function public.liveshop_evento_host(p_token text, p_tipo text, p_valor numeric) returns void
language plpgsql security definer set search_path = public, extensions, pg_temp as $$
declare v liveshop_vendedores;
begin
  v := liveshop__cuenta(p_token);
  if v.rol <> 'vendedor' or p_tipo not in ('transmision', 'mensaje', 'link_pago', 'pico') then return; end if;
  insert into liveshop_eventos(vendedor_id, tipo, valor)
  values (v.id, p_tipo, least(greatest(coalesce(p_valor, 1), 0), 10000000));
end $$;

create or replace function public.liveshop_pago_registrar(p_token text, p_ref text, p_producto_id text, p_monto numeric)
returns jsonb language plpgsql security definer set search_path = public, extensions, pg_temp as $$
declare v liveshop_vendedores; st int;
begin
  v := liveshop__cuenta(p_token);
  if coalesce(p_ref, '') !~ '^[A-Za-z0-9-]{3,24}$' then
    raise exception 'LS:ref_invalida' using errcode = 'P0001';
  end if;
  insert into liveshop_pagos(vendedor_id, ref, producto_id, monto)
  values (v.id, upper(p_ref), nullif(p_producto_id, ''), least(greatest(coalesce(p_monto, 0), 0), 9999999999))
  on conflict do nothing;
  if not found then
    select stock into st from liveshop_productos where vendedor_id = v.id and id = p_producto_id;
    return jsonb_build_object('duplicado', true, 'stock', st);
  end if;
  update liveshop_productos set stock = stock - 1
   where vendedor_id = v.id and id = p_producto_id and stock > 0
   returning stock into st;
  if st is null then
    select stock into st from liveshop_productos where vendedor_id = v.id and id = p_producto_id;
  end if;
  return jsonb_build_object('duplicado', false, 'stock', st);
end $$;

create or replace function public.liveshop_metricas(p_token text, p_dias int) returns jsonb
language plpgsql security definer set search_path = public, extensions, pg_temp as $$
declare v liveshop_vendedores; d int := least(greatest(coalesce(p_dias, 30), 1), 365);
begin
  v := liveshop__cuenta(p_token);
  return (select to_jsonb(m) - 'vendedor_id' || jsonb_build_object('dias', d)
            from liveshop__metricas(now() - make_interval(days => d)) m
           where m.vendedor_id = v.id);
end $$;

create or replace function public.liveshop_metricas_admin(p_token text, p_dias int) returns jsonb
language plpgsql security definer set search_path = public, extensions, pg_temp as $$
declare
  v liveshop_vendedores;
  d int := least(greatest(coalesce(p_dias, 30), 1), 365);
  desde timestamptz := now() - make_interval(days => d);
begin
  v := liveshop__cuenta(p_token);
  if v.rol <> 'admin' then
    raise exception 'LS:solo_admin' using errcode = 'P0001';
  end if;

  return (
    with m as (
      select ve.usuario, ve.nombre, ve.sala, ve.created_at, x.*
        from liveshop__metricas(desde) x
        join liveshop_vendedores ve on ve.id = x.vendedor_id
    )
    select jsonb_build_object(
      'dias', d,
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
                    'facturado',     coalesce(sum(facturado), 0))
                  from m),
      'vendedores', (select coalesce(jsonb_agg(to_jsonb(m) - 'vendedor_id'
                                               order by m.facturado desc, m.entradas desc, m.usuario), '[]'::jsonb)
                       from m),
      'serie', (select coalesce(jsonb_agg(jsonb_build_object(
                          'dia', to_char(g.dia, 'YYYY-MM-DD'),
                          'entradas', (select count(*) from liveshop_eventos e
                                        where e.tipo = 'entrada' and e.created_at >= g.dia
                                          and e.created_at < g.dia + interval '1 day'),
                          'pagos', (select count(*) from liveshop_pagos p
                                     where p.created_at >= g.dia and p.created_at < g.dia + interval '1 day'),
                          'facturado', (select coalesce(sum(p.monto), 0) from liveshop_pagos p
                                         where p.created_at >= g.dia and p.created_at < g.dia + interval '1 day'))
                        order by g.dia), '[]'::jsonb)
                  from generate_series(date_trunc('day', now()) - make_interval(days => d - 1),
                                       date_trunc('day', now()), interval '1 day') as g(dia))
    ));
end $$;

-- ----------------------------------------------------------------------------
-- Permisos
-- ----------------------------------------------------------------------------
-- Supabase da EXECUTE a anon sobre toda funcion nueva de public por defecto.
-- Los helpers (liveshop__*) no pueden quedar expuestos: liveshop__cuenta devuelve
-- el hash de la contrasena y liveshop__reset_demo resetea las cuentas.

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
-- Datos iniciales + reset diario
-- ----------------------------------------------------------------------------

select public.liveshop__reset_demo();

do $$
begin
  create extension if not exists pg_cron;
  perform cron.schedule('liveshop-reset-demo', '17 6 * * *', 'select public.liveshop__reset_demo()');
exception when others then
  raise notice 'pg_cron no disponible (%). Activarlo en Database > Extensions y volver a correr este bloque.', sqlerrm;
end $$;

notify pgrst, 'reload schema';
