-- 031 — Assign LUNDER Owner role only from trusted Supabase app_metadata.
--
-- Supabase Auth does not expose a trustworthy "created in Dashboard" flag:
-- dashboard-created users and public signups can otherwise look identical.
-- Therefore, an administrator must set this server-controlled app_metadata key
-- for each account that should be a LUNDER Owner:
--
--   { "lunder_role": "owner" }
--
-- Never use raw_user_meta_data for authorization; users can edit it themselves.
-- This migration does not touch or apply itself to any Supabase project.

CREATE OR REPLACE FUNCTION public.sync_lunder_owner_from_app_metadata()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  IF COALESCE(NEW.raw_app_meta_data ->> 'lunder_role', '') = 'owner' THEN
    INSERT INTO public.profiles (id, role, full_name)
    VALUES (
      NEW.id,
      'owner',
      NEW.raw_user_meta_data ->> 'name'
    )
    ON CONFLICT (id) DO UPDATE
      SET role = 'owner';
  ELSIF TG_OP = 'UPDATE'
     AND COALESCE(OLD.raw_app_meta_data ->> 'lunder_role', '') = 'owner' THEN
    -- Removing the trusted marker revokes only the owner role assigned by it.
    UPDATE public.profiles
       SET role = 'customer'
     WHERE id = NEW.id
       AND role = 'owner';
  END IF;

  RETURN NEW;
END;
$$;

COMMENT ON FUNCTION public.sync_lunder_owner_from_app_metadata() IS
  'Synchronizes LUNDER profile role from trusted auth.users.raw_app_meta_data.lunder_role. Never reads user-editable raw_user_meta_data for authorization.';

REVOKE ALL ON FUNCTION public.sync_lunder_owner_from_app_metadata()
  FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS zz_lunder_owner_metadata_after_insert ON auth.users;
CREATE TRIGGER zz_lunder_owner_metadata_after_insert
  AFTER INSERT ON auth.users
  FOR EACH ROW
  EXECUTE FUNCTION public.sync_lunder_owner_from_app_metadata();

DROP TRIGGER IF EXISTS zz_lunder_owner_metadata_after_app_metadata_update ON auth.users;
CREATE TRIGGER zz_lunder_owner_metadata_after_app_metadata_update
  AFTER UPDATE OF raw_app_meta_data ON auth.users
  FOR EACH ROW
  WHEN (OLD.raw_app_meta_data IS DISTINCT FROM NEW.raw_app_meta_data)
  EXECUTE FUNCTION public.sync_lunder_owner_from_app_metadata();
