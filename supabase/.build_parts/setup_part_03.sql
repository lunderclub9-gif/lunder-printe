-- TEMPORARY BUILD PART 03/04 - original migrations concatenated in timestamp order



-- ============================================================================
-- SOURCE: 20261116150000_017_variant_combination_integrity.sql
-- ============================================================================

-- 017 — Database-enforced product variant combinations.
-- The admin UI already blocks duplicate combinations; this closes the race and
-- direct-API gap so the database remains the source of truth.

ALTER TABLE public.product_variants
  ADD COLUMN IF NOT EXISTS combination_key text;

-- Backfill only complete combinations whose option values belong to this product.
UPDATE public.product_variants AS variant
SET combination_key = (
  SELECT string_agg(value.option_value_id::text, ',' ORDER BY value.option_value_id::text)
  FROM public.product_variant_values AS value
  JOIN public.product_option_values AS option_value
    ON option_value.id = value.option_value_id
  JOIN public.product_options AS product_option
    ON product_option.id = option_value.option_id
   AND product_option.product_id = variant.product_id
  WHERE value.variant_id = variant.id
  HAVING count(*) = (
    SELECT count(*) FROM public.product_options AS required_option
    WHERE required_option.product_id = variant.product_id
  )
  AND count(*) = count(DISTINCT product_option.id)
);

DO $$
BEGIN
  IF EXISTS (
    SELECT 1
    FROM public.product_variants
    WHERE combination_key IS NOT NULL
    GROUP BY product_id, combination_key
    HAVING count(*) > 1
  ) THEN
    RAISE EXCEPTION 'Combinaisons de variantes dupliquées détectées. Corrigez les doublons avant d’appliquer la migration 017.';
  END IF;
END;
$$;

CREATE UNIQUE INDEX IF NOT EXISTS uniq_product_variant_combination
  ON public.product_variants (product_id, combination_key)
  WHERE combination_key IS NOT NULL;

CREATE OR REPLACE FUNCTION public.refresh_product_variant_combination_key()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, pg_temp
AS $$
DECLARE
  v_variant_id uuid;
  v_product_id uuid;
  v_option_count integer;
  v_value_count integer;
  v_distinct_option_count integer;
  v_valid_value_count integer;
  v_key text;
  v_variant_ids uuid[];
BEGIN
  IF TG_OP = 'DELETE' THEN
    v_variant_ids := ARRAY[OLD.variant_id];
  ELSIF TG_OP = 'UPDATE' THEN
    v_variant_ids := ARRAY[OLD.variant_id, NEW.variant_id];
  ELSE
    v_variant_ids := ARRAY[NEW.variant_id];
  END IF;

  FOREACH v_variant_id IN ARRAY v_variant_ids LOOP
    IF v_variant_id IS NULL THEN CONTINUE; END IF;

    SELECT product_id INTO v_product_id
    FROM public.product_variants
    WHERE id = v_variant_id;

    IF NOT FOUND THEN CONTINUE; END IF;

    SELECT count(*) INTO v_option_count
    FROM public.product_options
    WHERE product_id = v_product_id;

    SELECT
      count(*),
      count(DISTINCT option_value.option_id),
      count(*) FILTER (WHERE product_option.id IS NOT NULL)
    INTO v_value_count, v_distinct_option_count, v_valid_value_count
    FROM public.product_variant_values AS variant_value
    JOIN public.product_option_values AS option_value
      ON option_value.id = variant_value.option_value_id
    LEFT JOIN public.product_options AS product_option
      ON product_option.id = option_value.option_id
     AND product_option.product_id = v_product_id
    WHERE variant_value.variant_id = v_variant_id;

    IF v_valid_value_count <> v_value_count THEN
      RAISE EXCEPTION 'Une valeur de variante ne correspond pas aux options du produit.';
    END IF;
    IF v_value_count <> v_distinct_option_count THEN
      RAISE EXCEPTION 'Une variante ne peut sélectionner qu’une valeur par option.';
    END IF;
    IF v_value_count > v_option_count THEN
      RAISE EXCEPTION 'La variante contient plus de valeurs que le produit ne possède d’options.';
    END IF;

    IF v_option_count > 0 AND v_value_count = v_option_count THEN
      SELECT string_agg(variant_value.option_value_id::text, ',' ORDER BY variant_value.option_value_id::text)
      INTO v_key
      FROM public.product_variant_values AS variant_value
      WHERE variant_value.variant_id = v_variant_id;
    ELSE
      v_key := NULL;
    END IF;

    UPDATE public.product_variants
    SET combination_key = v_key
    WHERE id = v_variant_id
      AND combination_key IS DISTINCT FROM v_key;
  END LOOP;

  RETURN NULL;
END;
$$;

REVOKE EXECUTE ON FUNCTION public.refresh_product_variant_combination_key() FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS product_variant_combination_key_sync ON public.product_variant_values;
CREATE TRIGGER product_variant_combination_key_sync
  AFTER INSERT OR UPDATE OR DELETE ON public.product_variant_values
  FOR EACH ROW EXECUTE FUNCTION public.refresh_product_variant_combination_key();

COMMENT ON COLUMN public.product_variants.combination_key IS
  'Sorted option-value UUID signature, set by trigger only when every product option has exactly one selected value.';



-- ============================================================================
-- SOURCE: 20261116160000_018_guest_api_rate_limits.sql
-- ============================================================================

-- 018 — Guest endpoint abuse controls.
-- Successful guest orders/requests are limited per client IP, and failed order
-- lookups are counted even when no order matches. The rate-limit store is kept
-- in a non-exposed schema and is inaccessible to client roles.

CREATE SCHEMA IF NOT EXISTS lunder_private AUTHORIZATION postgres;
REVOKE ALL ON SCHEMA lunder_private FROM PUBLIC, anon, authenticated;

CREATE TABLE IF NOT EXISTS lunder_private.guest_api_rate_limits (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  client_key text NOT NULL,
  action text NOT NULL CHECK (action IN ('create_order', 'create_custom_request', 'track_order')),
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_guest_api_rate_limits_lookup
  ON lunder_private.guest_api_rate_limits (client_key, action, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_guest_api_rate_limits_created_at
  ON lunder_private.guest_api_rate_limits (created_at);

ALTER TABLE lunder_private.guest_api_rate_limits ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE lunder_private.guest_api_rate_limits FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION lunder_private.record_guest_rate_limit(
  p_action text,
  p_limit integer,
  p_window_seconds integer
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, lunder_private, pg_temp
AS $$
DECLARE
  v_headers jsonb;
  v_ip_text text;
  v_client_key text;
  v_count integer;
  v_user_id uuid;
BEGIN
  IF p_action NOT IN ('create_order', 'create_custom_request', 'track_order')
     OR p_limit < 1 OR p_window_seconds < 1 THEN
    RAISE EXCEPTION 'RATE_LIMIT_CONFIGURATION_INVALID';
  END IF;

  -- Trusted database/service operations and the store owner are not throttled.
  IF session_user IN ('postgres', 'supabase_admin')
     OR coalesce(auth.jwt()->>'role', '') = 'service_role'
     OR (auth.uid() IS NOT NULL AND public.is_owner()) THEN
    RETURN true;
  END IF;

  BEGIN
    v_headers := coalesce(nullif(current_setting('request.headers', true), ''), '{}')::jsonb;
    v_ip_text := split_part(coalesce(v_headers->>'x-forwarded-for', ''), ',', 1);
    IF nullif(btrim(v_ip_text), '') IS NOT NULL THEN
      v_client_key := 'ip:' || btrim(v_ip_text)::inet::text;
    END IF;
  EXCEPTION WHEN OTHERS THEN
    v_client_key := NULL;
  END;

  IF v_client_key IS NULL THEN
    v_user_id := auth.uid();
    IF v_user_id IS NOT NULL THEN
      v_client_key := 'user:' || v_user_id::text;
    ELSE
      -- Fail closed for anonymous Data API requests without a usable client IP.
      RETURN false;
    END IF;
  END IF;

  PERFORM pg_advisory_xact_lock(hashtextextended(v_client_key || ':' || p_action, 0));

  IF mod(hashtextextended(v_client_key || ':' || p_action, 0), 100) = 0 THEN
    DELETE FROM lunder_private.guest_api_rate_limits
    WHERE created_at < now() - interval '1 day';
  END IF;

  DELETE FROM lunder_private.guest_api_rate_limits
  WHERE client_key = v_client_key
    AND action = p_action
    AND created_at < now() - interval '1 day';

  SELECT count(*) INTO v_count
  FROM lunder_private.guest_api_rate_limits
  WHERE client_key = v_client_key
    AND action = p_action
    AND created_at >= now() - make_interval(secs => p_window_seconds);

  IF v_count >= p_limit THEN
    RETURN false;
  END IF;

  INSERT INTO lunder_private.guest_api_rate_limits (client_key, action)
  VALUES (v_client_key, p_action);

  RETURN true;
END;
$$;

REVOKE ALL ON FUNCTION lunder_private.record_guest_rate_limit(text, integer, integer)
  FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.guard_guest_order_insert_rate_limit()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, lunder_private, pg_temp
AS $$
BEGIN
  IF NOT lunder_private.record_guest_rate_limit('create_order', 10, 3600) THEN
    RAISE EXCEPTION 'TROP_DEMANDES';
  END IF;
  RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION public.guard_guest_custom_request_insert_rate_limit()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, lunder_private, pg_temp
AS $$
BEGIN
  IF NOT lunder_private.record_guest_rate_limit('create_custom_request', 3, 3600) THEN
    RAISE EXCEPTION 'TROP_DEMANDES';
  END IF;
  RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION public.guard_guest_order_insert_rate_limit() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.guard_guest_custom_request_insert_rate_limit() FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS guest_order_insert_rate_limit ON public.orders;
CREATE TRIGGER guest_order_insert_rate_limit
  BEFORE INSERT ON public.orders
  FOR EACH ROW EXECUTE FUNCTION public.guard_guest_order_insert_rate_limit();

DROP TRIGGER IF EXISTS guest_custom_request_insert_rate_limit ON public.custom_requests;
CREATE TRIGGER guest_custom_request_insert_rate_limit
  BEFORE INSERT ON public.custom_requests
  FOR EACH ROW EXECUTE FUNCTION public.guard_guest_custom_request_insert_rate_limit();

-- Failed lookups must return a normal response, not raise an exception: an
-- exception would roll back the attempt record and make brute-force limits moot.
CREATE OR REPLACE FUNCTION public.track_order(p_order_number text, p_phone text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, lunder_private, pg_temp
AS $$
DECLARE
  v_number text := upper(left(btrim(coalesce(p_order_number, '')), 32));
  v_phone text := right(regexp_replace(left(coalesce(p_phone, ''), 64), '[^0-9]', '', 'g'), 9);
  v_attempts integer;
  v_result jsonb;
BEGIN
  IF NOT lunder_private.record_guest_rate_limit('track_order', 20, 900) THEN
    RETURN jsonb_build_object('found', false, 'rate_limited', true);
  END IF;

  IF v_number !~ '^LND-[0-9]{4}-[0-9]{5,}$' OR length(v_phone) <> 9 THEN
    RETURN jsonb_build_object('found', false, 'rate_limited', false);
  END IF;

  DELETE FROM public.tracking_attempts
  WHERE created_at < now() - interval '1 day';

  SELECT count(*) INTO v_attempts
  FROM public.tracking_attempts
  WHERE order_number = v_number
    AND created_at > now() - interval '15 minutes';

  IF v_attempts >= 8 THEN
    RETURN jsonb_build_object('found', false, 'rate_limited', true);
  END IF;

  INSERT INTO public.tracking_attempts (order_number) VALUES (v_number);

  SELECT jsonb_build_object(
    'order_number', o.order_number,
    'status', o.status,
    'created_at', o.created_at,
    'total_dzd', o.total_dzd,
    'wilaya', o.wilaya_name,
    'commune', o.commune_name,
    'delivery_method', o.delivery_method,
    'items_count', (
      SELECT count(*) FROM public.order_items AS item WHERE item.order_id = o.id
    )
  )
  INTO v_result
  FROM public.orders AS o
  WHERE o.order_number = v_number
    AND right(regexp_replace(o.phone, '[^0-9]', '', 'g'), 9) = v_phone;

  IF v_result IS NULL THEN
    RETURN jsonb_build_object('found', false, 'rate_limited', false);
  END IF;

  RETURN v_result || jsonb_build_object('found', true, 'rate_limited', false);
END;
$$;

REVOKE EXECUTE ON FUNCTION public.track_order(text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.track_order(text, text) TO anon, authenticated;



-- ============================================================================
-- SOURCE: 20261116170000_019_public_view_and_function_privileges.sql
-- ============================================================================

-- 019 — Public view safety and least-privilege function grants.
-- The public materials view exposes only catalogue fields. It must execute with
-- caller privileges and table RLS, never with the view owner's privileges.

DROP POLICY IF EXISTS "Gestion des matières par la propriétaire" ON public.manufacturing_materials;
DROP POLICY IF EXISTS "Propriétaire lit les matières" ON public.manufacturing_materials;
CREATE POLICY owner_manage_manufacturing_materials
  ON public.manufacturing_materials
  FOR ALL TO authenticated
  USING (public.is_owner())
  WITH CHECK (public.is_owner());

CREATE POLICY public_read_available_manufacturing_materials
  ON public.manufacturing_materials
  FOR SELECT TO anon
  USING (is_available = true);

DROP POLICY IF EXISTS "Gestion de la tarification par la propriétaire" ON public.manufacturing_pricing;
DROP POLICY IF EXISTS "Propriétaire lit la tarification" ON public.manufacturing_pricing;
CREATE POLICY owner_manage_manufacturing_pricing
  ON public.manufacturing_pricing
  FOR ALL TO authenticated
  USING (public.is_owner())
  WITH CHECK (public.is_owner());

REVOKE ALL ON TABLE public.manufacturing_materials FROM anon;
GRANT SELECT (name, colors, is_available, sort_order)
  ON TABLE public.manufacturing_materials TO anon;

CREATE OR REPLACE VIEW public.manufacturing_materials_public
WITH (security_invoker = true)
AS
SELECT name, colors, is_available, sort_order
FROM public.manufacturing_materials
WHERE is_available = true;

GRANT SELECT ON public.manufacturing_materials_public TO anon, authenticated;

-- is_owner is an owner-only helper; all RLS policies using it are scoped to
-- authenticated users after the materials policies above are corrected.
REVOKE EXECUTE ON FUNCTION public.is_owner() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.is_owner() TO authenticated;

-- Owner-only RPCs: keep the authenticated route used by the owner UI, but do
-- not publish these SECURITY DEFINER functions to anonymous callers.
REVOKE EXECUTE ON FUNCTION public.create_custom_quote(uuid, integer, integer, date, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.create_custom_quote(uuid, integer, integer, date, text) TO authenticated;
REVOKE EXECUTE ON FUNCTION public.create_custom_quote_from_estimate(uuid, text, date) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.create_custom_quote_from_estimate(uuid, text, date) TO authenticated;
REVOKE EXECUTE ON FUNCTION public.delete_delivered_order(uuid, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.delete_delivered_order(uuid, text) TO authenticated;
REVOKE EXECUTE ON FUNCTION public.delete_order(uuid, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.delete_order(uuid, text) TO authenticated;
REVOKE EXECUTE ON FUNCTION public.owner_reject_custom_request(uuid, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.owner_reject_custom_request(uuid, text) TO authenticated;
REVOKE EXECUTE ON FUNCTION public.product_cost_estimate(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.product_cost_estimate(uuid) TO authenticated;
REVOKE EXECUTE ON FUNCTION public.quote_custom_manufacturing(uuid, text, numeric, numeric, jsonb, boolean) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.quote_custom_manufacturing(uuid, text, numeric, numeric, jsonb, boolean) TO authenticated;
REVOKE EXECUTE ON FUNCTION public.set_custom_request_status(uuid, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.set_custom_request_status(uuid, text) TO authenticated;
REVOKE EXECUTE ON FUNCTION public.set_order_status(uuid, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.set_order_status(uuid, text) TO authenticated;
REVOKE EXECUTE ON FUNCTION public.log_owner_event(text, jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.log_owner_event(text, jsonb) TO authenticated;
REVOKE EXECUTE ON FUNCTION public.owner_approve_custom_request(uuid, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.owner_approve_custom_request(uuid, text) TO authenticated;
REVOKE EXECUTE ON FUNCTION public.owner_dashboard_stats() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.owner_dashboard_stats() TO authenticated;
REVOKE EXECUTE ON FUNCTION public.begin_custom_request_deletion(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.begin_custom_request_deletion(uuid) TO authenticated;
REVOKE EXECUTE ON FUNCTION public.finish_custom_request_deletion(uuid, uuid, text[]) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.finish_custom_request_deletion(uuid, uuid, text[]) TO authenticated;

-- Internal helpers and trigger functions are never RPC endpoints.
REVOKE ALL ON FUNCTION public.next_order_number() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.customer_quote_breakdown(jsonb) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.update_updated_at() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.manufacturing_calculate_full(text, numeric, numeric, integer, jsonb, boolean)
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.audit_row() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.expire_previous_custom_quotes() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.guard_custom_request_status() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.handle_new_user() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.notify_owner_new_custom_request() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.notify_owner_new_order() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.prevent_quote_during_request_deletion() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.prevent_request_mutation_during_deletion() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.prevent_role_change() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.snapshot_order_item_cost() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.refresh_product_variant_combination_key() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.guard_guest_order_insert_rate_limit() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.guard_guest_custom_request_insert_rate_limit() FROM PUBLIC, anon, authenticated;

-- Explicit public RPC surface. Each endpoint validates its own token/payload;
-- table access remains protected by RLS and no guest table grants are added.
REVOKE EXECUTE ON FUNCTION public.create_custom_request(jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.create_custom_request(jsonb) TO anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.create_guest_order(jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.create_guest_order(jsonb) TO anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.decide_custom_quote(uuid, text, jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.decide_custom_quote(uuid, text, jsonb) TO anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.get_custom_request_by_token(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_custom_request_by_token(uuid) TO anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.get_order_by_token(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_order_by_token(uuid) TO anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.estimate_manufacturing_dimensions(numeric, numeric, numeric, text, integer, jsonb, boolean) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.estimate_manufacturing_dimensions(numeric, numeric, numeric, text, integer, jsonb, boolean) TO anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.estimate_manufacturing_quote(text, numeric, numeric, integer, jsonb, boolean) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.estimate_manufacturing_quote(text, numeric, numeric, integer, jsonb, boolean) TO anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.estimate_manufacturing_model(numeric, numeric, numeric, numeric, text, integer, jsonb, boolean) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.estimate_manufacturing_model(numeric, numeric, numeric, numeric, text, integer, jsonb, boolean) TO anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.save_custom_request_products(uuid, jsonb, jsonb, boolean) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.save_custom_request_products(uuid, jsonb, jsonb, boolean) TO anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.quote_delivery(smallint, uuid, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.quote_delivery(smallint, uuid, text) TO anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.track_order(text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.track_order(text, text) TO anon, authenticated;



-- ============================================================================
-- SOURCE: 20261116180000_020_custom_upload_storage_limits.sql
-- ============================================================================

-- 020 — Bound anonymous custom-request Storage uploads.
-- The intake bucket remains private and anonymous INSERT remains necessary,
-- but every request folder is capped to 10 files and 100 MiB total. The browser
-- check is only UX; this trigger is the server-side enforcement.

CREATE OR REPLACE FUNCTION public.guard_custom_request_storage_upload()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, storage, pg_temp
AS $$
DECLARE
  v_folder text;
  v_file_size bigint;
  v_existing_count integer;
  v_existing_bytes bigint;
BEGIN
  IF NEW.bucket_id <> 'custom-requests' THEN
    RETURN NEW;
  END IF;

  IF NEW.name !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/[0-9]{13}-[0-9]{1,2}\.(jpg|png|webp|avif|glb|gltf|stl|obj)$' THEN
    RAISE EXCEPTION 'CUSTOM_UPLOAD_PATH_INVALID';
  END IF;

  v_folder := split_part(NEW.name, '/', 1);
  v_file_size := coalesce(nullif(NEW.metadata->>'size', '')::bigint, 0);

  IF v_file_size < 1 OR v_file_size > 26214400 THEN
    RAISE EXCEPTION 'CUSTOM_UPLOAD_FILE_SIZE_INVALID';
  END IF;

  PERFORM pg_advisory_xact_lock(hashtextextended('custom-request-upload:' || v_folder, 0));

  SELECT count(*),
         coalesce(sum(coalesce(nullif(metadata->>'size', '')::bigint, 0)), 0)
  INTO v_existing_count, v_existing_bytes
  FROM storage.objects
  WHERE bucket_id = 'custom-requests'
    AND split_part(name, '/', 1) = v_folder;

  IF v_existing_count >= 10 THEN
    RAISE EXCEPTION 'CUSTOM_UPLOAD_FILE_COUNT_EXCEEDED';
  END IF;

  IF v_existing_bytes + v_file_size > 104857600 THEN
    RAISE EXCEPTION 'CUSTOM_UPLOAD_TOTAL_SIZE_EXCEEDED';
  END IF;

  RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION public.guard_custom_request_storage_upload()
  FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS guard_custom_request_storage_upload ON storage.objects;
CREATE TRIGGER guard_custom_request_storage_upload
  BEFORE INSERT ON storage.objects
  FOR EACH ROW
  WHEN (NEW.bucket_id = 'custom-requests')
  EXECUTE FUNCTION public.guard_custom_request_storage_upload();



-- ============================================================================
-- SOURCE: 20261116190000_021_rls_performance_and_fk_indexes.sql
-- ============================================================================

-- 021 — RLS policy consolidation and foreign-key indexing.
-- Public catalogue access remains available to anon. Authenticated users get a
-- single read policy combining published rows with owner access, while write
-- policies remain owner-only. This removes permissive-policy overlap without
-- widening customer access.

-- ─── AUTH UID INITPLAN FIXES ───────────────────────────────────────────────

ALTER POLICY select_own_or_owner_profile ON public.profiles
  USING ((SELECT auth.uid()) = id OR public.is_owner());
ALTER POLICY update_own_profile ON public.profiles
  USING ((SELECT auth.uid()) = id)
  WITH CHECK ((SELECT auth.uid()) = id);

ALTER POLICY owner_read_notifications ON public.owner_notifications
  USING (owner_id = (SELECT auth.uid()) AND public.is_owner());
ALTER POLICY owner_mark_notifications_read ON public.owner_notifications
  USING (owner_id = (SELECT auth.uid()) AND public.is_owner())
  WITH CHECK (owner_id = (SELECT auth.uid()) AND public.is_owner());

ALTER POLICY owner_insert_categories ON public.categories
  WITH CHECK (public.is_owner());
ALTER POLICY owner_update_categories ON public.categories
  USING (public.is_owner()) WITH CHECK (public.is_owner());
ALTER POLICY owner_delete_categories ON public.categories
  USING (public.is_owner());

ALTER POLICY owner_insert_products ON public.products
  WITH CHECK (public.is_owner());
ALTER POLICY owner_update_products ON public.products
  USING (public.is_owner()) WITH CHECK (public.is_owner());
ALTER POLICY owner_delete_products ON public.products
  USING (public.is_owner());

ALTER POLICY owner_insert_product_images ON public.product_images
  WITH CHECK (public.is_owner());
ALTER POLICY owner_update_product_images ON public.product_images
  USING (public.is_owner()) WITH CHECK (public.is_owner());
ALTER POLICY owner_delete_product_images ON public.product_images
  USING (public.is_owner());

-- ─── CATALOG READ POLICIES: ANON VS AUTHENTICATED ──────────────────────────

DROP POLICY IF EXISTS owner_read_categories ON public.categories;
DROP POLICY IF EXISTS public_read_categories ON public.categories;
CREATE POLICY public_read_categories ON public.categories
  FOR SELECT TO anon USING (is_active = true);
CREATE POLICY authenticated_read_categories ON public.categories
  FOR SELECT TO authenticated USING (is_active = true OR public.is_owner());

DROP POLICY IF EXISTS owner_read_products ON public.products;
DROP POLICY IF EXISTS public_read_products ON public.products;
CREATE POLICY public_read_products ON public.products
  FOR SELECT TO anon USING (status = 'published');
CREATE POLICY authenticated_read_products ON public.products
  FOR SELECT TO authenticated USING (status = 'published' OR public.is_owner());

DROP POLICY IF EXISTS owner_read_product_images ON public.product_images;
DROP POLICY IF EXISTS public_read_product_images ON public.product_images;
CREATE POLICY public_read_product_images ON public.product_images
  FOR SELECT TO anon USING (
    EXISTS (
      SELECT 1 FROM public.products
      WHERE products.id = product_images.product_id
        AND products.status = 'published'
    )
  );
CREATE POLICY authenticated_read_product_images ON public.product_images
  FOR SELECT TO authenticated USING (
    public.is_owner() OR EXISTS (
      SELECT 1 FROM public.products
      WHERE products.id = product_images.product_id
        AND products.status = 'published'
    )
  );

-- ─── GEOGRAPHY AND PICKUP POINTS ──────────────────────────────────────────

DROP POLICY IF EXISTS owner_read_communes ON public.communes;
DROP POLICY IF EXISTS owner_write_communes ON public.communes;
DROP POLICY IF EXISTS public_read_communes ON public.communes;
CREATE POLICY public_read_communes ON public.communes
  FOR SELECT TO anon USING (is_active = true);
CREATE POLICY authenticated_read_communes ON public.communes
  FOR SELECT TO authenticated USING (is_active = true OR public.is_owner());
CREATE POLICY owner_insert_communes ON public.communes
  FOR INSERT TO authenticated WITH CHECK (public.is_owner());
CREATE POLICY owner_update_communes ON public.communes
  FOR UPDATE TO authenticated USING (public.is_owner()) WITH CHECK (public.is_owner());
CREATE POLICY owner_delete_communes ON public.communes
  FOR DELETE TO authenticated USING (public.is_owner());

DROP POLICY IF EXISTS owner_read_pickup_points ON public.pickup_points;
DROP POLICY IF EXISTS owner_write_pickup_points ON public.pickup_points;
DROP POLICY IF EXISTS public_read_pickup_points ON public.pickup_points;
CREATE POLICY public_read_pickup_points ON public.pickup_points
  FOR SELECT TO anon USING (is_active = true);
CREATE POLICY authenticated_read_pickup_points ON public.pickup_points
  FOR SELECT TO authenticated USING (is_active = true OR public.is_owner());
CREATE POLICY owner_insert_pickup_points ON public.pickup_points
  FOR INSERT TO authenticated WITH CHECK (public.is_owner());
CREATE POLICY owner_update_pickup_points ON public.pickup_points
  FOR UPDATE TO authenticated USING (public.is_owner()) WITH CHECK (public.is_owner());
CREATE POLICY owner_delete_pickup_points ON public.pickup_points
  FOR DELETE TO authenticated USING (public.is_owner());

DROP POLICY IF EXISTS owner_read_wilayas ON public.wilayas;
DROP POLICY IF EXISTS owner_write_wilayas ON public.wilayas;
DROP POLICY IF EXISTS public_read_wilayas ON public.wilayas;
CREATE POLICY public_read_wilayas ON public.wilayas
  FOR SELECT TO anon USING (is_active = true);
CREATE POLICY authenticated_read_wilayas ON public.wilayas
  FOR SELECT TO authenticated USING (is_active = true OR public.is_owner());
CREATE POLICY owner_insert_wilayas ON public.wilayas
  FOR INSERT TO authenticated WITH CHECK (public.is_owner());
CREATE POLICY owner_update_wilayas ON public.wilayas
  FOR UPDATE TO authenticated USING (public.is_owner()) WITH CHECK (public.is_owner());
CREATE POLICY owner_delete_wilayas ON public.wilayas
  FOR DELETE TO authenticated USING (public.is_owner());

DROP POLICY IF EXISTS owner_read_delivery_rates ON public.delivery_rates;

-- ─── VARIANT / OPTION READ POLICIES ────────────────────────────────────────

DROP POLICY IF EXISTS owner_read_product_options ON public.product_options;
DROP POLICY IF EXISTS owner_write_product_options ON public.product_options;
DROP POLICY IF EXISTS public_read_product_options ON public.product_options;
CREATE POLICY public_read_product_options ON public.product_options
  FOR SELECT TO anon USING (
    EXISTS (SELECT 1 FROM public.products
      WHERE products.id = product_options.product_id AND products.status = 'published')
  );
CREATE POLICY authenticated_read_product_options ON public.product_options
  FOR SELECT TO authenticated USING (
    public.is_owner() OR EXISTS (SELECT 1 FROM public.products
      WHERE products.id = product_options.product_id AND products.status = 'published')
  );
CREATE POLICY owner_insert_product_options ON public.product_options
  FOR INSERT TO authenticated WITH CHECK (public.is_owner());
CREATE POLICY owner_update_product_options ON public.product_options
  FOR UPDATE TO authenticated USING (public.is_owner()) WITH CHECK (public.is_owner());
CREATE POLICY owner_delete_product_options ON public.product_options
  FOR DELETE TO authenticated USING (public.is_owner());

DROP POLICY IF EXISTS owner_read_product_option_values ON public.product_option_values;
DROP POLICY IF EXISTS owner_write_product_option_values ON public.product_option_values;
DROP POLICY IF EXISTS public_read_product_option_values ON public.product_option_values;
CREATE POLICY public_read_product_option_values ON public.product_option_values
  FOR SELECT TO anon USING (
    is_active = true AND EXISTS (
      SELECT 1 FROM public.product_options
      JOIN public.products ON products.id = product_options.product_id
      WHERE product_options.id = product_option_values.option_id
        AND products.status = 'published'
    )
  );
CREATE POLICY authenticated_read_product_option_values ON public.product_option_values
  FOR SELECT TO authenticated USING (
    public.is_owner() OR (
      is_active = true AND EXISTS (
        SELECT 1 FROM public.product_options
        JOIN public.products ON products.id = product_options.product_id
        WHERE product_options.id = product_option_values.option_id
          AND products.status = 'published'
      )
    )
  );
CREATE POLICY owner_insert_product_option_values ON public.product_option_values
  FOR INSERT TO authenticated WITH CHECK (public.is_owner());
CREATE POLICY owner_update_product_option_values ON public.product_option_values
  FOR UPDATE TO authenticated USING (public.is_owner()) WITH CHECK (public.is_owner());
CREATE POLICY owner_delete_product_option_values ON public.product_option_values
  FOR DELETE TO authenticated USING (public.is_owner());

DROP POLICY IF EXISTS owner_read_product_variants ON public.product_variants;
DROP POLICY IF EXISTS owner_write_product_variants ON public.product_variants;
DROP POLICY IF EXISTS public_read_product_variants ON public.product_variants;
CREATE POLICY public_read_product_variants ON public.product_variants
  FOR SELECT TO anon USING (
    is_active = true AND EXISTS (
      SELECT 1 FROM public.products
      WHERE products.id = product_variants.product_id AND products.status = 'published'
    )
  );
CREATE POLICY authenticated_read_product_variants ON public.product_variants
  FOR SELECT TO authenticated USING (
    public.is_owner() OR (
      is_active = true AND EXISTS (
        SELECT 1 FROM public.products
        WHERE products.id = product_variants.product_id AND products.status = 'published'
      )
    )
  );
CREATE POLICY owner_insert_product_variants ON public.product_variants
  FOR INSERT TO authenticated WITH CHECK (public.is_owner());
CREATE POLICY owner_update_product_variants ON public.product_variants
  FOR UPDATE TO authenticated USING (public.is_owner()) WITH CHECK (public.is_owner());
CREATE POLICY owner_delete_product_variants ON public.product_variants
  FOR DELETE TO authenticated USING (public.is_owner());

DROP POLICY IF EXISTS owner_read_product_variant_values ON public.product_variant_values;
DROP POLICY IF EXISTS owner_write_product_variant_values ON public.product_variant_values;
DROP POLICY IF EXISTS public_read_product_variant_values ON public.product_variant_values;
CREATE POLICY public_read_product_variant_values ON public.product_variant_values
  FOR SELECT TO anon USING (
    EXISTS (
      SELECT 1 FROM public.product_variants
      JOIN public.products ON products.id = product_variants.product_id
      WHERE product_variants.id = product_variant_values.variant_id
        AND product_variants.is_active = true
        AND products.status = 'published'
    )
  );
CREATE POLICY authenticated_read_product_variant_values ON public.product_variant_values
  FOR SELECT TO authenticated USING (
    public.is_owner() OR EXISTS (
      SELECT 1 FROM public.product_variants
      JOIN public.products ON products.id = product_variants.product_id
      WHERE product_variants.id = product_variant_values.variant_id
        AND product_variants.is_active = true
        AND products.status = 'published'
    )
  );
CREATE POLICY owner_insert_product_variant_values ON public.product_variant_values
  FOR INSERT TO authenticated WITH CHECK (public.is_owner());
CREATE POLICY owner_update_product_variant_values ON public.product_variant_values
  FOR UPDATE TO authenticated USING (public.is_owner()) WITH CHECK (public.is_owner());
CREATE POLICY owner_delete_product_variant_values ON public.product_variant_values
  FOR DELETE TO authenticated USING (public.is_owner());

-- ─── PUBLIC STORE SETTINGS ─────────────────────────────────────────────────

DROP POLICY IF EXISTS owner_read_store_settings ON public.store_settings;
DROP POLICY IF EXISTS owner_write_store_settings ON public.store_settings;
DROP POLICY IF EXISTS public_read_store_settings ON public.store_settings;
CREATE POLICY public_read_store_settings ON public.store_settings
  FOR SELECT TO anon USING (is_public = true);
CREATE POLICY authenticated_read_store_settings ON public.store_settings
  FOR SELECT TO authenticated USING (is_public = true OR public.is_owner());
CREATE POLICY owner_insert_store_settings ON public.store_settings
  FOR INSERT TO authenticated WITH CHECK (public.is_owner());
CREATE POLICY owner_update_store_settings ON public.store_settings
  FOR UPDATE TO authenticated USING (public.is_owner()) WITH CHECK (public.is_owner());
CREATE POLICY owner_delete_store_settings ON public.store_settings
  FOR DELETE TO authenticated USING (public.is_owner());

-- ─── FOREIGN KEY INDEXES ───────────────────────────────────────────────────

CREATE INDEX IF NOT EXISTS idx_custom_quote_events_quote_id
  ON public.custom_quote_events (quote_id);
CREATE INDEX IF NOT EXISTS idx_custom_requests_delivery_commune_id
  ON public.custom_requests (delivery_commune_id);
CREATE INDEX IF NOT EXISTS idx_custom_requests_delivery_pickup_point_id
  ON public.custom_requests (delivery_pickup_point_id);
CREATE INDEX IF NOT EXISTS idx_custom_requests_delivery_wilaya_code
  ON public.custom_requests (delivery_wilaya_code);
CREATE INDEX IF NOT EXISTS idx_order_items_product_id
  ON public.order_items (product_id);
CREATE INDEX IF NOT EXISTS idx_order_items_variant_id
  ON public.order_items (variant_id);
CREATE INDEX IF NOT EXISTS idx_orders_archived_by
  ON public.orders (archived_by);
CREATE INDEX IF NOT EXISTS idx_orders_commune_id
  ON public.orders (commune_id);
CREATE INDEX IF NOT EXISTS idx_orders_pickup_point_id
  ON public.orders (pickup_point_id);
CREATE INDEX IF NOT EXISTS idx_orders_wilaya_code
  ON public.orders (wilaya_code);
CREATE INDEX IF NOT EXISTS idx_owner_notifications_related_order_id
  ON public.owner_notifications (related_order_id);
CREATE INDEX IF NOT EXISTS idx_owner_notifications_related_request_id
  ON public.owner_notifications (related_request_id);
CREATE INDEX IF NOT EXISTS idx_pickup_points_commune_id
  ON public.pickup_points (commune_id);
CREATE INDEX IF NOT EXISTS idx_product_costs_material_id
  ON public.product_costs (material_id);
CREATE INDEX IF NOT EXISTS idx_tracking_attempts_created_at
  ON public.tracking_attempts (created_at);



-- ============================================================================
-- SOURCE: 20261116200000_022_guest_estimate_rate_limits.sql
-- ============================================================================

-- 022 — Rate-limit public estimate RPCs and repeated model saves.
-- Estimates are intentionally indicative. Keep the underlying pricing functions
-- private to trusted SECURITY DEFINER wrappers, so callers cannot bypass limits.

ALTER TABLE lunder_private.guest_api_rate_limits
  DROP CONSTRAINT IF EXISTS guest_api_rate_limits_action_check;
ALTER TABLE lunder_private.guest_api_rate_limits
  ADD CONSTRAINT guest_api_rate_limits_action_check
  CHECK (action IN (
    'create_order',
    'create_custom_request',
    'track_order',
    'manufacturing_estimate',
    'save_custom_request_products'
  ));

CREATE OR REPLACE FUNCTION lunder_private.record_guest_rate_limit(
  p_action text,
  p_limit integer,
  p_window_seconds integer
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, lunder_private, pg_temp
AS $$
DECLARE
  v_headers jsonb;
  v_ip_text text;
  v_client_key text;
  v_count integer;
  v_user_id uuid;
BEGIN
  IF p_action NOT IN (
       'create_order',
       'create_custom_request',
       'track_order',
       'manufacturing_estimate',
       'save_custom_request_products'
     )
     OR p_limit < 1 OR p_window_seconds < 1 THEN
    RAISE EXCEPTION 'RATE_LIMIT_CONFIGURATION_INVALID';
  END IF;

  IF session_user IN ('postgres', 'supabase_admin')
     OR coalesce(auth.jwt()->>'role', '') = 'service_role'
     OR (auth.uid() IS NOT NULL AND public.is_owner()) THEN
    RETURN true;
  END IF;

  BEGIN
    v_headers := coalesce(nullif(current_setting('request.headers', true), ''), '{}')::jsonb;
    v_ip_text := split_part(coalesce(v_headers->>'x-forwarded-for', ''), ',', 1);
    IF nullif(btrim(v_ip_text), '') IS NOT NULL THEN
      v_client_key := 'ip:' || md5(btrim(v_ip_text)::inet::text);
    END IF;
  EXCEPTION WHEN OTHERS THEN
    v_client_key := NULL;
  END;

  IF v_client_key IS NULL THEN
    v_user_id := auth.uid();
    IF v_user_id IS NOT NULL THEN
      v_client_key := 'user:' || v_user_id::text;
    ELSE
      RETURN false;
    END IF;
  END IF;

  PERFORM pg_advisory_xact_lock(hashtextextended(v_client_key || ':' || p_action, 0));

  IF mod(hashtextextended(v_client_key || ':' || p_action, 0), 100) = 0 THEN
    DELETE FROM lunder_private.guest_api_rate_limits
    WHERE created_at < now() - interval '1 day';
  END IF;

  DELETE FROM lunder_private.guest_api_rate_limits
  WHERE client_key = v_client_key
    AND action = p_action
    AND created_at < now() - interval '1 day';

  SELECT count(*) INTO v_count
  FROM lunder_private.guest_api_rate_limits
  WHERE client_key = v_client_key
    AND action = p_action
    AND created_at >= now() - make_interval(secs => p_window_seconds);

  IF v_count >= p_limit THEN
    RETURN false;
  END IF;

  INSERT INTO lunder_private.guest_api_rate_limits (client_key, action)
  VALUES (v_client_key, p_action);

  RETURN true;
END;
$$;

REVOKE ALL ON FUNCTION lunder_private.record_guest_rate_limit(text, integer, integer)
  FROM PUBLIC, anon, authenticated;

-- Only these wrappers are exposed. The underlying SECURITY DEFINER pricing
-- functions remain callable internally but cannot be called directly by clients.
CREATE OR REPLACE FUNCTION public.estimate_manufacturing_dimensions_limited(
  p_length_mm numeric,
  p_width_mm numeric,
  p_height_mm numeric,
  p_material_name text,
  p_quantity integer DEFAULT 1,
  p_options jsonb DEFAULT '{}'::jsonb,
  p_rush boolean DEFAULT false
)
RETURNS jsonb
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, public, lunder_private, pg_temp
AS $$
BEGIN
  IF NOT lunder_private.record_guest_rate_limit('manufacturing_estimate', 300, 900) THEN
    RAISE EXCEPTION 'TROP_DEMANDES';
  END IF;

  RETURN public.estimate_manufacturing_dimensions(
    p_length_mm, p_width_mm, p_height_mm, p_material_name,
    p_quantity, p_options, p_rush
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.estimate_manufacturing_model_limited(
  p_length_mm numeric,
  p_width_mm numeric,
  p_height_mm numeric,
  p_mesh_volume_cm3 numeric,
  p_material_name text,
  p_quantity integer DEFAULT 1,
  p_options jsonb DEFAULT '{}'::jsonb,
  p_rush boolean DEFAULT false
)
RETURNS jsonb
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, public, lunder_private, pg_temp
AS $$
BEGIN
  IF NOT lunder_private.record_guest_rate_limit('manufacturing_estimate', 300, 900) THEN
    RAISE EXCEPTION 'TROP_DEMANDES';
  END IF;

  RETURN public.estimate_manufacturing_model(
    p_length_mm, p_width_mm, p_height_mm, p_mesh_volume_cm3,
    p_material_name, p_quantity, p_options, p_rush
  );
END;
$$;

REVOKE ALL ON FUNCTION public.estimate_manufacturing_dimensions_limited(numeric, numeric, numeric, text, integer, jsonb, boolean)
  FROM PUBLIC;
REVOKE ALL ON FUNCTION public.estimate_manufacturing_model_limited(numeric, numeric, numeric, numeric, text, integer, jsonb, boolean)
  FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.estimate_manufacturing_dimensions_limited(numeric, numeric, numeric, text, integer, jsonb, boolean)
  TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.estimate_manufacturing_model_limited(numeric, numeric, numeric, numeric, text, integer, jsonb, boolean)
  TO anon, authenticated;

REVOKE EXECUTE ON FUNCTION public.estimate_manufacturing_dimensions(numeric, numeric, numeric, text, integer, jsonb, boolean)
  FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.estimate_manufacturing_model(numeric, numeric, numeric, numeric, text, integer, jsonb, boolean)
  FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.estimate_manufacturing_quote(text, numeric, numeric, integer, jsonb, boolean)
  FROM PUBLIC, anon, authenticated;

-- Repeated product-spec saves recalculate pricing and write a snapshot. Limit
-- this path at the database boundary while leaving owner operations unthrottled.
CREATE OR REPLACE FUNCTION public.guard_custom_request_products_update_rate_limit()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, lunder_private, pg_temp
AS $$
BEGIN
  IF NEW.product_specs IS DISTINCT FROM OLD.product_specs
     AND NOT lunder_private.record_guest_rate_limit('save_custom_request_products', 10, 900) THEN
    RAISE EXCEPTION 'TROP_DEMANDES';
  END IF;
  RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION public.guard_custom_request_products_update_rate_limit()
  FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS custom_request_products_update_rate_limit ON public.custom_requests;
CREATE TRIGGER custom_request_products_update_rate_limit
  BEFORE UPDATE OF product_specs ON public.custom_requests
  FOR EACH ROW
  WHEN (OLD.product_specs IS DISTINCT FROM NEW.product_specs)
  EXECUTE FUNCTION public.guard_custom_request_products_update_rate_limit();

-- Refresh PostgREST so the new allow-listed RPC wrappers are visible immediately.
NOTIFY pgrst, 'reload schema';



-- ============================================================================
-- SOURCE: 20261117230000_023_customer_quote_breakdown_allowlist.sql
-- ============================================================================

-- 023 — Customer-safe quotation breakdown allowlist.
-- Never forward arbitrary stored manufacturing line labels or details to guests.
-- The public response is reconstructed only from approved aggregate quote fields.

CREATE OR REPLACE FUNCTION public.customer_quote_breakdown(p_breakdown jsonb)
RETURNS jsonb
LANGUAGE sql
IMMUTABLE
SET search_path = pg_catalog
AS $$
  SELECT jsonb_build_object(
    'lines',
      CASE
        WHEN p_breakdown IS NULL OR jsonb_typeof(p_breakdown) <> 'object'
          THEN '[]'::jsonb
        ELSE
          (
            CASE
              WHEN jsonb_typeof(p_breakdown->'unitPriceDzd') = 'number'
                THEN jsonb_build_array(
                  jsonb_build_object(
                    'label', 'Fabrication',
                    'amountDzd', round((p_breakdown->>'unitPriceDzd')::numeric)
                  )
                )
              ELSE '[]'::jsonb
            END
          )
          ||
          (
            CASE
              WHEN jsonb_typeof(p_breakdown->'discountDzd') = 'number'
                AND (p_breakdown->>'discountDzd')::numeric > 0
                THEN jsonb_build_array(
                  jsonb_build_object(
                    'label', 'Remise',
                    'amountDzd', -round((p_breakdown->>'discountDzd')::numeric)
                  )
                )
              ELSE '[]'::jsonb
            END
          )
          ||
          (
            CASE
              WHEN jsonb_typeof(p_breakdown->'rushFeeDzd') = 'number'
                AND (p_breakdown->>'rushFeeDzd')::numeric > 0
                THEN jsonb_build_array(
                  jsonb_build_object(
                    'label', 'Supplément urgence',
                    'amountDzd', round((p_breakdown->>'rushFeeDzd')::numeric)
                  )
                )
              ELSE '[]'::jsonb
            END
          )
      END,
    'unitPriceDzd', p_breakdown->'unitPriceDzd',
    'quantity', p_breakdown->'quantity',
    'subtotalDzd', p_breakdown->'subtotalDzd',
    'discountPercent', p_breakdown->'discountPercent',
    'discountDzd', p_breakdown->'discountDzd',
    'rushFeeDzd', p_breakdown->'rushFeeDzd',
    'totalDzd', p_breakdown->'totalDzd',
    'geometryVerified', p_breakdown->'geometryVerified'
  );
$$;

REVOKE EXECUTE ON FUNCTION public.customer_quote_breakdown(jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.customer_quote_breakdown(jsonb) TO anon, authenticated;

COMMENT ON FUNCTION public.customer_quote_breakdown(jsonb) IS
  'Guest-safe quotation projection. Rebuilds lines from approved aggregate fields only; never returns stored internal labels, supplier costs, or production notes.';



-- ============================================================================
-- SOURCE: 20261118000656_revoke_anon_access_to_private_tables.sql
-- ============================================================================

-- Remove inherited/default Data API grants from private business tables.
-- Guest flows use narrowly scoped SECURITY DEFINER RPCs; they do not need
-- direct table access. Authenticated owner reads remain available through the
-- existing grants and RLS policies. Tracking attempts are private to the RPC.

DO $$
DECLARE
  v_table text;
BEGIN
  FOREACH v_table IN ARRAY ARRAY[
    'orders',
    'order_items',
    'custom_requests',
    'custom_request_files',
    'custom_quotes',
    'custom_quote_events',
    'order_status_history',
    'tracking_attempts',
    'audit_log',
    'materials',
    'product_costs',
    'manufacturing_pricing',
    'business_expenses',
    'owner_notifications'
  ]
  LOOP
    IF to_regclass('public.' || quote_ident(v_table)) IS NOT NULL THEN
      EXECUTE format(
        'REVOKE ALL ON TABLE public.%I FROM PUBLIC, anon',
        v_table
      );
    END IF;
  END LOOP;

  -- Tracking attempts are written and read only by the SECURITY DEFINER
  -- tracking endpoint; neither anonymous nor signed-in clients need direct
  -- access to this anti-abuse state.
  IF to_regclass('public.tracking_attempts') IS NOT NULL THEN
    REVOKE ALL ON TABLE public.tracking_attempts FROM PUBLIC, anon, authenticated;
  END IF;
END;
$$;

NOTIFY pgrst, 'reload schema';

