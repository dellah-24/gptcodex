-- Adds private shop-proof uploads to an existing ZWConnect Supabase project.

alter table public.owner_applications
  add column if not exists proof_path text,
  add column if not exists proof_name text,
  add column if not exists proof_mime text,
  add column if not exists proof_size bigint;

alter table public.owner_applications
  drop constraint if exists owner_applications_proof_mime_check,
  drop constraint if exists owner_applications_proof_size_check;
alter table public.owner_applications
  add constraint owner_applications_proof_mime_check
    check (proof_mime is null or proof_mime in ('image/jpeg','image/png','image/webp','application/pdf')),
  add constraint owner_applications_proof_size_check
    check (proof_size is null or proof_size between 1 and 10485760);

insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types)
values('shop-proofs','shop-proofs',false,10485760,array['image/jpeg','image/png','image/webp','application/pdf'])
on conflict(id) do update set
  public=false,
  file_size_limit=excluded.file_size_limit,
  allowed_mime_types=excluded.allowed_mime_types;

drop policy if exists "applicants upload own shop proof" on storage.objects;
create policy "applicants upload own shop proof" on storage.objects for insert to authenticated
with check(bucket_id='shop-proofs' and (storage.foldername(name))[1]=auth.uid()::text);

drop policy if exists "applicants read own shop proof" on storage.objects;
create policy "applicants read own shop proof" on storage.objects for select to authenticated
using(bucket_id='shop-proofs' and (storage.foldername(name))[1]=auth.uid()::text);

drop policy if exists "admins read shop proofs" on storage.objects;
create policy "admins read shop proofs" on storage.objects for select to authenticated
using(bucket_id='shop-proofs' and public.is_site_admin());

drop policy if exists "applicants replace own shop proof" on storage.objects;
create policy "applicants replace own shop proof" on storage.objects for update to authenticated
using(bucket_id='shop-proofs' and (storage.foldername(name))[1]=auth.uid()::text)
with check(bucket_id='shop-proofs' and (storage.foldername(name))[1]=auth.uid()::text);
