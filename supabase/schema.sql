-- ============================================================
-- Family Silver Class Bali — Supabase schema (Tahap 3: database)
--
-- HOW TO RUN:
-- 1. Buka https://supabase.com/dashboard -> project Anda
-- 2. Klik menu "SQL Editor" di sidebar kiri -> "New query"
-- 3. Copy-paste SELURUH isi file ini -> klik "Run"
-- 4. Aman dijalankan berkali-kali (idempotent).
-- ============================================================

-- 1) Generic key/value store for CMS + Akunting data (admin-managed).
--    Setiap "key" menyimpan satu bagian data (content, catalog, dst)
--    sebagai JSON, supaya semua perubahan Admin CMS tersimpan permanen.
create table if not exists app_state (
  key text primary key,
  value jsonb not null,
  updated_at timestamptz not null default now()
);

alter table app_state enable row level security;

-- Tabel yang dibuat lewat SQL Editor tidak otomatis mendapat GRANT dasar
-- untuk role anon/authenticated (beda dengan tabel yang dibuat lewat Table
-- Editor UI). RLS di atas tetap jadi penjaga sesungguhnya soal siapa boleh apa.
grant usage on schema public to anon, authenticated;
grant select on app_state to anon, authenticated;
grant insert, update on app_state to authenticated;

-- Pengunjung biasa (tanpa login) boleh MEMBACA data yang tampil di halaman utama saja.
drop policy if exists "public_read_content_keys" on app_state;
create policy "public_read_content_keys" on app_state
  for select
  to anon, authenticated
  using (
    key in (
      'content','catalog','perGram','extras','settings','galleryPhotos',
      'reviews','heroPhotos','guestGalleryPhotos','instructors','asSeenIn','instagramPhotos',
      'blogPosts'
    )
  );

-- Admin yang sudah login boleh membaca semua key, termasuk data Akunting.
drop policy if exists "authenticated_read_all" on app_state;
create policy "authenticated_read_all" on app_state
  for select
  to authenticated
  using (true);

-- Hanya admin yang sudah login yang boleh menulis/mengubah data.
drop policy if exists "authenticated_write" on app_state;
create policy "authenticated_write" on app_state
  for insert
  to authenticated
  with check (true);

drop policy if exists "authenticated_update" on app_state;
create policy "authenticated_update" on app_state
  for update
  to authenticated
  using (true)
  with check (true);

-- 1b) Safety net: log the PREVIOUS value of any app_state row right before
--     it gets overwritten, so an accidental full-blob overwrite (e.g. from a
--     stale browser tab still running old buggy code) is always recoverable
--     from history instead of being permanently lost with no trace.
create table if not exists app_state_history (
  id bigserial primary key,
  key text not null,
  value jsonb not null,
  changed_at timestamptz not null default now()
);

create index if not exists app_state_history_key_idx on app_state_history (key, changed_at desc);

create or replace function log_app_state_history()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if old.value is distinct from new.value then
    insert into app_state_history (key, value, changed_at) values (old.key, old.value, now());
  end if;
  return new;
end;
$$;

drop trigger if exists app_state_history_trigger on app_state;
create trigger app_state_history_trigger
before update on app_state
for each row
execute function log_app_state_history();

alter table app_state_history enable row level security;
grant select on app_state_history to authenticated;

drop policy if exists "authenticated_read_history" on app_state_history;
create policy "authenticated_read_history" on app_state_history
  for select
  to authenticated
  using (true);

-- 2) Reservations — tabel nyata untuk booking dari pengunjung.
--    Pengunjung (tanpa login) hanya boleh MENAMBAH booking baru.
--    Hanya admin yang boleh melihat, mengubah status, atau menghapus.
create table if not exists reservations (
  id text primary key,
  name text not null,
  date text,
  pax int,
  status text not null default 'Pending',
  created_at timestamptz not null default now()
);

alter table reservations add column if not exists slot text;

-- Booking details from the public form (contact + package), so the admin can
-- follow up even if the guest's WhatsApp message never arrives. Anonymous
-- visitors can only INSERT these; only a logged-in admin can read them (RLS).
alter table reservations add column if not exists email text;
alter table reservations add column if not exists whatsapp text;
alter table reservations add column if not exists package text;
alter table reservations add column if not exists extras text;
alter table reservations add column if not exists meeting text;
alter table reservations add column if not exists pickup_note text;
alter table reservations add column if not exists estimated_total text;
alter table reservations add column if not exists admin_note text;

alter table reservations enable row level security;

grant select, insert, update, delete on reservations to anon, authenticated;

-- PENTING: booking dari pengunjung HARUS dikirim dengan Prefer: return=minimal
-- (yaitu tanpa memanggil .select() setelah .insert() di supabase-js). Karena
-- pengunjung anonim sengaja tidak diberi izin SELECT di tabel ini, meminta
-- baris hasil INSERT dikembalikan (return=representation) akan gagal RLS.
drop policy if exists "anyone_can_book" on reservations;
create policy "anyone_can_book" on reservations
  for insert
  to public
  with check (true);

drop policy if exists "admin_read_reservations" on reservations;
create policy "admin_read_reservations" on reservations
  for select
  to authenticated
  using (true);

drop policy if exists "admin_update_reservations" on reservations;
create policy "admin_update_reservations" on reservations
  for update
  to authenticated
  using (true)
  with check (true);

drop policy if exists "admin_delete_reservations" on reservations;
create policy "admin_delete_reservations" on reservations
  for delete
  to authenticated
  using (true);

-- Let the Admin CMS get live "new booking" updates via Supabase Realtime
-- without needing to poll/refresh the page. Wrapped so it's safe to re-run.
do $$
begin
  alter publication supabase_realtime add table reservations;
exception when duplicate_object then
  null;
end $$;

-- Safe way for the public booking form to check slot capacity without
-- ever exposing raw customer rows (name/email/phone) to anonymous visitors:
-- returns only aggregated pax counts per time slot for one date.
create or replace function get_slot_booked_pax(p_date text)
returns table(slot text, total_pax bigint)
language sql
security definer
set search_path = public
as $$
  select slot, sum(pax) as total_pax
  from reservations
  where date = p_date and slot is not null
  group by slot;
$$;

grant execute on function get_slot_booked_pax(text) to anon, authenticated;

-- 2b) Shared spending guard for the website AI chat (api/chat.js). Every chat
--     request calls chat_take_quota(ip) before contacting Claude: max 15 per IP
--     per 10 minutes, 60 per IP per 24h, 300 per Bali day for the whole site.
--     The tables have RLS and no grants; only the function touches them.
create table if not exists chat_usage_daily (
  day date primary key,
  requests int not null default 0
);

create table if not exists chat_usage_ip (
  ip text not null,
  window_start timestamptz not null,
  requests int not null default 0,
  primary key (ip, window_start)
);

alter table chat_usage_daily enable row level security;
alter table chat_usage_ip enable row level security;
revoke all on table chat_usage_daily from anon, authenticated;
revoke all on table chat_usage_ip from anon, authenticated;

create or replace function chat_take_quota(p_ip text)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  v_day date := (now() at time zone 'Asia/Makassar')::date;
  v_window timestamptz := date_trunc('hour', now()) + floor(extract(minute from now()) / 10) * interval '10 minutes';
  v_ip text := left(coalesce(nullif(trim(p_ip), ''), 'unknown'), 64);
  v_ip_window int;
  v_ip_day int;
  v_day_total int;
begin
  insert into chat_usage_ip (ip, window_start, requests) values (v_ip, v_window, 1)
  on conflict (ip, window_start) do update set requests = chat_usage_ip.requests + 1
  returning requests into v_ip_window;
  if v_ip_window > 15 then return 'ip_limited'; end if;

  select coalesce(sum(requests), 0) into v_ip_day
  from chat_usage_ip where ip = v_ip and window_start > now() - interval '24 hours';
  if v_ip_day > 60 then return 'ip_limited'; end if;

  insert into chat_usage_daily (day, requests) values (v_day, 1)
  on conflict (day) do update set requests = chat_usage_daily.requests + 1
  returning requests into v_day_total;
  if v_day_total > 300 then return 'daily_limited'; end if;

  delete from chat_usage_ip where window_start < now() - interval '2 days';
  return 'ok';
end;
$$;

revoke all on function chat_take_quota(text) from public;
grant execute on function chat_take_quota(text) to anon, authenticated;

-- 3) Storage bucket for admin-uploaded photos (Hero Carousel, Homepage
--    galleries, package covers, instructor photos, step-by-step photos,
--    etc). Photos are public to read (they're shown on the public site);
--    only a logged-in admin can upload/replace/delete them.
insert into storage.buckets (id, name, public)
values ('site-photos', 'site-photos', true)
on conflict (id) do nothing;

drop policy if exists "public_read_site_photos" on storage.objects;
create policy "public_read_site_photos" on storage.objects
  for select
  to anon, authenticated
  using (bucket_id = 'site-photos');

drop policy if exists "authenticated_upload_site_photos" on storage.objects;
create policy "authenticated_upload_site_photos" on storage.objects
  for insert
  to authenticated
  with check (bucket_id = 'site-photos');

drop policy if exists "authenticated_update_site_photos" on storage.objects;
create policy "authenticated_update_site_photos" on storage.objects
  for update
  to authenticated
  using (bucket_id = 'site-photos')
  with check (bucket_id = 'site-photos');

drop policy if exists "authenticated_delete_site_photos" on storage.objects;
create policy "authenticated_delete_site_photos" on storage.objects
  for delete
  to authenticated
  using (bucket_id = 'site-photos');
