-- TEMPORARY BUILD PART 02/04 - original migrations concatenated in timestamp order



-- ============================================================================
-- SOURCE: 20261113150000_009_order_archive_source_and_security.sql
-- ============================================================================

-- ═══════════════════════════════════════════════════════════════════════════
-- 009 — ARCHIVAGE DES COMMANDES, SOURCE ET DURCISSEMENT SÉCURITÉ
--
-- Remplace la suppression physique de 008 par un archivage réversible :
-- les informations, articles, historique de statut et pistes d'audit sont
-- conservés. Les commandes archivées sont masquées de la liste normale mais
-- restent consultables par la propriétaire.
-- ═══════════════════════════════════════════════════════════════════════════

-- ─── COLONNES D'ARCHIVAGE ET DE SOURCE ─────────────────────────────────────

ALTER TABLE orders
  ADD COLUMN IF NOT EXISTS source text NOT NULL DEFAULT 'store'
    CHECK (source IN ('store', 'custom')),
  ADD COLUMN IF NOT EXISTS archived_at timestamptz,
  ADD COLUMN IF NOT EXISTS archived_by uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS archive_reason text;

CREATE INDEX IF NOT EXISTS idx_orders_archived ON orders (archived_at) WHERE archived_at IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_orders_source ON orders (source);

-- ─── APPROVE_CUSTOM_QUOTE : SOURCE = custom ────────────────────────────────

CREATE OR REPLACE FUNCTION public.approve_custom_quote(p_quote_token uuid, p_delivery jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_quote custom_quotes%ROWTYPE;
  v_request custom_requests%ROWTYPE;
  v_existing orders%ROWTYPE;
  v_wilaya smallint;
  v_commune uuid;
  v_method text := coalesce(p_delivery->>'delivery_method', '');
  v_address text := nullif(btrim(coalesce(p_delivery->>'address', '')), '');
  v_pickup uuid := nullif(p_delivery->>'pickup_point_id', '')::uuid;
  v_pickup_name text;
  v_wilaya_name text;
  v_commune_name text;
  v_rate record;
  v_order_id uuid;
  v_number text;
  v_token uuid;
BEGIN
  IF p_quote_token IS NULL THEN
    RAISE EXCEPTION 'DEVIS_INTROUVABLE';
  END IF;

  SELECT * INTO v_quote FROM custom_quotes WHERE public_token = p_quote_token FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'DEVIS_INTROUVABLE';
  END IF;

  SELECT * INTO v_request FROM custom_requests WHERE id = v_quote.request_id FOR UPDATE;

  IF v_quote.order_id IS NOT NULL THEN
    SELECT * INTO v_existing FROM orders WHERE id = v_quote.order_id;
    RETURN jsonb_build_object(
      'order_number', v_existing.order_number,
      'tracking_token', v_existing.tracking_token,
      'total_dzd', v_existing.total_dzd,
      'already_exists', true
    );
  END IF;

  IF v_quote.status <> 'sent' THEN
    RAISE EXCEPTION 'DEVIS_NON_APPROUVABLE';
  END IF;
  IF v_quote.valid_until < current_date THEN
    RAISE EXCEPTION 'DEVIS_EXPIRE';
  END IF;

  v_wilaya := nullif(p_delivery->>'wilaya_code', '')::smallint;
  SELECT name_fr INTO v_wilaya_name FROM wilayas WHERE code = v_wilaya AND is_active;
  IF v_wilaya_name IS NULL THEN
    RAISE EXCEPTION 'WILAYA_INVALIDE';
  END IF;

  v_commune := nullif(p_delivery->>'commune_id', '')::uuid;
  SELECT name_fr INTO v_commune_name
  FROM communes WHERE id = v_commune AND wilaya_code = v_wilaya AND is_active;
  IF v_commune_name IS NULL THEN
    RAISE EXCEPTION 'COMMUNE_INVALIDE';
  END IF;

  IF v_method NOT IN ('domicile', 'stopdesk') THEN
    RAISE EXCEPTION 'METHODE_LIVRAISON_INVALIDE';
  END IF;

  IF v_method = 'stopdesk' THEN
    SELECT name INTO v_pickup_name
    FROM pickup_points WHERE id = v_pickup AND wilaya_code = v_wilaya AND is_active;
    IF v_pickup_name IS NULL THEN
      RAISE EXCEPTION 'POINT_RELAIS_INVALIDE';
    END IF;
  ELSIF v_address IS NULL THEN
    RAISE EXCEPTION 'ADRESSE_REQUISE';
  END IF;

  SELECT * INTO v_rate FROM quote_delivery(v_wilaya, v_commune, v_method);

  v_number := public.next_order_number();

  INSERT INTO orders (
    order_number, idempotency_key, customer_name, phone, email,
    wilaya_code, commune_id, wilaya_name, commune_name,
    delivery_method, delivery_carrier, delivery_eta_min, delivery_eta_max,
    address, pickup_point_id, pickup_point_snapshot, note,
    subtotal_dzd, delivery_dzd, total_dzd, source
  ) VALUES (
    v_number, 'devis:' || v_quote.id, v_request.customer_name, v_request.phone, v_request.email,
    v_wilaya, v_commune, v_wilaya_name, v_commune_name,
    v_method, v_rate.carrier, v_rate.estimated_days_min, v_rate.estimated_days_max,
    v_address, v_pickup, v_pickup_name,
    'Devis sur mesure ' || v_request.request_number || ' (version ' || v_quote.version || ')',
    v_quote.price_dzd, v_rate.price_dzd, v_quote.price_dzd + v_rate.price_dzd, 'custom'
  )
  RETURNING id, tracking_token INTO v_order_id, v_token;

  INSERT INTO order_items (
    order_id, product_id, variant_id, product_name, variant_label, sku,
    unit_price_dzd, quantity, line_total_dzd
  ) VALUES (
    v_order_id, NULL, NULL,
    v_request.title,
    'Fabrication sur mesure · quantité ' || v_request.quantity,
    v_request.request_number,
    v_quote.price_dzd, 1, v_quote.price_dzd
  );

  INSERT INTO order_status_history (order_id, from_status, to_status, actor)
  VALUES (v_order_id, NULL, 'pending', 'client');

  UPDATE custom_quotes
  SET status = 'approved', decided_at = now(), order_id = v_order_id
  WHERE id = v_quote.id;

  UPDATE custom_requests SET status = 'approved' WHERE id = v_request.id;

  INSERT INTO custom_quote_events (request_id, quote_id, action, actor, note)
  VALUES (v_request.id, v_quote.id, 'approved', 'client', v_number);

  RETURN jsonb_build_object(
    'order_number', v_number,
    'tracking_token', v_token,
    'total_dzd', v_quote.price_dzd + v_rate.price_dzd,
    'already_exists', false
  );
END;
$$;

REVOKE EXECUTE ON FUNCTION public.approve_custom_quote(uuid, jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.approve_custom_quote(uuid, jsonb) TO anon, authenticated;

-- ─── QUOTE_CUSTOM_MANUFACTURING : OWNER ONLY ───────────────────────────────

CREATE OR REPLACE FUNCTION public.quote_custom_manufacturing(
  p_request_id uuid,
  p_material_name text,
  p_grams numeric,
  p_print_hours numeric,
  p_options jsonb DEFAULT '{}'::jsonb,
  p_rush boolean DEFAULT false
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_request custom_requests%ROWTYPE;
  v_rules manufacturing_pricing%ROWTYPE;
  v_material manufacturing_materials%ROWTYPE;
  v_quantity integer;
  v_grams numeric;
  v_hours numeric;
  v_hourly integer;
  v_material_cost integer;
  v_print_cost integer;
  v_labor integer := 0;
  v_lines jsonb := '[]'::jsonb;
  v_production integer;
  v_complexity integer;
  v_margin integer;
  v_unit integer;
  v_subtotal integer;
  v_discount_pct integer := 0;
  v_discount integer;
  v_rush integer := 0;
  v_total integer;
  v_version integer;
  v_quote custom_quotes%ROWTYPE;
  v_tier jsonb;
BEGIN
  IF NOT public.is_owner() THEN
    RAISE EXCEPTION 'ACCES_REFUSE';
  END IF;

  IF p_request_id IS NULL THEN
    RAISE EXCEPTION 'DEMANDE_INTROUVABLE';
  END IF;

  SELECT * INTO v_request FROM custom_requests WHERE id = p_request_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'DEMANDE_INTROUVABLE';
  END IF;
  IF v_request.status IN ('approved', 'closed') THEN
    RAISE EXCEPTION 'DEMANDE_CLOTUREE';
  END IF;

  IF EXISTS (
    SELECT 1 FROM custom_quotes
    WHERE request_id = p_request_id AND status = 'approved'
  ) THEN
    RAISE EXCEPTION 'DEMANDE_CLOTUREE';
  END IF;

  SELECT * INTO v_rules FROM manufacturing_pricing WHERE id;
  SELECT * INTO v_material
  FROM manufacturing_materials
  WHERE lower(btrim(name)) = lower(btrim(coalesce(p_material_name, ''))) AND is_available;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'MATIERE_INDISPONIBLE';
  END IF;
  IF p_grams IS NULL OR p_grams <= 0 OR p_grams > 100000 THEN
    RAISE EXCEPTION 'POIDS_INVALIDE';
  END IF;
  IF p_print_hours IS NULL OR p_print_hours <= 0 OR p_print_hours > 2000 THEN
    RAISE EXCEPTION 'TEMPS_INVALIDE';
  END IF;

  v_quantity := coalesce(v_request.quantity, 1);
  IF v_quantity < 1 OR v_quantity > 100 THEN
    RAISE EXCEPTION 'QUANTITE_INVALIDE';
  END IF;

  v_grams := p_grams * (1 + v_rules.waste_percent::numeric / 100);
  v_material_cost := round(v_grams * v_material.price_per_gram_dzd * v_material.multiplier);

  v_hourly := v_rules.price_per_hour_dzd
            + v_rules.machine_hourly_cost_dzd
            + v_rules.electricity_per_hour_dzd;
  v_print_cost := greatest(round(p_print_hours * v_hourly), v_rules.minimum_print_charge_dzd);

  IF coalesce((p_options->>'design')::boolean, false) THEN
    v_labor := v_labor + v_rules.design_preparation_fee_dzd;
    v_lines := v_lines || jsonb_build_object('label', 'Préparation du design', 'amountDzd', v_rules.design_preparation_fee_dzd);
  END IF;
  IF coalesce((p_options->>'modeling')::boolean, false) THEN
    v_labor := v_labor + v_rules.modeling_fee_dzd;
    v_lines := v_lines || jsonb_build_object('label', 'Modélisation / modification', 'amountDzd', v_rules.modeling_fee_dzd);
  END IF;
  IF coalesce((p_options->>'assembly')::boolean, false) THEN
    v_labor := v_labor + v_rules.assembly_fee_dzd;
    v_lines := v_lines || jsonb_build_object('label', 'Assemblage', 'amountDzd', v_rules.assembly_fee_dzd);
  END IF;
  IF coalesce((p_options->>'finishing')::boolean, false) THEN
    v_labor := v_labor + v_rules.finishing_fee_dzd;
    v_lines := v_lines || jsonb_build_object('label', 'Ponçage et finition', 'amountDzd', v_rules.finishing_fee_dzd);
  END IF;
  IF coalesce((p_options->>'painting')::boolean, false) THEN
    v_labor := v_labor + v_rules.painting_fee_dzd;
    v_lines := v_lines || jsonb_build_object('label', 'Peinture', 'amountDzd', v_rules.painting_fee_dzd);
  END IF;

  v_production := v_material_cost + v_print_cost + v_labor + v_rules.extra_production_dzd;
  v_complexity := v_rules.complexity_fee_dzd;
  v_margin := round((v_production + v_complexity) * v_rules.margin_percent::numeric / 100);
  v_unit := greatest(v_production + v_complexity + v_margin, v_rules.minimum_order_dzd);

  v_subtotal := v_unit * v_quantity;

  SELECT coalesce(max((tier->>'percent')::integer), 0) INTO v_discount_pct
  FROM jsonb_array_elements(v_rules.quantity_discounts) AS tier
  WHERE (tier->>'minQuantity')::integer <= v_quantity
    AND (tier->>'percent')::integer > 0;

  v_discount := round(v_subtotal * v_discount_pct::numeric / 100);
  IF coalesce(p_rush, false) THEN
    v_rush := round((v_subtotal - v_discount) * v_rules.rush_fee_percent::numeric / 100);
  END IF;
  v_total := greatest(v_subtotal - v_discount + v_rush, v_rules.minimum_order_dzd);

  v_lines := jsonb_build_array(
    jsonb_build_object('label', 'Matière', 'amountDzd', v_material_cost,
      'detail', v_material.name || ' · ' || round(v_grams) || ' g × ' || v_material.price_per_gram_dzd || ' DA/g'),
    jsonb_build_object('label', 'Impression', 'amountDzd', v_print_cost,
      'detail', round(p_print_hours * 10) / 10 || ' h × ' || v_hourly || ' DA/h')
  ) || v_lines;

  IF v_complexity > 0 THEN
    v_lines := v_lines || jsonb_build_object('label', 'Complexité', 'amountDzd', v_complexity);
  END IF;
  IF v_margin > 0 THEN
    v_lines := v_lines || jsonb_build_object('label', 'Marge studio', 'amountDzd', v_margin,
      'detail', v_rules.margin_percent || ' %');
  END IF;

  UPDATE custom_quotes SET status = 'expired', decided_at = now()
  WHERE request_id = p_request_id AND status = 'sent';

  SELECT coalesce(max(version), 0) + 1 INTO v_version
  FROM custom_quotes WHERE request_id = p_request_id;

  INSERT INTO custom_quotes (
    request_id, version, price_dzd, production_lead_days, valid_until, terms,
    source, pricing_snapshot, breakdown
  ) VALUES (
    p_request_id, v_version, v_total, NULL,
    current_date + v_rules.validity_days,
    'Estimation automatique : le studio confirme le prix après réception du fichier définitif.',
    'automatic',
    jsonb_build_object(
      'rules', to_jsonb(v_rules) - 'id',
      'material', to_jsonb(v_material) - 'id',
      'grams', p_grams, 'printHours', p_print_hours,
      'options', coalesce(p_options, '{}'::jsonb), 'rush', coalesce(p_rush, false),
      'calculatedAt', now()
    ),
    jsonb_build_object(
      'lines', v_lines,
      'unitPriceDzd', v_unit, 'quantity', v_quantity,
      'subtotalDzd', v_subtotal,
      'discountPercent', v_discount_pct, 'discountDzd', v_discount,
      'rushFeeDzd', v_rush, 'totalDzd', v_total,
      'geometryVerified', false
    )
  ) RETURNING * INTO v_quote;

  UPDATE custom_requests SET status = 'quoted' WHERE id = p_request_id;

  INSERT INTO custom_quote_events (request_id, quote_id, action, actor, note)
  VALUES (p_request_id, v_quote.id, 'created', 'moteur',
          'Tarification automatique v' || v_version);

  RETURN jsonb_build_object(
    'version', v_version,
    'public_token', v_quote.public_token,
    'valid_until', v_quote.valid_until,
    'price_dzd', v_quote.price_dzd,
    'breakdown', v_quote.breakdown
  );
END;
$$;

REVOKE EXECUTE ON FUNCTION public.quote_custom_manufacturing(uuid, text, numeric, numeric, jsonb, boolean) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.quote_custom_manufacturing(uuid, text, numeric, numeric, jsonb, boolean) TO authenticated;

-- ─── SOFT DELETE ───────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION public.delete_order(p_order_id uuid, p_reason text DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_order orders%ROWTYPE;
BEGIN
  IF NOT public.is_owner() THEN
    RAISE EXCEPTION 'ACCES_REFUSE';
  END IF;

  SELECT * INTO v_order FROM orders WHERE id = p_order_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'COMMANDE_INTROUVABLE';
  END IF;

  IF v_order.status IN ('delivered', 'shipped') THEN
    RAISE EXCEPTION 'COMMANDE_NON_SUPPRIMABLE';
  END IF;

  IF v_order.archived_at IS NOT NULL THEN
    RETURN jsonb_build_object('archived', true, 'already_archived', true, 'order_number', v_order.order_number);
  END IF;

  UPDATE orders
  SET archived_at = now(),
      archived_by = auth.uid(),
      archive_reason = nullif(btrim(coalesce(p_reason, '')), '')
  WHERE id = p_order_id;

  PERFORM public.log_owner_event(
    'order.deleted',
    jsonb_build_object(
      'order_id', v_order.id,
      'order_number', v_order.order_number,
      'status', v_order.status,
      'total_dzd', v_order.total_dzd,
      'archived', true
    )
  );

  RETURN jsonb_build_object('archived', true, 'already_archived', false, 'order_number', v_order.order_number);
END;
$$;

REVOKE EXECUTE ON FUNCTION public.delete_order(uuid, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.delete_order(uuid, text) TO authenticated;

-- ─── GET_CUSTOM_REQUEST_BY_TOKEN : INCLUDE BREAKDOWN ───────────────────────

CREATE OR REPLACE FUNCTION public.get_custom_request_by_token(p_token uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_result jsonb;
BEGIN
  IF p_token IS NULL THEN
    RAISE EXCEPTION 'DEMANDE_INTROUVABLE';
  END IF;

  UPDATE custom_quotes
  SET status = 'expired', decided_at = now()
  WHERE request_id = (SELECT id FROM custom_requests WHERE tracking_token = p_token)
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
        'kind', f.kind, 'original_name', f.original_name, 'mime_type', f.mime_type
      ) ORDER BY f.created_at)
      FROM custom_request_files f WHERE f.request_id = r.id
    ), '[]'::jsonb),
    'quotes', coalesce((
      SELECT jsonb_agg(jsonb_build_object(
        'version', q.version,
        'public_token', q.public_token,
        'price_dzd', q.price_dzd,
        'production_lead_days', q.production_lead_days,
        'valid_until', q.valid_until,
        'terms', q.terms,
        'status', q.status,
        'source', q.source,
        'breakdown', q.breakdown,
        'created_at', q.created_at
      ) ORDER BY q.version DESC)
      FROM custom_quotes q WHERE q.request_id = r.id
    ), '[]'::jsonb),
    'order_number', (
      SELECT o.order_number
      FROM custom_quotes q JOIN orders o ON o.id = q.order_id
      WHERE q.request_id = r.id AND q.order_id IS NOT NULL
      LIMIT 1
    )
  )
  INTO v_result
  FROM custom_requests r
  WHERE r.tracking_token = p_token;

  IF v_result IS NULL THEN
    RAISE EXCEPTION 'DEMANDE_INTROUVABLE';
  END IF;

  RETURN v_result;
END;
$$;

REVOKE EXECUTE ON FUNCTION public.get_custom_request_by_token(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_custom_request_by_token(uuid) TO anon, authenticated;

-- ─── DECIDE_CUSTOM_QUOTE : ALREADY EXISTS IN 008, REDEFINE FOR CONSISTENCY ─

CREATE OR REPLACE FUNCTION public.decide_custom_quote(
  p_quote_token uuid,
  p_decision text,
  p_delivery jsonb DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_quote custom_quotes%ROWTYPE;
  v_request custom_requests%ROWTYPE;
BEGIN
  IF p_decision NOT IN ('accept', 'cancel') THEN
    RAISE EXCEPTION 'DECISION_INVALIDE';
  END IF;

  SELECT * INTO v_quote FROM custom_quotes WHERE public_token = p_quote_token FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'DEVIS_INTROUVABLE';
  END IF;
  SELECT * INTO v_request FROM custom_requests WHERE id = v_quote.request_id FOR UPDATE;

  IF p_decision = 'cancel' THEN
    IF v_quote.order_id IS NOT NULL THEN
      RAISE EXCEPTION 'COMMANDE_DEJA_CREEE';
    END IF;
    IF v_quote.status <> 'sent' THEN
      RETURN jsonb_build_object('status', v_quote.status, 'already_decided', true);
    END IF;

    UPDATE custom_quotes SET status = 'rejected', decided_at = now() WHERE id = v_quote.id;
    UPDATE custom_requests SET status = 'rejected' WHERE id = v_request.id;
    INSERT INTO custom_quote_events (request_id, quote_id, action, actor, note)
    VALUES (v_request.id, v_quote.id, 'status_changed', 'client', 'Devis refusé par le client');

    RETURN jsonb_build_object('status', 'rejected', 'already_decided', false);
  END IF;

  RETURN public.approve_custom_quote(p_quote_token, coalesce(p_delivery, '{}'::jsonb));
END;
$$;

REVOKE EXECUTE ON FUNCTION public.decide_custom_quote(uuid, text, jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.decide_custom_quote(uuid, text, jsonb) TO anon, authenticated;



-- ============================================================================
-- SOURCE: 20261113160000_010_pricing_security_and_public_estimate.sql
-- ============================================================================

-- ═══════════════════════════════════════════════════════════════════════════
-- 010 — SÉCURITÉ DE LA TARIFICATION ET ESTIMATION PUBLIQUE
--
-- Les tables manufacturing_materials et manufacturing_pricing contiennent des
-- coûts internes, marges et règles de calcul. Elles ne sont désormais
-- accessibles qu'à la propriétaire. Le public dispose d'une vue sûre (noms et
-- couleurs uniquement) et d'une fonction d'estimation qui renvoie un prix et une
-- ventilation sans exposer les tarifs bruts.
-- ═══════════════════════════════════════════════════════════════════════════

-- ─── RETIRER L'ACCÈS PUBLIC ────────────────────────────────────────────────

DROP POLICY IF EXISTS "Lecture publique des matières disponibles" ON manufacturing_materials;
DROP POLICY IF EXISTS "Lecture publique de la tarification" ON manufacturing_pricing;

-- La propriétaire conserve l'accès complet via la policy FOR ALL existante ;
-- on ajoute une policy de lecture explicite pour la clarté.
DROP POLICY IF EXISTS "Propriétaire lit les matières" ON manufacturing_materials;
CREATE POLICY "Propriétaire lit les matières" ON manufacturing_materials
  FOR SELECT USING (public.is_owner());

DROP POLICY IF EXISTS "Propriétaire lit la tarification" ON manufacturing_pricing;
CREATE POLICY "Propriétaire lit la tarification" ON manufacturing_pricing
  FOR SELECT USING (public.is_owner());

REVOKE SELECT ON manufacturing_materials, manufacturing_pricing FROM anon;

-- ─── VUE PUBLIQUE SÛRE (matières uniquement) ──────────────────────────────

CREATE OR REPLACE VIEW public.manufacturing_materials_public AS
SELECT name, colors, is_available, sort_order
FROM manufacturing_materials
WHERE is_available = true;

GRANT SELECT ON public.manufacturing_materials_public TO anon, authenticated;

-- ─── ESTIMATION PUBLIQUE (sans exposer les tarifs bruts) ───────────────────

CREATE OR REPLACE FUNCTION public.estimate_manufacturing_quote(
  p_material_name text,
  p_grams numeric,
  p_print_hours numeric,
  p_quantity integer DEFAULT 1,
  p_options jsonb DEFAULT '{}'::jsonb,
  p_rush boolean DEFAULT false
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_rules manufacturing_pricing%ROWTYPE;
  v_material manufacturing_materials%ROWTYPE;
  v_quantity integer;
  v_grams numeric;
  v_hourly integer;
  v_material_cost integer;
  v_print_cost integer;
  v_labor integer := 0;
  v_lines jsonb := '[]'::jsonb;
  v_production integer;
  v_complexity integer;
  v_margin integer;
  v_unit integer;
  v_subtotal integer;
  v_discount_pct integer := 0;
  v_discount integer;
  v_rush integer := 0;
  v_total integer;
  v_tier jsonb;
BEGIN
  IF p_grams IS NULL OR p_grams <= 0 OR p_grams > 100000 THEN
    RAISE EXCEPTION 'POIDS_INVALIDE';
  END IF;
  IF p_print_hours IS NULL OR p_print_hours <= 0 OR p_print_hours > 2000 THEN
    RAISE EXCEPTION 'TEMPS_INVALIDE';
  END IF;
  v_quantity := coalesce(p_quantity, 1);
  IF v_quantity < 1 OR v_quantity > 100 THEN
    RAISE EXCEPTION 'QUANTITE_INVALIDE';
  END IF;

  SELECT * INTO v_rules FROM manufacturing_pricing WHERE id = true;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'TARIFICATION_INDISPONIBLE';
  END IF;
  SELECT * INTO v_material
  FROM manufacturing_materials
  WHERE lower(btrim(name)) = lower(btrim(coalesce(p_material_name, ''))) AND is_available;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'MATIERE_INDISPONIBLE';
  END IF;

  v_grams := p_grams * (1 + v_rules.waste_percent::numeric / 100);
  v_material_cost := round(v_grams * v_material.price_per_gram_dzd * v_material.multiplier);

  v_hourly := v_rules.price_per_hour_dzd
            + v_rules.machine_hourly_cost_dzd
            + v_rules.electricity_per_hour_dzd;
  v_print_cost := greatest(round(p_print_hours * v_hourly), v_rules.minimum_print_charge_dzd);

  IF coalesce((p_options->>'design')::boolean, false) THEN
    v_labor := v_labor + v_rules.design_preparation_fee_dzd;
    v_lines := v_lines || jsonb_build_object('label', 'Préparation du design', 'amountDzd', v_rules.design_preparation_fee_dzd);
  END IF;
  IF coalesce((p_options->>'modeling')::boolean, false) THEN
    v_labor := v_labor + v_rules.modeling_fee_dzd;
    v_lines := v_lines || jsonb_build_object('label', 'Modélisation / modification', 'amountDzd', v_rules.modeling_fee_dzd);
  END IF;
  IF coalesce((p_options->>'assembly')::boolean, false) THEN
    v_labor := v_labor + v_rules.assembly_fee_dzd;
    v_lines := v_lines || jsonb_build_object('label', 'Assemblage', 'amountDzd', v_rules.assembly_fee_dzd);
  END IF;
  IF coalesce((p_options->>'finishing')::boolean, false) THEN
    v_labor := v_labor + v_rules.finishing_fee_dzd;
    v_lines := v_lines || jsonb_build_object('label', 'Ponçage et finition', 'amountDzd', v_rules.finishing_fee_dzd);
  END IF;
  IF coalesce((p_options->>'painting')::boolean, false) THEN
    v_labor := v_labor + v_rules.painting_fee_dzd;
    v_lines := v_lines || jsonb_build_object('label', 'Peinture', 'amountDzd', v_rules.painting_fee_dzd);
  END IF;

  v_production := v_material_cost + v_print_cost + v_labor + v_rules.extra_production_dzd;
  v_complexity := v_rules.complexity_fee_dzd;
  v_margin := round((v_production + v_complexity) * v_rules.margin_percent::numeric / 100);
  v_unit := greatest(v_production + v_complexity + v_margin, v_rules.minimum_order_dzd);

  v_subtotal := v_unit * v_quantity;

  SELECT coalesce(max((tier->>'percent')::integer), 0) INTO v_discount_pct
  FROM jsonb_array_elements(v_rules.quantity_discounts) AS tier
  WHERE (tier->>'minQuantity')::integer <= v_quantity
    AND (tier->>'percent')::integer > 0;

  v_discount := round(v_subtotal * v_discount_pct::numeric / 100);
  IF coalesce(p_rush, false) THEN
    v_rush := round((v_subtotal - v_discount) * v_rules.rush_fee_percent::numeric / 100);
  END IF;
  v_total := greatest(v_subtotal - v_discount + v_rush, v_rules.minimum_order_dzd);

  -- Ventilation publique : on ne divulgue ni le prix du gramme, ni le tarif
  -- horaire, ni la marge. Seuls les postes facturés au client apparaissent.
  v_lines := jsonb_build_array(
    jsonb_build_object('label', 'Fabrication (matière, impression, préparation)',
      'amountDzd', v_unit, 'detail', v_material.name || ' · ' || v_quantity || ' pièce(s)')
  );

  IF v_complexity > 0 THEN
    v_lines := v_lines || jsonb_build_object('label', 'Complexité', 'amountDzd', v_complexity);
  END IF;
  IF v_discount > 0 THEN
    v_lines := v_lines || jsonb_build_object('label', 'Remise quantité', 'amountDzd', -v_discount);
  END IF;
  IF v_rush > 0 THEN
    v_lines := v_lines || jsonb_build_object('label', 'Supplément urgence', 'amountDzd', v_rush);
  END IF;

  RETURN jsonb_build_object(
    'material', v_material.name,
    'lines', v_lines,
    'unitPriceDzd', v_unit,
    'quantity', v_quantity,
    'subtotalDzd', v_subtotal,
    'discountPercent', v_discount_pct,
    'discountDzd', v_discount,
    'rushFeeDzd', v_rush,
    'totalDzd', v_total,
    'geometryVerified', false,
    'assumptions', jsonb_build_array(
      'Le poids de matière et le temps d’impression sont des estimations de production, pas des mesures garanties.',
      'Le prix ferme est confirmé par le studio après réception du fichier ou des dimensions définitives.',
      'Les frais de livraison sont calculés séparément selon la wilaya et la commune.'
    )
  );
END;
$$;

REVOKE EXECUTE ON FUNCTION public.estimate_manufacturing_quote(text, numeric, numeric, integer, jsonb, boolean) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.estimate_manufacturing_quote(text, numeric, numeric, integer, jsonb, boolean) TO anon, authenticated;

-- ─── VENTILATION CLIENT SANS COÛTS INTERNES ────────────────────────────────

CREATE OR REPLACE FUNCTION public.customer_quote_breakdown(p_breakdown jsonb)
RETURNS jsonb
LANGUAGE sql
IMMUTABLE
AS $$
  WITH lines AS (
    SELECT value AS line
    FROM jsonb_array_elements(coalesce(p_breakdown->'lines', '[]'::jsonb))
  ),
  split AS (
    SELECT
      coalesce(sum(
        CASE
          WHEN line->>'label' IN ('Matière', 'Impression', 'Marge studio', 'Complexité')
            THEN (line->>'amountDzd')::numeric
          ELSE 0
        END
      ), 0) AS internal,
      coalesce(jsonb_agg(line) FILTER (
        WHERE line->>'label' NOT IN ('Matière', 'Impression', 'Marge studio', 'Complexité')
      ), '[]'::jsonb) AS public_lines
    FROM lines
  )
  SELECT jsonb_build_object(
    'lines',
    jsonb_build_array(
      jsonb_build_object(
        'label', 'Fabrication (matière, impression, préparation)',
        'amountDzd', round(internal)
      )
    ) || public_lines,
    'unitPriceDzd', p_breakdown->'unitPriceDzd',
    'quantity', p_breakdown->'quantity',
    'subtotalDzd', p_breakdown->'subtotalDzd',
    'discountPercent', p_breakdown->'discountPercent',
    'discountDzd', p_breakdown->'discountDzd',
    'rushFeeDzd', p_breakdown->'rushFeeDzd',
    'totalDzd', p_breakdown->'totalDzd',
    'geometryVerified', p_breakdown->'geometryVerified'
  )
  FROM split;
$$;

REVOKE EXECUTE ON FUNCTION public.customer_quote_breakdown(jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.customer_quote_breakdown(jsonb) TO anon, authenticated;

-- ─── VUE CLIENT : VENTILATION ASSAINIE ─────────────────────────────────────

CREATE OR REPLACE FUNCTION public.get_custom_request_by_token(p_token uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_result jsonb;
BEGIN
  IF p_token IS NULL THEN
    RAISE EXCEPTION 'DEMANDE_INTROUVABLE';
  END IF;

  UPDATE custom_quotes
  SET status = 'expired', decided_at = now()
  WHERE request_id = (SELECT id FROM custom_requests WHERE tracking_token = p_token)
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
        'kind', f.kind, 'original_name', f.original_name, 'mime_type', f.mime_type
      ) ORDER BY f.created_at)
      FROM custom_request_files f WHERE f.request_id = r.id
    ), '[]'::jsonb),
    'quotes', coalesce((
      SELECT jsonb_agg(jsonb_build_object(
        'version', q.version,
        'public_token', q.public_token,
        'price_dzd', q.price_dzd,
        'production_lead_days', q.production_lead_days,
        'valid_until', q.valid_until,
        'terms', q.terms,
        'status', q.status,
        'source', q.source,
        'breakdown', public.customer_quote_breakdown(q.breakdown),
        'created_at', q.created_at
      ) ORDER BY q.version DESC)
      FROM custom_quotes q WHERE q.request_id = r.id
    ), '[]'::jsonb),
    'order_number', (
      SELECT o.order_number
      FROM custom_quotes q JOIN orders o ON o.id = q.order_id
      WHERE q.request_id = r.id AND q.order_id IS NOT NULL
      LIMIT 1
    )
  )
  INTO v_result
  FROM custom_requests r
  WHERE r.tracking_token = p_token;

  IF v_result IS NULL THEN
    RAISE EXCEPTION 'DEMANDE_INTROUVABLE';
  END IF;

  RETURN v_result;
END;
$$;

REVOKE EXECUTE ON FUNCTION public.get_custom_request_by_token(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_custom_request_by_token(uuid) TO anon, authenticated;



-- ============================================================================
-- SOURCE: 20261113170000_011_custom_workflow_and_delivered_deletion.sql
-- ============================================================================

-- ═══════════════════════════════════════════════════════════════════════════
-- 011 — FLUX COMPLET DE FABRICATION SUR MESURE
--
-- 1. Le client ne saisit plus de poids ni d'heures : l'estimation est dérivée
--    des dimensions (volume de la boîte englobante × taux de remplissage ×
--    densité de la matière ÷ vitesse d'impression), avec des hypothèses
--    explicites. Le propriétaire peut ajuster ces hypothèses.
-- 2. Le client accepte l'estimation puis fournit ses coordonnées et sa
--    livraison ; la demande n'est créée qu'à ce moment-là.
-- 3. Accepter un devis ne crée plus de commande. Le propriétaire doit approuver
--    explicitement la demande pour créer une commande unique et idempotente.
-- 4. Les commandes livrées peuvent être supprimées définitivement par le
--    propriétaire, avec journal d'audit conservé.
-- ═══════════════════════════════════════════════════════════════════════════

-- ─── HYPOTHÈSES DE CALCUL ──────────────────────────────────────────────────

ALTER TABLE manufacturing_materials
  ADD COLUMN IF NOT EXISTS density_g_cm3 numeric(6, 3) NOT NULL DEFAULT 1.24
    CHECK (density_g_cm3 > 0 AND density_g_cm3 <= 25);

ALTER TABLE manufacturing_pricing
  ADD COLUMN IF NOT EXISTS effective_volume_percent integer NOT NULL DEFAULT 30
    CHECK (effective_volume_percent BETWEEN 1 AND 100),
  ADD COLUMN IF NOT EXISTS print_speed_g_per_hour integer NOT NULL DEFAULT 15
    CHECK (print_speed_g_per_hour > 0 AND print_speed_g_per_hour <= 500);

-- ─── DEMANDES : DIMENSIONS, ESTIMATION, LIVRAISON ─────────────────────────

ALTER TABLE custom_requests
  ADD COLUMN IF NOT EXISTS dim_length_mm numeric(8, 2) CHECK (dim_length_mm IS NULL OR (dim_length_mm > 0 AND dim_length_mm <= 2000)),
  ADD COLUMN IF NOT EXISTS dim_width_mm numeric(8, 2) CHECK (dim_width_mm IS NULL OR (dim_width_mm > 0 AND dim_width_mm <= 2000)),
  ADD COLUMN IF NOT EXISTS dim_height_mm numeric(8, 2) CHECK (dim_height_mm IS NULL OR (dim_height_mm > 0 AND dim_height_mm <= 2000)),
  ADD COLUMN IF NOT EXISTS manufacturing_options jsonb NOT NULL DEFAULT '{}'::jsonb,
  ADD COLUMN IF NOT EXISTS rush boolean NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS estimate_price_dzd integer CHECK (estimate_price_dzd IS NULL OR estimate_price_dzd >= 0),
  ADD COLUMN IF NOT EXISTS estimate_breakdown jsonb,
  ADD COLUMN IF NOT EXISTS estimate_public_breakdown jsonb,
  ADD COLUMN IF NOT EXISTS estimate_accepted_at timestamptz,
  ADD COLUMN IF NOT EXISTS delivery_wilaya_code smallint REFERENCES wilayas(code) ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS delivery_commune_id uuid REFERENCES communes(id) ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS delivery_method text CHECK (delivery_method IS NULL OR delivery_method IN ('domicile', 'stopdesk')),
  ADD COLUMN IF NOT EXISTS delivery_address text,
  ADD COLUMN IF NOT EXISTS delivery_pickup_point_id uuid REFERENCES pickup_points(id) ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS rejection_reason text;

-- Statut « accepted » : le client a accepté le devis, le propriétaire doit
-- encore approuver la fabrication.
ALTER TABLE custom_quotes DROP CONSTRAINT IF EXISTS custom_quotes_status_check;
ALTER TABLE custom_quotes ADD CONSTRAINT custom_quotes_status_check
  CHECK (status IN ('sent', 'accepted', 'approved', 'rejected', 'expired'));

-- Une seule version reste actionnable : dès qu'une nouvelle version est
-- insérée, toute version encore « sent » ou « accepted » expire. Cela couvre
-- aussi bien le devis manuel que le devis technique ou l'estimation.
CREATE OR REPLACE FUNCTION public.expire_previous_custom_quotes()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  UPDATE custom_quotes
  SET status = 'expired', decided_at = now()
  WHERE request_id = NEW.request_id
    AND id <> NEW.id
    AND status IN ('sent', 'accepted');
  RETURN NEW;
END;
$$;

REVOKE EXECUTE ON FUNCTION public.expire_previous_custom_quotes() FROM PUBLIC;

DROP TRIGGER IF EXISTS custom_quotes_expire_previous ON custom_quotes;
CREATE TRIGGER custom_quotes_expire_previous
  BEFORE INSERT ON custom_quotes
  FOR EACH ROW EXECUTE FUNCTION public.expire_previous_custom_quotes();

-- ─── CALCUL COMPLET (interne, propriétaire) ────────────────────────────────

CREATE OR REPLACE FUNCTION public.manufacturing_calculate_full(
  p_material_name text,
  p_grams numeric,
  p_print_hours numeric,
  p_quantity integer DEFAULT 1,
  p_options jsonb DEFAULT '{}'::jsonb,
  p_rush boolean DEFAULT false
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_rules manufacturing_pricing%ROWTYPE;
  v_material manufacturing_materials%ROWTYPE;
  v_quantity integer := coalesce(p_quantity, 1);
  v_grams numeric;
  v_hourly integer;
  v_material_cost integer;
  v_print_cost integer;
  v_labor integer := 0;
  v_lines jsonb := '[]'::jsonb;
  v_production integer;
  v_complexity integer;
  v_margin integer;
  v_unit integer;
  v_subtotal integer;
  v_discount_pct integer := 0;
  v_discount integer;
  v_rush integer := 0;
  v_total integer;
  v_tier jsonb;
BEGIN
  IF p_grams IS NULL OR p_grams <= 0 OR p_grams > 100000 THEN
    RAISE EXCEPTION 'POIDS_INVALIDE';
  END IF;
  IF p_print_hours IS NULL OR p_print_hours <= 0 OR p_print_hours > 2000 THEN
    RAISE EXCEPTION 'TEMPS_INVALIDE';
  END IF;
  IF v_quantity < 1 OR v_quantity > 100 THEN
    RAISE EXCEPTION 'QUANTITE_INVALIDE';
  END IF;

  SELECT * INTO v_rules FROM manufacturing_pricing WHERE id = true;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'TARIFICATION_INDISPONIBLE';
  END IF;

  SELECT * INTO v_material
  FROM manufacturing_materials
  WHERE lower(btrim(name)) = lower(btrim(coalesce(p_material_name, ''))) AND is_available;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'MATIERE_INDISPONIBLE';
  END IF;

  v_grams := p_grams * (1 + v_rules.waste_percent::numeric / 100);
  v_material_cost := round(v_grams * v_material.price_per_gram_dzd * v_material.multiplier);

  v_hourly := v_rules.price_per_hour_dzd
            + v_rules.machine_hourly_cost_dzd
            + v_rules.electricity_per_hour_dzd;
  v_print_cost := greatest(round(p_print_hours * v_hourly), v_rules.minimum_print_charge_dzd);

  IF coalesce((p_options->>'design')::boolean, false) THEN
    v_labor := v_labor + v_rules.design_preparation_fee_dzd;
    v_lines := v_lines || jsonb_build_object('label', 'Préparation du design', 'amountDzd', v_rules.design_preparation_fee_dzd);
  END IF;
  IF coalesce((p_options->>'modeling')::boolean, false) THEN
    v_labor := v_labor + v_rules.modeling_fee_dzd;
    v_lines := v_lines || jsonb_build_object('label', 'Modélisation / modification', 'amountDzd', v_rules.modeling_fee_dzd);
  END IF;
  IF coalesce((p_options->>'assembly')::boolean, false) THEN
    v_labor := v_labor + v_rules.assembly_fee_dzd;
    v_lines := v_lines || jsonb_build_object('label', 'Assemblage', 'amountDzd', v_rules.assembly_fee_dzd);
  END IF;
  IF coalesce((p_options->>'finishing')::boolean, false) THEN
    v_labor := v_labor + v_rules.finishing_fee_dzd;
    v_lines := v_lines || jsonb_build_object('label', 'Ponçage et finition', 'amountDzd', v_rules.finishing_fee_dzd);
  END IF;
  IF coalesce((p_options->>'painting')::boolean, false) THEN
    v_labor := v_labor + v_rules.painting_fee_dzd;
    v_lines := v_lines || jsonb_build_object('label', 'Peinture', 'amountDzd', v_rules.painting_fee_dzd);
  END IF;

  v_production := v_material_cost + v_print_cost + v_labor + v_rules.extra_production_dzd;
  v_complexity := v_rules.complexity_fee_dzd;
  v_margin := round((v_production + v_complexity) * v_rules.margin_percent::numeric / 100);
  v_unit := greatest(v_production + v_complexity + v_margin, v_rules.minimum_order_dzd);

  v_subtotal := v_unit * v_quantity;

  SELECT coalesce(max((tier->>'percent')::integer), 0) INTO v_discount_pct
  FROM jsonb_array_elements(v_rules.quantity_discounts) AS tier
  WHERE (tier->>'minQuantity')::integer <= v_quantity
    AND (tier->>'percent')::integer > 0;

  v_discount := round(v_subtotal * v_discount_pct::numeric / 100);
  IF coalesce(p_rush, false) THEN
    v_rush := round((v_subtotal - v_discount) * v_rules.rush_fee_percent::numeric / 100);
  END IF;
  v_total := greatest(v_subtotal - v_discount + v_rush, v_rules.minimum_order_dzd);

  v_lines := jsonb_build_array(
    jsonb_build_object('label', 'Matière', 'amountDzd', v_material_cost,
      'detail', v_material.name || ' · ' || round(v_grams) || ' g × ' || v_material.price_per_gram_dzd || ' DA/g'),
    jsonb_build_object('label', 'Impression', 'amountDzd', v_print_cost,
      'detail', round(p_print_hours * 10) / 10 || ' h × ' || v_hourly || ' DA/h')
  ) || v_lines;

  IF v_complexity > 0 THEN
    v_lines := v_lines || jsonb_build_object('label', 'Complexité', 'amountDzd', v_complexity);
  END IF;
  IF v_margin > 0 THEN
    v_lines := v_lines || jsonb_build_object('label', 'Marge studio', 'amountDzd', v_margin,
      'detail', v_rules.margin_percent || ' %');
  END IF;

  RETURN jsonb_build_object(
    'lines', v_lines,
    'unitProductionCostDzd', v_production,
    'unitPriceDzd', v_unit,
    'quantity', v_quantity,
    'subtotalDzd', v_subtotal,
    'discountPercent', v_discount_pct,
    'discountDzd', v_discount,
    'rushFeeDzd', v_rush,
    'totalDzd', v_total,
    'material', v_material.name,
    'geometryVerified', false,
    'assumptions', jsonb_build_array(
      'Le poids et le temps sont estimés à partir des dimensions (boîte englobante), pas mesurés sur le fichier.',
      'Le prix ferme est confirmé par le studio après vérification du fichier définitif.',
      'Les frais de livraison sont calculés séparément selon la wilaya et la commune.'
    )
  );
END;
$$;

REVOKE EXECUTE ON FUNCTION public.manufacturing_calculate_full(text, numeric, numeric, integer, jsonb, boolean) FROM PUBLIC;

-- ─── ESTIMATION À PARTIR DES DIMENSIONS (PUBLIC) ──────────────────────────

CREATE OR REPLACE FUNCTION public.estimate_manufacturing_dimensions(
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
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_rules manufacturing_pricing%ROWTYPE;
  v_material manufacturing_materials%ROWTYPE;
  v_volume_cm3 numeric;
  v_effective_cm3 numeric;
  v_grams numeric;
  v_hours numeric;
  v_full jsonb;
BEGIN
  IF p_length_mm IS NULL OR p_width_mm IS NULL OR p_height_mm IS NULL
     OR p_length_mm <= 0 OR p_width_mm <= 0 OR p_height_mm <= 0
     OR p_length_mm > 2000 OR p_width_mm > 2000 OR p_height_mm > 2000 THEN
    RAISE EXCEPTION 'DIMENSIONS_INVALIDES';
  END IF;

  SELECT * INTO v_rules FROM manufacturing_pricing WHERE id = true;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'TARIFICATION_INDISPONIBLE';
  END IF;

  SELECT * INTO v_material
  FROM manufacturing_materials
  WHERE lower(btrim(name)) = lower(btrim(coalesce(p_material_name, ''))) AND is_available;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'MATIERE_INDISPONIBLE';
  END IF;

  v_volume_cm3 := (p_length_mm * p_width_mm * p_height_mm) / 1000.0;
  v_effective_cm3 := v_volume_cm3 * v_rules.effective_volume_percent::numeric / 100;
  v_grams := greatest(v_effective_cm3 * v_material.density_g_cm3, 1);
  v_hours := greatest(v_grams / v_rules.print_speed_g_per_hour::numeric, 0.1);

  v_full := public.manufacturing_calculate_full(
    p_material_name, v_grams, v_hours, coalesce(p_quantity, 1), p_options, p_rush
  );

  RETURN public.customer_quote_breakdown(v_full) || jsonb_build_object(
    'estimates', jsonb_build_object(
      'grams', round(v_grams),
      'printHours', round(v_hours * 10) / 10,
      'method', 'bounding_box_heuristic',
      'effectiveVolumePercent', v_rules.effective_volume_percent,
      'printSpeedGPerHour', v_rules.print_speed_g_per_hour,
      'densityGPerCm3', v_material.density_g_cm3,
      'geometryVerified', false
    ),
    'material', v_full->>'material'
  );
END;
$$;

REVOKE EXECUTE ON FUNCTION public.estimate_manufacturing_dimensions(numeric, numeric, numeric, text, integer, jsonb, boolean) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.estimate_manufacturing_dimensions(numeric, numeric, numeric, text, integer, jsonb, boolean) TO anon, authenticated;

-- ─── CRÉATION DE LA DEMANDE COMPLÈTE ───────────────────────────────────────

CREATE OR REPLACE FUNCTION public.create_custom_request(p_payload jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_key text := nullif(btrim(coalesce(p_payload->>'idempotency_key', '')), '');
  v_existing custom_requests%ROWTYPE;
  v_phone text;
  v_name text := btrim(coalesce(p_payload->>'customer_name', ''));
  v_email text := nullif(btrim(coalesce(p_payload->>'email', '')), '');
  v_title text := btrim(coalesce(p_payload->>'title', ''));
  v_description text := btrim(coalesce(p_payload->>'description', ''));
  v_quantity integer := coalesce((p_payload->>'quantity')::integer, 1);
  v_unit text := coalesce(p_payload->>'dimension_unit', 'mm');
  v_length numeric := nullif(p_payload->>'dim_length_mm', '')::numeric;
  v_width numeric := nullif(p_payload->>'dim_width_mm', '')::numeric;
  v_height numeric := nullif(p_payload->>'dim_height_mm', '')::numeric;
  v_material text := nullif(btrim(coalesce(p_payload->>'material_preference', '')), '');
  v_options jsonb := coalesce(p_payload->'manufacturing_options', '{}'::jsonb);
  v_rush boolean := coalesce((p_payload->>'rush')::boolean, false);
  v_estimate_accepted boolean := coalesce((p_payload->>'estimate_accepted')::boolean, false);
  v_wilaya smallint := nullif(p_payload->'delivery'->>'wilaya_code', '')::smallint;
  v_commune uuid := nullif(p_payload->'delivery'->>'commune_id', '')::uuid;
  v_method text := coalesce(p_payload->'delivery'->>'method', p_payload->'delivery'->>'delivery_method', '');
  v_address text := nullif(btrim(coalesce(p_payload->'delivery'->>'address', '')), '');
  v_pickup uuid := nullif(p_payload->'delivery'->>'pickup_point_id', '')::uuid;
  v_pickup_name text;
  v_wilaya_ok text;
  v_commune_ok text;
  v_files jsonb := coalesce(p_payload->'files', '[]'::jsonb);
  v_file jsonb;
  v_request custom_requests%ROWTYPE;
  v_number text;
  v_exists boolean;
  v_full jsonb;
  v_public jsonb;
  v_estimate_price integer;
  v_accepted_at timestamptz;
BEGIN
  IF v_key IS NULL THEN
    RAISE EXCEPTION 'CLE_IDEMPOTENCE_MANQUANTE';
  END IF;

  PERFORM pg_advisory_xact_lock(hashtextextended(v_key, 0));
  SELECT * INTO v_existing FROM custom_requests WHERE idempotency_key = v_key;
  IF FOUND THEN
    RETURN jsonb_build_object(
      'request_number', v_existing.request_number,
      'tracking_token', v_existing.tracking_token,
      'already_exists', true
    );
  END IF;

  IF v_name = '' THEN
    RAISE EXCEPTION 'NOM_REQUIS';
  END IF;

  v_phone := regexp_replace(coalesce(p_payload->>'phone', ''), '\D', '', 'g');
  IF left(v_phone, 2) = '00' THEN v_phone := substr(v_phone, 3); END IF;
  IF left(v_phone, 3) = '213' THEN v_phone := '0' || substr(v_phone, 4); END IF;
  IF length(v_phone) = 9 AND left(v_phone, 1) IN ('5', '6', '7') THEN v_phone := '0' || v_phone; END IF;
  IF v_phone !~ '^0[5-7][0-9]{8}$' THEN
    RAISE EXCEPTION 'TELEPHONE_INVALIDE';
  END IF;

  IF length(v_title) < 3 THEN RAISE EXCEPTION 'TITRE_REQUIS'; END IF;
  IF length(v_description) < 20 THEN RAISE EXCEPTION 'DESCRIPTION_TROP_COURTE'; END IF;
  IF v_quantity < 1 OR v_quantity > 500 THEN RAISE EXCEPTION 'QUANTITE_INVALIDE'; END IF;
  IF v_unit NOT IN ('mm', 'cm', 'm') THEN RAISE EXCEPTION 'UNITE_INVALIDE'; END IF;
  IF jsonb_typeof(v_files) <> 'array' OR jsonb_array_length(v_files) > 10 THEN
    RAISE EXCEPTION 'FICHIERS_INVALIDES';
  END IF;

  -- Livraison obligatoire dès la soumission : le propriétaire approuvera une
  -- demande complète, sans redemander les informations au client.
  IF v_wilaya IS NULL THEN RAISE EXCEPTION 'WILAYA_REQUISE'; END IF;
  SELECT name_fr INTO v_wilaya_ok FROM wilayas WHERE code = v_wilaya AND is_active;
  IF v_wilaya_ok IS NULL THEN RAISE EXCEPTION 'WILAYA_INVALIDE'; END IF;
  IF v_commune IS NULL THEN RAISE EXCEPTION 'COMMUNE_REQUISE'; END IF;
  SELECT name_fr INTO v_commune_ok FROM communes WHERE id = v_commune AND wilaya_code = v_wilaya AND is_active;
  IF v_commune_ok IS NULL THEN RAISE EXCEPTION 'COMMUNE_INVALIDE'; END IF;
  IF v_method NOT IN ('domicile', 'stopdesk') THEN RAISE EXCEPTION 'METHODE_LIVRAISON_INVALIDE'; END IF;

  IF v_method = 'stopdesk' THEN
    IF v_pickup IS NULL THEN RAISE EXCEPTION 'POINT_RELAIS_REQUIS'; END IF;
    SELECT name INTO v_pickup_name
    FROM pickup_points WHERE id = v_pickup AND wilaya_code = v_wilaya AND is_active;
    IF v_pickup_name IS NULL THEN RAISE EXCEPTION 'POINT_RELAIS_INVALIDE'; END IF;
  ELSIF v_address IS NULL THEN
    RAISE EXCEPTION 'ADRESSE_REQUISE';
  END IF;

  -- Estimation serveur : jamais un total envoyé par le navigateur.
  IF v_length IS NOT NULL AND v_width IS NOT NULL AND v_height IS NOT NULL AND v_material IS NOT NULL THEN
    BEGIN
      v_full := public.manufacturing_calculate_full(
        v_material,
        greatest(((v_length * v_width * v_height) / 1000.0)
          * (SELECT effective_volume_percent FROM manufacturing_pricing WHERE id = true) / 100
          * (SELECT density_g_cm3 FROM manufacturing_materials WHERE lower(btrim(name)) = lower(v_material) AND is_available),
          1),
        greatest((((v_length * v_width * v_height) / 1000.0)
          * (SELECT effective_volume_percent FROM manufacturing_pricing WHERE id = true) / 100
          * (SELECT density_g_cm3 FROM manufacturing_materials WHERE lower(btrim(name)) = lower(v_material) AND is_available))
          / (SELECT print_speed_g_per_hour FROM manufacturing_pricing WHERE id = true), 0.1),
        v_quantity, v_options, v_rush
      );
      v_public := public.customer_quote_breakdown(v_full);
      v_estimate_price := (v_full->>'totalDzd')::integer;
    EXCEPTION WHEN OTHERS THEN
      v_full := NULL;
      v_public := NULL;
      v_estimate_price := NULL;
    END;
  END IF;

  IF v_estimate_accepted THEN
    IF v_estimate_price IS NULL THEN
      RAISE EXCEPTION 'ESTIMATION_INDISPONIBLE';
    END IF;
    v_accepted_at := now();
  END IF;

  v_number := 'DEM-' || to_char(now(), 'YYYY') || '-' ||
              lpad(nextval('custom_request_seq')::text, 5, '0');

  INSERT INTO custom_requests (
    request_number, idempotency_key, customer_name, phone, email,
    title, description, intended_use, dimensions, dimension_unit,
    dim_length_mm, dim_width_mm, dim_height_mm,
    material_preference, color_preference, quantity,
    manufacturing_options, rush,
    estimate_price_dzd, estimate_breakdown, estimate_public_breakdown, estimate_accepted_at,
    delivery_wilaya_code, delivery_commune_id, delivery_method, delivery_address, delivery_pickup_point_id
  ) VALUES (
    v_number, v_key, v_name, v_phone, v_email,
    v_title, v_description, nullif(btrim(coalesce(p_payload->>'intended_use', '')), ''),
    nullif(btrim(coalesce(p_payload->>'dimensions', '')), ''), v_unit,
    v_length, v_width, v_height,
    v_material, nullif(btrim(coalesce(p_payload->>'color_preference', '')), ''), v_quantity,
    v_options, v_rush,
    v_estimate_price, v_full, v_public, v_accepted_at,
    v_wilaya, v_commune, v_method, v_address, v_pickup
  )
  RETURNING * INTO v_request;

  FOR v_file IN SELECT * FROM jsonb_array_elements(v_files) LOOP
    SELECT EXISTS (
      SELECT 1 FROM storage.objects
      WHERE bucket_id = 'custom-requests' AND name = (v_file->>'path')
    ) INTO v_exists;
    IF NOT v_exists THEN RAISE EXCEPTION 'FICHIER_INTROUVABLE'; END IF;

    INSERT INTO custom_request_files (request_id, kind, storage_path, original_name, mime_type, size_bytes)
    VALUES (
      v_request.id,
      CASE WHEN (v_file->>'kind') = 'image' THEN 'image' ELSE 'model' END,
      v_file->>'path',
      coalesce(nullif(btrim(v_file->>'name'), ''), 'fichier'),
      nullif(btrim(v_file->>'mime'), ''),
      nullif(v_file->>'size', '')::bigint
    );
  END LOOP;

  INSERT INTO custom_quote_events (request_id, action, actor)
  VALUES (v_request.id, 'created', 'client');

  RETURN jsonb_build_object(
    'request_number', v_number,
    'tracking_token', v_request.tracking_token,
    'estimate_price_dzd', v_estimate_price,
    'already_exists', false
  );
END;
$$;

REVOKE EXECUTE ON FUNCTION public.create_custom_request(jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.create_custom_request(jsonb) TO anon, authenticated;

-- ─── DEVIS AUTOMATIQUE DEPUIS L'ESTIMATION (PROPRIÉTAIRE) ──────────────────

CREATE OR REPLACE FUNCTION public.create_custom_quote_from_estimate(
  p_request_id uuid,
  p_terms text DEFAULT NULL,
  p_valid_until date DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_request custom_requests%ROWTYPE;
  v_rules manufacturing_pricing%ROWTYPE;
  v_version integer;
  v_quote custom_quotes%ROWTYPE;
BEGIN
  IF NOT public.is_owner() THEN RAISE EXCEPTION 'ACCES_REFUSE'; END IF;

  SELECT * INTO v_request FROM custom_requests WHERE id = p_request_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'DEMANDE_INTROUVABLE'; END IF;
  IF v_request.status IN ('approved', 'closed') THEN RAISE EXCEPTION 'DEMANDE_CLOTUREE'; END IF;
  IF v_request.estimate_price_dzd IS NULL THEN RAISE EXCEPTION 'ESTIMATION_INDISPONIBLE'; END IF;

  SELECT * INTO v_rules FROM manufacturing_pricing WHERE id = true;

  UPDATE custom_quotes SET status = 'expired', decided_at = now()
  WHERE request_id = p_request_id AND status = 'sent';

  SELECT coalesce(max(version), 0) + 1 INTO v_version
  FROM custom_quotes WHERE request_id = p_request_id;

  INSERT INTO custom_quotes (
    request_id, version, price_dzd, production_lead_days, valid_until, terms,
    source, pricing_snapshot, breakdown
  ) VALUES (
    p_request_id, v_version, v_request.estimate_price_dzd, NULL,
    coalesce(p_valid_until, current_date + coalesce(v_rules.validity_days, 14)),
    coalesce(nullif(btrim(coalesce(p_terms, '')), ''),
      'Devis établi à partir de l’estimation automatique. Le studio confirme après vérification du fichier.'),
    'automatic',
    jsonb_build_object(
      'requestId', p_request_id,
      'estimateAcceptedAt', v_request.estimate_accepted_at,
      'dimensions', jsonb_build_object('lengthMm', v_request.dim_length_mm, 'widthMm', v_request.dim_width_mm, 'heightMm', v_request.dim_height_mm),
      'material', v_request.material_preference,
      'quantity', v_request.quantity,
      'options', v_request.manufacturing_options,
      'rush', v_request.rush,
      'calculatedAt', now()
    ),
    v_request.estimate_breakdown
  )
  RETURNING * INTO v_quote;

  UPDATE custom_requests SET status = 'quoted' WHERE id = p_request_id;

  INSERT INTO custom_quote_events (request_id, quote_id, action, actor, note)
  VALUES (p_request_id, v_quote.id, 'sent', 'proprietaire', 'Devis automatique v' || v_version);

  RETURN jsonb_build_object(
    'version', v_version,
    'public_token', v_quote.public_token,
    'valid_until', v_quote.valid_until,
    'price_dzd', v_quote.price_dzd
  );
END;
$$;

REVOKE EXECUTE ON FUNCTION public.create_custom_quote_from_estimate(uuid, text, date) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.create_custom_quote_from_estimate(uuid, text, date) TO authenticated;

-- ─── DÉCISION CLIENT : ACCEPTER / REFUSER (SANS CRÉER DE COMMANDE) ─────────

CREATE OR REPLACE FUNCTION public.decide_custom_quote(
  p_quote_token uuid,
  p_decision text,
  p_delivery jsonb DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_quote custom_quotes%ROWTYPE;
  v_request custom_requests%ROWTYPE;
BEGIN
  IF p_decision NOT IN ('accept', 'cancel') THEN
    RAISE EXCEPTION 'DECISION_INVALIDE';
  END IF;

  SELECT * INTO v_quote FROM custom_quotes WHERE public_token = p_quote_token FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'DEVIS_INTROUVABLE'; END IF;
  SELECT * INTO v_request FROM custom_requests WHERE id = v_quote.request_id FOR UPDATE;

  IF p_decision = 'cancel' THEN
    IF v_quote.order_id IS NOT NULL THEN RAISE EXCEPTION 'COMMANDE_DEJA_CREEE'; END IF;
    IF v_quote.status <> 'sent' THEN
      RETURN jsonb_build_object('status', v_quote.status, 'already_decided', true);
    END IF;
    UPDATE custom_quotes SET status = 'rejected', decided_at = now() WHERE id = v_quote.id;
    UPDATE custom_requests SET status = 'rejected' WHERE id = v_request.id;
    INSERT INTO custom_quote_events (request_id, quote_id, action, actor, note)
    VALUES (v_request.id, v_quote.id, 'status_changed', 'client', 'Devis refusé par le client');
    RETURN jsonb_build_object('status', 'rejected', 'already_decided', false);
  END IF;

  -- Acceptation = le client accepte l'estimation. Aucune commande n'est créée :
  -- le propriétaire doit inspecter la demande puis approuver explicitement.
  IF v_quote.status = 'accepted' THEN
    RETURN jsonb_build_object('status', 'accepted', 'already_decided', true);
  END IF;
  IF v_quote.status <> 'sent' THEN RAISE EXCEPTION 'DEVIS_NON_APPROUVABLE'; END IF;
  IF v_quote.valid_until < current_date THEN RAISE EXCEPTION 'DEVIS_EXPIRE'; END IF;

  UPDATE custom_quotes SET status = 'accepted', decided_at = now() WHERE id = v_quote.id;
  INSERT INTO custom_quote_events (request_id, quote_id, action, actor, note)
  VALUES (v_request.id, v_quote.id, 'status_changed', 'client',
    'Estimation acceptée par le client — en attente d''approbation du studio');

  RETURN jsonb_build_object('status', 'accepted', 'already_decided', false);
END;
$$;

REVOKE EXECUTE ON FUNCTION public.decide_custom_quote(uuid, text, jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.decide_custom_quote(uuid, text, jsonb) TO anon, authenticated;

-- ─── APPROBATION PROPRIÉTAIRE → UNE SEULE COMMANDE ────────────────────────

CREATE OR REPLACE FUNCTION public.owner_approve_custom_request(
  p_quote_id uuid,
  p_note text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_quote custom_quotes%ROWTYPE;
  v_request custom_requests%ROWTYPE;
  v_existing orders%ROWTYPE;
  v_wilaya_name text;
  v_commune_name text;
  v_pickup_name text;
  v_rate record;
  v_order_id uuid;
  v_number text;
  v_token uuid;
BEGIN
  IF NOT public.is_owner() THEN RAISE EXCEPTION 'ACCES_REFUSE'; END IF;

  SELECT * INTO v_quote FROM custom_quotes WHERE id = p_quote_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'DEVIS_INTROUVABLE'; END IF;

  IF v_quote.order_id IS NOT NULL THEN
    SELECT * INTO v_existing FROM orders WHERE id = v_quote.order_id;
    RETURN jsonb_build_object(
      'order_number', v_existing.order_number,
      'tracking_token', v_existing.tracking_token,
      'total_dzd', v_existing.total_dzd,
      'already_exists', true
    );
  END IF;

  -- Le prix officiel doit avoir été accepté par le client avant que le
  -- propriétaire ne crée la commande : une estimation acceptée ne suffit pas
  -- si le devis final diffère.
  IF v_quote.status <> 'accepted' THEN RAISE EXCEPTION 'DEVIS_NON_APPROUVABLE'; END IF;
  IF v_quote.valid_until < current_date THEN RAISE EXCEPTION 'DEVIS_EXPIRE'; END IF;

  SELECT * INTO v_request FROM custom_requests WHERE id = v_quote.request_id FOR UPDATE;
  IF v_request.status IN ('approved', 'closed') THEN RAISE EXCEPTION 'DEMANDE_CLOTUREE'; END IF;
  IF v_request.delivery_wilaya_code IS NULL OR v_request.delivery_commune_id IS NULL
     OR v_request.delivery_method IS NULL THEN
    RAISE EXCEPTION 'LIVRAISON_REQUISE';
  END IF;

  SELECT name_fr INTO v_wilaya_name FROM wilayas WHERE code = v_request.delivery_wilaya_code AND is_active;
  IF v_wilaya_name IS NULL THEN RAISE EXCEPTION 'WILAYA_INVALIDE'; END IF;
  SELECT name_fr INTO v_commune_name
  FROM communes WHERE id = v_request.delivery_commune_id
    AND wilaya_code = v_request.delivery_wilaya_code AND is_active;
  IF v_commune_name IS NULL THEN RAISE EXCEPTION 'COMMUNE_INVALIDE'; END IF;

  IF v_request.delivery_method = 'stopdesk' THEN
    SELECT name INTO v_pickup_name FROM pickup_points
    WHERE id = v_request.delivery_pickup_point_id
      AND wilaya_code = v_request.delivery_wilaya_code AND is_active;
    IF v_pickup_name IS NULL THEN RAISE EXCEPTION 'POINT_RELAIS_INVALIDE'; END IF;
  ELSIF v_request.delivery_address IS NULL THEN
    RAISE EXCEPTION 'ADRESSE_REQUISE';
  END IF;

  SELECT * INTO v_rate FROM quote_delivery(
    v_request.delivery_wilaya_code, v_request.delivery_commune_id, v_request.delivery_method
  );

  v_number := public.next_order_number();

  INSERT INTO orders (
    order_number, idempotency_key, customer_name, phone, email,
    wilaya_code, commune_id, wilaya_name, commune_name,
    delivery_method, delivery_carrier, delivery_eta_min, delivery_eta_max,
    address, pickup_point_id, pickup_point_snapshot, note,
    subtotal_dzd, delivery_dzd, total_dzd, source
  ) VALUES (
    v_number, 'devis:' || v_quote.id, v_request.customer_name, v_request.phone, v_request.email,
    v_request.delivery_wilaya_code, v_request.delivery_commune_id, v_wilaya_name, v_commune_name,
    v_request.delivery_method, v_rate.carrier, v_rate.estimated_days_min, v_rate.estimated_days_max,
    v_request.delivery_address, v_request.delivery_pickup_point_id, v_pickup_name,
    coalesce(nullif(btrim(coalesce(p_note, '')), ''), 'Demande sur mesure ' || v_request.request_number),
    v_quote.price_dzd, v_rate.price_dzd, v_quote.price_dzd + v_rate.price_dzd, 'custom'
  )
  RETURNING id, tracking_token INTO v_order_id, v_token;

  INSERT INTO order_items (
    order_id, product_id, variant_id, product_name, variant_label, sku,
    unit_price_dzd, quantity, line_total_dzd
  ) VALUES (
    v_order_id, NULL, NULL, v_request.title,
    'Fabrication sur mesure · quantité ' || v_request.quantity,
    v_request.request_number, v_quote.price_dzd, 1, v_quote.price_dzd
  );

  INSERT INTO order_status_history (order_id, from_status, to_status, actor)
  VALUES (v_order_id, NULL, 'pending', 'proprietaire');

  UPDATE custom_quotes
  SET status = 'approved', decided_at = now(), order_id = v_order_id
  WHERE id = v_quote.id;

  UPDATE custom_requests SET status = 'approved' WHERE id = v_request.id;

  INSERT INTO custom_quote_events (request_id, quote_id, action, actor, note)
  VALUES (v_request.id, v_quote.id, 'approved', 'proprietaire', v_number);

  RETURN jsonb_build_object(
    'order_number', v_number,
    'tracking_token', v_token,
    'total_dzd', v_quote.price_dzd + v_rate.price_dzd,
    'already_exists', false
  );
END;
$$;

REVOKE EXECUTE ON FUNCTION public.owner_approve_custom_request(uuid, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.owner_approve_custom_request(uuid, text) TO authenticated;

-- ─── REFUS PROPRIÉTAIRE ───────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION public.owner_reject_custom_request(
  p_request_id uuid,
  p_reason text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_request custom_requests%ROWTYPE;
BEGIN
  IF NOT public.is_owner() THEN RAISE EXCEPTION 'ACCES_REFUSE'; END IF;

  SELECT * INTO v_request FROM custom_requests WHERE id = p_request_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'DEMANDE_INTROUVABLE'; END IF;
  IF v_request.status = 'approved' THEN RAISE EXCEPTION 'DEMANDE_CLOTUREE'; END IF;

  UPDATE custom_requests
  SET status = 'rejected', rejection_reason = nullif(btrim(coalesce(p_reason, '')), '')
  WHERE id = p_request_id;

  UPDATE custom_quotes SET status = 'rejected', decided_at = now()
  WHERE request_id = p_request_id AND status IN ('sent', 'accepted');

  INSERT INTO custom_quote_events (request_id, action, actor, note)
  VALUES (p_request_id, 'status_changed', 'proprietaire',
    'Demande refusée' || CASE WHEN nullif(btrim(coalesce(p_reason, '')), '') IS NOT NULL
      THEN ' : ' || btrim(p_reason) ELSE '' END);

  RETURN jsonb_build_object('status', 'rejected');
END;
$$;

REVOKE EXECUTE ON FUNCTION public.owner_reject_custom_request(uuid, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.owner_reject_custom_request(uuid, text) TO authenticated;

-- ─── ARCHIVAGE (CORRIGE L'AUDIT DE 009) ───────────────────────────────────

CREATE OR REPLACE FUNCTION public.delete_order(p_order_id uuid, p_reason text DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_order orders%ROWTYPE;
BEGIN
  IF NOT public.is_owner() THEN RAISE EXCEPTION 'ACCES_REFUSE'; END IF;

  SELECT * INTO v_order FROM orders WHERE id = p_order_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'COMMANDE_INTROUVABLE'; END IF;
  IF v_order.status IN ('delivered', 'shipped') THEN RAISE EXCEPTION 'COMMANDE_NON_SUPPRIMABLE'; END IF;
  IF v_order.archived_at IS NOT NULL THEN
    RETURN jsonb_build_object('archived', true, 'already_archived', true, 'order_number', v_order.order_number);
  END IF;

  UPDATE orders
  SET archived_at = now(), archived_by = auth.uid(),
      archive_reason = nullif(btrim(coalesce(p_reason, '')), '')
  WHERE id = p_order_id;

  INSERT INTO audit_log (actor_id, action, entity, entity_id, details)
  VALUES (auth.uid(), 'order.archived', 'orders', v_order.id::text,
    jsonb_build_object('order_number', v_order.order_number, 'status', v_order.status,
      'total_dzd', v_order.total_dzd, 'reason', p_reason));

  RETURN jsonb_build_object('archived', true, 'already_archived', false, 'order_number', v_order.order_number);
END;
$$;

REVOKE EXECUTE ON FUNCTION public.delete_order(uuid, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.delete_order(uuid, text) TO authenticated;

-- ─── SUPPRESSION DÉFINITIVE D'UNE COMMANDE LIVRÉE ─────────────────────────

CREATE OR REPLACE FUNCTION public.delete_delivered_order(
  p_order_id uuid,
  p_reason text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_order orders%ROWTYPE;
  v_items integer;
BEGIN
  IF NOT public.is_owner() THEN RAISE EXCEPTION 'ACCES_REFUSE'; END IF;

  SELECT * INTO v_order FROM orders WHERE id = p_order_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'COMMANDE_INTROUVABLE'; END IF;
  IF v_order.status <> 'delivered' THEN RAISE EXCEPTION 'COMMANDE_NON_LIVREE'; END IF;

  SELECT count(*) INTO v_items FROM order_items WHERE order_id = v_order.id;

  -- Le journal survit à la suppression : l'audit du trigger couvre aussi le
  -- DELETE, cette entrée explicite conserve la référence métier complète.
  INSERT INTO audit_log (actor_id, action, entity, entity_id, details)
  VALUES (auth.uid(), 'order.delivered_deleted', 'orders', v_order.id::text,
    jsonb_build_object('order_number', v_order.order_number, 'customer_name', v_order.customer_name,
      'phone', v_order.phone, 'total_dzd', v_order.total_dzd, 'items_count', v_items,
      'source', v_order.source, 'created_at', v_order.created_at,
      'reason', nullif(btrim(coalesce(p_reason, '')), '')));

  DELETE FROM orders WHERE id = p_order_id;

  RETURN jsonb_build_object('deleted', true, 'order_number', v_order.order_number);
END;
$$;

REVOKE EXECUTE ON FUNCTION public.delete_delivered_order(uuid, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.delete_delivered_order(uuid, text) TO authenticated;

-- ─── VUE CLIENT : ESTIMATION ACCEPTÉE ET LIVRAISON ─────────────────────────

CREATE OR REPLACE FUNCTION public.get_custom_request_by_token(p_token uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_result jsonb;
BEGIN
  IF p_token IS NULL THEN
    RAISE EXCEPTION 'DEMANDE_INTROUVABLE';
  END IF;

  UPDATE custom_quotes
  SET status = 'expired', decided_at = now()
  WHERE request_id = (SELECT id FROM custom_requests WHERE tracking_token = p_token)
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
    'estimate_price_dzd', r.estimate_price_dzd,
    'estimate_public_breakdown', public.customer_quote_breakdown(r.estimate_breakdown),
    'estimate_accepted_at', r.estimate_accepted_at,
    'rejection_reason', r.rejection_reason,
    'delivery', jsonb_build_object(
      'method', r.delivery_method,
      'address', r.delivery_address,
      'wilaya', (SELECT name_fr FROM wilayas WHERE code = r.delivery_wilaya_code),
      'commune', (SELECT name_fr FROM communes WHERE id = r.delivery_commune_id)
    ),
    'files', coalesce((
      SELECT jsonb_agg(jsonb_build_object(
        'kind', f.kind, 'original_name', f.original_name, 'mime_type', f.mime_type
      ) ORDER BY f.created_at)
      FROM custom_request_files f WHERE f.request_id = r.id
    ), '[]'::jsonb),
    'quotes', coalesce((
      SELECT jsonb_agg(jsonb_build_object(
        'version', q.version,
        'public_token', q.public_token,
        'price_dzd', q.price_dzd,
        'production_lead_days', q.production_lead_days,
        'valid_until', q.valid_until,
        'terms', q.terms,
        'status', q.status,
        'source', q.source,
        'breakdown', public.customer_quote_breakdown(q.breakdown),
        'created_at', q.created_at
      ) ORDER BY q.version DESC)
      FROM custom_quotes q WHERE q.request_id = r.id
    ), '[]'::jsonb),
    'order_number', (
      SELECT o.order_number
      FROM custom_quotes q JOIN orders o ON o.id = q.order_id
      WHERE q.request_id = r.id AND q.order_id IS NOT NULL
      LIMIT 1
    )
  )
  INTO v_result
  FROM custom_requests r
  WHERE r.tracking_token = p_token;

  IF v_result IS NULL THEN
    RAISE EXCEPTION 'DEMANDE_INTROUVABLE';
  END IF;

  RETURN v_result;
END;
$$;

REVOKE EXECUTE ON FUNCTION public.get_custom_request_by_token(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_custom_request_by_token(uuid) TO anon, authenticated;



-- ============================================================================
-- SOURCE: 20261113180000_012_owner_approval_and_safe_request_deletion.sql
-- ============================================================================

-- 012 — Sécurisation de l'approbation propriétaire et suppression sûre des demandes
-- À appliquer après 011. Cette migration ne modifie aucune donnée de production.

-- Retirer l'ancien chemin client qui créait directement une commande en acceptant
-- un devis « sent ». L'unique création d'une commande sur mesure passe désormais
-- par owner_approve_custom_request, réservé au propriétaire.
REVOKE EXECUTE ON FUNCTION public.approve_custom_quote(uuid, jsonb) FROM PUBLIC, anon, authenticated;
DROP FUNCTION IF EXISTS public.approve_custom_quote(uuid, jsonb);

-- Éliminer l'ancienne surcharge sans motif de suppression; l'API doit utiliser
-- delete_order(uuid, text), seule version journalisée par la migration 011.
DROP FUNCTION IF EXISTS public.delete_order(uuid);

-- Un devis doit rester impossible à créer lorsqu'une suppression est engagée.
ALTER TABLE public.custom_requests
  ADD COLUMN IF NOT EXISTS deletion_started_at timestamptz,
  ADD COLUMN IF NOT EXISTS deletion_token uuid;

CREATE OR REPLACE FUNCTION public.prevent_quote_during_request_deletion()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_deletion_started_at timestamptz;
BEGIN
  SELECT r.deletion_started_at INTO v_deletion_started_at
  FROM public.custom_requests AS r
  WHERE r.id = NEW.request_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'DEMANDE_INTROUVABLE';
  END IF;
  IF v_deletion_started_at IS NOT NULL THEN
    RAISE EXCEPTION 'SUPPRESSION_DEMANDE_EN_COURS';
  END IF;
  RETURN NEW;
END;
$$;

REVOKE EXECUTE ON FUNCTION public.prevent_quote_during_request_deletion() FROM PUBLIC, anon, authenticated;
DROP TRIGGER IF EXISTS prevent_quote_during_request_deletion ON public.custom_quotes;
CREATE TRIGGER prevent_quote_during_request_deletion
  BEFORE INSERT ON public.custom_quotes
  FOR EACH ROW EXECUTE FUNCTION public.prevent_quote_during_request_deletion();

CREATE OR REPLACE FUNCTION public.prevent_request_mutation_during_deletion()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
BEGIN
  IF OLD.deletion_started_at IS NOT NULL AND (
    NEW.deletion_started_at IS DISTINCT FROM OLD.deletion_started_at OR
    NEW.deletion_token IS DISTINCT FROM OLD.deletion_token OR
    NEW.status IS DISTINCT FROM OLD.status
  ) THEN
    RAISE EXCEPTION 'SUPPRESSION_DEMANDE_EN_COURS';
  END IF;
  RETURN NEW;
END;
$$;

REVOKE EXECUTE ON FUNCTION public.prevent_request_mutation_during_deletion() FROM PUBLIC, anon, authenticated;
DROP TRIGGER IF EXISTS prevent_request_mutation_during_deletion ON public.custom_requests;
CREATE TRIGGER prevent_request_mutation_during_deletion
  BEFORE UPDATE ON public.custom_requests
  FOR EACH ROW EXECUTE FUNCTION public.prevent_request_mutation_during_deletion();

-- Approbation propriétaire : le client peut accepter ou non le devis, mais cette
-- action n'est jamais un prérequis à la décision du propriétaire. Un devis
-- « sent » ou « accepted », encore valide, peut être approuvé par le propriétaire.
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
  v_wilaya_name text;
  v_commune_name text;
  v_pickup_name text;
  v_rate record;
  v_order_id uuid;
  v_number text;
  v_token uuid;
  v_total bigint;
  v_idempotency_key text;
BEGIN
  IF NOT public.is_owner() THEN RAISE EXCEPTION 'ACCES_REFUSE'; END IF;
  IF p_quote_id IS NULL THEN RAISE EXCEPTION 'DEVIS_INTROUVABLE'; END IF;

  SELECT * INTO v_quote
  FROM public.custom_quotes
  WHERE id = p_quote_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'DEVIS_INTROUVABLE'; END IF;

  -- Toutes les décisions et créations de devis verrouillent d'abord la demande,
  -- puis le devis, afin d'éviter les cycles avec owner_reject_custom_request.
  SELECT * INTO v_request
  FROM public.custom_requests
  WHERE id = v_quote.request_id
  FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'DEMANDE_INTROUVABLE'; END IF;

  SELECT * INTO v_quote
  FROM public.custom_quotes
  WHERE id = p_quote_id
  FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'DEVIS_INTROUVABLE'; END IF;
  IF v_quote.request_id <> v_request.id THEN RAISE EXCEPTION 'DEVIS_INTROUVABLE'; END IF;

  v_idempotency_key := 'devis:' || v_quote.id::text;

  -- Rejouer une requête dont la réponse réseau a été perdue sans créer une
  -- deuxième commande; reconstruire le lien si seule la référence manque.
  SELECT * INTO v_existing
  FROM public.orders
  WHERE idempotency_key = v_idempotency_key
  FOR UPDATE;
  IF FOUND THEN
    IF v_request.status IN ('rejected', 'closed') OR v_request.deletion_started_at IS NOT NULL THEN
      RAISE EXCEPTION 'COMMANDE_EXISTANTE_INCOHERENTE';
    END IF;
    IF v_existing.source <> 'custom' OR v_existing.subtotal_dzd <> v_quote.price_dzd THEN
      RAISE EXCEPTION 'COMMANDE_EXISTANTE_INCOHERENTE';
    END IF;
    UPDATE public.custom_quotes
    SET status = 'approved', decided_at = coalesce(decided_at, now()), order_id = v_existing.id
    WHERE id = v_quote.id;
    UPDATE public.custom_requests
    SET status = 'approved'
    WHERE id = v_quote.request_id AND status NOT IN ('approved', 'closed', 'rejected');
    RETURN jsonb_build_object(
      'order_number', v_existing.order_number,
      'tracking_token', v_existing.tracking_token,
      'total_dzd', v_existing.total_dzd,
      'already_exists', true
    );
  END IF;

  IF v_quote.order_id IS NOT NULL THEN
    SELECT * INTO v_existing FROM public.orders WHERE id = v_quote.order_id;
    IF FOUND THEN
      IF v_existing.source <> 'custom'
         OR v_existing.subtotal_dzd <> v_quote.price_dzd
         OR v_existing.idempotency_key <> v_idempotency_key THEN
        RAISE EXCEPTION 'COMMANDE_EXISTANTE_INCOHERENTE';
      END IF;
      RETURN jsonb_build_object(
        'order_number', v_existing.order_number,
        'tracking_token', v_existing.tracking_token,
        'total_dzd', v_existing.total_dzd,
        'already_exists', true
      );
    END IF;
    RAISE EXCEPTION 'COMMANDE_LIEE_INTROUVABLE';
  END IF;

  IF v_quote.status NOT IN ('sent', 'accepted') THEN
    RAISE EXCEPTION 'DEVIS_NON_APPROUVABLE';
  END IF;
  IF v_quote.valid_until < current_date THEN RAISE EXCEPTION 'DEVIS_EXPIRE'; END IF;
  IF v_quote.price_dzd < 0 THEN RAISE EXCEPTION 'PRIX_INVALIDE'; END IF;

  IF v_request.status IN ('approved', 'rejected', 'closed') THEN
    RAISE EXCEPTION 'DEMANDE_CLOTUREE';
  END IF;
  IF v_request.deletion_started_at IS NOT NULL THEN
    RAISE EXCEPTION 'SUPPRESSION_DEMANDE_EN_COURS';
  END IF;

  IF v_request.delivery_wilaya_code IS NULL OR v_request.delivery_commune_id IS NULL
     OR v_request.delivery_method IS NULL THEN
    RAISE EXCEPTION 'LIVRAISON_REQUISE';
  END IF;
  IF v_request.delivery_method NOT IN ('domicile', 'stopdesk') THEN
    RAISE EXCEPTION 'METHODE_LIVRAISON_INVALIDE';
  END IF;

  SELECT name_fr INTO v_wilaya_name
  FROM public.wilayas
  WHERE code = v_request.delivery_wilaya_code AND is_active;
  IF v_wilaya_name IS NULL THEN RAISE EXCEPTION 'WILAYA_INVALIDE'; END IF;

  SELECT name_fr INTO v_commune_name
  FROM public.communes
  WHERE id = v_request.delivery_commune_id
    AND wilaya_code = v_request.delivery_wilaya_code AND is_active;
  IF v_commune_name IS NULL THEN RAISE EXCEPTION 'COMMUNE_INVALIDE'; END IF;

  IF v_request.delivery_method = 'stopdesk' THEN
    SELECT name INTO v_pickup_name
    FROM public.pickup_points
    WHERE id = v_request.delivery_pickup_point_id
      AND wilaya_code = v_request.delivery_wilaya_code AND is_active;
    IF v_pickup_name IS NULL THEN RAISE EXCEPTION 'POINT_RELAIS_INVALIDE'; END IF;
  ELSE
    IF nullif(btrim(coalesce(v_request.delivery_address, '')), '') IS NULL THEN
      RAISE EXCEPTION 'ADRESSE_REQUISE';
    END IF;
  END IF;

  SELECT * INTO v_rate FROM public.quote_delivery(
    v_request.delivery_wilaya_code,
    v_request.delivery_commune_id,
    v_request.delivery_method
  );
  IF NOT FOUND OR v_rate.price_dzd IS NULL OR v_rate.price_dzd < 0 THEN
    RAISE EXCEPTION 'TARIF_LIVRAISON_INVALIDE';
  END IF;

  v_total := v_quote.price_dzd::bigint + v_rate.price_dzd::bigint;
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
    v_request.delivery_wilaya_code, v_request.delivery_commune_id, v_wilaya_name, v_commune_name,
    v_request.delivery_method, v_rate.carrier, v_rate.estimated_days_min, v_rate.estimated_days_max,
    v_request.delivery_address, v_request.delivery_pickup_point_id, v_pickup_name,
    coalesce(nullif(btrim(coalesce(p_note, '')), ''), 'Demande sur mesure ' || v_request.request_number),
    v_quote.price_dzd, v_rate.price_dzd, v_total::integer, 'custom'
  )
  RETURNING id, tracking_token INTO v_order_id, v_token;

  INSERT INTO public.order_items (
    order_id, product_id, variant_id, product_name, variant_label, sku,
    unit_price_dzd, quantity, line_total_dzd
  ) VALUES (
    v_order_id, NULL, NULL, v_request.title,
    'Fabrication sur mesure · quantité ' || v_request.quantity,
    v_request.request_number, v_quote.price_dzd, 1, v_quote.price_dzd
  );

  INSERT INTO public.order_status_history (order_id, from_status, to_status, actor)
  VALUES (v_order_id, NULL, 'pending', 'proprietaire');

  UPDATE public.custom_quotes
  SET status = 'approved', decided_at = now(), order_id = v_order_id
  WHERE id = v_quote.id;
  UPDATE public.custom_requests SET status = 'approved' WHERE id = v_request.id;

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

REVOKE EXECUTE ON FUNCTION public.owner_approve_custom_request(uuid, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.owner_approve_custom_request(uuid, text) TO authenticated;

-- La décision du client sur le devis reste informative. Seul le propriétaire
-- peut faire passer la demande en « rejected » ou créer une commande.
CREATE OR REPLACE FUNCTION public.decide_custom_quote(
  p_quote_token uuid,
  p_decision text,
  p_delivery jsonb DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_quote public.custom_quotes%ROWTYPE;
  v_request public.custom_requests%ROWTYPE;
BEGIN
  IF p_decision IS NULL OR p_decision NOT IN ('accept', 'cancel') THEN
    RAISE EXCEPTION 'DECISION_INVALIDE';
  END IF;

  SELECT * INTO v_quote
  FROM public.custom_quotes
  WHERE public_token = p_quote_token;
  IF NOT FOUND THEN RAISE EXCEPTION 'DEVIS_INTROUVABLE'; END IF;

  SELECT * INTO v_request
  FROM public.custom_requests
  WHERE id = v_quote.request_id
  FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'DEMANDE_INTROUVABLE'; END IF;

  SELECT * INTO v_quote
  FROM public.custom_quotes
  WHERE id = v_quote.id
  FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'DEVIS_INTROUVABLE'; END IF;
  IF v_request.status IN ('approved', 'rejected', 'closed') THEN
    RAISE EXCEPTION 'DEMANDE_CLOTUREE';
  END IF;

  IF p_decision = 'cancel' THEN
    IF v_quote.order_id IS NOT NULL THEN RAISE EXCEPTION 'COMMANDE_DEJA_CREEE'; END IF;
    IF v_quote.status <> 'sent' THEN
      RETURN jsonb_build_object('status', v_quote.status, 'already_decided', true);
    END IF;
    UPDATE public.custom_quotes
    SET status = 'rejected', decided_at = now()
    WHERE id = v_quote.id;
    INSERT INTO public.custom_quote_events (request_id, quote_id, action, actor, note)
    VALUES (v_request.id, v_quote.id, 'status_changed', 'client', 'Devis refusé par le client');
    RETURN jsonb_build_object('status', 'rejected', 'already_decided', false);
  END IF;

  IF v_quote.status = 'accepted' THEN
    RETURN jsonb_build_object('status', 'accepted', 'already_decided', true);
  END IF;
  IF v_quote.status <> 'sent' THEN RAISE EXCEPTION 'DEVIS_NON_APPROUVABLE'; END IF;
  IF v_quote.valid_until < current_date THEN RAISE EXCEPTION 'DEVIS_EXPIRE'; END IF;

  UPDATE public.custom_quotes
  SET status = 'accepted', decided_at = now()
  WHERE id = v_quote.id;
  INSERT INTO public.custom_quote_events (request_id, quote_id, action, actor, note)
  VALUES (
    v_request.id, v_quote.id, 'status_changed', 'client',
    'Estimation acceptée par le client — en attente d''approbation du studio'
  );
  RETURN jsonb_build_object('status', 'accepted', 'already_decided', false);
END;
$$;

REVOKE EXECUTE ON FUNCTION public.decide_custom_quote(uuid, text, jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.decide_custom_quote(uuid, text, jsonb) TO anon, authenticated;

-- Démarrer une suppression en deux phases. Les demandes avec devis, décision
-- historique ou commande ne sont pas effaçables. Le verrou de ligne et le
-- trigger sur custom_quotes ferment la course avec une création de devis.
CREATE OR REPLACE FUNCTION public.begin_custom_request_deletion(p_request_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_request public.custom_requests%ROWTYPE;
  v_paths text[];
BEGIN
  IF NOT public.is_owner() THEN RAISE EXCEPTION 'ACCES_REFUSE'; END IF;

  SELECT * INTO v_request
  FROM public.custom_requests
  WHERE id = p_request_id
  FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'DEMANDE_INTROUVABLE'; END IF;

  IF v_request.status NOT IN ('new', 'reviewing') THEN
    RAISE EXCEPTION 'DEMANDE_HISTORIQUE_NON_SUPPRIMABLE';
  END IF;
  IF EXISTS (SELECT 1 FROM public.custom_quotes q WHERE q.request_id = p_request_id) THEN
    RAISE EXCEPTION 'DEMANDE_AVEC_DEVIS_NON_SUPPRIMABLE';
  END IF;
  IF EXISTS (
    SELECT 1
    FROM public.orders o
    JOIN public.order_items i ON i.order_id = o.id
    WHERE o.source = 'custom' AND i.sku = v_request.request_number
  ) THEN
    RAISE EXCEPTION 'DEMANDE_LIEE_COMMANDE_NON_SUPPRIMABLE';
  END IF;

  IF v_request.deletion_started_at IS NULL THEN
    UPDATE public.custom_requests
    SET deletion_started_at = now(), deletion_token = gen_random_uuid()
    WHERE id = p_request_id
    RETURNING * INTO v_request;
  END IF;

  SELECT coalesce(array_agg(f.storage_path ORDER BY f.storage_path), ARRAY[]::text[])
  INTO v_paths
  FROM public.custom_request_files f
  WHERE f.request_id = p_request_id;

  RETURN jsonb_build_object(
    'request_number', v_request.request_number,
    'deletion_token', v_request.deletion_token,
    'file_paths', to_jsonb(v_paths)
  );
END;
$$;

REVOKE EXECUTE ON FUNCTION public.begin_custom_request_deletion(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.begin_custom_request_deletion(uuid) TO authenticated;

-- Finaliser après suppression des blobs par Storage API (jamais par DELETE SQL
-- sur storage.objects). Le token lie l'opération à son début et les chemins
-- doivent correspondre exactement aux métadonnées de la demande.
CREATE OR REPLACE FUNCTION public.finish_custom_request_deletion(
  p_request_id uuid,
  p_deletion_token uuid,
  p_deleted_paths text[] DEFAULT ARRAY[]::text[]
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_request public.custom_requests%ROWTYPE;
  v_expected text[];
  v_received text[];
BEGIN
  IF NOT public.is_owner() THEN RAISE EXCEPTION 'ACCES_REFUSE'; END IF;

  SELECT * INTO v_request
  FROM public.custom_requests
  WHERE id = p_request_id AND deletion_token = p_deletion_token
  FOR UPDATE;
  IF NOT FOUND OR v_request.deletion_started_at IS NULL THEN
    RAISE EXCEPTION 'SUPPRESSION_DEMANDE_INVALIDE';
  END IF;

  IF EXISTS (SELECT 1 FROM public.custom_quotes q WHERE q.request_id = p_request_id)
     OR EXISTS (
       SELECT 1 FROM public.orders o JOIN public.order_items i ON i.order_id = o.id
       WHERE o.source = 'custom' AND i.sku = v_request.request_number
     ) THEN
    RAISE EXCEPTION 'DEMANDE_LIEE_COMMANDE_NON_SUPPRIMABLE';
  END IF;

  SELECT coalesce(array_agg(DISTINCT f.storage_path ORDER BY f.storage_path), ARRAY[]::text[])
  INTO v_expected
  FROM public.custom_request_files f WHERE f.request_id = p_request_id;
  SELECT coalesce(array_agg(DISTINCT x.path ORDER BY x.path), ARRAY[]::text[])
  INTO v_received
  FROM unnest(coalesce(p_deleted_paths, ARRAY[]::text[])) AS x(path);
  IF v_expected IS DISTINCT FROM v_received THEN
    RAISE EXCEPTION 'FICHIERS_SUPPRESSION_INCOMPLETE';
  END IF;
  IF EXISTS (
    SELECT 1
    FROM storage.objects AS o
    WHERE o.bucket_id = 'custom-requests'
      AND o.name = ANY(v_expected)
  ) THEN
    RAISE EXCEPTION 'FICHIERS_SUPPRESSION_INCOMPLETE';
  END IF;

  INSERT INTO public.audit_log (actor_id, action, entity, entity_id, details)
  VALUES (
    auth.uid(), 'custom_request.deleted', 'custom_requests', p_request_id::text,
    jsonb_build_object(
      'request_number', v_request.request_number,
      'previous_status', v_request.status,
      'file_count', cardinality(v_expected),
      'created_at', v_request.created_at,
      'events', coalesce((
        SELECT jsonb_agg(
          jsonb_build_object(
            'event_id', e.id,
            'quote_id', e.quote_id,
            'action', e.action,
            'actor', e.actor,
            'note', e.note,
            'created_at', e.created_at
          ) ORDER BY e.created_at, e.id
        )
        FROM public.custom_quote_events e
        WHERE e.request_id = p_request_id
      ), '[]'::jsonb)
    )
  );

  DELETE FROM public.custom_requests WHERE id = p_request_id;
  RETURN jsonb_build_object('deleted', true, 'request_number', v_request.request_number);
END;
$$;

REVOKE EXECUTE ON FUNCTION public.finish_custom_request_deletion(uuid, uuid, text[]) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.finish_custom_request_deletion(uuid, uuid, text[]) TO authenticated;


-- Statistiques du tableau de bord en un seul aller-retour et sous RLS propriétaire.
CREATE OR REPLACE FUNCTION public.owner_dashboard_stats()
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
BEGIN
  IF NOT public.is_owner() THEN RAISE EXCEPTION 'ACCES_REFUSE'; END IF;

  RETURN jsonb_build_object(
    'products_total', (SELECT count(*) FROM public.products),
    'products_published', (SELECT count(*) FROM public.products WHERE status = 'published'),
    'products_draft', (SELECT count(*) FROM public.products WHERE status = 'draft'),
    'categories_total', (SELECT count(*) FROM public.categories),
    'orders_total', (SELECT count(*) FROM public.orders),
    'orders_pending', (SELECT count(*) FROM public.orders WHERE status = 'pending'),
    'orders_confirmed', (SELECT count(*) FROM public.orders WHERE status = 'confirmed'),
    'orders_shipped', (SELECT count(*) FROM public.orders WHERE status = 'shipped'),
    'orders_delivered', (SELECT count(*) FROM public.orders WHERE status = 'delivered'),
    'requests_total', (SELECT count(*) FROM public.custom_requests),
    'requests_new', (SELECT count(*) FROM public.custom_requests WHERE status = 'new'),
    'requests_reviewing', (SELECT count(*) FROM public.custom_requests WHERE status = 'reviewing'),
    'requests_approved', (SELECT count(*) FROM public.custom_requests WHERE status = 'approved'),
    'requests_rejected', (SELECT count(*) FROM public.custom_requests WHERE status = 'rejected'),
    'quotes_issued', (SELECT count(*) FROM public.custom_quotes),
    'quotes_pending', (SELECT count(*) FROM public.custom_quotes WHERE status IN ('sent', 'accepted'))
  );
END;
$$;

REVOKE EXECUTE ON FUNCTION public.owner_dashboard_stats() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.owner_dashboard_stats() TO authenticated;



-- ============================================================================
-- SOURCE: 20261114224500_013_owner_notifications.sql
-- ============================================================================

-- 013 — Notifications privées du propriétaire pour les nouveaux événements métier.
-- Les triggers s’exécutent dans la transaction qui crée la commande ou la demande :
-- toute opération métier annulée annule aussi sa notification.

CREATE TABLE IF NOT EXISTS public.owner_notifications (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  owner_id uuid NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  event_type text NOT NULL CHECK (event_type IN ('new_order', 'new_custom_request')),
  event_id uuid NOT NULL,
  -- Une notification sans entité à ouvrir n’est plus utile : elle est supprimée avec sa cible.
  related_order_id uuid REFERENCES public.orders(id) ON DELETE CASCADE,
  related_request_id uuid REFERENCES public.custom_requests(id) ON DELETE CASCADE,
  title text NOT NULL CHECK (length(btrim(title)) BETWEEN 1 AND 180),
  description text NOT NULL CHECK (length(btrim(description)) BETWEEN 1 AND 500),
  created_at timestamptz NOT NULL DEFAULT now(),
  read_at timestamptz,
  CONSTRAINT owner_notifications_related_entity_check CHECK (
    (event_type = 'new_order' AND related_order_id IS NOT NULL AND related_request_id IS NULL)
    OR
    (event_type = 'new_custom_request' AND related_request_id IS NOT NULL AND related_order_id IS NULL)
  ),
  CONSTRAINT owner_notifications_event_unique UNIQUE (owner_id, event_type, event_id)
);

CREATE INDEX IF NOT EXISTS idx_owner_notifications_unread
  ON public.owner_notifications (owner_id, created_at DESC)
  WHERE read_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_owner_notifications_recent
  ON public.owner_notifications (owner_id, created_at DESC);

ALTER TABLE public.owner_notifications ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.owner_notifications FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.owner_notifications TO authenticated;
GRANT UPDATE (read_at) ON public.owner_notifications TO authenticated;

DROP POLICY IF EXISTS owner_read_notifications ON public.owner_notifications;
CREATE POLICY owner_read_notifications ON public.owner_notifications FOR SELECT
  TO authenticated USING (owner_id = auth.uid() AND public.is_owner());

DROP POLICY IF EXISTS owner_mark_notifications_read ON public.owner_notifications;
CREATE POLICY owner_mark_notifications_read ON public.owner_notifications FOR UPDATE
  TO authenticated
  USING (owner_id = auth.uid() AND public.is_owner())
  WITH CHECK (owner_id = auth.uid() AND public.is_owner());

CREATE OR REPLACE FUNCTION public.notify_owner_new_order()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
BEGIN
  -- Une commande créée par approbation propriétaire d’une demande sur mesure
  -- n’est pas une nouvelle commande client et ne réclame pas une seconde alerte.
  IF NEW.source IS DISTINCT FROM 'custom' THEN
    INSERT INTO public.owner_notifications (
      owner_id, event_type, event_id, related_order_id, title, description
    )
    SELECT
      p.id,
      'new_order',
      NEW.id,
      NEW.id,
      left('Nouvelle commande ' || NEW.order_number, 180),
      left(NEW.customer_name || ' vient de passer une commande.', 500)
    FROM public.profiles AS p
    WHERE p.role = 'owner'
    ON CONFLICT (owner_id, event_type, event_id) DO NOTHING;
  END IF;
  RETURN NEW;
END;
$$;

REVOKE EXECUTE ON FUNCTION public.notify_owner_new_order() FROM PUBLIC, anon, authenticated;
DROP TRIGGER IF EXISTS owner_notification_on_order_insert ON public.orders;
CREATE TRIGGER owner_notification_on_order_insert
  AFTER INSERT ON public.orders
  FOR EACH ROW EXECUTE FUNCTION public.notify_owner_new_order();

CREATE OR REPLACE FUNCTION public.notify_owner_new_custom_request()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
BEGIN
  INSERT INTO public.owner_notifications (
    owner_id, event_type, event_id, related_request_id, title, description
  )
  SELECT
    p.id,
    'new_custom_request',
    NEW.id,
    NEW.id,
    left('Nouvelle demande sur mesure ' || NEW.request_number, 180),
    left(NEW.customer_name || ' a envoyé une demande : ' || NEW.title, 500)
  FROM public.profiles AS p
  WHERE p.role = 'owner'
  ON CONFLICT (owner_id, event_type, event_id) DO NOTHING;
  RETURN NEW;
END;
$$;

REVOKE EXECUTE ON FUNCTION public.notify_owner_new_custom_request() FROM PUBLIC, anon, authenticated;
DROP TRIGGER IF EXISTS owner_notification_on_custom_request_insert ON public.custom_requests;
CREATE TRIGGER owner_notification_on_custom_request_insert
  AFTER INSERT ON public.custom_requests
  FOR EACH ROW EXECUTE FUNCTION public.notify_owner_new_custom_request();

-- Active Realtime uniquement si la publication Supabase existe; l’interface garde
-- un repli de rafraîchissement léger si Realtime n’est pas activé côté projet.
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_publication WHERE pubname = 'supabase_realtime')
     AND NOT EXISTS (
       SELECT 1 FROM pg_publication_tables
       WHERE pubname = 'supabase_realtime'
         AND schemaname = 'public'
         AND tablename = 'owner_notifications'
     ) THEN
    ALTER PUBLICATION supabase_realtime ADD TABLE public.owner_notifications;
  END IF;
END;
$$;



-- ============================================================================
-- SOURCE: 20261116100000_014_multi_model_custom_requests.sql
-- ============================================================================

-- 014 — Multi-model custom manufacturing requests
-- Stores one independent specification per uploaded 3D model and recalculates
-- the combined indicative estimate on the server using the existing pricing engine.
-- No existing request, quote, order, or tracking workflow is replaced.

ALTER TABLE public.custom_requests
  ADD COLUMN IF NOT EXISTS product_specs jsonb NOT NULL DEFAULT '[]'::jsonb;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname = 'custom_requests_product_specs_array_check'
      AND conrelid = 'public.custom_requests'::regclass
  ) THEN
    ALTER TABLE public.custom_requests
      ADD CONSTRAINT custom_requests_product_specs_array_check
      CHECK (CASE WHEN jsonb_typeof(product_specs) = 'array' THEN jsonb_array_length(product_specs) <= 10 ELSE false END);
  END IF;
END $$;

CREATE OR REPLACE FUNCTION public.save_custom_request_products(
  p_tracking_token uuid,
  p_products jsonb,
  p_options jsonb DEFAULT '{}'::jsonb,
  p_rush boolean DEFAULT false
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_request public.custom_requests%ROWTYPE;
  v_rules public.manufacturing_pricing%ROWTYPE;
  v_product jsonb;
  v_material public.manufacturing_materials%ROWTYPE;
  v_length numeric;
  v_width numeric;
  v_height numeric;
  v_original_length numeric;
  v_original_width numeric;
  v_original_height numeric;
  v_quantity integer;
  v_volume_cm3 numeric;
  v_mesh_volume_cm3 numeric;
  v_estimate_method text;
  v_grams numeric;
  v_hours numeric;
  v_full jsonb;
  v_lines jsonb := '[]'::jsonb;
  v_saved jsonb := '[]'::jsonb;
  v_product_breakdown jsonb := '[]'::jsonb;
  v_total integer := 0;
  v_total_quantity integer := 0;
  v_total_grams numeric := 0;
  v_total_hours numeric := 0;
  v_name text;
  v_file_path text;
  v_mode text;
  v_instructions text;
  v_file_exists boolean;
  v_line jsonb;
BEGIN
  IF p_tracking_token IS NULL THEN
    RAISE EXCEPTION 'JETON_INVALIDE';
  END IF;
  IF jsonb_typeof(p_products) IS DISTINCT FROM 'array' THEN
    RAISE EXCEPTION 'PRODUITS_INVALIDES';
  END IF;
  IF jsonb_array_length(p_products) < 1 OR jsonb_array_length(p_products) > 10 THEN
    RAISE EXCEPTION 'PRODUITS_INVALIDES';
  END IF;

  SELECT * INTO v_request
  FROM public.custom_requests
  WHERE tracking_token = p_tracking_token
  FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'DEMANDE_INTROUVABLE'; END IF;
  IF v_request.status NOT IN ('new', 'reviewing') THEN
    RAISE EXCEPTION 'DEMANDE_NON_MODIFIABLE';
  END IF;
  SELECT * INTO v_rules FROM public.manufacturing_pricing WHERE id = true;
  IF NOT FOUND THEN RAISE EXCEPTION 'TARIFICATION_INDISPONIBLE'; END IF;

  FOR v_product IN SELECT value FROM jsonb_array_elements(p_products) LOOP
    v_name := coalesce(nullif(btrim(v_product->>'file_name'), ''), 'Modèle 3D');
    v_file_path := nullif(btrim(v_product->>'file_path'), '');
    v_mode := coalesce(nullif(v_product->>'mode', ''), 'reference');
    v_instructions := nullif(btrim(coalesce(v_product->>'instructions', '')), '');
    IF v_mode NOT IN ('reference', 'exact', 'modify', 'inspiration') THEN
      RAISE EXCEPTION 'MODE_PRODUIT_INVALIDE';
    END IF;
    IF length(v_name) > 180 OR length(coalesce(v_instructions, '')) > 2000 THEN
      RAISE EXCEPTION 'DETAILS_PRODUIT_TROP_LONGS';
    END IF;
    IF v_file_path IS NULL THEN RAISE EXCEPTION 'FICHIER_PRODUIT_REQUIS'; END IF;

    SELECT EXISTS (
      SELECT 1 FROM public.custom_request_files
      WHERE request_id = v_request.id
        AND storage_path = v_file_path
        AND kind = 'model'
    ) INTO v_file_exists;
    IF NOT v_file_exists THEN RAISE EXCEPTION 'FICHIER_PRODUIT_INTROUVABLE'; END IF;

    v_length := nullif(v_product->'target_dimensions_mm'->>'length', '')::numeric;
    v_width := nullif(v_product->'target_dimensions_mm'->>'width', '')::numeric;
    v_height := nullif(v_product->'target_dimensions_mm'->>'height', '')::numeric;
    v_original_length := nullif(v_product->'original_dimensions_mm'->>'length', '')::numeric;
    v_original_width := nullif(v_product->'original_dimensions_mm'->>'width', '')::numeric;
    v_original_height := nullif(v_product->'original_dimensions_mm'->>'height', '')::numeric;
    v_quantity := coalesce(nullif(v_product->>'quantity', '')::integer, 1);

    IF v_length IS NULL OR v_width IS NULL OR v_height IS NULL
       OR v_length <= 0 OR v_width <= 0 OR v_height <= 0
       OR v_length > 2000 OR v_width > 2000 OR v_height > 2000 THEN
      RAISE EXCEPTION 'DIMENSIONS_PRODUIT_INVALIDES';
    END IF;
    IF v_original_length IS NULL OR v_original_width IS NULL OR v_original_height IS NULL
       OR v_original_length <= 0 OR v_original_width <= 0 OR v_original_height <= 0
       OR v_original_length > 100000 OR v_original_width > 100000 OR v_original_height > 100000 THEN
      RAISE EXCEPTION 'DIMENSIONS_ORIGINALES_INVALIDES';
    END IF;
    IF v_mode = 'exact' AND (
      abs(v_length - v_original_length) > 0.01 OR
      abs(v_width - v_original_width) > 0.01 OR
      abs(v_height - v_original_height) > 0.01
    ) THEN
      RAISE EXCEPTION 'MODE_EXACT_DIMENSIONS_MODIFIEES';
    END IF;
    IF v_quantity < 1 OR v_quantity > 100 THEN RAISE EXCEPTION 'QUANTITE_PRODUIT_INVALIDE'; END IF;

    SELECT * INTO v_material
    FROM public.manufacturing_materials
    WHERE lower(btrim(name)) = lower(btrim(coalesce(v_product->>'material_name', '')))
      AND is_available;
    IF NOT FOUND THEN RAISE EXCEPTION 'MATIERE_INDISPONIBLE'; END IF;

    v_volume_cm3 := (v_length * v_width * v_height) / 1000.0;
    v_mesh_volume_cm3 := nullif(v_product->'geometry'->>'mesh_volume_cm3', '')::numeric;
    IF coalesce(v_product->>'mode', 'reference') NOT IN ('reference', 'exact') THEN
      v_mesh_volume_cm3 := NULL;
    ELSIF v_mesh_volume_cm3 IS NOT NULL
      AND nullif(v_product->'original_dimensions_mm'->>'length', '')::numeric > 0
      AND nullif(v_product->'original_dimensions_mm'->>'width', '')::numeric > 0
      AND nullif(v_product->'original_dimensions_mm'->>'height', '')::numeric > 0 THEN
      v_mesh_volume_cm3 := v_mesh_volume_cm3 * v_volume_cm3 /
        ((nullif(v_product->'original_dimensions_mm'->>'length', '')::numeric
          * nullif(v_product->'original_dimensions_mm'->>'width', '')::numeric
          * nullif(v_product->'original_dimensions_mm'->>'height', '')::numeric) / 1000.0);
    ELSE
      v_mesh_volume_cm3 := NULL;
    END IF;
    IF v_mesh_volume_cm3 IS NOT NULL
       AND v_mesh_volume_cm3 >= v_volume_cm3 * 0.001
       AND v_mesh_volume_cm3 <= v_volume_cm3 * 1.05 THEN
      v_volume_cm3 := v_mesh_volume_cm3;
      v_estimate_method := 'mesh_volume_heuristic';
    ELSE
      v_estimate_method := 'bounding_box_heuristic';
    END IF;
    v_grams := greatest(
      v_volume_cm3 * v_rules.effective_volume_percent::numeric / 100
        * v_material.density_g_cm3,
      1
    );
    v_hours := greatest(v_grams / v_rules.print_speed_g_per_hour::numeric, 0.1);

    v_full := public.manufacturing_calculate_full(
      v_material.name, v_grams, v_hours, v_quantity,
      coalesce(p_options, '{}'::jsonb), coalesce(p_rush, false)
    );

    v_total := v_total + coalesce((v_full->>'totalDzd')::integer, 0);
    v_total_quantity := v_total_quantity + v_quantity;
    v_total_grams := v_total_grams + v_grams * v_quantity;
    v_total_hours := v_total_hours + v_hours * v_quantity;

    FOR v_line IN SELECT value FROM jsonb_array_elements(coalesce(v_full->'lines', '[]'::jsonb)) LOOP
      v_lines := v_lines || jsonb_build_array(
        jsonb_build_object(
          'label', v_name || ' — ' || coalesce(v_line->>'label', 'Coût'),
          'amountDzd', coalesce((v_line->>'amountDzd')::integer, 0),
          'detail', v_line->'detail'
        )
      );
    END LOOP;

    v_saved := v_saved || jsonb_build_array(jsonb_build_object(
      'id', v_product->>'id',
      'file_path', v_file_path,
      'file_name', v_name,
      'mode', v_mode,
      'original_dimensions_mm', v_product->'original_dimensions_mm',
      'target_dimensions_mm', jsonb_build_object(
        'length', v_length, 'width', v_width, 'height', v_height
      ),
      'quantity', v_quantity,
      'material_name', v_material.name,
      'color', nullif(btrim(coalesce(v_product->>'color', '')), ''),
      'preserve_ratio', coalesce((v_product->>'preserve_ratio')::boolean, true),
      'instructions', v_instructions,
      'geometry', coalesce(v_product->'geometry', '{}'::jsonb)
    ));

    v_product_breakdown := v_product_breakdown || jsonb_build_array(jsonb_build_object(
      'name', v_name,
      'quantity', v_quantity,
      'dimensionsMm', jsonb_build_object('length', v_length, 'width', v_width, 'height', v_height),
      'material', v_material.name,
      'gramsPerPiece', round(v_grams, 2),
      'hoursPerPiece', round(v_hours, 2),
      'totalDzd', coalesce((v_full->>'totalDzd')::integer, 0),
      'method', v_estimate_method
    ));
  END LOOP;

  IF v_total_quantity > 500 THEN RAISE EXCEPTION 'QUANTITE_TOTALE_INVALIDE'; END IF;

  UPDATE public.custom_requests
  SET product_specs = v_saved,
      quantity = v_total_quantity,
      estimate_accepted_at = coalesce(estimate_accepted_at, now()),
      estimate_price_dzd = v_total,
      estimate_breakdown = jsonb_build_object(
        'lines', v_lines,
        'totalDzd', v_total,
        'quantity', v_total_quantity,
        'products', v_product_breakdown,
        'estimates', jsonb_build_object(
          'grams', round(v_total_grams, 1),
          'printHours', round(v_total_hours, 1),
          'method', 'multi_product_mesh_or_bounding_box_heuristic',
          'geometryVerified', false
        ),
        'assumptions', jsonb_build_array(
          'Chaque produit est estimé séparément avec ses dimensions, sa matière et sa quantité.',
          'Le poids et le temps sont des estimations basées sur le volume géométrique disponible ou la boîte englobante, puis les paramètres du studio ; ce ne sont pas des données de trancheur.',
          'Le studio vérifie les fichiers et confirme le prix final avant fabrication.'
        )
      ),
      estimate_public_breakdown = jsonb_build_object(
        'totalDzd', v_total,
        'quantity', v_total_quantity,
        'productCount', jsonb_array_length(v_saved),
        'geometryVerified', false
      )
  WHERE id = v_request.id;

  RETURN jsonb_build_object(
    'saved', true,
    'productCount', jsonb_array_length(v_saved),
    'quantity', v_total_quantity,
    'totalDzd', v_total,
    'grams', round(v_total_grams, 1),
    'printHours', round(v_total_hours, 1)
  );
END;
$$;

REVOKE EXECUTE ON FUNCTION public.save_custom_request_products(uuid, jsonb, jsonb, boolean) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.save_custom_request_products(uuid, jsonb, jsonb, boolean) TO anon, authenticated;


-- Keep the customer's tracking page in sync with the new product-by-product request.
CREATE OR REPLACE FUNCTION public.get_custom_request_by_token(p_token uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_result jsonb;
BEGIN
  IF p_token IS NULL THEN RAISE EXCEPTION 'DEMANDE_INTROUVABLE'; END IF;

  UPDATE public.custom_quotes
  SET status = 'expired', decided_at = now()
  WHERE request_id = (SELECT id FROM public.custom_requests WHERE tracking_token = p_token)
    AND status = 'sent' AND valid_until < current_date;

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
    'estimate_price_dzd', r.estimate_price_dzd,
    'estimate_public_breakdown', public.customer_quote_breakdown(r.estimate_breakdown),
    'estimate_accepted_at', r.estimate_accepted_at,
    'rejection_reason', r.rejection_reason,
    'product_specs', coalesce((
      SELECT jsonb_agg(jsonb_build_object(
        'id', p->>'id',
        'file_name', p->>'file_name',
        'mode', p->>'mode',
        'original_dimensions_mm', p->'original_dimensions_mm',
        'target_dimensions_mm', p->'target_dimensions_mm',
        'quantity', p->'quantity',
        'material_name', p->>'material_name',
        'color', p->>'color',
        'instructions', p->>'instructions'
      ))
      FROM jsonb_array_elements(coalesce(r.product_specs, '[]'::jsonb)) p
    ), '[]'::jsonb),
    'files', coalesce((
      SELECT jsonb_agg(jsonb_build_object(
        'kind', f.kind, 'original_name', f.original_name, 'mime_type', f.mime_type
      ) ORDER BY f.created_at)
      FROM public.custom_request_files f WHERE f.request_id = r.id
    ), '[]'::jsonb),
    'quotes', coalesce((
      SELECT jsonb_agg(jsonb_build_object(
        'version', q.version,
        'public_token', q.public_token,
        'price_dzd', q.price_dzd,
        'production_lead_days', q.production_lead_days,
        'valid_until', q.valid_until,
        'terms', q.terms,
        'status', q.status,
        'source', q.source,
        'breakdown', public.customer_quote_breakdown(q.breakdown),
        'created_at', q.created_at
      ) ORDER BY q.version DESC)
      FROM public.custom_quotes q WHERE q.request_id = r.id
    ), '[]'::jsonb),
    'order_number', (
      SELECT o.order_number
      FROM public.custom_quotes q JOIN public.orders o ON o.id = q.order_id
      WHERE q.request_id = r.id AND q.order_id IS NOT NULL
      LIMIT 1
    )
  ) INTO v_result
  FROM public.custom_requests r
  WHERE r.tracking_token = p_token;

  IF v_result IS NULL THEN RAISE EXCEPTION 'DEMANDE_INTROUVABLE'; END IF;
  RETURN v_result;
END;
$$;

REVOKE EXECUTE ON FUNCTION public.get_custom_request_by_token(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_custom_request_by_token(uuid) TO anon, authenticated;


-- Geometry-aware public estimate. Mesh volume is a client-side measurement of
-- the uploaded mesh and is treated only as an indicative input; the final quote
-- is still checked by the studio and can use slicer/G-code measurements.
CREATE OR REPLACE FUNCTION public.estimate_manufacturing_model(
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
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_rules public.manufacturing_pricing%ROWTYPE;
  v_material public.manufacturing_materials%ROWTYPE;
  v_box_volume_cm3 numeric;
  v_volume_cm3 numeric;
  v_grams numeric;
  v_hours numeric;
  v_full jsonb;
  v_method text := 'bounding_box_heuristic';
BEGIN
  IF p_quantity IS NULL OR p_quantity < 1 OR p_quantity > 100 THEN
    RAISE EXCEPTION 'QUANTITE_PRODUIT_INVALIDE';
  END IF;
  IF p_length_mm IS NULL OR p_width_mm IS NULL OR p_height_mm IS NULL
     OR p_length_mm <= 0 OR p_width_mm <= 0 OR p_height_mm <= 0
     OR p_length_mm > 2000 OR p_width_mm > 2000 OR p_height_mm > 2000 THEN
    RAISE EXCEPTION 'DIMENSIONS_INVALIDES';
  END IF;

  SELECT * INTO v_rules FROM public.manufacturing_pricing WHERE id = true;
  IF NOT FOUND THEN RAISE EXCEPTION 'TARIFICATION_INDISPONIBLE'; END IF;

  SELECT * INTO v_material
  FROM public.manufacturing_materials
  WHERE lower(btrim(name)) = lower(btrim(coalesce(p_material_name, ''))) AND is_available;
  IF NOT FOUND THEN RAISE EXCEPTION 'MATIERE_INDISPONIBLE'; END IF;

  v_box_volume_cm3 := (p_length_mm * p_width_mm * p_height_mm) / 1000.0;
  v_volume_cm3 := v_box_volume_cm3;
  IF p_mesh_volume_cm3 IS NOT NULL
     AND p_mesh_volume_cm3 >= v_box_volume_cm3 * 0.001
     AND p_mesh_volume_cm3 <= v_box_volume_cm3 * 1.05 THEN
    v_volume_cm3 := p_mesh_volume_cm3;
    v_method := 'mesh_volume_heuristic';
  END IF;

  v_grams := greatest(
    v_volume_cm3 * v_rules.effective_volume_percent::numeric / 100
      * v_material.density_g_cm3,
    1
  );
  v_hours := greatest(v_grams / v_rules.print_speed_g_per_hour::numeric, 0.1);

  v_full := public.manufacturing_calculate_full(
    v_material.name, v_grams, v_hours, coalesce(p_quantity, 1),
    coalesce(p_options, '{}'::jsonb), coalesce(p_rush, false)
  );

  RETURN public.customer_quote_breakdown(v_full) || jsonb_build_object(
    'estimates', jsonb_build_object(
      'grams', round(v_grams),
      'printHours', round(v_hours * 10) / 10,
      'method', v_method,
      'meshVolumeCm3', CASE WHEN v_method = 'mesh_volume_heuristic' THEN round(v_volume_cm3, 3) ELSE NULL END,
      'boundingBoxVolumeCm3', round(v_box_volume_cm3, 3),
      'effectiveVolumePercent', v_rules.effective_volume_percent,
      'printSpeedGPerHour', v_rules.print_speed_g_per_hour,
      'densityGPerCm3', v_material.density_g_cm3,
      'geometryVerified', false
    ),
    'material', v_full->>'material'
  );
END;
$$;

REVOKE EXECUTE ON FUNCTION public.estimate_manufacturing_model(numeric, numeric, numeric, numeric, text, integer, jsonb, boolean) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.estimate_manufacturing_model(numeric, numeric, numeric, numeric, text, integer, jsonb, boolean) TO anon, authenticated;



-- ============================================================================
-- SOURCE: 20261116120000_015_profit_analytics.sql
-- ============================================================================

-- 015 — Finance analytics, immutable order cost snapshots and owner expenses.
-- All figures remain estimates unless the owner records verified actual expenses.
-- This migration is code-only until explicitly applied to the Supabase project.

ALTER TABLE public.order_items
  ADD COLUMN IF NOT EXISTS unit_cost_dzd integer,
  ADD COLUMN IF NOT EXISTS cost_status text NOT NULL DEFAULT 'legacy_untracked'
    CHECK (cost_status IN ('complete', 'partial', 'missing', 'not_configured', 'legacy_untracked')),
  ADD COLUMN IF NOT EXISTS cost_snapshot jsonb;

COMMENT ON COLUMN public.order_items.unit_cost_dzd IS
  'Estimated unit production cost frozen when the order item is created; NULL means unavailable.';
COMMENT ON COLUMN public.order_items.cost_snapshot IS
  'Immutable cost inputs and component estimates captured at order creation.';

CREATE OR REPLACE FUNCTION public.snapshot_order_item_cost()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_cost public.product_costs%ROWTYPE;
  v_material_cost integer := 0;
  v_machine_cost integer := 0;
  v_labor_cost integer := 0;
  v_failure_cost integer := 0;
  v_packaging_cost integer := 0;
  v_return_cost integer := 0;
  v_material_price integer;
  v_material_missing boolean := false;
  v_total integer := 0;
BEGIN
  IF NEW.product_id IS NULL THEN
    NEW.unit_cost_dzd := NULL;
    NEW.cost_status := 'not_configured';
    NEW.cost_snapshot := jsonb_build_object(
      'status', 'not_configured',
      'reason', 'Custom production cost must be entered as an order-linked expense.'
    );
    RETURN NEW;
  END IF;

  SELECT * INTO v_cost
  FROM public.product_costs
  WHERE product_id = NEW.product_id;

  IF NOT FOUND THEN
    NEW.unit_cost_dzd := NULL;
    NEW.cost_status := 'missing';
    NEW.cost_snapshot := jsonb_build_object(
      'status', 'missing',
      'reason', 'No product cost sheet existed when this order was created.'
    );
    RETURN NEW;
  END IF;

  IF v_cost.material_id IS NULL THEN
    v_material_missing := true;
  ELSE
    SELECT cost_per_kg_dzd INTO v_material_price
    FROM public.materials
    WHERE id = v_cost.material_id AND is_active;
    IF NOT FOUND THEN
      v_material_missing := true;
    ELSE
      v_material_cost := round(v_material_price::numeric * v_cost.print_grams / 1000.0);
    END IF;
  END IF;

  v_machine_cost := round(v_cost.print_hours * v_cost.machine_hour_rate_dzd);
  v_labor_cost := round(v_cost.labor_minutes / 60.0 * v_cost.labor_hour_rate_dzd);
  v_failure_cost := round(
    (v_material_cost + v_machine_cost + v_labor_cost) * v_cost.failure_rate_pct / 100.0
  );
  v_packaging_cost := v_cost.packaging_dzd;
  v_return_cost := v_cost.return_reserve_dzd;
  v_total := v_material_cost + v_machine_cost + v_labor_cost
    + v_failure_cost + v_packaging_cost + v_return_cost;

  NEW.unit_cost_dzd := v_total;
  NEW.cost_status := CASE WHEN v_material_missing THEN 'partial' ELSE 'complete' END;
  NEW.cost_snapshot := jsonb_build_object(
    'status', CASE WHEN v_material_missing THEN 'partial' ELSE 'complete' END,
    'material_dzd', v_material_cost,
    'machine_dzd', v_machine_cost,
    'labor_dzd', v_labor_cost,
    'failure_dzd', v_failure_cost,
    'packaging_dzd', v_packaging_cost,
    'return_reserve_dzd', v_return_cost,
    'total_dzd', v_total,
    'print_grams', v_cost.print_grams,
    'print_hours', v_cost.print_hours,
    'material_id', v_cost.material_id,
    'material_price_per_kg_dzd', v_material_price,
    'captured_at', now()
  );

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS order_items_cost_snapshot ON public.order_items;
CREATE TRIGGER order_items_cost_snapshot
  BEFORE INSERT ON public.order_items
  FOR EACH ROW EXECUTE FUNCTION public.snapshot_order_item_cost();

ALTER TABLE public.orders
  ADD COLUMN IF NOT EXISTS delivered_at timestamptz;

-- Existing delivered orders use their last known update timestamp as the best
-- available delivery-date approximation; they are not silently discarded.
UPDATE public.orders
SET delivered_at = coalesce(updated_at, created_at, now())
WHERE status = 'delivered' AND delivered_at IS NULL;

CREATE OR REPLACE FUNCTION public.capture_order_delivery_date()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = public
AS $$
BEGIN
  IF NEW.status = 'delivered' AND OLD.status IS DISTINCT FROM NEW.status THEN
    NEW.delivered_at := coalesce(NEW.delivered_at, now());
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS orders_capture_delivered_at ON public.orders;
CREATE TRIGGER orders_capture_delivered_at
  BEFORE UPDATE OF status ON public.orders
  FOR EACH ROW EXECUTE FUNCTION public.capture_order_delivery_date();

CREATE INDEX IF NOT EXISTS idx_orders_delivered_at
  ON public.orders (delivered_at DESC)
  WHERE status = 'delivered';

CREATE TABLE IF NOT EXISTS public.business_expenses (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  category text NOT NULL CHECK (category IN (
    'production', 'shipping', 'marketing', 'rent', 'utilities',
    'maintenance', 'fees', 'salary', 'other'
  )),
  description text NOT NULL CHECK (length(btrim(description)) BETWEEN 2 AND 300),
  amount_dzd integer NOT NULL CHECK (amount_dzd > 0),
  expense_date date NOT NULL DEFAULT current_date,
  order_id uuid REFERENCES public.orders(id) ON DELETE SET NULL,
  created_by uuid REFERENCES auth.users(id) ON DELETE SET NULL DEFAULT auth.uid(),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_business_expenses_date
  ON public.business_expenses (expense_date DESC);
CREATE INDEX IF NOT EXISTS idx_business_expenses_order
  ON public.business_expenses (order_id)
  WHERE order_id IS NOT NULL;

DROP TRIGGER IF EXISTS business_expenses_updated_at ON public.business_expenses;
CREATE TRIGGER business_expenses_updated_at
  BEFORE UPDATE ON public.business_expenses
  FOR EACH ROW EXECUTE FUNCTION public.update_updated_at();

ALTER TABLE public.business_expenses ENABLE ROW LEVEL SECURITY;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.business_expenses TO authenticated;

DROP POLICY IF EXISTS owner_manage_business_expenses ON public.business_expenses;
CREATE POLICY owner_manage_business_expenses ON public.business_expenses
  FOR ALL TO authenticated
  USING (public.is_owner())
  WITH CHECK (public.is_owner());

COMMENT ON TABLE public.business_expenses IS
  'Owner-entered operating expenses and custom-order production costs. Do not duplicate costs already included in product cost snapshots.';



-- ============================================================================
-- SOURCE: 20261116140000_016_security_financial_accuracy_hardening.sql
-- ============================================================================

-- 016 — Security hardening for privileged routines.
-- Keep trusted schemas before pg_temp: SECURITY DEFINER functions must never
-- resolve attacker-created temporary relations ahead of application tables.

-- Client roles need object access through grants/RLS, never CREATE in public.
REVOKE CREATE ON SCHEMA public FROM PUBLIC, anon, authenticated;

-- Future functions created by postgres migrations must be explicitly granted.
ALTER DEFAULT PRIVILEGES FOR ROLE postgres REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres REVOKE EXECUTE ON FUNCTIONS FROM anon, authenticated;

ALTER FUNCTION public.handle_new_user()
  SET search_path = pg_catalog, public, pg_temp;
ALTER FUNCTION public.is_owner()
  SET search_path = pg_catalog, public, pg_temp;
ALTER FUNCTION public.prevent_role_change()
  SET search_path = pg_catalog, public, pg_temp;
ALTER FUNCTION public.quote_delivery(smallint, uuid, text)
  SET search_path = pg_catalog, public, pg_temp;
ALTER FUNCTION public.create_guest_order(jsonb)
  SET search_path = pg_catalog, public, pg_temp;
ALTER FUNCTION public.track_order(text, text)
  SET search_path = pg_catalog, public, pg_temp;
ALTER FUNCTION public.get_order_by_token(uuid)
  SET search_path = pg_catalog, public, pg_temp;
ALTER FUNCTION public.set_order_status(uuid, text)
  SET search_path = pg_catalog, public, pg_temp;
ALTER FUNCTION public.create_custom_request(jsonb)
  SET search_path = pg_catalog, public, pg_temp;
ALTER FUNCTION public.get_custom_request_by_token(uuid)
  SET search_path = pg_catalog, public, pg_temp;
ALTER FUNCTION public.create_custom_quote(uuid, integer, integer, date, text)
  SET search_path = pg_catalog, public, pg_temp;
ALTER FUNCTION public.set_custom_request_status(uuid, text)
  SET search_path = pg_catalog, public, pg_temp;
ALTER FUNCTION public.product_cost_estimate(uuid)
  SET search_path = pg_catalog, public, pg_temp;
ALTER FUNCTION public.audit_row()
  SET search_path = pg_catalog, public, pg_temp;
ALTER FUNCTION public.log_owner_event(text, jsonb)
  SET search_path = pg_catalog, public, pg_temp;
ALTER FUNCTION public.quote_custom_manufacturing(uuid, text, numeric, numeric, jsonb, boolean)
  SET search_path = pg_catalog, public, pg_temp;
ALTER FUNCTION public.decide_custom_quote(uuid, text, jsonb)
  SET search_path = pg_catalog, public, pg_temp;
ALTER FUNCTION public.guard_custom_request_status()
  SET search_path = pg_catalog, public, pg_temp;
ALTER FUNCTION public.delete_order(uuid, text)
  SET search_path = pg_catalog, public, pg_temp;
ALTER FUNCTION public.estimate_manufacturing_quote(text, numeric, numeric, integer, jsonb, boolean)
  SET search_path = pg_catalog, public, pg_temp;
ALTER FUNCTION public.expire_previous_custom_quotes()
  SET search_path = pg_catalog, public, pg_temp;
ALTER FUNCTION public.manufacturing_calculate_full(text, numeric, numeric, integer, jsonb, boolean)
  SET search_path = pg_catalog, public, pg_temp;
ALTER FUNCTION public.estimate_manufacturing_dimensions(numeric, numeric, numeric, text, integer, jsonb, boolean)
  SET search_path = pg_catalog, public, pg_temp;
ALTER FUNCTION public.create_custom_quote_from_estimate(uuid, text, date)
  SET search_path = pg_catalog, public, pg_temp;
ALTER FUNCTION public.owner_approve_custom_request(uuid, text)
  SET search_path = pg_catalog, public, pg_temp;
ALTER FUNCTION public.owner_reject_custom_request(uuid, text)
  SET search_path = pg_catalog, public, pg_temp;
ALTER FUNCTION public.delete_delivered_order(uuid, text)
  SET search_path = pg_catalog, public, pg_temp;
ALTER FUNCTION public.prevent_quote_during_request_deletion()
  SET search_path = pg_catalog, public, pg_temp;
ALTER FUNCTION public.prevent_request_mutation_during_deletion()
  SET search_path = pg_catalog, public, pg_temp;
ALTER FUNCTION public.begin_custom_request_deletion(uuid)
  SET search_path = pg_catalog, public, pg_temp;
ALTER FUNCTION public.finish_custom_request_deletion(uuid, uuid, text[])
  SET search_path = pg_catalog, public, pg_temp;
ALTER FUNCTION public.owner_dashboard_stats()
  SET search_path = pg_catalog, public, pg_temp;
ALTER FUNCTION public.notify_owner_new_order()
  SET search_path = pg_catalog, public, pg_temp;
ALTER FUNCTION public.notify_owner_new_custom_request()
  SET search_path = pg_catalog, public, pg_temp;
ALTER FUNCTION public.save_custom_request_products(uuid, jsonb, jsonb, boolean)
  SET search_path = pg_catalog, public, pg_temp;
ALTER FUNCTION public.estimate_manufacturing_model(numeric, numeric, numeric, numeric, text, integer, jsonb, boolean)
  SET search_path = pg_catalog, public, pg_temp;
ALTER FUNCTION public.snapshot_order_item_cost()
  SET search_path = pg_catalog, public, pg_temp;
ALTER FUNCTION public.update_updated_at()
  SET search_path = pg_catalog, public, pg_temp;
ALTER FUNCTION public.next_order_number()
  SET search_path = pg_catalog, public, pg_temp;
ALTER FUNCTION public.customer_quote_breakdown(jsonb)
  SET search_path = pg_catalog, public, pg_temp;

-- The old trigger checked current_user from inside SECURITY DEFINER. In that
-- context current_user is the function owner, so the check could never reliably
-- distinguish a client request. auth.uid() is the caller identity in Supabase.
CREATE OR REPLACE FUNCTION public.prevent_role_change()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, pg_temp
AS $$
BEGIN
  IF NEW.role IS DISTINCT FROM OLD.role AND auth.uid() IS NOT NULL THEN
    RAISE EXCEPTION 'Le rôle du profil ne peut pas être modifié depuis le client.';
  END IF;
  RETURN NEW;
END;
$$;

COMMENT ON FUNCTION public.prevent_role_change() IS
  'Blocks profile role changes whenever a Supabase end-user identity is present; privileged database maintenance without auth.uid() remains possible.';

