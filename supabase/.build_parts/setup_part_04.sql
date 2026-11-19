-- TEMPORARY BUILD PART 04/04 - original migrations concatenated in timestamp order



-- ============================================================================
-- SOURCE: 20261118090000_024_immutable_custom_quotations.sql
-- ============================================================================

-- 024 — Immutable, version-bound custom quotations.
-- All financial and manufacturing values accepted by a customer are frozen
-- in the database. Owner approval can only consume the latest accepted version.

ALTER TABLE public.custom_quotes
  ADD COLUMN IF NOT EXISTS currency_code text NOT NULL DEFAULT 'DZD',
  ADD COLUMN IF NOT EXISTS specifications_snapshot jsonb,
  ADD COLUMN IF NOT EXISTS delivery_snapshot jsonb,
  ADD COLUMN IF NOT EXISTS delivery_price_dzd integer,
  ADD COLUMN IF NOT EXISTS accepted_at timestamptz,
  ADD COLUMN IF NOT EXISTS accepted_snapshot jsonb,
  ADD COLUMN IF NOT EXISTS accepted_snapshot_hash text;

ALTER TABLE public.custom_quotes
  ADD CONSTRAINT custom_quotes_currency_code_check
  CHECK (currency_code = 'DZD');

ALTER TABLE public.custom_quotes
  ADD CONSTRAINT custom_quotes_delivery_price_check
  CHECK (delivery_price_dzd IS NULL OR delivery_price_dzd >= 0);

CREATE OR REPLACE FUNCTION public.snapshot_custom_quote_context()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_request public.custom_requests%ROWTYPE;
  v_rate record;
  v_wilaya_name text;
  v_commune_name text;
  v_pickup_name text;
BEGIN
  SELECT * INTO v_request
  FROM public.custom_requests
  WHERE id = NEW.request_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'DEMANDE_INTROUVABLE';
  END IF;

  NEW.specifications_snapshot := jsonb_build_object(
    'title', v_request.title,
    'description', v_request.description,
    'intended_use', v_request.intended_use,
    'dimensions', v_request.dimensions,
    'dimension_unit', v_request.dimension_unit,
    'dim_length_mm', v_request.dim_length_mm,
    'dim_width_mm', v_request.dim_width_mm,
    'dim_height_mm', v_request.dim_height_mm,
    'quantity', v_request.quantity,
    'material_preference', v_request.material_preference,
    'color_preference', v_request.color_preference,
    'manufacturing_options', v_request.manufacturing_options,
    'rush', v_request.rush,
    'product_specs', v_request.product_specs
  );

  NEW.delivery_snapshot := NULL;
  NEW.delivery_price_dzd := NULL;

  IF v_request.delivery_wilaya_code IS NOT NULL
     AND v_request.delivery_commune_id IS NOT NULL
     AND v_request.delivery_method IN ('domicile', 'stopdesk') THEN

    SELECT name_fr INTO v_wilaya_name
    FROM public.wilayas
    WHERE code = v_request.delivery_wilaya_code AND is_active;

    SELECT name_fr INTO v_commune_name
    FROM public.communes
    WHERE id = v_request.delivery_commune_id
      AND wilaya_code = v_request.delivery_wilaya_code
      AND is_active;

    IF v_wilaya_name IS NULL OR v_commune_name IS NULL THEN
      RAISE EXCEPTION 'LIVRAISON_INVALIDE';
    END IF;

    IF v_request.delivery_method = 'stopdesk' THEN
      SELECT name INTO v_pickup_name
      FROM public.pickup_points
      WHERE id = v_request.delivery_pickup_point_id
        AND wilaya_code = v_request.delivery_wilaya_code
        AND is_active;
      IF v_pickup_name IS NULL THEN
        RAISE EXCEPTION 'POINT_RELAIS_INVALIDE';
      END IF;
    ELSE
      IF nullif(btrim(coalesce(v_request.delivery_address, '')), '') IS NULL THEN
        RAISE EXCEPTION 'ADRESSE_REQUISE';
      END IF;
    END IF;

    SELECT * INTO v_rate
    FROM public.quote_delivery(
      v_request.delivery_wilaya_code,
      v_request.delivery_commune_id,
      v_request.delivery_method
    );

    NEW.delivery_price_dzd := v_rate.price_dzd;
    NEW.delivery_snapshot := jsonb_build_object(
      'wilaya_code', v_request.delivery_wilaya_code,
      'wilaya_name', v_wilaya_name,
      'commune_id', v_request.delivery_commune_id,
      'commune_name', v_commune_name,
      'delivery_method', v_request.delivery_method,
      'address', v_request.delivery_address,
      'pickup_point_id', v_request.delivery_pickup_point_id,
      'pickup_point_name', v_pickup_name,
      'carrier', v_rate.carrier,
      'estimated_days_min', v_rate.estimated_days_min,
      'estimated_days_max', v_rate.estimated_days_max,
      'price_dzd', v_rate.price_dzd
    );
  END IF;

  RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION public.snapshot_custom_quote_context()
  FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS custom_quotes_snapshot_context ON public.custom_quotes;
CREATE TRIGGER custom_quotes_snapshot_context
  BEFORE INSERT ON public.custom_quotes
  FOR EACH ROW EXECUTE FUNCTION public.snapshot_custom_quote_context();

-- Preserve accepted versions as historical approvals. Only unaccepted sent
-- versions are superseded automatically by a later quotation.
CREATE OR REPLACE FUNCTION public.expire_previous_custom_quotes()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
BEGIN
  UPDATE public.custom_quotes
  SET status = 'expired', decided_at = now()
  WHERE request_id = NEW.request_id
    AND id <> NEW.id
    AND status = 'sent';
  RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION public.expire_previous_custom_quotes()
  FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.guard_custom_quote_immutability()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_latest_version integer;
  v_request public.custom_requests%ROWTYPE;
BEGIN
  IF TG_OP = 'DELETE' THEN
    IF OLD.status IN ('accepted', 'approved') THEN
      RAISE EXCEPTION 'DEVIS_ACCEPTE_IMMUABLE';
    END IF;
    RETURN OLD;
  END IF;

  IF NEW.request_id IS DISTINCT FROM OLD.request_id
     OR NEW.version IS DISTINCT FROM OLD.version
     OR NEW.public_token IS DISTINCT FROM OLD.public_token
     OR NEW.price_dzd IS DISTINCT FROM OLD.price_dzd
     OR NEW.production_lead_days IS DISTINCT FROM OLD.production_lead_days
     OR NEW.valid_until IS DISTINCT FROM OLD.valid_until
     OR NEW.terms IS DISTINCT FROM OLD.terms
     OR NEW.source IS DISTINCT FROM OLD.source
     OR NEW.pricing_snapshot IS DISTINCT FROM OLD.pricing_snapshot
     OR NEW.breakdown IS DISTINCT FROM OLD.breakdown
     OR NEW.currency_code IS DISTINCT FROM OLD.currency_code
     OR NEW.specifications_snapshot IS DISTINCT FROM OLD.specifications_snapshot
     OR NEW.delivery_snapshot IS DISTINCT FROM OLD.delivery_snapshot
     OR NEW.delivery_price_dzd IS DISTINCT FROM OLD.delivery_price_dzd
     OR NEW.created_at IS DISTINCT FROM OLD.created_at THEN
    RAISE EXCEPTION 'DEVIS_CONTENU_IMMUABLE';
  END IF;

  IF NEW.accepted_snapshot IS DISTINCT FROM OLD.accepted_snapshot
     OR NEW.accepted_snapshot_hash IS DISTINCT FROM OLD.accepted_snapshot_hash
     OR NEW.accepted_at IS DISTINCT FROM OLD.accepted_at THEN
    RAISE EXCEPTION 'DEVIS_SNAPSHOT_IMMUABLE';
  END IF;

  IF OLD.status IN ('rejected', 'expired') AND NEW.status <> OLD.status THEN
    RAISE EXCEPTION 'DEVIS_TERMINAL_IMMUABLE';
  END IF;

  IF OLD.status IN ('accepted', 'approved') THEN
    IF OLD.status = 'approved' AND NEW.status <> 'approved' THEN
      RAISE EXCEPTION 'DEVIS_APPROUVE_IMMUABLE';
    END IF;
    IF OLD.status = 'accepted' AND NEW.status NOT IN ('accepted', 'approved') THEN
      RAISE EXCEPTION 'DEVIS_ACCEPTE_IMMUABLE';
    END IF;
    IF OLD.order_id IS NOT NULL AND NEW.order_id IS DISTINCT FROM OLD.order_id THEN
      RAISE EXCEPTION 'COMMANDE_LIEE_IMMUABLE';
    END IF;
  ELSE
    IF NEW.order_id IS DISTINCT FROM OLD.order_id THEN
      RAISE EXCEPTION 'LIEN_COMMANDE_NON_AUTORISE';
    END IF;
  END IF;

  IF OLD.status = 'sent' AND NEW.status = 'accepted' THEN
    SELECT * INTO v_request
    FROM public.custom_requests
    WHERE id = OLD.request_id
    FOR UPDATE;

    IF NOT FOUND THEN
      RAISE EXCEPTION 'DEMANDE_INTROUVABLE';
    END IF;

    SELECT max(version) INTO v_latest_version
    FROM public.custom_quotes
    WHERE request_id = OLD.request_id;

    IF OLD.version <> v_latest_version THEN
      RAISE EXCEPTION 'DEVIS_VERSION_OBSOLETE';
    END IF;
    IF OLD.valid_until < current_date THEN
      RAISE EXCEPTION 'DEVIS_EXPIRE';
    END IF;
    IF OLD.specifications_snapshot IS NULL THEN
      RAISE EXCEPTION 'DEVIS_SNAPSHOT_MANQUANT';
    END IF;
    IF OLD.delivery_snapshot IS NULL OR OLD.delivery_price_dzd IS NULL THEN
      RAISE EXCEPTION 'LIVRAISON_NON_FIGEE';
    END IF;

    NEW.accepted_at := now();
    NEW.accepted_snapshot := jsonb_build_object(
      'quote_id', OLD.id,
      'version', OLD.version,
      'price_dzd', OLD.price_dzd,
      'currency_code', OLD.currency_code,
      'production_lead_days', OLD.production_lead_days,
      'valid_until', OLD.valid_until,
      'terms', OLD.terms,
      'source', OLD.source,
      'pricing_snapshot', OLD.pricing_snapshot,
      'breakdown', OLD.breakdown,
      'specifications', OLD.specifications_snapshot,
      'delivery', OLD.delivery_snapshot,
      'delivery_price_dzd', OLD.delivery_price_dzd,
      'accepted_at', now()
    );
    NEW.accepted_snapshot_hash := md5(NEW.accepted_snapshot::text);
  ELSIF NEW.status = 'approved' AND OLD.status <> 'accepted' THEN
    RAISE EXCEPTION 'ACCEPTATION_CLIENT_REQUISE';
  ELSIF OLD.status = 'accepted' AND NEW.status = 'approved' THEN
    SELECT max(version) INTO v_latest_version
    FROM public.custom_quotes
    WHERE request_id = OLD.request_id;

    IF OLD.version <> v_latest_version THEN
      RAISE EXCEPTION 'DEVIS_VERSION_OBSOLETE';
    END IF;
    IF OLD.accepted_snapshot IS NULL
       OR OLD.accepted_snapshot_hash IS NULL
       OR OLD.accepted_at IS NULL THEN
      RAISE EXCEPTION 'ACCEPTATION_NON_VERIFIABLE';
    END IF;
  END IF;

  IF NEW.status NOT IN ('sent', 'accepted', 'approved', 'rejected', 'expired') THEN
    RAISE EXCEPTION 'STATUT_DEVIS_INVALIDE';
  END IF;

  RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION public.guard_custom_quote_immutability()
  FROM PUBLIC, anon, authenticated;

-- Backfill still-pending legacy quotes when their current request data and
-- a current delivery rate are available. Already accepted legacy quotes remain
-- unverified and must be re-issued/re-accepted before a new order is created.
UPDATE public.custom_quotes q
SET specifications_snapshot = jsonb_build_object(
      'title', r.title,
      'description', r.description,
      'intended_use', r.intended_use,
      'dimensions', r.dimensions,
      'dimension_unit', r.dimension_unit,
      'dim_length_mm', r.dim_length_mm,
      'dim_width_mm', r.dim_width_mm,
      'dim_height_mm', r.dim_height_mm,
      'quantity', r.quantity,
      'material_preference', r.material_preference,
      'color_preference', r.color_preference,
      'manufacturing_options', r.manufacturing_options,
      'rush', r.rush,
      'product_specs', r.product_specs
    ),
    delivery_price_dzd = d.price_dzd,
    delivery_snapshot = jsonb_build_object(
      'wilaya_code', r.delivery_wilaya_code,
      'wilaya_name', w.name_fr,
      'commune_id', r.delivery_commune_id,
      'commune_name', c.name_fr,
      'delivery_method', r.delivery_method,
      'address', r.delivery_address,
      'pickup_point_id', r.delivery_pickup_point_id,
      'pickup_point_name', pp.name,
      'carrier', d.carrier,
      'estimated_days_min', d.estimated_days_min,
      'estimated_days_max', d.estimated_days_max,
      'price_dzd', d.price_dzd
    )
FROM public.custom_requests r
JOIN public.wilayas w
  ON w.code = r.delivery_wilaya_code AND w.is_active
JOIN public.communes c
  ON c.id = r.delivery_commune_id
 AND c.wilaya_code = r.delivery_wilaya_code
 AND c.is_active
LEFT JOIN public.pickup_points pp
  ON pp.id = r.delivery_pickup_point_id
 AND pp.wilaya_code = r.delivery_wilaya_code
 AND pp.is_active
CROSS JOIN LATERAL (
  SELECT dr.price_dzd, dr.estimated_days_min, dr.estimated_days_max, dr.carrier
  FROM public.delivery_rates dr
  WHERE dr.is_active
    AND dr.method = r.delivery_method
    AND (
      (dr.commune_id IS NOT NULL AND dr.commune_id = r.delivery_commune_id)
      OR (dr.commune_id IS NULL AND dr.wilaya_code = r.delivery_wilaya_code)
    )
  ORDER BY (dr.commune_id IS NOT NULL) DESC
  LIMIT 1
) d
WHERE q.request_id = r.id
  AND q.status = 'sent'
  AND r.delivery_method IN ('domicile', 'stopdesk')
  AND (r.delivery_method <> 'domicile' OR nullif(btrim(coalesce(r.delivery_address, '')), '') IS NOT NULL)
  AND (r.delivery_method <> 'stopdesk' OR pp.id IS NOT NULL);

DROP TRIGGER IF EXISTS custom_quotes_immutability_guard ON public.custom_quotes;
CREATE TRIGGER custom_quotes_immutability_guard
  BEFORE UPDATE OR DELETE ON public.custom_quotes
  FOR EACH ROW EXECUTE FUNCTION public.guard_custom_quote_immutability();

-- Legacy quotations are deliberately not marked as verified acceptances:
-- their exact historical specifications/delivery price cannot be reconstructed.
-- New approvals must be based on a fresh, newly accepted version.
COMMENT ON COLUMN public.custom_quotes.accepted_snapshot IS
  'Immutable customer-approved quotation snapshot, including specifications, DZD price and delivery quote.';
COMMENT ON COLUMN public.custom_quotes.accepted_snapshot_hash IS
  'MD5 integrity fingerprint of accepted_snapshot; not an authentication credential.';

-- Only trusted owner RPCs may approve the latest customer-accepted version.
CREATE OR REPLACE FUNCTION public.owner_approve_custom_request(
  p_quote_id uuid,
  p_note text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_quote public.custom_quotes%ROWTYPE;
  v_request public.custom_requests%ROWTYPE;
  v_existing public.orders%ROWTYPE;
  v_delivery jsonb;
  v_specs jsonb;
  v_order_id uuid;
  v_number text;
  v_token uuid;
  v_total bigint;
  v_latest_version integer;
  v_idempotency_key text;
BEGIN
  IF NOT public.is_owner() THEN RAISE EXCEPTION 'ACCES_REFUSE'; END IF;
  IF p_quote_id IS NULL THEN RAISE EXCEPTION 'DEVIS_INTROUVABLE'; END IF;

  SELECT * INTO v_quote
  FROM public.custom_quotes
  WHERE id = p_quote_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'DEVIS_INTROUVABLE'; END IF;

  SELECT * INTO v_request
  FROM public.custom_requests
  WHERE id = v_quote.request_id
  FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'DEMANDE_INTROUVABLE'; END IF;

  SELECT * INTO v_quote
  FROM public.custom_quotes
  WHERE id = p_quote_id
  FOR UPDATE;
  IF NOT FOUND OR v_quote.request_id <> v_request.id THEN
    RAISE EXCEPTION 'DEVIS_INTROUVABLE';
  END IF;

  v_idempotency_key := 'devis:' || v_quote.id::text;

  SELECT * INTO v_existing
  FROM public.orders
  WHERE idempotency_key = v_idempotency_key
  FOR UPDATE;

  IF FOUND THEN
    IF v_request.status IN ('rejected', 'closed')
       OR v_request.deletion_started_at IS NOT NULL
       OR v_existing.source <> 'custom'
       OR v_existing.subtotal_dzd <> v_quote.price_dzd THEN
      RAISE EXCEPTION 'COMMANDE_EXISTANTE_INCOHERENTE';
    END IF;

    UPDATE public.custom_quotes
    SET status = 'approved',
        decided_at = coalesce(decided_at, now()),
        order_id = v_existing.id
    WHERE id = v_quote.id;

    UPDATE public.custom_requests
    SET status = 'approved'
    WHERE id = v_request.id
      AND status NOT IN ('approved', 'closed', 'rejected');

    RETURN jsonb_build_object(
      'order_number', v_existing.order_number,
      'tracking_token', v_existing.tracking_token,
      'total_dzd', v_existing.total_dzd,
      'already_exists', true
    );
  END IF;

  IF v_quote.order_id IS NOT NULL THEN
    SELECT * INTO v_existing
    FROM public.orders
    WHERE id = v_quote.order_id;

    IF FOUND
       AND v_existing.source = 'custom'
       AND v_existing.subtotal_dzd = v_quote.price_dzd
       AND v_existing.idempotency_key = v_idempotency_key THEN
      RETURN jsonb_build_object(
        'order_number', v_existing.order_number,
        'tracking_token', v_existing.tracking_token,
        'total_dzd', v_existing.total_dzd,
        'already_exists', true
      );
    END IF;
    RAISE EXCEPTION 'COMMANDE_LIEE_INCOHERENTE';
  END IF;

  SELECT max(version) INTO v_latest_version
  FROM public.custom_quotes
  WHERE request_id = v_request.id;

  IF v_quote.status <> 'accepted'
     OR v_quote.version <> v_latest_version
     OR v_quote.accepted_snapshot IS NULL
     OR v_quote.accepted_snapshot_hash IS NULL
     OR v_quote.accepted_at IS NULL THEN
    RAISE EXCEPTION 'ACCEPTATION_CLIENT_REQUISE';
  END IF;

  IF v_quote.accepted_snapshot->>'quote_id' <> v_quote.id::text
     OR (v_quote.accepted_snapshot->>'version')::integer <> v_quote.version
     OR (v_quote.accepted_snapshot->>'price_dzd')::integer <> v_quote.price_dzd
     OR md5(v_quote.accepted_snapshot::text) <> v_quote.accepted_snapshot_hash THEN
    RAISE EXCEPTION 'SNAPSHOT_DEVIS_INCOHERENT';
  END IF;

  IF v_quote.valid_until < current_date THEN RAISE EXCEPTION 'DEVIS_EXPIRE'; END IF;
  IF v_request.status IN ('approved', 'rejected', 'closed') THEN
    RAISE EXCEPTION 'DEMANDE_CLOTUREE';
  END IF;
  IF v_request.deletion_started_at IS NOT NULL THEN
    RAISE EXCEPTION 'SUPPRESSION_DEMANDE_EN_COURS';
  END IF;

  v_delivery := v_quote.accepted_snapshot->'delivery';
  v_specs := v_quote.accepted_snapshot->'specifications';

  IF v_delivery IS NULL OR v_specs IS NULL THEN
    RAISE EXCEPTION 'SNAPSHOT_DEVIS_INCOMPLET';
  END IF;

  v_total := v_quote.price_dzd::bigint
           + (v_delivery->>'price_dzd')::integer;

  IF v_total < 0 OR v_total > 2147483647 THEN
    RAISE EXCEPTION 'TOTAL_COMMANDE_INVALIDE';
  END IF;

  v_number := public.next_order_number();

  INSERT INTO public.orders (
    order_number, idempotency_key, customer_name, phone, email,
    wilaya_code, commune_id, wilaya_name, commune_name,
    delivery_method, delivery_carrier, delivery_eta_min, delivery_eta_max,
    address, pickup_point_id, pickup_point_snapshot, note,
    subtotal_dzd, delivery_dzd, total_dzd, source
  ) VALUES (
    v_number, v_idempotency_key, v_request.customer_name, v_request.phone, v_request.email,
    (v_delivery->>'wilaya_code')::smallint,
    (v_delivery->>'commune_id')::uuid,
    v_delivery->>'wilaya_name',
    v_delivery->>'commune_name',
    v_delivery->>'delivery_method',
    v_delivery->>'carrier',
    (v_delivery->>'estimated_days_min')::integer,
    (v_delivery->>'estimated_days_max')::integer,
    nullif(v_delivery->>'address', ''),
    nullif(v_delivery->>'pickup_point_id', '')::uuid,
    nullif(v_delivery->>'pickup_point_name', ''),
    coalesce(nullif(btrim(coalesce(p_note, '')), ''),
      'Demande sur mesure ' || v_request.request_number || ' · devis v' || v_quote.version),
    v_quote.price_dzd,
    (v_delivery->>'price_dzd')::integer,
    v_total::integer,
    'custom'
  )
  RETURNING id, tracking_token INTO v_order_id, v_token;

  INSERT INTO public.order_items (
    order_id, product_id, variant_id, product_name, variant_label, sku,
    unit_price_dzd, quantity, line_total_dzd
  ) VALUES (
    v_order_id, NULL, NULL,
    coalesce(nullif(v_specs->>'title', ''), v_request.title),
    'Fabrication sur mesure · quantité ' || coalesce(v_specs->>'quantity', v_request.quantity::text),
    v_request.request_number || '-V' || v_quote.version,
    v_quote.price_dzd, 1, v_quote.price_dzd
  );

  INSERT INTO public.order_status_history (order_id, from_status, to_status, actor)
  VALUES (v_order_id, NULL, 'pending', 'proprietaire');

  UPDATE public.custom_quotes
  SET status = 'approved', decided_at = now(), order_id = v_order_id
  WHERE id = v_quote.id;

  UPDATE public.custom_requests
  SET status = 'approved'
  WHERE id = v_request.id;

  INSERT INTO public.custom_quote_events (request_id, quote_id, action, actor, note)
  VALUES (v_request.id, v_quote.id, 'approved', 'proprietaire', v_number);

  RETURN jsonb_build_object(
    'order_number', v_number,
    'tracking_token', v_token,
    'total_dzd', v_total,
    'already_exists', false
  );
END;
$$;

REVOKE EXECUTE ON FUNCTION public.owner_approve_custom_request(uuid, text)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.owner_approve_custom_request(uuid, text)
  TO authenticated;

-- Internal projection helper must not be directly callable by clients.
REVOKE EXECUTE ON FUNCTION public.customer_quote_breakdown(jsonb)
  FROM PUBLIC, anon, authenticated;

NOTIFY pgrst, 'reload schema';


-- Customer token RPC exposes only the public projection of manufacturing
-- breakdowns and the exact delivery amount that was frozen when the quote
-- version was issued. Never return pricing_snapshot or internal specifications.
CREATE OR REPLACE FUNCTION public.get_custom_request_by_token(p_token uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_result jsonb;
BEGIN
  IF p_token IS NULL THEN
    RAISE EXCEPTION 'DEMANDE_INTROUVABLE';
  END IF;

  UPDATE public.custom_quotes
  SET status = 'expired', decided_at = now()
  WHERE request_id = (
    SELECT id FROM public.custom_requests WHERE tracking_token = p_token
  )
    AND status = 'sent'
    AND valid_until < current_date;

  SELECT jsonb_build_object(
    'request_number', r.request_number,
    'status', r.status,
    'created_at', r.created_at,
    'title', r.title,
    'description', r.description,
    'quantity', r.quantity,
    'dimensions', r.dimensions,
    'dimension_unit', r.dimension_unit,
    'material_preference', r.material_preference,
    'color_preference', r.color_preference,
    'customer_name', r.customer_name,
    'files', coalesce((
      SELECT jsonb_agg(jsonb_build_object(
        'kind', f.kind,
        'original_name', f.original_name,
        'mime_type', f.mime_type
      ) ORDER BY f.created_at)
      FROM public.custom_request_files f
      WHERE f.request_id = r.id
    ), '[]'::jsonb),
    'quotes', coalesce((
      SELECT jsonb_agg(jsonb_build_object(
        'version', q.version,
        'public_token', q.public_token,
        'price_dzd', q.price_dzd,
        'currency_code', q.currency_code,
        'delivery_price_dzd', q.delivery_price_dzd,
        'production_lead_days', q.production_lead_days,
        'valid_until', q.valid_until,
        'terms', q.terms,
        'status', q.status,
        'source', q.source,
        'breakdown', public.customer_quote_breakdown(q.breakdown),
        'created_at', q.created_at
      ) ORDER BY q.version DESC)
      FROM public.custom_quotes q
      WHERE q.request_id = r.id
    ), '[]'::jsonb),
    'order_number', (
      SELECT o.order_number
      FROM public.custom_quotes q
      JOIN public.orders o ON o.id = q.order_id
      WHERE q.request_id = r.id AND q.order_id IS NOT NULL
      LIMIT 1
    )
  )
  INTO v_result
  FROM public.custom_requests r
  WHERE r.tracking_token = p_token;

  IF v_result IS NULL THEN
    RAISE EXCEPTION 'DEMANDE_INTROUVABLE';
  END IF;

  RETURN v_result;
END;
$$;

REVOKE EXECUTE ON FUNCTION public.get_custom_request_by_token(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_custom_request_by_token(uuid) TO anon, authenticated;

-- Tighten the public breakdown projection: only typed, non-negative aggregate
-- fields are copied. Unknown keys, nested objects, strings and internal costs
-- are discarded instead of being forwarded to the customer.
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
          (CASE
            WHEN jsonb_typeof(p_breakdown->'subtotalDzd') = 'number'
              AND (p_breakdown->>'subtotalDzd')::numeric >= 0
            THEN jsonb_build_array(jsonb_build_object(
              'label', 'Fabrication',
              'amountDzd', round((p_breakdown->>'subtotalDzd')::numeric)
            ))
            WHEN jsonb_typeof(p_breakdown->'unitPriceDzd') = 'number'
              AND (p_breakdown->>'unitPriceDzd')::numeric >= 0
            THEN jsonb_build_array(jsonb_build_object(
              'label', 'Fabrication',
              'amountDzd', round((p_breakdown->>'unitPriceDzd')::numeric)
            ))
            ELSE '[]'::jsonb
          END)
          ||
          (CASE
            WHEN jsonb_typeof(p_breakdown->'discountDzd') = 'number'
              AND (p_breakdown->>'discountDzd')::numeric > 0
            THEN jsonb_build_array(jsonb_build_object(
              'label', 'Remise',
              'amountDzd', -round((p_breakdown->>'discountDzd')::numeric)
            ))
            ELSE '[]'::jsonb
          END)
          ||
          (CASE
            WHEN jsonb_typeof(p_breakdown->'rushFeeDzd') = 'number'
              AND (p_breakdown->>'rushFeeDzd')::numeric > 0
            THEN jsonb_build_array(jsonb_build_object(
              'label', 'Supplément urgence',
              'amountDzd', round((p_breakdown->>'rushFeeDzd')::numeric)
            ))
            ELSE '[]'::jsonb
          END)
      END,
    'unitPriceDzd', CASE
      WHEN jsonb_typeof(p_breakdown->'unitPriceDzd') = 'number'
       AND (p_breakdown->>'unitPriceDzd')::numeric >= 0
      THEN p_breakdown->'unitPriceDzd' ELSE NULL END,
    'quantity', CASE
      WHEN jsonb_typeof(p_breakdown->'quantity') = 'number'
       AND (p_breakdown->>'quantity')::numeric BETWEEN 1 AND 100000
       AND trunc((p_breakdown->>'quantity')::numeric) = (p_breakdown->>'quantity')::numeric
      THEN p_breakdown->'quantity' ELSE NULL END,
    'subtotalDzd', CASE
      WHEN jsonb_typeof(p_breakdown->'subtotalDzd') = 'number'
       AND (p_breakdown->>'subtotalDzd')::numeric >= 0
      THEN p_breakdown->'subtotalDzd' ELSE NULL END,
    'discountPercent', CASE
      WHEN jsonb_typeof(p_breakdown->'discountPercent') = 'number'
       AND (p_breakdown->>'discountPercent')::numeric BETWEEN 0 AND 100
      THEN p_breakdown->'discountPercent' ELSE NULL END,
    'discountDzd', CASE
      WHEN jsonb_typeof(p_breakdown->'discountDzd') = 'number'
       AND (p_breakdown->>'discountDzd')::numeric >= 0
      THEN p_breakdown->'discountDzd' ELSE NULL END,
    'rushFeeDzd', CASE
      WHEN jsonb_typeof(p_breakdown->'rushFeeDzd') = 'number'
       AND (p_breakdown->>'rushFeeDzd')::numeric >= 0
      THEN p_breakdown->'rushFeeDzd' ELSE NULL END,
    'totalDzd', CASE
      WHEN jsonb_typeof(p_breakdown->'totalDzd') = 'number'
       AND (p_breakdown->>'totalDzd')::numeric >= 0
      THEN p_breakdown->'totalDzd' ELSE NULL END,
    'geometryVerified', CASE
      WHEN jsonb_typeof(p_breakdown->'geometryVerified') = 'boolean'
      THEN p_breakdown->'geometryVerified' ELSE NULL END
  );
$$;

REVOKE EXECUTE ON FUNCTION public.customer_quote_breakdown(jsonb)
  FROM PUBLIC, anon, authenticated;

NOTIFY pgrst, 'reload schema';



-- ============================================================================
-- SOURCE: 20261118100000_025_inventory_movement_ledger.sql
-- ============================================================================

-- 025 — Idempotent inventory reservation ledger and archive restoration.
-- Checkout still reserves stock in its existing atomic RPC. This migration
-- records those reservations, makes release/re-reserve idempotent, and fixes
-- archive/cancel transitions without changing order financial snapshots.

ALTER TABLE public.order_items
  ADD COLUMN IF NOT EXISTS stock_tracked boolean NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS stock_reserved boolean NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS stock_product_id_snapshot uuid,
  ADD COLUMN IF NOT EXISTS stock_variant_id_snapshot uuid,
  ADD COLUMN IF NOT EXISTS inventory_movement_sequence integer NOT NULL DEFAULT 0;

ALTER TABLE public.order_items
  ADD CONSTRAINT order_items_inventory_sequence_check
  CHECK (inventory_movement_sequence >= 0);

CREATE TABLE IF NOT EXISTS public.inventory_movements (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  order_id uuid REFERENCES public.orders(id) ON DELETE SET NULL,
  order_item_id uuid REFERENCES public.order_items(id) ON DELETE SET NULL,
  order_number text NOT NULL,
  product_id uuid,
  variant_id uuid,
  movement_sequence integer NOT NULL CHECK (movement_sequence > 0),
  movement_type text NOT NULL CHECK (movement_type IN ('reserved', 'released', 'consumed')),
  quantity integer NOT NULL CHECK (quantity > 0),
  quantity_delta integer NOT NULL,
  reason text NOT NULL CHECK (reason IN ('checkout', 'cancellation', 'archive', 'restore', 'delivery')),
  actor_id uuid,
  created_at timestamptz NOT NULL DEFAULT now(),
  CHECK (
    (movement_type = 'reserved' AND quantity_delta = -quantity)
    OR
    (movement_type = 'released' AND quantity_delta = quantity)
    OR
    (movement_type = 'consumed' AND quantity_delta = 0)
  )
);

CREATE UNIQUE INDEX IF NOT EXISTS inventory_movements_item_sequence_uidx
  ON public.inventory_movements(order_item_id, movement_sequence)
  WHERE order_item_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS inventory_movements_order_idx
  ON public.inventory_movements(order_id, created_at DESC);

CREATE INDEX IF NOT EXISTS inventory_movements_product_idx
  ON public.inventory_movements(product_id, created_at DESC);

ALTER TABLE public.inventory_movements ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.inventory_movements FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.inventory_movements TO authenticated;

DROP POLICY IF EXISTS inventory_movements_owner_read ON public.inventory_movements;
CREATE POLICY inventory_movements_owner_read
  ON public.inventory_movements
  FOR SELECT TO authenticated
  USING (public.is_owner());

-- Recover the historical stock-tracking decision as closely as possible from
-- the current product/variant policy. Product and variant IDs are snapshotted
-- so later catalog deletion cannot erase the movement target.
UPDATE public.order_items i
SET stock_tracked = (
      i.product_id IS NOT NULL
      AND NOT coalesce(
        (SELECT v.made_to_order FROM public.product_variants v WHERE v.id = i.variant_id),
        (SELECT p.made_to_order FROM public.products p WHERE p.id = i.product_id),
        false
      )
    ),
    stock_product_id_snapshot = i.product_id,
    stock_variant_id_snapshot = i.variant_id
WHERE i.product_id IS NOT NULL;

UPDATE public.order_items i
SET stock_reserved = (
      i.stock_tracked
      AND o.archived_at IS NULL
      AND o.status NOT IN ('cancelled', 'delivered')
    ),
    inventory_movement_sequence = CASE
      WHEN i.stock_tracked AND (o.archived_at IS NOT NULL OR o.status IN ('cancelled', 'delivered')) THEN 2
      WHEN i.stock_tracked THEN 1
      ELSE 0
    END
FROM public.orders o
WHERE o.id = i.order_id;

-- Archive previously left pending/confirmed reservations deducted. Restore
-- those quantities once as part of this migration, then represent the release
-- in the ledger. Cancelled orders were already restored by the old status RPC.
WITH archived_variant_stock AS (
  SELECT i.stock_variant_id_snapshot AS variant_id, sum(i.quantity)::integer AS quantity
  FROM public.order_items i
  JOIN public.orders o ON o.id = i.order_id
  WHERE i.stock_tracked
    AND i.stock_variant_id_snapshot IS NOT NULL
    AND o.archived_at IS NOT NULL
    AND o.status IN ('pending', 'confirmed')
  GROUP BY i.stock_variant_id_snapshot
)
UPDATE public.product_variants v
SET stock_quantity = v.stock_quantity + a.quantity
FROM archived_variant_stock a
WHERE v.id = a.variant_id;

WITH archived_product_stock AS (
  SELECT i.stock_product_id_snapshot AS product_id, sum(i.quantity)::integer AS quantity
  FROM public.order_items i
  JOIN public.orders o ON o.id = i.order_id
  WHERE i.stock_tracked
    AND i.stock_variant_id_snapshot IS NULL
    AND i.stock_product_id_snapshot IS NOT NULL
    AND o.archived_at IS NOT NULL
    AND o.status IN ('pending', 'confirmed')
  GROUP BY i.stock_product_id_snapshot
)
UPDATE public.products p
SET stock_quantity = p.stock_quantity + a.quantity
FROM archived_product_stock a
WHERE p.id = a.product_id;

-- Initial reserve rows plus compensating releases for already-cancelled or
-- already-archived orders. This records existing state without re-deducting
-- active orders.
INSERT INTO public.inventory_movements (
  order_id, order_item_id, order_number, product_id, variant_id,
  movement_sequence, movement_type, quantity, quantity_delta, reason
)
SELECT
  o.id, i.id, o.order_number, i.stock_product_id_snapshot, i.stock_variant_id_snapshot,
  1, 'reserved', i.quantity, -i.quantity, 'checkout'
FROM public.order_items i
JOIN public.orders o ON o.id = i.order_id
WHERE i.stock_tracked
ON CONFLICT DO NOTHING;

INSERT INTO public.inventory_movements (
  order_id, order_item_id, order_number, product_id, variant_id,
  movement_sequence, movement_type, quantity, quantity_delta, reason
)
SELECT
  o.id, i.id, o.order_number, i.stock_product_id_snapshot, i.stock_variant_id_snapshot,
  2, 'released', i.quantity, i.quantity,
  CASE WHEN o.archived_at IS NOT NULL THEN 'archive' ELSE 'cancellation' END
FROM public.order_items i
JOIN public.orders o ON o.id = i.order_id
WHERE i.stock_tracked
  AND (o.archived_at IS NOT NULL OR o.status = 'cancelled')
ON CONFLICT DO NOTHING;

INSERT INTO public.inventory_movements (
  order_id, order_item_id, order_number, product_id, variant_id,
  movement_sequence, movement_type, quantity, quantity_delta, reason
)
SELECT
  o.id, i.id, o.order_number, i.stock_product_id_snapshot, i.stock_variant_id_snapshot,
  2, 'consumed', i.quantity, 0, 'delivery'
FROM public.order_items i
JOIN public.orders o ON o.id = i.order_id
WHERE i.stock_tracked
  AND o.status = 'delivered'
  AND o.archived_at IS NULL
ON CONFLICT DO NOTHING;

CREATE OR REPLACE FUNCTION public.record_order_item_stock_reservation()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_product public.products%ROWTYPE;
  v_variant public.product_variants%ROWTYPE;
  v_order public.orders%ROWTYPE;
  v_track_stock boolean;
BEGIN
  IF NEW.product_id IS NULL THEN
    RETURN NEW;
  END IF;

  SELECT * INTO v_product
  FROM public.products
  WHERE id = NEW.product_id
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'PRODUIT_INTROUVABLE';
  END IF;

  IF NEW.variant_id IS NOT NULL THEN
    SELECT * INTO v_variant
    FROM public.product_variants
    WHERE id = NEW.variant_id AND product_id = NEW.product_id
    FOR UPDATE;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'VARIANTE_INTROUVABLE';
    END IF;
  END IF;

  v_track_stock := NOT coalesce(v_variant.made_to_order, v_product.made_to_order, false);

  IF NOT v_track_stock THEN
    RETURN NEW;
  END IF;

  SELECT * INTO v_order
  FROM public.orders
  WHERE id = NEW.order_id
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'COMMANDE_INTROUVABLE';
  END IF;

  UPDATE public.order_items
  SET stock_tracked = true,
      stock_reserved = true,
      stock_product_id_snapshot = NEW.product_id,
      stock_variant_id_snapshot = NEW.variant_id,
      inventory_movement_sequence = 1
  WHERE id = NEW.id;

  INSERT INTO public.inventory_movements (
    order_id, order_item_id, order_number, product_id, variant_id,
    movement_sequence, movement_type, quantity, quantity_delta, reason, actor_id
  ) VALUES (
    NEW.order_id, NEW.id, v_order.order_number, NEW.product_id, NEW.variant_id,
    1, 'reserved', NEW.quantity, -NEW.quantity, 'checkout', auth.uid()
  );

  RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION public.record_order_item_stock_reservation()
  FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS order_items_record_stock_reservation ON public.order_items;
CREATE TRIGGER order_items_record_stock_reservation
  AFTER INSERT ON public.order_items
  FOR EACH ROW EXECUTE FUNCTION public.record_order_item_stock_reservation();

CREATE OR REPLACE FUNCTION public.apply_order_inventory_movement(
  p_order_id uuid,
  p_action text,
  p_reason text
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_order public.orders%ROWTYPE;
  v_item public.order_items%ROWTYPE;
  v_next_sequence integer;
  v_updated integer;
BEGIN
  IF NOT public.is_owner() THEN
    RAISE EXCEPTION 'ACCES_REFUSE';
  END IF;

  IF p_action NOT IN ('release', 'reserve', 'consume')
     OR p_reason NOT IN ('cancellation', 'archive', 'restore', 'delivery') THEN
    RAISE EXCEPTION 'MOUVEMENT_STOCK_INVALIDE';
  END IF;

  SELECT * INTO v_order
  FROM public.orders
  WHERE id = p_order_id
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'COMMANDE_INTROUVABLE';
  END IF;

  FOR v_item IN
    SELECT *
    FROM public.order_items
    WHERE order_id = p_order_id AND stock_tracked
    ORDER BY id
    FOR UPDATE
  LOOP
    IF p_action = 'release' AND v_item.stock_reserved THEN
      IF v_item.stock_variant_id_snapshot IS NOT NULL THEN
        UPDATE public.product_variants
        SET stock_quantity = stock_quantity + v_item.quantity
        WHERE id = v_item.stock_variant_id_snapshot;
      ELSE
        UPDATE public.products
        SET stock_quantity = stock_quantity + v_item.quantity
        WHERE id = v_item.stock_product_id_snapshot;
      END IF;

      GET DIAGNOSTICS v_updated = ROW_COUNT;
      IF v_updated <> 1 THEN
        RAISE EXCEPTION 'ARTICLE_STOCK_INTROUVABLE';
      END IF;

      v_next_sequence := v_item.inventory_movement_sequence + 1;
      UPDATE public.order_items
      SET stock_reserved = false,
          inventory_movement_sequence = v_next_sequence
      WHERE id = v_item.id;

      INSERT INTO public.inventory_movements (
        order_id, order_item_id, order_number, product_id, variant_id,
        movement_sequence, movement_type, quantity, quantity_delta, reason, actor_id
      ) VALUES (
        v_order.id, v_item.id, v_order.order_number,
        v_item.stock_product_id_snapshot, v_item.stock_variant_id_snapshot,
        v_next_sequence, 'released', v_item.quantity, v_item.quantity, p_reason, auth.uid()
      );

    ELSIF p_action = 'reserve' AND NOT v_item.stock_reserved THEN
      IF v_item.stock_variant_id_snapshot IS NOT NULL THEN
        UPDATE public.product_variants
        SET stock_quantity = stock_quantity - v_item.quantity
        WHERE id = v_item.stock_variant_id_snapshot
          AND stock_quantity >= v_item.quantity;
      ELSE
        UPDATE public.products
        SET stock_quantity = stock_quantity - v_item.quantity
        WHERE id = v_item.stock_product_id_snapshot
          AND stock_quantity >= v_item.quantity;
      END IF;

      GET DIAGNOSTICS v_updated = ROW_COUNT;
      IF v_updated <> 1 THEN
        RAISE EXCEPTION 'STOCK_INSUFFISANT';
      END IF;

      v_next_sequence := v_item.inventory_movement_sequence + 1;
      UPDATE public.order_items
      SET stock_reserved = true,
          inventory_movement_sequence = v_next_sequence
      WHERE id = v_item.id;

      INSERT INTO public.inventory_movements (
        order_id, order_item_id, order_number, product_id, variant_id,
        movement_sequence, movement_type, quantity, quantity_delta, reason, actor_id
      ) VALUES (
        v_order.id, v_item.id, v_order.order_number,
        v_item.stock_product_id_snapshot, v_item.stock_variant_id_snapshot,
        v_next_sequence, 'reserved', v_item.quantity, -v_item.quantity, p_reason, auth.uid()
      );
    ELSIF p_action = 'consume' AND v_item.stock_reserved THEN
      v_next_sequence := v_item.inventory_movement_sequence + 1;
      UPDATE public.order_items
      SET stock_reserved = false,
          inventory_movement_sequence = v_next_sequence
      WHERE id = v_item.id;

      INSERT INTO public.inventory_movements (
        order_id, order_item_id, order_number, product_id, variant_id,
        movement_sequence, movement_type, quantity, quantity_delta, reason, actor_id
      ) VALUES (
        v_order.id, v_item.id, v_order.order_number,
        v_item.stock_product_id_snapshot, v_item.stock_variant_id_snapshot,
        v_next_sequence, 'consumed', v_item.quantity, 0, p_reason, auth.uid()
      );
    END IF;
  END LOOP;
END;
$$;

REVOKE ALL ON FUNCTION public.apply_order_inventory_movement(uuid, text, text)
  FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.set_order_status(p_order_id uuid, p_status text)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_order public.orders%ROWTYPE;
BEGIN
  IF NOT public.is_owner() THEN
    RAISE EXCEPTION 'ACCES_REFUSE';
  END IF;

  SELECT * INTO v_order
  FROM public.orders
  WHERE id = p_order_id
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'COMMANDE_INTROUVABLE';
  END IF;

  IF v_order.archived_at IS NOT NULL THEN
    RAISE EXCEPTION 'COMMANDE_ARCHIVEE';
  END IF;

  IF v_order.status = p_status THEN
    RETURN;
  END IF;

  IF NOT (
    (v_order.status = 'pending' AND p_status IN ('confirmed', 'cancelled')) OR
    (v_order.status = 'confirmed' AND p_status IN ('shipped', 'cancelled')) OR
    (v_order.status = 'shipped' AND p_status = 'delivered')
  ) THEN
    RAISE EXCEPTION 'TRANSITION_INVALIDE';
  END IF;

  IF p_status = 'cancelled' THEN
    PERFORM public.apply_order_inventory_movement(p_order_id, 'release', 'cancellation');
  ELSIF p_status = 'delivered' THEN
    PERFORM public.apply_order_inventory_movement(p_order_id, 'consume', 'delivery');
  END IF;

  UPDATE public.orders
  SET status = p_status
  WHERE id = p_order_id;

  INSERT INTO public.order_status_history (order_id, from_status, to_status, actor)
  VALUES (p_order_id, v_order.status, p_status, 'proprietaire');
END;
$$;

REVOKE EXECUTE ON FUNCTION public.set_order_status(uuid, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.set_order_status(uuid, text) TO authenticated;

-- Archiving releases outstanding reservations. Repeated archive requests are
-- harmless because stock_reserved is the authoritative state and the order
-- row is locked for the entire transaction.
CREATE OR REPLACE FUNCTION public.delete_order(
  p_order_id uuid,
  p_reason text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_order public.orders%ROWTYPE;
BEGIN
  IF NOT public.is_owner() THEN
    RAISE EXCEPTION 'ACCES_REFUSE';
  END IF;

  SELECT * INTO v_order
  FROM public.orders
  WHERE id = p_order_id
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'COMMANDE_INTROUVABLE';
  END IF;

  IF v_order.status IN ('delivered', 'shipped') THEN
    RAISE EXCEPTION 'COMMANDE_NON_SUPPRIMABLE';
  END IF;

  IF v_order.archived_at IS NOT NULL THEN
    RETURN jsonb_build_object(
      'archived', true,
      'already_archived', true,
      'order_number', v_order.order_number
    );
  END IF;

  PERFORM public.apply_order_inventory_movement(p_order_id, 'release', 'archive');

  UPDATE public.orders
  SET archived_at = now(),
      archived_by = auth.uid(),
      archive_reason = nullif(btrim(coalesce(p_reason, '')), '')
  WHERE id = p_order_id;

  INSERT INTO public.audit_log (actor_id, action, entity, entity_id, details)
  VALUES (
    auth.uid(), 'order.archived', 'orders', v_order.id::text,
    jsonb_build_object(
      'order_number', v_order.order_number,
      'status', v_order.status,
      'total_dzd', v_order.total_dzd,
      'reason', p_reason,
      'inventory_released', true
    )
  );

  RETURN jsonb_build_object(
    'archived', true,
    'already_archived', false,
    'order_number', v_order.order_number
  );
END;
$$;

REVOKE EXECUTE ON FUNCTION public.delete_order(uuid, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.delete_order(uuid, text) TO authenticated;

CREATE OR REPLACE FUNCTION public.restore_archived_order(p_order_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_order public.orders%ROWTYPE;
BEGIN
  IF NOT public.is_owner() THEN
    RAISE EXCEPTION 'ACCES_REFUSE';
  END IF;

  SELECT * INTO v_order
  FROM public.orders
  WHERE id = p_order_id
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'COMMANDE_INTROUVABLE';
  END IF;

  IF v_order.archived_at IS NULL THEN
    RETURN jsonb_build_object('restored', true, 'already_restored', true);
  END IF;

  IF v_order.status IN ('pending', 'confirmed') THEN
    PERFORM public.apply_order_inventory_movement(p_order_id, 'reserve', 'restore');
  ELSIF v_order.status <> 'cancelled' THEN
    RAISE EXCEPTION 'COMMANDE_NON_RESTAURABLE';
  END IF;

  UPDATE public.orders
  SET archived_at = NULL,
      archived_by = NULL,
      archive_reason = NULL
  WHERE id = p_order_id;

  INSERT INTO public.audit_log (actor_id, action, entity, entity_id, details)
  VALUES (
    auth.uid(), 'order.restored', 'orders', v_order.id::text,
    jsonb_build_object('order_number', v_order.order_number, 'status', v_order.status)
  );

  RETURN jsonb_build_object('restored', true, 'already_restored', false);
END;
$$;

REVOKE EXECUTE ON FUNCTION public.restore_archived_order(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.restore_archived_order(uuid) TO authenticated;

COMMENT ON TABLE public.inventory_movements IS
  'Append-only inventory movement ledger. Negative quantity_delta reserves stock; positive quantity_delta releases it.';
COMMENT ON COLUMN public.order_items.stock_reserved IS
  'Whether this order item currently holds a physical stock reservation.';
COMMENT ON COLUMN public.order_items.inventory_movement_sequence IS
  'Monotonic per-order-item movement sequence; unique ledger rows prevent duplicate state transitions.';

NOTIFY pgrst, 'reload schema';



-- ============================================================================
-- SOURCE: 20261118110000_026_storage_atomic_quotas.sql
-- ============================================================================

-- 026 — Close Storage upsert and anonymous folder-creation quota bypasses.
-- The intake bucket remains private. Limits are enforced inside the storage
-- transaction, serialized per client and folder, and apply to INSERT and UPDATE.

CREATE TABLE IF NOT EXISTS lunder_private.storage_upload_attempts (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  client_key text NOT NULL,
  folder_id text NOT NULL,
  object_name text NOT NULL,
  size_bytes bigint NOT NULL CHECK (size_bytes > 0),
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS storage_upload_attempts_client_time_idx
  ON lunder_private.storage_upload_attempts(client_key, created_at DESC);

REVOKE ALL ON lunder_private.storage_upload_attempts
  FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.guard_custom_request_storage_upload()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, storage, lunder_private, pg_temp
AS $$
DECLARE
  v_folder text;
  v_old_folder text;
  v_extension text;
  v_mime text;
  v_file_size bigint;
  v_existing_count integer;
  v_existing_bytes bigint;
  v_client_key text;
  v_headers jsonb;
  v_ip_text text;
  v_folder_count integer;
  v_upload_count integer;
  v_upload_bytes bigint;
  v_folder_exists boolean;
  v_is_new_upload boolean;
BEGIN
  IF NEW.bucket_id <> 'custom-requests' THEN
    RETURN NEW;
  END IF;

  IF TG_OP = 'INSERT' THEN
    v_is_new_upload := true;
  ELSE
    v_is_new_upload := NEW.name IS DISTINCT FROM OLD.name
      OR NEW.metadata->>'size' IS DISTINCT FROM OLD.metadata->>'size';
  END IF;

  IF NOT v_is_new_upload THEN
    RETURN NEW;
  END IF;

  IF NEW.name !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/[0-9]{13}-[0-9]{1,2}\.(jpg|jpeg|png|webp|avif|glb|gltf|stl|obj)$' THEN
    RAISE EXCEPTION 'CUSTOM_UPLOAD_PATH_INVALID';
  END IF;

  v_folder := split_part(NEW.name, '/', 1);
  v_extension := lower(split_part(NEW.name, '.', 2));

  IF coalesce(NEW.metadata->>'size', '') !~ '^[0-9]{1,12}$' THEN
    RAISE EXCEPTION 'CUSTOM_UPLOAD_FILE_SIZE_INVALID';
  END IF;

  v_file_size := (NEW.metadata->>'size')::bigint;
  IF v_file_size < 1 OR v_file_size > 26214400 THEN
    RAISE EXCEPTION 'CUSTOM_UPLOAD_FILE_SIZE_INVALID';
  END IF;

  v_mime := lower(coalesce(NEW.metadata->>'mimetype', NEW.metadata->>'mimeType', ''));
  IF v_mime <> '' THEN
    IF v_extension IN ('jpg', 'jpeg') AND v_mime <> 'image/jpeg' THEN
      RAISE EXCEPTION 'CUSTOM_UPLOAD_MIME_INVALID';
    ELSIF v_extension = 'png' AND v_mime <> 'image/png' THEN
      RAISE EXCEPTION 'CUSTOM_UPLOAD_MIME_INVALID';
    ELSIF v_extension = 'webp' AND v_mime <> 'image/webp' THEN
      RAISE EXCEPTION 'CUSTOM_UPLOAD_MIME_INVALID';
    ELSIF v_extension = 'avif' AND v_mime <> 'image/avif' THEN
      RAISE EXCEPTION 'CUSTOM_UPLOAD_MIME_INVALID';
    ELSIF v_extension = 'glb' AND v_mime NOT IN ('model/gltf-binary', 'application/octet-stream') THEN
      RAISE EXCEPTION 'CUSTOM_UPLOAD_MIME_INVALID';
    ELSIF v_extension = 'gltf' AND v_mime NOT IN ('model/gltf+json', 'application/octet-stream', 'text/plain') THEN
      RAISE EXCEPTION 'CUSTOM_UPLOAD_MIME_INVALID';
    ELSIF v_extension = 'stl' AND v_mime NOT IN ('model/stl', 'application/octet-stream', 'text/plain') THEN
      RAISE EXCEPTION 'CUSTOM_UPLOAD_MIME_INVALID';
    ELSIF v_extension = 'obj' AND v_mime NOT IN ('model/obj', 'application/octet-stream', 'text/plain') THEN
      RAISE EXCEPTION 'CUSTOM_UPLOAD_MIME_INVALID';
    END IF;
  END IF;

  -- Stable server-observed client identity. Anonymous uploads fail closed if
  -- the gateway does not provide a usable source IP; no client-supplied folder
  -- identifier is accepted as the rate-limit identity.
  BEGIN
    v_headers := coalesce(
      nullif(current_setting('request.headers', true), '')::jsonb,
      '{}'::jsonb
    );
    v_ip_text := split_part(
      coalesce(v_headers->>'x-forwarded-for', v_headers->>'x-real-ip', ''),
      ',',
      1
    );
    IF nullif(btrim(v_ip_text), '') IS NOT NULL THEN
      v_client_key := 'ip:' || md5(btrim(v_ip_text)::inet::text);
    END IF;
  EXCEPTION WHEN OTHERS THEN
    v_client_key := NULL;
  END;

  IF v_client_key IS NULL AND auth.uid() IS NOT NULL THEN
    v_client_key := 'user:' || auth.uid()::text;
  END IF;

  IF v_client_key IS NULL THEN
    RAISE EXCEPTION 'CUSTOM_UPLOAD_CLIENT_ID_REQUIRED';
  END IF;

  -- Serialize all uploads from one client, then lock both affected folders in
  -- stable order for safe upserts/moves without deadlocks.
  PERFORM pg_advisory_xact_lock(hashtextextended('custom-upload-client:' || v_client_key, 0));

  IF TG_OP = 'UPDATE' AND OLD.bucket_id = 'custom-requests' THEN
    v_old_folder := split_part(OLD.name, '/', 1);
    IF v_old_folder <> v_folder THEN
      IF v_old_folder < v_folder THEN
        PERFORM pg_advisory_xact_lock(hashtextextended('custom-request-upload:' || v_old_folder, 0));
        PERFORM pg_advisory_xact_lock(hashtextextended('custom-request-upload:' || v_folder, 0));
      ELSE
        PERFORM pg_advisory_xact_lock(hashtextextended('custom-request-upload:' || v_folder, 0));
        PERFORM pg_advisory_xact_lock(hashtextextended('custom-request-upload:' || v_old_folder, 0));
      END IF;
    ELSE
      PERFORM pg_advisory_xact_lock(hashtextextended('custom-request-upload:' || v_folder, 0));
    END IF;
  ELSE
    PERFORM pg_advisory_xact_lock(hashtextextended('custom-request-upload:' || v_folder, 0));
  END IF;

  IF TG_OP = 'UPDATE'
     AND OLD.bucket_id = 'custom-requests'
     AND split_part(OLD.name, '/', 1) = v_folder THEN
    v_folder_exists := true;
  ELSE
    SELECT EXISTS (
      SELECT 1
      FROM storage.objects
      WHERE bucket_id = 'custom-requests'
        AND split_part(name, '/', 1) = v_folder
        AND (TG_OP <> 'UPDATE' OR id <> NEW.id)
    ) INTO v_folder_exists;
  END IF;

  SELECT count(*),
         coalesce(sum(coalesce(nullif(metadata->>'size', '')::bigint, 0)), 0)
  INTO v_existing_count, v_existing_bytes
  FROM storage.objects
  WHERE bucket_id = 'custom-requests'
    AND split_part(name, '/', 1) = v_folder
    AND (TG_OP <> 'UPDATE' OR id <> NEW.id);

  IF v_existing_count >= 10 THEN
    RAISE EXCEPTION 'CUSTOM_UPLOAD_FILE_COUNT_EXCEEDED';
  END IF;

  IF v_existing_bytes + v_file_size > 104857600 THEN
    RAISE EXCEPTION 'CUSTOM_UPLOAD_TOTAL_SIZE_EXCEEDED';
  END IF;

  SELECT count(DISTINCT folder_id),
         count(*),
         coalesce(sum(size_bytes), 0)
  INTO v_folder_count, v_upload_count, v_upload_bytes
  FROM lunder_private.storage_upload_attempts
  WHERE client_key = v_client_key
    AND created_at >= now() - interval '24 hours';

  IF NOT v_folder_exists AND v_folder_count >= 10 THEN
    RAISE EXCEPTION 'CUSTOM_UPLOAD_DAILY_FOLDER_LIMIT';
  END IF;

  IF v_upload_count >= 50 THEN
    RAISE EXCEPTION 'CUSTOM_UPLOAD_DAILY_FILE_LIMIT';
  END IF;

  IF v_upload_bytes + v_file_size > 262144000 THEN
    RAISE EXCEPTION 'CUSTOM_UPLOAD_DAILY_SIZE_LIMIT';
  END IF;

  INSERT INTO lunder_private.storage_upload_attempts (
    client_key, folder_id, object_name, size_bytes
  ) VALUES (
    v_client_key, v_folder, NEW.name, v_file_size
  );

  RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION public.guard_custom_request_storage_upload()
  FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS guard_custom_request_storage_upload ON storage.objects;
CREATE TRIGGER guard_custom_request_storage_upload
  BEFORE INSERT OR UPDATE ON storage.objects
  FOR EACH ROW
  WHEN (NEW.bucket_id = 'custom-requests')
  EXECUTE FUNCTION public.guard_custom_request_storage_upload();

-- The intake bucket must stay private and guest uploads must never gain read,
-- update, or delete rights through this migration.
UPDATE storage.buckets
SET public = false,
    file_size_limit = 26214400,
    allowed_mime_types = ARRAY[
      'image/jpeg', 'image/png', 'image/webp', 'image/avif',
      'model/gltf-binary', 'model/gltf+json', 'model/stl', 'model/obj',
      'application/octet-stream', 'text/plain'
    ]
WHERE id = 'custom-requests';

DROP POLICY IF EXISTS "guest_upload_custom_requests" ON storage.objects;
CREATE POLICY "guest_upload_custom_requests" ON storage.objects
  FOR INSERT TO anon, authenticated
  WITH CHECK (bucket_id = 'custom-requests');

DROP POLICY IF EXISTS "owner_read_custom_requests" ON storage.objects;
CREATE POLICY "owner_read_custom_requests" ON storage.objects
  FOR SELECT TO authenticated
  USING (bucket_id = 'custom-requests' AND public.is_owner());

DROP POLICY IF EXISTS "owner_delete_custom_requests" ON storage.objects;
CREATE POLICY "owner_delete_custom_requests" ON storage.objects
  FOR DELETE TO authenticated
  USING (bucket_id = 'custom-requests' AND public.is_owner());

NOTIFY pgrst, 'reload schema';



-- ============================================================================
-- SOURCE: 20261118120000_027_tracking_attempt_serialization.sql
-- ============================================================================

-- 027 — Serialize per-order tracking attempts.
-- The per-client rate limit is already atomic; this closes the second race in
-- the per-order 8-attempt window when multiple IPs hit the same order at once.

CREATE INDEX IF NOT EXISTS idx_tracking_attempts_order_created
  ON public.tracking_attempts(order_number, created_at DESC);

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
  -- Atomic per-client/IP budget, including invalid and unsuccessful attempts.
  IF NOT lunder_private.record_guest_rate_limit('track_order', 20, 900) THEN
    RETURN jsonb_build_object('found', false, 'rate_limited', true);
  END IF;

  IF v_number !~ '^LND-[0-9]{4}-[0-9]{5,}$' OR length(v_phone) <> 9 THEN
    RETURN jsonb_build_object('found', false, 'rate_limited', false);
  END IF;

  -- Serialize attempts against one order across different clients/IPs. Without
  -- this lock, simultaneous requests could all read a count below eight.
  PERFORM pg_advisory_xact_lock(
    hashtextextended('track-order:' || v_number, 0)
  );

  DELETE FROM public.tracking_attempts
  WHERE created_at < now() - interval '1 day';

  SELECT count(*) INTO v_attempts
  FROM public.tracking_attempts
  WHERE order_number = v_number
    AND created_at > now() - interval '15 minutes';

  IF v_attempts >= 8 THEN
    RETURN jsonb_build_object('found', false, 'rate_limited', true);
  END IF;

  INSERT INTO public.tracking_attempts (order_number)
  VALUES (v_number);

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

NOTIFY pgrst, 'reload schema';



-- ============================================================================
-- SOURCE: 20261118130000_028_manufacturing_cost_engine.sql
-- ============================================================================

-- 028 — General-purpose custom manufacturing costing.
-- Extends the existing materials catalogue instead of creating a duplicate.
-- Quotes snapshot every material price and rate used by the server calculation.

CREATE TABLE IF NOT EXISTS public.suppliers (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name text NOT NULL UNIQUE CHECK (length(btrim(name)) BETWEEN 1 AND 120),
  contact_name text,
  phone text,
  email text,
  address text,
  notes text,
  is_active boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE public.suppliers ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.suppliers FROM PUBLIC, anon, authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.suppliers TO authenticated;
DROP POLICY IF EXISTS suppliers_owner_all ON public.suppliers;
CREATE POLICY suppliers_owner_all ON public.suppliers
  FOR ALL TO authenticated
  USING (public.is_owner())
  WITH CHECK (public.is_owner());

ALTER TABLE public.materials
  ADD COLUMN IF NOT EXISTS unit_type text NOT NULL DEFAULT 'kg',
  ADD COLUMN IF NOT EXISTS unit_cost_dzd integer NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS unit_cost_configured boolean NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS supplier_id uuid REFERENCES public.suppliers(id) ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS supplier_reference text;

ALTER TABLE public.materials
  ADD CONSTRAINT materials_unit_type_check
  CHECK (unit_type IN ('piece', 'meter', 'm2', 'kg'));

ALTER TABLE public.materials
  ADD CONSTRAINT materials_unit_cost_check
  CHECK (unit_cost_dzd >= 0);

UPDATE public.materials
SET unit_type = 'kg',
    unit_cost_dzd = cost_per_kg_dzd,
    unit_cost_configured = cost_per_kg_dzd > 0
WHERE unit_type = 'kg' AND unit_cost_dzd = 0;

CREATE OR REPLACE FUNCTION public.sync_legacy_material_unit_cost()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, public
AS $$
BEGIN
  IF NEW.unit_type = 'kg' THEN
    IF TG_OP = 'INSERT' THEN
      NEW.unit_cost_dzd := NEW.cost_per_kg_dzd;
      NEW.unit_cost_configured := NEW.cost_per_kg_dzd > 0;
    ELSIF NEW.cost_per_kg_dzd IS DISTINCT FROM OLD.cost_per_kg_dzd THEN
      NEW.unit_cost_dzd := NEW.cost_per_kg_dzd;
      NEW.unit_cost_configured := NEW.cost_per_kg_dzd > 0;
    END IF;
  END IF;
  RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION public.sync_legacy_material_unit_cost()
  FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS materials_sync_legacy_unit_cost ON public.materials;
CREATE TRIGGER materials_sync_legacy_unit_cost
  BEFORE INSERT OR UPDATE ON public.materials
  FOR EACH ROW EXECUTE FUNCTION public.sync_legacy_material_unit_cost();

CREATE TABLE IF NOT EXISTS public.material_price_history (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  material_id uuid REFERENCES public.materials(id) ON DELETE SET NULL,
  material_name_snapshot text NOT NULL,
  old_unit_type text,
  new_unit_type text NOT NULL,
  old_unit_cost_dzd integer,
  new_unit_cost_dzd integer NOT NULL,
  supplier_id uuid,
  changed_by uuid,
  changed_at timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE public.material_price_history ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.material_price_history FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.material_price_history TO authenticated;
DROP POLICY IF EXISTS material_price_history_owner_read ON public.material_price_history;
CREATE POLICY material_price_history_owner_read
  ON public.material_price_history FOR SELECT TO authenticated
  USING (public.is_owner());

CREATE OR REPLACE FUNCTION public.record_material_price_history()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
BEGIN
  IF TG_OP = 'INSERT' THEN
    INSERT INTO public.material_price_history (
      material_id, material_name_snapshot, old_unit_type, new_unit_type,
      old_unit_cost_dzd, new_unit_cost_dzd, supplier_id, changed_by
    ) VALUES (
      NEW.id, NEW.name, NULL, NEW.unit_type,
      NULL, NEW.unit_cost_dzd, NEW.supplier_id, auth.uid()
    );
  ELSIF NEW.unit_type IS DISTINCT FROM OLD.unit_type
     OR NEW.unit_cost_dzd IS DISTINCT FROM OLD.unit_cost_dzd
     OR NEW.supplier_id IS DISTINCT FROM OLD.supplier_id THEN
    INSERT INTO public.material_price_history (
      material_id, material_name_snapshot, old_unit_type, new_unit_type,
      old_unit_cost_dzd, new_unit_cost_dzd, supplier_id, changed_by
    ) VALUES (
      NEW.id, NEW.name, OLD.unit_type, NEW.unit_type,
      OLD.unit_cost_dzd, NEW.unit_cost_dzd, NEW.supplier_id, auth.uid()
    );
  END IF;
  RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION public.record_material_price_history()
  FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS materials_price_history ON public.materials;
CREATE TRIGGER materials_price_history
  AFTER INSERT OR UPDATE ON public.materials
  FOR EACH ROW EXECUTE FUNCTION public.record_material_price_history();

CREATE TABLE IF NOT EXISTS public.manufacturing_cost_settings (
  id boolean PRIMARY KEY DEFAULT true CHECK (id),
  labor_hour_rate_dzd integer NOT NULL DEFAULT 0 CHECK (labor_hour_rate_dzd >= 0),
  machine_hour_rate_dzd integer NOT NULL DEFAULT 0 CHECK (machine_hour_rate_dzd >= 0),
  assembly_hour_rate_dzd integer NOT NULL DEFAULT 0 CHECK (assembly_hour_rate_dzd >= 0),
  finishing_hour_rate_dzd integer NOT NULL DEFAULT 0 CHECK (finishing_hour_rate_dzd >= 0),
  waste_percent numeric(5,2) NOT NULL DEFAULT 0 CHECK (waste_percent BETWEEN 0 AND 100),
  tax_percent numeric(5,2) NOT NULL DEFAULT 0 CHECK (tax_percent BETWEEN 0 AND 30),
  margin_percent numeric(5,2) NOT NULL DEFAULT 0 CHECK (margin_percent BETWEEN 0 AND 90),
  minimum_quote_dzd integer NOT NULL DEFAULT 0 CHECK (minimum_quote_dzd >= 0),
  updated_at timestamptz NOT NULL DEFAULT now()
);

INSERT INTO public.manufacturing_cost_settings (id)
VALUES (true)
ON CONFLICT (id) DO NOTHING;

ALTER TABLE public.manufacturing_cost_settings ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.manufacturing_cost_settings FROM PUBLIC, anon, authenticated;
GRANT SELECT, INSERT, UPDATE ON public.manufacturing_cost_settings TO authenticated;
DROP POLICY IF EXISTS manufacturing_cost_settings_owner_all ON public.manufacturing_cost_settings;
CREATE POLICY manufacturing_cost_settings_owner_all
  ON public.manufacturing_cost_settings FOR ALL TO authenticated
  USING (public.is_owner())
  WITH CHECK (public.is_owner());

DROP TRIGGER IF EXISTS manufacturing_cost_settings_updated_at ON public.manufacturing_cost_settings;
CREATE TRIGGER manufacturing_cost_settings_updated_at
  BEFORE UPDATE ON public.manufacturing_cost_settings
  FOR EACH ROW EXECUTE FUNCTION public.update_updated_at();

CREATE OR REPLACE FUNCTION public.create_custom_quote_from_costing(
  p_request_id uuid,
  p_material_lines jsonb,
  p_labor_minutes numeric,
  p_machine_hours numeric,
  p_assembly_minutes numeric,
  p_finishing_minutes numeric,
  p_packaging_dzd integer,
  p_transport_dzd integer,
  p_extra_dzd integer,
  p_lead_days integer,
  p_valid_until date,
  p_terms text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_request public.custom_requests%ROWTYPE;
  v_settings public.manufacturing_cost_settings%ROWTYPE;
  v_material public.materials%ROWTYPE;
  v_line jsonb;
  v_material_id uuid;
  v_quantity numeric;
  v_quantity_with_waste numeric;
  v_line_cost bigint;
  v_material_total bigint := 0;
  v_labor_cost integer := 0;
  v_machine_cost integer := 0;
  v_assembly_cost integer := 0;
  v_finishing_cost integer := 0;
  v_cost_before_margin bigint;
  v_selling_before_tax bigint;
  v_profit bigint;
  v_tax bigint;
  v_final_price bigint;
  v_margin_percent numeric;
  v_tax_percent numeric;
  v_waste_percent numeric;
  v_version integer;
  v_quote public.custom_quotes%ROWTYPE;
  v_material_snapshot jsonb := '[]'::jsonb;
  v_pricing_snapshot jsonb;
  v_breakdown jsonb;
BEGIN
  IF NOT public.is_owner() THEN
    RAISE EXCEPTION 'ACCES_REFUSE';
  END IF;

  IF p_request_id IS NULL
     OR p_material_lines IS NULL
     OR jsonb_typeof(p_material_lines) <> 'array' THEN
    RAISE EXCEPTION 'LIGNES_MATIERES_INVALIDES';
  END IF;
  IF jsonb_array_length(p_material_lines) > 50 THEN
    RAISE EXCEPTION 'TROP_DE_LIGNES_MATIERES';
  END IF;

  IF coalesce(p_labor_minutes, 0) < 0 OR coalesce(p_labor_minutes, 0) > 100000
     OR coalesce(p_machine_hours, 0) < 0 OR coalesce(p_machine_hours, 0) > 10000
     OR coalesce(p_assembly_minutes, 0) < 0 OR coalesce(p_assembly_minutes, 0) > 100000
     OR coalesce(p_finishing_minutes, 0) < 0 OR coalesce(p_finishing_minutes, 0) > 100000
     OR coalesce(p_packaging_dzd, 0) < 0
     OR coalesce(p_transport_dzd, 0) < 0
     OR coalesce(p_extra_dzd, 0) < 0 THEN
    RAISE EXCEPTION 'COUTS_INVALIDES';
  END IF;

  IF p_valid_until IS NULL OR p_valid_until < current_date
     OR coalesce(p_lead_days, 0) < 0 OR coalesce(p_lead_days, 0) > 365 THEN
    RAISE EXCEPTION 'VALIDITE_INVALIDE';
  END IF;

  SELECT * INTO v_request
  FROM public.custom_requests
  WHERE id = p_request_id
  FOR UPDATE;

  IF NOT FOUND THEN RAISE EXCEPTION 'DEMANDE_INTROUVABLE'; END IF;
  IF v_request.status IN ('approved', 'closed', 'rejected')
     OR v_request.deletion_started_at IS NOT NULL THEN
    RAISE EXCEPTION 'DEMANDE_CLOTUREE';
  END IF;

  SELECT * INTO v_settings
  FROM public.manufacturing_cost_settings
  WHERE id = true
  FOR SHARE;

  IF NOT FOUND THEN RAISE EXCEPTION 'PARAMETRES_COUT_MANQUANTS'; END IF;

  v_waste_percent := v_settings.waste_percent;
  v_margin_percent := v_settings.margin_percent;
  v_tax_percent := v_settings.tax_percent;

  FOR v_line IN SELECT value FROM jsonb_array_elements(p_material_lines)
  LOOP
    BEGIN
      v_material_id := (v_line->>'material_id')::uuid;
      v_quantity := (v_line->>'quantity')::numeric;
    EXCEPTION WHEN OTHERS THEN
      RAISE EXCEPTION 'LIGNE_MATIERE_INVALIDE';
    END;

    IF v_material_id IS NULL OR v_quantity IS NULL
       OR v_quantity <= 0 OR v_quantity > 10000000 THEN
      RAISE EXCEPTION 'LIGNE_MATIERE_INVALIDE';
    END IF;

    SELECT * INTO v_material
    FROM public.materials
    WHERE id = v_material_id AND is_active
    FOR SHARE;

    IF NOT FOUND THEN RAISE EXCEPTION 'MATIERE_INTROUVABLE'; END IF;
    IF NOT v_material.unit_cost_configured OR v_material.unit_cost_dzd <= 0 THEN
      RAISE EXCEPTION 'PRIX_MATIERE_NON_CONFIGURE';
    END IF;

    v_quantity_with_waste := v_quantity * (1 + v_waste_percent / 100);
    v_line_cost := round(v_quantity_with_waste * v_material.unit_cost_dzd);
    v_material_total := v_material_total + v_line_cost;

    v_material_snapshot := v_material_snapshot || jsonb_build_array(
      jsonb_build_object(
        'material_id', v_material.id,
        'name', v_material.name,
        'unit_type', v_material.unit_type,
        'quantity', v_quantity,
        'waste_percent', v_waste_percent,
        'quantity_with_waste', v_quantity_with_waste,
        'unit_cost_dzd', v_material.unit_cost_dzd,
        'line_cost_dzd', v_line_cost,
        'supplier_id', v_material.supplier_id,
        'supplier_reference', v_material.supplier_reference
      )
    );
  END LOOP;

  IF coalesce(p_labor_minutes, 0) > 0 AND v_settings.labor_hour_rate_dzd <= 0 THEN
    RAISE EXCEPTION 'TAUX_MAIN_OEUVRE_NON_CONFIGURE';
  END IF;
  IF coalesce(p_machine_hours, 0) > 0 AND v_settings.machine_hour_rate_dzd <= 0 THEN
    RAISE EXCEPTION 'TAUX_MACHINE_NON_CONFIGURE';
  END IF;
  IF coalesce(p_assembly_minutes, 0) > 0 AND v_settings.assembly_hour_rate_dzd <= 0 THEN
    RAISE EXCEPTION 'TAUX_ASSEMBLAGE_NON_CONFIGURE';
  END IF;
  IF coalesce(p_finishing_minutes, 0) > 0 AND v_settings.finishing_hour_rate_dzd <= 0 THEN
    RAISE EXCEPTION 'TAUX_FINITION_NON_CONFIGURE';
  END IF;

  v_labor_cost := round(coalesce(p_labor_minutes, 0) / 60 * v_settings.labor_hour_rate_dzd);
  v_machine_cost := round(coalesce(p_machine_hours, 0) * v_settings.machine_hour_rate_dzd);
  v_assembly_cost := round(coalesce(p_assembly_minutes, 0) / 60 * v_settings.assembly_hour_rate_dzd);
  v_finishing_cost := round(coalesce(p_finishing_minutes, 0) / 60 * v_settings.finishing_hour_rate_dzd);

  v_cost_before_margin := v_material_total
    + v_labor_cost
    + v_machine_cost
    + v_assembly_cost
    + v_finishing_cost
    + coalesce(p_packaging_dzd, 0)
    + coalesce(p_transport_dzd, 0)
    + coalesce(p_extra_dzd, 0);

  IF v_cost_before_margin <= 0 THEN
    RAISE EXCEPTION 'COUT_TOTAL_NON_CONFIGURE';
  END IF;

  -- Gross margin is a share of the selling price, not a markup on cost.
  -- The minimum quote is a tax-inclusive floor, so lift the pre-tax price
  -- before calculating profit and tax rather than silently distorting either.
  v_selling_before_tax := greatest(
    round(v_cost_before_margin / (1 - v_margin_percent / 100)),
    ceil(v_settings.minimum_quote_dzd / (1 + v_tax_percent / 100))
  );
  v_profit := v_selling_before_tax - v_cost_before_margin;
  v_tax := round(v_selling_before_tax * v_tax_percent / 100);
  v_final_price := v_selling_before_tax + v_tax;

  IF v_final_price > 2147483647 THEN
    RAISE EXCEPTION 'PRIX_DEVIS_TROP_ELEVE';
  END IF;

  v_pricing_snapshot := jsonb_build_object(
    'engine', 'custom_costing_v1',
    'currency', 'DZD',
    'materials', v_material_snapshot,
    'rates', jsonb_build_object(
      'labor_hour_rate_dzd', v_settings.labor_hour_rate_dzd,
      'machine_hour_rate_dzd', v_settings.machine_hour_rate_dzd,
      'assembly_hour_rate_dzd', v_settings.assembly_hour_rate_dzd,
      'finishing_hour_rate_dzd', v_settings.finishing_hour_rate_dzd
    ),
    'time_inputs', jsonb_build_object(
      'labor_minutes', p_labor_minutes,
      'machine_hours', p_machine_hours,
      'assembly_minutes', p_assembly_minutes,
      'finishing_minutes', p_finishing_minutes
    ),
    'fixed_costs', jsonb_build_object(
      'packaging_dzd', p_packaging_dzd,
      'transport_dzd', p_transport_dzd,
      'extra_dzd', p_extra_dzd
    ),
    'waste_percent', v_waste_percent,
    'margin_percent', v_margin_percent,
    'tax_percent', v_tax_percent,
    'cost_before_margin_dzd', v_cost_before_margin,
    'profit_dzd', v_profit,
    'selling_before_tax_dzd', v_selling_before_tax,
    'tax_dzd', v_tax,
    'final_price_dzd', v_final_price,
    'calculated_at', now()
  );

  v_breakdown := jsonb_build_object(
    'lines', jsonb_build_array(
      jsonb_build_object('label', 'Fabrication', 'amountDzd', v_final_price)
    ),
    'unitPriceDzd', v_final_price,
    'quantity', 1,
    'subtotalDzd', v_final_price,
    'discountPercent', 0,
    'discountDzd', 0,
    'rushFeeDzd', 0,
    'totalDzd', v_final_price,
    'geometryVerified', false
  );

  SELECT coalesce(max(version), 0) + 1 INTO v_version
  FROM public.custom_quotes
  WHERE request_id = p_request_id;

  INSERT INTO public.custom_quotes (
    request_id, version, price_dzd, production_lead_days, valid_until,
    terms, source, pricing_snapshot, breakdown
  ) VALUES (
    p_request_id, v_version, v_final_price, p_lead_days, p_valid_until,
    nullif(btrim(coalesce(p_terms, '')), ''), 'manual', v_pricing_snapshot, v_breakdown
  )
  RETURNING * INTO v_quote;

  UPDATE public.custom_requests
  SET status = 'quoted'
  WHERE id = p_request_id;

  INSERT INTO public.custom_quote_events (request_id, quote_id, action, actor, note)
  VALUES (p_request_id, v_quote.id, 'sent', 'proprietaire', 'Devis calculé · version ' || v_version);

  RETURN jsonb_build_object(
    'quote_id', v_quote.id,
    'version', v_version,
    'price_dzd', v_final_price,
    'delivery_price_dzd', v_quote.delivery_price_dzd,
    'currency_code', v_quote.currency_code,
    'cost_snapshot', v_pricing_snapshot
  );
END;
$$;

REVOKE EXECUTE ON FUNCTION public.create_custom_quote_from_costing(
  uuid, jsonb, numeric, numeric, numeric, numeric, integer, integer, integer, integer, date, text
) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.create_custom_quote_from_costing(
  uuid, jsonb, numeric, numeric, numeric, numeric, integer, integer, integer, integer, date, text
) TO authenticated;

NOTIFY pgrst, 'reload schema';


-- Keep the existing product-cost screen limited to configured per-kilogram
-- materials. A piece/meter/m² material must never be treated as a kg price.
CREATE OR REPLACE FUNCTION public.product_cost_estimate(p_product_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_cost public.product_costs%ROWTYPE;
  v_material_cost numeric := 0;
  v_cost_per_kg integer;
  v_machine numeric := 0;
  v_labour numeric := 0;
  v_failures numeric := 0;
  v_packaging numeric := 0;
  v_returns numeric := 0;
  v_total numeric;
  v_price integer;
  v_margin numeric;
  v_material_missing boolean := false;
BEGIN
  IF NOT public.is_owner() THEN
    RAISE EXCEPTION 'ACCES_REFUSE';
  END IF;

  SELECT * INTO v_cost
  FROM public.product_costs
  WHERE product_id = p_product_id;

  SELECT price_dzd INTO v_price
  FROM public.products
  WHERE id = p_product_id;

  IF v_price IS NULL THEN
    RAISE EXCEPTION 'PRODUIT_INTROUVABLE';
  END IF;

  IF v_cost.product_id IS NULL OR v_cost.material_id IS NULL THEN
    v_material_missing := true;
  ELSE
    SELECT cost_per_kg_dzd INTO v_cost_per_kg
    FROM public.materials
    WHERE id = v_cost.material_id
      AND is_active
      AND unit_type = 'kg'
      AND unit_cost_configured;

    IF NOT FOUND THEN
      v_material_missing := true;
    ELSE
      v_material_cost := coalesce(v_cost_per_kg, 0) * v_cost.print_grams / 1000.0;
    END IF;
  END IF;

  IF v_cost.product_id IS NOT NULL THEN
    v_machine := v_cost.print_hours * v_cost.machine_hour_rate_dzd;
    v_labour := v_cost.labor_minutes / 60.0 * v_cost.labor_hour_rate_dzd;
    v_failures := (v_material_cost + v_machine + v_labour) * v_cost.failure_rate_pct / 100.0;
    v_packaging := v_cost.packaging_dzd;
    v_returns := v_cost.return_reserve_dzd;
  END IF;

  v_total := v_material_cost + v_machine + v_labour + v_failures + v_packaging + v_returns;
  v_margin := v_price - v_total;

  RETURN jsonb_build_object(
    'is_estimate', true,
    'material_manquante', v_material_missing,
    'material_dzd', round(v_material_cost),
    'machine_dzd', round(v_machine),
    'labour_dzd', round(v_labour),
    'failures_dzd', round(v_failures),
    'packaging_dzd', round(v_packaging),
    'return_reserve_dzd', round(v_returns),
    'total_cost_dzd', round(v_total),
    'price_dzd', v_price,
    'margin_dzd', round(v_margin),
    'margin_pct', CASE WHEN v_price > 0 THEN round(v_margin / v_price * 100, 1) ELSE NULL END,
    'markup_pct', CASE WHEN v_total > 0 THEN round(v_margin / v_total * 100, 1) ELSE NULL END
  );
END;
$$;

REVOKE EXECUTE ON FUNCTION public.product_cost_estimate(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.product_cost_estimate(uuid) TO authenticated;



-- ============================================================================
-- SOURCE: 20261118140000_029_visual_identity_studio.sql
-- ============================================================================

/*
  LUNDER Visual Identity Studio
  Extends the existing store_settings system; no competing settings table.
*/
CREATE TABLE IF NOT EXISTS public.store_design_versions (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  config jsonb NOT NULL CHECK (jsonb_typeof(config) = 'object'),
  published_by uuid NOT NULL REFERENCES public.profiles(id),
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_store_design_versions_created
  ON public.store_design_versions(created_at DESC);
ALTER TABLE public.store_design_versions ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.store_design_versions FROM PUBLIC, anon, authenticated;
GRANT SELECT, INSERT ON public.store_design_versions TO authenticated;
REVOKE ALL ON SEQUENCE public.store_design_versions_id_seq FROM PUBLIC, anon, authenticated;
GRANT USAGE ON SEQUENCE public.store_design_versions_id_seq TO authenticated;
DROP POLICY IF EXISTS owner_read_store_design_versions ON public.store_design_versions;
CREATE POLICY owner_read_store_design_versions
  ON public.store_design_versions FOR SELECT TO authenticated
  USING (public.is_owner());
DROP POLICY IF EXISTS owner_insert_store_design_versions ON public.store_design_versions;
CREATE POLICY owner_insert_store_design_versions
  ON public.store_design_versions FOR INSERT TO authenticated
  WITH CHECK (public.is_owner());

CREATE OR REPLACE FUNCTION public.publish_visual_identity(p_config jsonb)
RETURNS bigint LANGUAGE plpgsql SECURITY INVOKER SET search_path = '' AS $$
DECLARE v_version_id bigint;
BEGIN
  IF NOT public.is_owner() THEN RAISE EXCEPTION 'ACCES_REFUSE'; END IF;
  IF p_config IS NULL OR jsonb_typeof(p_config) <> 'object'
     OR octet_length(p_config::text) > 50000 OR p_config->>'version' <> '1'
     OR jsonb_typeof(p_config->'colors') IS DISTINCT FROM 'object'
     OR EXISTS (
       SELECT 1 FROM jsonb_each_text(p_config->'colors') AS c(key, value)
       WHERE c.key IN ('primary','secondary','accent','background','surface','surfaceAlt','text','muted','border','header','footer','buttonText','glow','gradientStart','gradientEnd')
         AND c.value !~ '^#[0-9A-Fa-f]{6}$'
     ) THEN
    RAISE EXCEPTION 'CONFIGURATION_VISUELLE_INVALIDE';
  END IF;
  INSERT INTO public.store_settings(key, value, is_public)
  VALUES ('visual_identity', p_config::text, true)
  ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value, is_public = true;
  INSERT INTO public.store_design_versions(config, published_by)
  VALUES (p_config, auth.uid()) RETURNING id INTO v_version_id;
  RETURN v_version_id;
END;
$$;

CREATE OR REPLACE FUNCTION public.restore_visual_identity_version(p_version_id bigint)
RETURNS bigint LANGUAGE plpgsql SECURITY INVOKER SET search_path = '' AS $$
DECLARE v_config jsonb;
BEGIN
  IF NOT public.is_owner() THEN RAISE EXCEPTION 'ACCES_REFUSE'; END IF;
  SELECT config INTO v_config FROM public.store_design_versions WHERE id = p_version_id;
  IF v_config IS NULL THEN RAISE EXCEPTION 'VERSION_INTROUVABLE'; END IF;
  RETURN public.publish_visual_identity(v_config);
END;
$$;
REVOKE ALL ON FUNCTION public.publish_visual_identity(jsonb) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.restore_visual_identity_version(bigint) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.publish_visual_identity(jsonb) TO authenticated;
GRANT EXECUTE ON FUNCTION public.restore_visual_identity_version(bigint) TO authenticated;



-- ============================================================================
-- SOURCE: 20261118150000_030_customer_account_ownership.sql
-- ============================================================================

-- 030 — Secure customer account ownership for orders and custom requests.
-- Existing guest flows remain unchanged: only authenticated identities are linked.
-- This migration is committed to the feature branch only; it is not applied to production.

ALTER TABLE public.orders
  ADD COLUMN IF NOT EXISTS customer_user_id uuid REFERENCES auth.users(id) ON DELETE SET NULL;

ALTER TABLE public.custom_requests
  ADD COLUMN IF NOT EXISTS customer_user_id uuid REFERENCES auth.users(id) ON DELETE SET NULL;

CREATE INDEX IF NOT EXISTS idx_orders_customer_user_created
  ON public.orders(customer_user_id, created_at DESC)
  WHERE customer_user_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_custom_requests_customer_user_created
  ON public.custom_requests(customer_user_id, created_at DESC)
  WHERE customer_user_id IS NOT NULL;

-- The identity is taken from the verified Supabase JWT, never from client payload.
CREATE OR REPLACE FUNCTION public.link_customer_to_custom_request()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = public
AS $$
BEGIN
  NEW.customer_user_id := auth.uid();
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS custom_requests_link_customer ON public.custom_requests;
CREATE TRIGGER custom_requests_link_customer
  BEFORE INSERT ON public.custom_requests
  FOR EACH ROW EXECUTE FUNCTION public.link_customer_to_custom_request();

-- Normal checkout orders belong to the currently authenticated customer.
-- A quote-generated order inherits the owner of the originating request, even
-- when the customer approves the quote later from a guest tracking link.
CREATE OR REPLACE FUNCTION public.link_customer_to_order()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = public
AS $$
DECLARE
  v_quote_id uuid;
  v_customer_user_id uuid;
BEGIN
  -- Only the trusted custom-order flow may inherit a request owner.
  -- Store checkout accepts a client idempotency key, so its text prefix alone
  -- must never be treated as proof that an order came from a custom quote.
  IF NEW.source = 'custom' AND NEW.idempotency_key LIKE 'devis:%' THEN
    BEGIN
      v_quote_id := substring(NEW.idempotency_key FROM 7)::uuid;
    EXCEPTION WHEN invalid_text_representation THEN
      v_quote_id := NULL;
    END;

    IF v_quote_id IS NOT NULL THEN
      SELECT r.customer_user_id
        INTO v_customer_user_id
      FROM public.custom_quotes q
      JOIN public.custom_requests r ON r.id = q.request_id
      WHERE q.id = v_quote_id;
      NEW.customer_user_id := v_customer_user_id;
      RETURN NEW;
    END IF;
  END IF;

  NEW.customer_user_id := auth.uid();
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS orders_link_customer ON public.orders;
CREATE TRIGGER orders_link_customer
  BEFORE INSERT ON public.orders
  FOR EACH ROW EXECUTE FUNCTION public.link_customer_to_order();

-- Customer-facing account reads must use allowlisted views, not the private
-- business tables. Row-level policies alone would expose every column in a row,
-- including manufacturing cost snapshots and internal production metadata.
DROP POLICY IF EXISTS customer_read_own_orders ON public.orders;
DROP POLICY IF EXISTS customer_read_own_order_items ON public.order_items;
DROP POLICY IF EXISTS customer_read_own_order_history ON public.order_status_history;
DROP POLICY IF EXISTS customer_read_own_custom_requests ON public.custom_requests;
DROP POLICY IF EXISTS customer_read_own_custom_quotes ON public.custom_quotes;
DROP POLICY IF EXISTS customer_read_own_custom_quote_events ON public.custom_quote_events;

CREATE OR REPLACE VIEW public.customer_account_orders
WITH (security_barrier = true)
AS
SELECT
  o.id,
  o.order_number,
  o.status,
  o.created_at,
  o.total_dzd,
  o.delivery_method,
  o.delivery_eta_min,
  o.delivery_eta_max,
  o.wilaya_name,
  o.commune_name,
  coalesce((
    SELECT jsonb_agg(jsonb_build_object(
      'product_name', i.product_name,
      'variant_label', i.variant_label,
      'quantity', i.quantity,
      'unit_price_dzd', i.unit_price_dzd,
      'line_total_dzd', i.line_total_dzd
    ) ORDER BY i.created_at)
    FROM public.order_items i
    WHERE i.order_id = o.id
  ), '[]'::jsonb) AS items
FROM public.orders o
WHERE o.customer_user_id = (SELECT auth.uid());

CREATE OR REPLACE VIEW public.customer_account_requests
WITH (security_barrier = true)
AS
SELECT
  r.id,
  r.request_number,
  r.tracking_token,
  r.title,
  r.status,
  r.created_at,
  r.estimate_price_dzd,
  r.estimate_public_breakdown,
  r.estimate_accepted_at,
  r.rejection_reason
FROM public.custom_requests r
WHERE r.customer_user_id = (SELECT auth.uid());

CREATE OR REPLACE VIEW public.customer_account_quotes
WITH (security_barrier = true)
AS
SELECT
  q.request_id,
  q.version,
  q.status,
  q.price_dzd,
  q.currency_code,
  q.production_lead_days,
  q.valid_until,
  q.terms,
  q.created_at,
  q.accepted_at,
  q.delivery_price_dzd,
  public.customer_quote_breakdown(q.breakdown) AS public_breakdown
FROM public.custom_quotes q
WHERE EXISTS (
  SELECT 1
  FROM public.custom_requests r
  WHERE r.id = q.request_id
    AND r.customer_user_id = (SELECT auth.uid())
);

REVOKE ALL ON public.customer_account_orders,
  public.customer_account_requests,
  public.customer_account_quotes
  FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.customer_account_orders,
  public.customer_account_requests,
  public.customer_account_quotes
  TO authenticated;

NOTIFY pgrst, 'reload schema';

