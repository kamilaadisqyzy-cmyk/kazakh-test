-- =====================================================================
--  «Білгір баспалдағы» ойыны — базаға қосымша (database.sql-ден КЕЙІН іске қосыңыз)
-- =====================================================================

-- Тест түрі: 'test' — қарапайым тест, 'ladder' — Білгір баспалдағы
alter table public.tests add column if not exists kind text not null default 'test';
alter table public.tests drop constraint if exists tests_kind_check;
alter table public.tests add constraint tests_kind_check check (kind in ('test','ladder'));
-- Ұстаз кеңестері (оқушыға тек «кеңес» көмегін алғанда ғана көрінеді)
alter table public.test_keys add column if not exists hints text[];

-- Ойын барысы
create table if not exists public.ladder_runs (
  id           bigint generated always as identity primary key,
  user_id      uuid not null references public.profiles on delete cascade,
  test_id      bigint not null references public.tests on delete cascade,
  step         int not null default 0,          -- дұрыс жауап берілген сұрақтар саны
  total        int not null,
  status       text not null default 'playing' check (status in ('playing','won','lost','stopped')),
  final_step   int not null default 0,          -- есепке алынатын саты
  used_5050    boolean not null default false,
  used_hint    boolean not null default false,
  used_second  boolean not null default false,
  second_armed boolean not null default false,
  wrong_choice int,
  q_started    timestamptz not null default now(), -- ағымдағы сұрақ басталған уақыт (таймер серверде)
  created_at   timestamptz not null default now(),
  finished_at  timestamptz,
  unique (user_id, test_id)
);
alter table public.ladder_runs enable row level security;
grant select, delete on public.ladder_runs to authenticated;
revoke all on public.ladder_runs from anon;
drop policy if exists "ladder read"   on public.ladder_runs;
drop policy if exists "ladder delete" on public.ladder_runs;
create policy "ladder read"   on public.ladder_runs for select to authenticated using (user_id = auth.uid() or public.is_teacher());
create policy "ladder delete" on public.ladder_runs for delete to authenticated using (public.is_teacher());

-- Бекітілген сатылар: n/3 және 2n/3 (15 сұрақта — 5 және 10)
create or replace function public.ladder_safe(n int, s int) returns int
language sql immutable as $$
  select case when s >= round(n * 2 / 3.0) then round(n * 2 / 3.0)::int
              when s >= round(n / 3.0)     then round(n / 3.0)::int
              else 0 end;
$$;

-- Қарапайым тест енді тек kind='test' үшін
create or replace function public.submit_result(p_test_id bigint, p_answers int[])
returns json language plpgsql security definer set search_path = public as $$
declare
  k int[]; n int; s int := 0; pct int;
begin
  if auth.uid() is null then raise exception 'Жүйеге кіріңіз'; end if;
  if not exists (select 1 from tests where id = p_test_id and active and kind = 'test') then
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

-- Ойынды бастау / жалғастыру
create or replace function public.ladder_start(p_test_id bigint)
returns json language plpgsql security definer set search_path = public as $$
declare r ladder_runs; n int;
begin
  if auth.uid() is null then raise exception 'Жүйеге кіріңіз'; end if;
  if not exists (select 1 from tests where id = p_test_id and active and kind = 'ladder') then
    raise exception 'Ойын табылмады немесе жабық';
  end if;
  select * into r from ladder_runs where user_id = auth.uid() and test_id = p_test_id;
  if found then
    if r.status <> 'playing' then raise exception 'Сіз бұл ойынды ойнап қойғансыз'; end if;
  else
    select array_length(answers, 1) into n from test_keys where test_id = p_test_id;
    insert into ladder_runs (user_id, test_id, total) values (auth.uid(), p_test_id, n) returning * into r;
  end if;
  return json_build_object('run_id', r.id, 'step', r.step, 'total', r.total,
    'used_5050', r.used_5050, 'used_hint', r.used_hint, 'used_second', r.used_second,
    'second_armed', r.second_armed,
    'elapsed', floor(extract(epoch from now() - r.q_started)));
end $$;

-- Жауап беру (30 секунд + 5 секунд қосымша уақыт серверде тексеріледі)
create or replace function public.ladder_answer(p_run_id bigint, p_choice int)
returns json language plpgsql security definer set search_path = public as $$
declare r ladder_runs; k int[]; ok boolean;
begin
  select * into r from ladder_runs where id = p_run_id and user_id = auth.uid() for update;
  if not found or r.status <> 'playing' then raise exception 'Ойын аяқталған'; end if;
  select answers into k from test_keys where test_id = r.test_id;

  ok := (p_choice = k[r.step + 1]) and extract(epoch from now() - r.q_started) <= 35;

  if ok then
    r.step := r.step + 1;
    if r.step >= r.total then
      update ladder_runs set step = r.step, second_armed = false, status = 'won', final_step = r.total,
             finished_at = now() where id = r.id;
      return json_build_object('correct', true, 'step', r.step, 'status', 'won', 'final_step', r.total);
    end if;
    update ladder_runs set step = r.step, second_armed = false, q_started = now() where id = r.id;
    return json_build_object('correct', true, 'step', r.step, 'status', 'playing');
  end if;

  if r.second_armed then
    update ladder_runs set second_armed = false, q_started = now() where id = r.id;
    return json_build_object('correct', false, 'retry', true, 'step', r.step, 'status', 'playing');
  end if;

  r.final_step := public.ladder_safe(r.total, r.step);
  update ladder_runs set status = 'lost', final_step = r.final_step, wrong_choice = p_choice,
         finished_at = now() where id = r.id;
  return json_build_object('correct', false, 'correct_index', k[r.step + 1], 'step', r.step,
                           'status', 'lost', 'final_step', r.final_step);
end $$;

-- Тоқтап, жиналған ұпайды алу
create or replace function public.ladder_stop(p_run_id bigint)
returns json language plpgsql security definer set search_path = public as $$
declare r ladder_runs; k int[];
begin
  select * into r from ladder_runs where id = p_run_id and user_id = auth.uid() for update;
  if not found or r.status <> 'playing' then raise exception 'Ойын аяқталған'; end if;
  update ladder_runs set status = 'stopped', final_step = r.step, finished_at = now() where id = r.id;
  select answers into k from test_keys where test_id = r.test_id;
  return json_build_object('status', 'stopped', 'step', r.step, 'final_step', r.step, 'correct_index', k[r.step + 1]);
end $$;

-- Көмектер: 50/50, ұстаз кеңесі, тағы бір мүмкіндік (әрқайсысы бір рет)
create or replace function public.ladder_lifeline(p_run_id bigint, p_kind text)
returns json language plpgsql security definer set search_path = public as $$
declare r ladder_runs; k int[]; h text[]; nopt int; rem int[];
begin
  select * into r from ladder_runs where id = p_run_id and user_id = auth.uid() for update;
  if not found or r.status <> 'playing' then raise exception 'Ойын аяқталған'; end if;
  select answers, hints into k, h from test_keys where test_id = r.test_id;

  if p_kind = '5050' then
    if r.used_5050 then raise exception 'Бұл көмек қолданылған'; end if;
    select jsonb_array_length(questions -> r.step -> 'options') into nopt from tests where id = r.test_id;
    select array_agg(i) into rem from (
      select i from generate_series(0, nopt - 1) i
      where i <> k[r.step + 1] order by random() limit greatest(nopt - 2, 0)
    ) x;
    update ladder_runs set used_5050 = true where id = r.id;
    return json_build_object('remove', coalesce(rem, '{}'::int[]));
  elsif p_kind = 'hint' then
    if r.used_hint then raise exception 'Бұл көмек қолданылған'; end if;
    update ladder_runs set used_hint = true where id = r.id;
    return json_build_object('hint', coalesce(nullif(h[r.step + 1], ''), 'Бұл сұраққа кеңес жоқ. Мұқият ойланыңыз!'));
  elsif p_kind = 'second' then
    if r.used_second then raise exception 'Бұл көмек қолданылған'; end if;
    update ladder_runs set used_second = true, second_armed = true where id = r.id;
    return json_build_object('armed', true);
  end if;
  raise exception 'Белгісіз көмек';
end $$;

-- Тест/ойын қосу (мұғалім): түрі мен кеңестер қосылды
drop function if exists public.save_test(text, jsonb, int[]);
create or replace function public.save_test(p_title text, p_questions jsonb, p_answers int[],
                                            p_kind text default 'test', p_hints text[] default null)
returns bigint language plpgsql security definer set search_path = public as $$
declare new_id bigint; n int;
begin
  if not public.is_teacher() then raise exception 'Тек мұғалім тест қоса алады'; end if;
  if coalesce(trim(p_title), '') = '' then raise exception 'Атауын жазыңыз'; end if;
  if p_kind not in ('test','ladder') then raise exception 'Түрі қате'; end if;
  n := jsonb_array_length(p_questions);
  if n = 0 or n <> coalesce(array_length(p_answers, 1), 0) then
    raise exception 'Сұрақтар мен жауаптар саны сәйкес емес';
  end if;
  if p_kind = 'ladder' and (n < 5 or n > 15) then
    raise exception 'Білгір баспалдағында 5–15 сұрақ болуы керек';
  end if;
  insert into tests (title, questions, kind) values (trim(p_title), p_questions, p_kind) returning id into new_id;
  insert into test_keys (test_id, answers, hints) values (new_id, p_answers, p_hints);
  return new_id;
end $$;

revoke execute on function public.ladder_start(bigint)                         from public, anon;
revoke execute on function public.ladder_answer(bigint, int)                   from public, anon;
revoke execute on function public.ladder_stop(bigint)                          from public, anon;
revoke execute on function public.ladder_lifeline(bigint, text)                from public, anon;
revoke execute on function public.save_test(text, jsonb, int[], text, text[])  from public, anon;
revoke execute on function public.submit_result(bigint, int[])                 from public, anon;
grant  execute on function public.ladder_start(bigint)                         to authenticated;
grant  execute on function public.ladder_answer(bigint, int)                   to authenticated;
grant  execute on function public.ladder_stop(bigint)                          to authenticated;
grant  execute on function public.ladder_lifeline(bigint, text)                to authenticated;
grant  execute on function public.save_test(text, jsonb, int[], text, text[])  to authenticated;
grant  execute on function public.submit_result(bigint, int[])                 to authenticated;

-- Мысал ойын: 15 сұрақ, жеңілден қиынға
do $$
declare tid bigint;
begin
  if not exists (select 1 from public.tests where kind = 'ladder') then
    insert into public.tests (title, questions, kind) values (
      'Білгір баспалдағы: қазақ тілі',
      '[
        {"q":"«Ана» сөзі неше әріптен тұрады?","options":["2","3","4","5"]},
        {"q":"Қай сөз дауысты дыбыстан басталады?","options":["мектеп","ағаш","бала","қала"]},
        {"q":"«Күн» сөзінің антонимі қайсы?","options":["түн","ай","жұлдыз","таң"]},
        {"q":"Қайсысы жыл мезгілі?","options":["көктем","сәрсенбі","қаңтар","таңертең"]},
        {"q":"«Бала» сөзінің көпше түрі:","options":["балалар","баладар","балатар","балалер"]},
        {"q":"«Ақылды» сөзі қай сөз табына жатады?","options":["зат есім","сын есім","етістік","үстеу"]},
        {"q":"«Үйге» сөзі қай септікте тұр?","options":["атау","ілік","барыс","табыс"]},
        {"q":"Болымсыз етістікті табыңыз.","options":["оқыды","оқымады","оқиды","оқып"]},
        {"q":"Қазақ тіліне тән төл дыбыстарды беретін әріптер саны (кирилл әліпбиі):","options":["7","9","11","12"]},
        {"q":"Шығыс септігінің сұрақтары:","options":["кімде? неде?","кімнен? неден?","кіммен? немен?","кімге? неге?"]},
        {"q":"Көмектес септігінің жалғауы:","options":["-нан, -нен","-мен, -бен, -пен","-ның, -нің","-да, -де"]},
        {"q":"Мақалды аяқтаңыз: «Еңбек етсең ерінбей, ...»","options":["тояды қарның тіленбей","болады ісің бітпей","келеді досың ізденбей","өседі бағың күтпей"]},
        {"q":"«Абай жолы» роман-эпопеясының авторы кім?","options":["Сәбит Мұқанов","Мұхтар Әуезов","Ғабит Мүсірепов","Ілияс Есенберлин"]},
        {"q":"«Қара сөздер» (Ғақлиялар) кімнің шығармасы?","options":["Ыбырай Алтынсарин","Абай Құнанбайұлы","Шоқан Уәлиханов","Мағжан Жұмабаев"]},
        {"q":"Сөздегі буындардың бірыңғай жуан не жіңішке болып келу заңы қалай аталады?","options":["Үндестік заңы","Ілгерінді ықпал","Буын жігі","Екпін"]}
      ]'::jsonb,
      'ladder'
    ) returning id into tid;
    insert into public.test_keys (test_id, answers, hints) values (
      tid,
      array[1,1,0,0,0,1,2,1,1,1,1,0,1,1,0],
      array[
        'Әріптерді бір-бірлеп санаңыз: а-н-а.',
        'Дауысты дыбыстар: а, ә, о, ө, ұ, ү, ы, і, е...',
        'Күн батқан соң не болады?',
        'Жылда төрт мезгіл бар: қыс, ..., жаз, күз.',
        'Соңғы дыбыс дауысты болса, -лар/-лер жалғанады.',
        'Қандай? деген сұраққа жауап береді.',
        'Кімге? Неге? Қайда? деген сұраққа жауап береді.',
        'Болымсыздық -ма/-ме, -ба/-бе, -па/-пе арқылы жасалады.',
        'Ә, ғ, қ, ң, ө, ұ, ү, һ, і — санап көріңіз.',
        '«Мектептен», «қаладан» сөздерін еске түсіріңіз.',
        '«Досыммен», «қаламмен» сөздеріне назар аударыңыз.',
        'Еңбек еткен адам ешкімнен тамақ сұрамайды.',
        'Бұл кітап — Абайдың өмірі туралы.',
        'Ақын әрі ойшыл, «Қара сөздердің» авторы.',
        'Сингармонизм қазақша қалай аталады?'
      ]
    );
  end if;
end $$;

select 'GAME OK' as status, (select count(*) from public.tests where kind = 'ladder') as ladders;
