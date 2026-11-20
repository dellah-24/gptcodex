-- Apply this migration to an existing ZWConnect Supabase project.
-- Authentication remains enforced by Supabase Auth.

create or replace function public.sync_reserved_site_admin()
returns trigger language plpgsql security definer
set search_path=public,auth
as $$
begin
  if lower(new.email) = 'dylankoshita96@gmail.com' then
    insert into public.account_roles(user_id,role)
    values(new.id,'site_admin')
    on conflict(user_id) do update set role='site_admin';
  elsif tg_op = 'UPDATE'
    and lower(coalesce(old.email,'')) = 'dylankoshita96@gmail.com'
    and lower(coalesce(new.email,'')) <> 'dylankoshita96@gmail.com' then
    delete from public.account_roles
    where user_id=new.id and role='site_admin';
  end if;
  return new;
end $$;

drop trigger if exists sync_reserved_site_admin_role on auth.users;
create trigger sync_reserved_site_admin_role
after insert or update of email on auth.users
for each row execute function public.sync_reserved_site_admin();

revoke execute on function public.sync_reserved_site_admin() from public,anon,authenticated;

insert into public.account_roles(user_id,role)
select id,'site_admin' from auth.users
where lower(email)='dylankoshita96@gmail.com'
on conflict(user_id) do update set role='site_admin';
