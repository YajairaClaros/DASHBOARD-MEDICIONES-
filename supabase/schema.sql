-- Historial del Observatorio solar en Supabase (Postgres 15+).
-- Pegar completo en Supabase → SQL Editor → Run. Se puede volver a correr sin romper nada.
--
-- Diseño:
--   * El ESP32 nunca escribe directo en las tablas: llama a registrar(), que valida su token.
--   * El tablero solo lee (lecturas, termicas e historial()). La tabla dispositivos, con los
--     tokens, no es accesible desde la API.

create table if not exists public.dispositivos (
  id     text primary key,
  token  text not null,
  creado timestamptz not null default now()
);

create table if not exists public.lecturas (
  id            bigint generated always as identity primary key,
  creado        timestamptz not null default now(),
  dispositivo   text not null references public.dispositivos (id),
  voltaje       real,   -- V
  corriente     real,   -- A
  potencia      real,   -- W
  irradiancia   real,   -- W/m² (aproximada con la LDR)
  luz_pct       real,
  temp_ambiente real,   -- °C, LM35
  temp_panel    real,   -- °C, promedio de la cámara
  panel_min     real,
  panel_max     real,
  rssi          smallint
);
create index if not exists lecturas_dispositivo_creado on public.lecturas (dispositivo, creado desc);

create table if not exists public.termicas (
  id          bigint generated always as identity primary key,
  creado      timestamptz not null default now(),
  dispositivo text not null references public.dispositivos (id),
  ancho       smallint not null,
  alto        smallint not null,
  t_min       real,
  t_max       real,
  t_prom      real,
  datos       smallint[] not null   -- °C × 10 por píxel, fila por fila
);
create index if not exists termicas_dispositivo_creado on public.termicas (dispositivo, creado desc);

alter table public.dispositivos enable row level security;
alter table public.lecturas enable row level security;
alter table public.termicas enable row level security;

drop policy if exists "lectura publica" on public.lecturas;
create policy "lectura publica" on public.lecturas for select to anon, authenticated using (true);
drop policy if exists "lectura publica" on public.termicas;
create policy "lectura publica" on public.termicas for select to anon, authenticated using (true);

revoke all on public.dispositivos from anon, authenticated;
grant usage on schema public to anon, authenticated;
grant select on public.lecturas, public.termicas to anon, authenticated;

-- El ESP32 guarda una lectura y, opcionalmente, un cuadro térmico.
-- p_lectura y p_termica usan el mismo JSON que publica por MQTT.
create or replace function public.registrar(
  p_dispositivo text,
  p_token       text,
  p_lectura     jsonb,
  p_termica     jsonb default null
) returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not exists (select 1 from dispositivos d where d.id = p_dispositivo and d.token = p_token) then
    raise exception 'dispositivo no autorizado' using errcode = '42501';
  end if;

  if p_lectura is not null then
    insert into lecturas (dispositivo, voltaje, corriente, potencia, irradiancia, luz_pct,
                          temp_ambiente, temp_panel, panel_min, panel_max, rssi)
    values (p_dispositivo,
            (p_lectura ->> 'voltage')::real,
            (p_lectura ->> 'current')::real,
            (p_lectura ->> 'power')::real,
            (p_lectura ->> 'irradiance')::real,
            (p_lectura ->> 'light_pct')::real,
            (p_lectura ->> 'temp_ambient')::real,
            (p_lectura ->> 'temp_panel')::real,
            (p_lectura ->> 'panel_min')::real,
            (p_lectura ->> 'panel_max')::real,
            (p_lectura ->> 'rssi')::smallint);
  end if;

  if p_termica is not null then
    insert into termicas (dispositivo, ancho, alto, t_min, t_max, t_prom, datos)
    values (p_dispositivo,
            (p_termica ->> 'w')::smallint,
            (p_termica ->> 'h')::smallint,
            (p_termica ->> 'min')::real,
            (p_termica ->> 'max')::real,
            (p_termica ->> 'avg')::real,
            array(select e.v::smallint
                  from jsonb_array_elements_text(p_termica -> 'data') with ordinality as e(v, n)
                  order by e.n));
  end if;
end;
$$;

revoke execute on function public.registrar(text, text, jsonb, jsonb) from public;
grant execute on function public.registrar(text, text, jsonb, jsonb) to anon, authenticated;

-- Historial resumido para las gráficas: promedia en tramos para devolver como máximo
-- ~p_puntos filas. La corriente se recalcula como potencia/voltaje para que la energía cuadre.
create or replace function public.historial(
  p_dispositivo text,
  p_desde       timestamptz default null,
  p_hasta       timestamptz default now(),
  p_puntos      int default 900
) returns table (
  t             timestamptz,
  voltaje       real,
  corriente     real,
  irradiancia   real,
  temp_panel    real,
  temp_ambiente real,
  muestras      int
)
language sql
stable
set search_path = public
as $$
  with rango as (
    select coalesce(p_desde, (select min(l.creado) from lecturas l where l.dispositivo = p_dispositivo)) as desde,
           p_hasta as hasta
  ), paso as (
    select desde, hasta,
           greatest(15, ceil(extract(epoch from (hasta - desde)) / greatest(p_puntos, 1)))::int as seg
    from rango
    where desde is not null
  )
  select date_bin(make_interval(secs => paso.seg), l.creado, paso.desde) as t,
         avg(l.voltaje)::real,
         (case when avg(l.voltaje) > 0 then avg(l.potencia) / avg(l.voltaje) else avg(l.corriente) end)::real,
         avg(l.irradiancia)::real,
         avg(l.temp_panel)::real,
         avg(l.temp_ambiente)::real,
         count(*)::int
  from lecturas l, paso
  where l.dispositivo = p_dispositivo
    and l.creado >= paso.desde
    and l.creado <= paso.hasta
  group by 1
  order by 1;
$$;

grant execute on function public.historial(text, timestamptz, timestamptz, int) to anon, authenticated;
