-- ═══════════════════════════════════════════════════════════════════════════
--  SISTEMA DE INVITADOS MULTI-CLIENTE
--  Una sola base para todas las bodas.
--
--  Pegar TODO esto en Supabase → SQL Editor → New query → Run.
--  Se puede correr varias veces sin romper nada.
--
--  Va a salir el aviso "Potential issue detected / destructive operations":
--  es por los `drop policy if exists`. Es normal, darle a "Run query".
--  Resultado esperado: "Success. No rows returned"
--
--  ┌─────────────────────────────────────────────────────────────────────┐
--  │  bodas      → un renglón por cliente, con sus funciones prendidas    │
--  │  invitados  → todos los invitados de todas las bodas                 │
--  │  perfiles   → quién es quién: 'super' (vos) o 'novio' (el cliente)   │
--  └─────────────────────────────────────────────────────────────────────┘
-- ═══════════════════════════════════════════════════════════════════════════


-- ───────────────────────────────────────────────────────────────────────────
--  1. LOS CLIENTES
-- ───────────────────────────────────────────────────────────────────────────

create table if not exists public.bodas (
  id        uuid primary key default gen_random_uuid(),

  -- Nombre corto sin espacios, para identificarla de un vistazo: 'ana-lucia-marcelo'
  slug      text not null unique,
  nombre    text not null,              -- 'Ana Lucía & Marcelo'
  fecha     date,

  -- El dominio del sitio de ESA boda. Se usa para armar los links de los
  -- invitados desde el panel central, donde window.location.origin sería
  -- el dominio equivocado.
  sitio_url text,

  -- El interruptor de siempre, pero ahora por cliente en vez de global:
  -- apagarlo congela la lista de ese cliente sin tocar a los demás.
  registro_abierto boolean not null default true,

  -- ═══ LAS FUNCIONES QUE TIENE CONTRATADAS ═══
  -- Prendiendo y apagando estas casillas cambia lo que ve el cliente en su
  -- panel y lo que pide su invitación. Un solo código para todos.
  --
  --   confirmacion  → el invitado puede confirmar asistencia
  --   mesa          → columna de número de mesa en el panel
  --   acompanantes  → el invitado escribe los nombres de quienes lo acompañan
  funciones jsonb not null default
    '{"confirmacion": true, "mesa": false, "acompanantes": false}'::jsonb,

  activa    boolean not null default true,
  creado_en timestamptz not null default now()
);


-- ───────────────────────────────────────────────────────────────────────────
--  2. LOS INVITADOS  (de todas las bodas, juntos)
-- ───────────────────────────────────────────────────────────────────────────

create table if not exists public.invitados (
  id       uuid primary key default gen_random_uuid(),
  boda_id  uuid not null references public.bodas (id) on delete cascade,

  -- ⚠️ ÚNICO ENTRE TODAS LAS BODAS, no solo dentro de una.
  -- Así buscar_invitado() encuentra al dueño del código sin preguntar de qué
  -- boda es, y un link nunca puede apuntar a dos personas distintas.
  codigo   text not null unique,

  nombre   text not null,
  pases    integer not null default 1 check (pases between 1 and 30),

  -- ── Confirmación ──
  -- confirmado: null = no respondió · true = viene · false = no viene
  -- asisten:    cuántos vienen de verdad. Distinto de `pases`: una invitación
  --             de 2 donde va uno solo libera un lugar, y eso es justo lo que
  --             hay que saber para reservar.
  confirmado    boolean,
  asisten       integer check (asisten is null or asisten >= 0),
  acompanantes  text[] not null default '{}',
  confirmado_en timestamptz,

  -- ── Opcional (función 'mesa') ──
  mesa     integer check (mesa is null or mesa > 0),

  creado_en timestamptz not null default now()
);

create index if not exists invitados_boda_idx   on public.invitados (boda_id, creado_en desc);
create index if not exists invitados_codigo_idx on public.invitados (codigo);


-- ───────────────────────────────────────────────────────────────────────────
--  3. QUIÉN ES QUIÉN
-- ───────────────────────────────────────────────────────────────────────────

create table if not exists public.perfiles (
  id      uuid primary key references auth.users (id) on delete cascade,

  --   'super' → vos: ves y administrás todas las bodas
  --   'novio' → el cliente: solo ve la suya
  rol     text not null default 'novio' check (rol in ('super', 'novio')),

  -- Null para el super (no pertenece a ninguna en particular)
  boda_id uuid references public.bodas (id) on delete set null
);

create index if not exists perfiles_boda_idx on public.perfiles (boda_id);


-- ───────────────────────────────────────────────────────────────────────────
--  4. FUNCIONES DE IDENTIDAD
--
--  security definer para que puedan leer `perfiles` sin quedar atrapadas en
--  las políticas de `perfiles` (si no, se llaman a sí mismas en bucle).
-- ───────────────────────────────────────────────────────────────────────────

create or replace function public.soy_super()
returns boolean
language sql stable security definer set search_path = public
as $$
  select exists (
    select 1 from public.perfiles where id = auth.uid() and rol = 'super'
  );
$$;

create or replace function public.mi_boda()
returns uuid
language sql stable security definer set search_path = public
as $$
  select boda_id from public.perfiles where id = auth.uid();
$$;

-- ¿Puedo modificar la lista de esta boda? El super siempre; el cliente solo
-- si su registro está abierto.
create or replace function public.puedo_editar(la_boda uuid)
returns boolean
language sql stable security definer set search_path = public
as $$
  select
    public.soy_super()
    or (
      la_boda = public.mi_boda()
      and coalesce((select registro_abierto from public.bodas where id = la_boda), false)
    );
$$;


-- ───────────────────────────────────────────────────────────────────────────
--  5. LA PUERTA DEL INVITADO
--
--  El invitado anónimo NO puede leer ninguna tabla. Solo puede llamar a estas
--  dos funciones, que exigen el código exacto y devuelven como mucho UNA fila.
--  No hay forma de listar nada ni de saber que existen otras bodas.
-- ───────────────────────────────────────────────────────────────────────────

drop function if exists public.buscar_invitado(text);

create function public.buscar_invitado(codigo_buscado text)
returns table (
  nombre       text,
  pases        integer,
  confirmado   boolean,
  asisten      integer,
  acompanantes text[],
  mesa         integer,
  funciones    jsonb
)
language sql stable security definer set search_path = public
as $$
  select i.nombre, i.pases, i.confirmado, i.asisten, i.acompanantes,
         case when b.funciones->>'mesa' = 'true' then i.mesa else null end,
         b.funciones
  from public.invitados i
  join public.bodas b on b.id = i.boda_id
  where i.codigo = codigo_buscado and b.activa
  limit 1;
$$;


-- El invitado responde. Solo puede tocar SU fila (la del código) y solo las
-- columnas de confirmación: no puede cambiar su nombre, sus pases, su mesa,
-- ni la fila de nadie más.
--
-- Se puede llamar más de una vez: quien confirmó por dos y después se queda
-- solo vuelve a entrar por el mismo link y corrige.
drop function if exists public.confirmar_asistencia(text, boolean, integer);
drop function if exists public.confirmar_asistencia(text, boolean, integer, text[]);

create function public.confirmar_asistencia(
  codigo_buscado      text,
  asiste              boolean,
  cantidad            integer default null,
  acompanantes_nuevos text[]  default null
)
returns table (
  nombre       text,
  pases        integer,
  confirmado   boolean,
  asisten      integer,
  acompanantes text[],
  mesa         integer,
  funciones    jsonb
)
language plpgsql volatile security definer set search_path = public
as $$
declare
  fila    public.invitados%rowtype;
  permite boolean;
  cuantos integer;
  limpios text[];
begin
  select i.* into fila from public.invitados i where i.codigo = codigo_buscado;
  if not found then
    return;  -- código inexistente: nada se toca y nada se devuelve
  end if;

  -- Si el cliente no contrató la confirmación, la función no hace nada.
  select coalesce((b.funciones->>'confirmacion')::boolean, false) into permite
  from public.bodas b where b.id = fila.boda_id and b.activa;

  if not coalesce(permite, false) then
    return query select * from public.buscar_invitado(codigo_buscado);
    return;
  end if;

  /*
     El número llega del navegador, así que no se confía en él: se recorta al
     rango que la invitación permite. Sin esto, cualquiera podría anotar diez
     asistentes en una invitación de dos pases.
  */
  if asiste is not true then
    cuantos := 0;
    limpios := '{}';
  else
    cuantos := least(greatest(coalesce(cantidad, fila.pases), 1), fila.pases);

    -- Los nombres se limpian acá y no en el navegador: fuera los espacios de
    -- sobra y los vacíos (los campos son opcionales, vienen vacíos a propósito).
    select coalesce(array_agg(x), '{}') into limpios
    from (
      select btrim(n) as x
      from unnest(coalesce(acompanantes_nuevos, '{}'::text[])) as n
      where btrim(n) <> ''
    ) s;

    -- Nunca más nombres que acompañantes: el invitado principal ya está en
    -- la columna `nombre`. Si baja de 3 a 2, el sobrante se descarta.
    limpios := limpios[1:greatest(cuantos - 1, 0)];
  end if;

  update public.invitados i
     set confirmado    = asiste,
         asisten       = cuantos,
         acompanantes  = limpios,
         confirmado_en = now()
   where i.id = fila.id;

  return query select * from public.buscar_invitado(codigo_buscado);
end;
$$;


-- ───────────────────────────────────────────────────────────────────────────
--  6. ALTA DE CLIENTES  (solo el super)
--
--  Crear el usuario en sí requiere la clave service_role, que JAMÁS puede ir
--  al navegador. Por eso el alta es en dos tiempos:
--    1) Supabase → Authentication → Add user  (30 segundos, a mano)
--    2) Desde tu panel: asignar ese correo a una boda con esta función
-- ───────────────────────────────────────────────────────────────────────────

create or replace function public.asignar_cliente(correo text, la_boda uuid)
returns text
language plpgsql volatile security definer set search_path = public
as $$
declare
  usuario uuid;
begin
  if not public.soy_super() then
    raise exception 'Solo el administrador puede asignar clientes';
  end if;

  select id into usuario from auth.users where lower(email) = lower(btrim(correo));
  if usuario is null then
    return 'No existe ningún usuario con ese correo. Creálo primero en Authentication → Add user.';
  end if;

  insert into public.perfiles (id, rol, boda_id)
  values (usuario, 'novio', la_boda)
  on conflict (id) do update set rol = 'novio', boda_id = excluded.boda_id;

  return 'Listo: ese usuario ya entra a esa boda.';
end;
$$;


-- Al crear un usuario nuevo se le arma el perfil vacío. Queda sin boda hasta
-- que lo asignes: así un usuario recién creado no ve nada de nadie.
create or replace function public.crear_perfil()
returns trigger
language plpgsql security definer set search_path = public
as $$
begin
  insert into public.perfiles (id, rol) values (new.id, 'novio')
  on conflict (id) do nothing;
  return new;
end;
$$;

drop trigger if exists al_crear_usuario on auth.users;
create trigger al_crear_usuario
  after insert on auth.users
  for each row execute function public.crear_perfil();


-- ───────────────────────────────────────────────────────────────────────────
--  7. PERMISOS DE LAS FUNCIONES
--  Estas dos son lo ÚNICO que el visitante anónimo puede ejecutar.
-- ───────────────────────────────────────────────────────────────────────────

revoke all on function public.buscar_invitado(text)                             from public;
revoke all on function public.confirmar_asistencia(text, boolean, int, text[])   from public;
revoke all on function public.asignar_cliente(text, uuid)                        from public;

grant execute on function public.buscar_invitado(text)                           to anon, authenticated;
grant execute on function public.confirmar_asistencia(text, boolean, int, text[]) to anon, authenticated;
grant execute on function public.asignar_cliente(text, uuid)                     to authenticated;


-- ───────────────────────────────────────────────────────────────────────────
--  8. ROW LEVEL SECURITY
--
--  ⚠️ ESTO ES LO QUE SEPARA A UN CLIENTE DE OTRO.
--  La clave publishable viaja al navegador y cualquiera la ve con F12. El
--  cliente 2 puede manipular todo el JavaScript que quiera: Postgres le va a
--  negar las filas del cliente 1. Un `if` en el frontend no protege nada.
-- ───────────────────────────────────────────────────────────────────────────

alter table public.bodas     enable row level security;
alter table public.invitados enable row level security;
alter table public.perfiles  enable row level security;

-- ── bodas ──
drop policy if exists "bodas: ver la propia"    on public.bodas;
drop policy if exists "bodas: super administra" on public.bodas;

create policy "bodas: ver la propia"
  on public.bodas for select to authenticated
  using (public.soy_super() or id = public.mi_boda());

-- Crear, editar y borrar bodas: solo vos.
create policy "bodas: super administra"
  on public.bodas for all to authenticated
  using (public.soy_super())
  with check (public.soy_super());

-- ── invitados ──
drop policy if exists "invitados: ver los de mi boda" on public.invitados;
drop policy if exists "invitados: alta"              on public.invitados;
drop policy if exists "invitados: edicion"           on public.invitados;
drop policy if exists "invitados: baja"              on public.invitados;

create policy "invitados: ver los de mi boda"
  on public.invitados for select to authenticated
  using (public.soy_super() or boda_id = public.mi_boda());

create policy "invitados: alta"
  on public.invitados for insert to authenticated
  with check (public.puedo_editar(boda_id));

create policy "invitados: edicion"
  on public.invitados for update to authenticated
  using (public.puedo_editar(boda_id))
  with check (public.puedo_editar(boda_id));

create policy "invitados: baja"
  on public.invitados for delete to authenticated
  using (public.puedo_editar(boda_id));

-- (el anónimo no tiene NINGUNA política en ninguna tabla: entra solo por las
--  dos funciones de la sección 5)

-- ── perfiles ──
drop policy if exists "perfiles: el propio"   on public.perfiles;
drop policy if exists "perfiles: super ve"    on public.perfiles;
drop policy if exists "perfiles: super edita" on public.perfiles;

create policy "perfiles: el propio"
  on public.perfiles for select to authenticated
  using (id = auth.uid());

create policy "perfiles: super ve"
  on public.perfiles for select to authenticated
  using (public.soy_super());

create policy "perfiles: super edita"
  on public.perfiles for all to authenticated
  using (public.soy_super())
  with check (public.soy_super());


-- ───────────────────────────────────────────────────────────────────────────
--  9. TIEMPO REAL
--  Para que el panel se actualice solo cuando entra un invitado nuevo o
--  cuando alguien confirma, sin que nadie apriete F5.
--
--  Realtime respeta el RLS de arriba: a cada cliente le llegan solo los
--  eventos de SU boda. El invitado anónimo no recibe nada.
-- ───────────────────────────────────────────────────────────────────────────

alter table public.invitados replica identity full;

do $$
begin
  alter publication supabase_realtime add table public.invitados;
exception when duplicate_object then null;
end;
$$;


-- ───────────────────────────────────────────────────────────────────────────
--  10. LA PRIMERA BODA
--  Ana Lucía & Marcelo. Para las siguientes usás el botón del panel.
-- ───────────────────────────────────────────────────────────────────────────

insert into public.bodas (slug, nombre, fecha, funciones)
values (
  'ana-lucia-marcelo',
  'Ana Lucía & Marcelo',
  '2026-10-10',
  '{"confirmacion": true, "mesa": false, "acompanantes": false}'::jsonb
)
on conflict (slug) do nothing;


-- Avisarle a la API que cambiaron las tablas. Sin esto contesta unos segundos:
--   Could not find the 'xxx' column of 'invitados' in the schema cache
notify pgrst, 'reload schema';


-- ───────────────────────────────────────────────────────────────────────────
--  LISTO. Ahora seguí con el PASO 3: crear tu usuario y marcarte como super.
-- ───────────────────────────────────────────────────────────────────────────
