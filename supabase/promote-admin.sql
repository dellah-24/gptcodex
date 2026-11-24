-- Run only from the Supabase SQL editor after the intended admin has signed up.
-- Replace the email exactly. Never place service-role keys in the Android app or admin website.
update public.tapcard_profiles
set role = 'admin', updated_at = now()
where lower(email) = lower('owner@example.com');
