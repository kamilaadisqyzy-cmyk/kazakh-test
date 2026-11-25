-- =====================================================================
--  Қазақ тілі тесті — Supabase базасы
--  Supabase → SQL Editor → New query → осы кодты түгел қойып → RUN
-- =====================================================================

-- ---------- 1. Пайдаланушылар (оқушы / мұғалім) ----------
create table if not exists public.profiles (
  id         uuid primary key references auth.users on delete cascade,
  login      text unique not null,
  full_name  text not null,
  class      text not null default '',
  role       text not null default 'student' check (role in ('student','teacher')),
  created_at timestamptz not null default now()
);

-- Тіркелгенде профиль автоматты жасалады (рөлі әрқашан 'student')
create or replace function public.handle_new_user()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  insert into public.profiles (id, login, full_name, class)
  values (
    new.id,
    coalesce(nullif(left(new.raw_user_meta_data->>'login', 30), ''), split_part(new.email, '@', 1)),
    coalesce(left(new.raw_user_meta_data->>'full_name', 100), ''),
    coalesce(left(new.raw_user_meta_data->>'class', 20), '')
  );
  return new;
end $$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

create or replace function public.is_teacher()
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.profiles where id = auth.uid() and role = 'teacher');
$$;

-- ---------- 2. Тесттер және дұрыс жауаптар ----------
create table if not exists public.tests (
  id         bigint generated always as identity primary key,
  title      text not null,
  questions  jsonb not null,          -- [{"q": "...", "options": ["...", "..."]}]
  active     boolean not null default true,
  created_at timestamptz not null default now()
);

-- Дұрыс жауаптар бөлек кестеде: оқушылар оны оқи алмайды
create table if not exists public.test_keys (
  test_id bigint primary key references public.tests on delete cascade,
  answers int[] not null              -- әр сұрақтың дұрыс нұсқасының нөмірі (0-ден)
);

-- ---------- 3. Нәтижелер ----------
create table if not exists public.results (
  id         bigint generated always as identity primary key,
  user_id    uuid not null references public.profiles on delete cascade,
  test_id    bigint not null references public.tests on delete cascade,
  score      int not null,
  total      int not null,
  percent    int not null,
  answers    int[] not null,
  created_at timestamptz not null default now(),
  unique (user_id, test_id)           -- бір тестті бір рет тапсырады
);

-- ---------- 4. Қауіпсіздік ережелері (RLS) ----------
-- Data API-ге кіру құқығы (жолдарды төмендегі RLS ережелері шектейді)
grant usage on schema public to authenticated;
grant select on public.profiles, public.tests, public.test_keys, public.results to authenticated;
grant update, delete on public.tests to authenticated;
grant delete on public.results to authenticated;
revoke all on public.profiles, public.tests, public.test_keys, public.results from anon;

alter table public.profiles  enable row level security;
alter table public.tests     enable row level security;
alter table public.test_keys enable row level security;
alter table public.results   enable row level security;

drop policy if exists "profiles read"  on public.profiles;
drop policy if exists "tests read"     on public.tests;
drop policy if exists "tests update"   on public.tests;
drop policy if exists "tests delete"   on public.tests;
drop policy if exists "keys read"      on public.test_keys;
drop policy if exists "results read"   on public.results;
drop policy if exists "results delete" on public.results;

-- Оқушы тек өзін, мұғалім бәрін көреді
create policy "profiles read"  on public.profiles  for select to authenticated using (id = auth.uid() or public.is_teacher());
-- Оқушы тек белсенді тесттерді көреді
create policy "tests read"     on public.tests     for select to authenticated using (active or public.is_teacher());
create policy "tests update"   on public.tests     for update to authenticated using (public.is_teacher()) with check (public.is_teacher());
create policy "tests delete"   on public.tests     for delete to authenticated using (public.is_teacher());
-- Дұрыс жауаптарды тек мұғалім көреді
create policy "keys read"      on public.test_keys for select to authenticated using (public.is_teacher());
-- Оқушы тек өз нәтижесін, мұғалім бәрін көреді
create policy "results read"   on public.results   for select to authenticated using (user_id = auth.uid() or public.is_teacher());
-- Мұғалім нәтижені өшіре алады (қайта тапсыруға рұқсат беру үшін)
create policy "results delete" on public.results   for delete to authenticated using (public.is_teacher());
-- Нәтижені тікелей жазуға ешкімге рұқсат жоқ — тек төмендегі функция арқылы.

-- ---------- 5. Тест тапсыру: ұпай СЕРВЕРДЕ есептеледі ----------
create or replace function public.submit_result(p_test_id bigint, p_answers int[])
returns json language plpgsql security definer set search_path = public as $$
declare
  k int[]; n int; s int := 0; pct int;
begin
  if auth.uid() is null then raise exception 'Жүйеге кіріңіз'; end if;
  if not exists (select 1 from tests where id = p_test_id and active) then
    raise exception 'Тест табылмады немесе жабық';
  end if;
  if exists (select 1 from results where user_id = auth.uid() and test_id = p_test_id) then
    raise exception 'Сіз бұл тестті тапсырып қойғансыз';
  end if;

  select answers into k from test_keys where test_id = p_test_id;
  n := coalesce(array_length(k, 1), 0);
  if n = 0 or coalesce(array_length(p_answers, 1), 0) <> n then
    raise exception 'Барлық сұраққа жауап беріңіз';
  end if;

  for i in 1..n loop
    if p_answers[i] = k[i] then s := s + 1; end if;
  end loop;
  pct := round(s * 100.0 / n);

  insert into results (user_id, test_id, score, total, percent, answers)
  values (auth.uid(), p_test_id, s, n, pct, p_answers);

  return json_build_object('score', s, 'total', n, 'percent', pct, 'key', k);
end $$;

-- ---------- 6. Жаңа тест қосу (тек мұғалім) ----------
create or replace function public.save_test(p_title text, p_questions jsonb, p_answers int[])
returns bigint language plpgsql security definer set search_path = public as $$
declare new_id bigint;
begin
  if not public.is_teacher() then raise exception 'Тек мұғалім тест қоса алады'; end if;
  if coalesce(trim(p_title), '') = '' then raise exception 'Тест атауын жазыңыз'; end if;
  if jsonb_array_length(p_questions) = 0
     or jsonb_array_length(p_questions) <> coalesce(array_length(p_answers, 1), 0) then
    raise exception 'Сұрақтар мен жауаптар саны сәйкес емес';
  end if;
  insert into tests (title, questions) values (trim(p_title), p_questions) returning id into new_id;
  insert into test_keys (test_id, answers) values (new_id, p_answers);
  return new_id;
end $$;

revoke execute on function public.submit_result(bigint, int[])      from public, anon;
revoke execute on function public.save_test(text, jsonb, int[])     from public, anon;
grant  execute on function public.submit_result(bigint, int[])      to authenticated;
grant  execute on function public.save_test(text, jsonb, int[])     to authenticated;

-- ---------- 7. Бірінші тест (мысал) ----------
do $$
declare tid bigint;
begin
  if not exists (select 1 from public.tests) then
    insert into public.tests (title, questions) values (
      'Қазақ тілі: грамматика негіздері',
      '[
        {"q":"Қазақ тілінде неше септік бар?","options":["5","6","7","8"]},
        {"q":"«Кітап» сөзінің көпше түрі қалай жазылады?","options":["кітаплар","кітаптар","кітапдар","кітаптер"]},
        {"q":"Зат есім қандай сұраққа жауап береді?","options":["Қандай? Қай?","Не істеді?","Кім? Не?","Қанша? Нешінші?"]},
        {"q":"«Әдемі» сөзінің синонимін табыңыз.","options":["сұлу","ұсқынсыз","биік","жылдам"]},
        {"q":"«Үлкен» сөзінің антонимін табыңыз.","options":["зор","кіші","алып","ұзын"]},
        {"q":"Етістікті табыңыз.","options":["жасыл","үстел","жүгірді","бес"]},
        {"q":"Сын есімді табыңыз.","options":["биік","оқыды","мектеп","он"]},
        {"q":"Табыс септігінің сұрақтары:","options":["кімнің? ненің?","кімге? неге?","кімді? нені?","кімде? неде?"]},
        {"q":"«Мектепке» сөзі қай септікте тұр?","options":["Атау","Барыс","Жатыс","Шығыс"]},
        {"q":"Жатыс септігінің жалғауы:","options":["-ға, -ге","-ны, -ні","-да, -де, -та, -те","-нан, -нен"]}
      ]'::jsonb
    ) returning id into tid;
    insert into public.test_keys (test_id, answers) values (tid, array[2,1,2,0,1,2,0,2,1,2]);
  end if;
end $$;

-- =====================================================================
--  МҰҒАЛІМ ЖАСАУ: сайтта әдеттегідей тіркеліп болған соң, мына жолды
--  логиніңізді қойып, жеке іске қосыңыз:
--
--  update public.profiles set role = 'teacher' where login = 'mugalim';  -- логин кіші әріппен
-- =====================================================================
