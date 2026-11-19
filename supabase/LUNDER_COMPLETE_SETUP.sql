-- =============================================================================
-- LUNDER COMPLETE SUPABASE SETUP
-- =============================================================================
-- Purpose: Bootstrap a BRAND-NEW, EMPTY Supabase project from the repository's
-- ordered migrations. This is a convenience bundle; the original migration
-- files remain the canonical, versioned source of truth.
--
-- IMPORTANT:
-- 1. Run this ONCE only in the SQL Editor of a newly-created empty Supabase
--    project. Do NOT run it on an existing/production database.
-- 2. This script does NOT insert rows into supabase_migrations.schema_migrations.
--    It is a manual bootstrap, not a replacement for the Supabase CLI migration
--    history. Do not later run the same migrations through CLI on this database
--    without reconciling migration history first.
-- 3. Supabase-managed schemas/roles (auth, storage, anon, authenticated,
--    service_role) must exist. Run in Supabase SQL Editor with project-owner
--    privileges.
-- 4. The original SQL statements are preserved in timestamp order. Each source
--    migration is marked below. No application schema is dropped by this bundle.
-- 5. Review project-specific Auth, Storage, API exposure and environment
--    settings separately after database bootstrap.
--
-- Source repository: lunderclub9-gif/lunder-printe
-- Source branch at bundle creation: main
-- Source migration count: 31
-- =============================================================================



-- >>> BEGIN CONSOLIDATED MIGRATIONS 001–008



-- ============================================================================
-- SOURCE: 20261112190919_001_lunders_catalog_and_auth.sql
-- ============================================================================

/*
# Lunder's 3D Studio — Catalog, Media, and Owner Auth Foundation

## Overview
Creates the foundational schema for Lunder's 3D Studio: owner authentication
via Supabase Auth with a profiles table for role assignment, plus the product
catalog (categories, products, product images) and Supabase Storage buckets
for product photos and 3D models.

## New Tables
1. profiles — links to auth.users, role column (owner/customer)
2. categories — product categories with slug
3. products — full product model with DZD pricing, status, 3D model URL
4. product_images — gallery images per product

## Security
- profiles: RLS, authenticated can read all, update own. Role escalation prevented.
- categories: public read for active, owner-only write.
- products: public read for published only, owner-only write.
- product_images: public read through published products, owner-only write.
- Storage buckets: public read, owner-only write.

## Important Notes
1. Owner role assigned by direct DB update — no public UI.
2. Prices are integer DZD (whole dinars).
3. status field: draft/published/archived.
4. Production lead time separate from delivery time.
*/

-- ─── PROFILES ──────────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS profiles (
  id uuid PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  role text NOT NULL DEFAULT 'customer' CHECK (role IN ('owner', 'customer')),
  full_name text,
  created_at timestamptz DEFAULT now()
);

ALTER TABLE profiles ENABLE ROW LEVEL SECURITY;

GRANT SELECT, UPDATE ON profiles TO authenticated;

DROP POLICY IF EXISTS "select_profiles" ON profiles;
CREATE POLICY "select_profiles" ON profiles FOR SELECT
  TO authenticated USING (true);

DROP POLICY IF EXISTS "update_own_profile" ON profiles;
CREATE POLICY "update_own_profile" ON profiles FOR UPDATE
  TO authenticated USING (auth.uid() = id) WITH CHECK (auth.uid() = id);

-- ─── CATEGORIES ────────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS categories (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name text NOT NULL,
  slug text UNIQUE NOT NULL,
  description text,
  sort_order integer NOT NULL DEFAULT 0,
  is_active boolean NOT NULL DEFAULT true,
  created_at timestamptz DEFAULT now()
);

ALTER TABLE categories ENABLE ROW LEVEL SECURITY;

GRANT SELECT ON categories TO anon, authenticated;
GRANT INSERT, UPDATE, DELETE ON categories TO authenticated;

DROP POLICY IF EXISTS "public_read_categories" ON categories;
CREATE POLICY "public_read_categories" ON categories FOR SELECT
  TO anon, authenticated USING (is_active = true);

DROP POLICY IF EXISTS "owner_insert_categories" ON categories;
CREATE POLICY "owner_insert_categories" ON categories FOR INSERT
  TO authenticated WITH CHECK (EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid() AND role = 'owner'));

DROP POLICY IF EXISTS "owner_update_categories" ON categories;
CREATE POLICY "owner_update_categories" ON categories FOR UPDATE
  TO authenticated USING (EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid() AND role = 'owner'))
  WITH CHECK (EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid() AND role = 'owner'));

DROP POLICY IF EXISTS "owner_delete_categories" ON categories;
CREATE POLICY "owner_delete_categories" ON categories FOR DELETE
  TO authenticated USING (EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid() AND role = 'owner'));

-- ─── PRODUCTS ──────────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS products (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name text NOT NULL,
  slug text UNIQUE NOT NULL,
  description text,
  category_id uuid REFERENCES categories(id) ON DELETE SET NULL,
  sku text UNIQUE NOT NULL,
  price_dzd integer NOT NULL CHECK (price_dzd >= 0),
  stock_quantity integer NOT NULL DEFAULT 0 CHECK (stock_quantity >= 0),
  made_to_order boolean NOT NULL DEFAULT false,
  production_lead_days integer,
  weight_g numeric,
  dimensions text,
  material text,
  available_colors text[] DEFAULT '{}',
  model_url text,
  status text NOT NULL DEFAULT 'draft' CHECK (status IN ('draft', 'published', 'archived')),
  is_featured boolean NOT NULL DEFAULT false,
  seo_title text,
  seo_description text,
  created_at timestamptz DEFAULT now(),
  updated_at timestamptz DEFAULT now()
);

ALTER TABLE products ENABLE ROW LEVEL SECURITY;

GRANT SELECT ON products TO anon, authenticated;
GRANT INSERT, UPDATE, DELETE ON products TO authenticated;

CREATE INDEX IF NOT EXISTS idx_products_category ON products(category_id);
CREATE INDEX IF NOT EXISTS idx_products_status ON products(status);

DROP POLICY IF EXISTS "public_read_products" ON products;
CREATE POLICY "public_read_products" ON products FOR SELECT
  TO anon, authenticated USING (status = 'published');

DROP POLICY IF EXISTS "owner_insert_products" ON products;
CREATE POLICY "owner_insert_products" ON products FOR INSERT
  TO authenticated WITH CHECK (EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid() AND role = 'owner'));

DROP POLICY IF EXISTS "owner_update_products" ON products;
CREATE POLICY "owner_update_products" ON products FOR UPDATE
  TO authenticated USING (EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid() AND role = 'owner'))
  WITH CHECK (EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid() AND role = 'owner'));

DROP POLICY IF EXISTS "owner_delete_products" ON products;
CREATE POLICY "owner_delete_products" ON products FOR DELETE
  TO authenticated USING (EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid() AND role = 'owner'));

-- ─── PRODUCT IMAGES ────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS product_images (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  product_id uuid NOT NULL REFERENCES products(id) ON DELETE CASCADE,
  image_url text NOT NULL,
  alt_text text,
  sort_order integer NOT NULL DEFAULT 0,
  is_primary boolean NOT NULL DEFAULT false,
  created_at timestamptz DEFAULT now()
);

ALTER TABLE product_images ENABLE ROW LEVEL SECURITY;

GRANT SELECT ON product_images TO anon, authenticated;
GRANT INSERT, UPDATE, DELETE ON product_images TO authenticated;

CREATE INDEX IF NOT EXISTS idx_product_images_product ON product_images(product_id);

DROP POLICY IF EXISTS "public_read_product_images" ON product_images;
CREATE POLICY "public_read_product_images" ON product_images FOR SELECT
  TO anon, authenticated USING (
    EXISTS (SELECT 1 FROM products WHERE products.id = product_images.product_id AND products.status = 'published')
  );

DROP POLICY IF EXISTS "owner_insert_product_images" ON product_images;
CREATE POLICY "owner_insert_product_images" ON product_images FOR INSERT
  TO authenticated WITH CHECK (EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid() AND role = 'owner'));

DROP POLICY IF EXISTS "owner_update_product_images" ON product_images;
CREATE POLICY "owner_update_product_images" ON product_images FOR UPDATE
  TO authenticated USING (EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid() AND role = 'owner'))
  WITH CHECK (EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid() AND role = 'owner'));

DROP POLICY IF EXISTS "owner_delete_product_images" ON product_images;
CREATE POLICY "owner_delete_product_images" ON product_images FOR DELETE
  TO authenticated USING (EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid() AND role = 'owner'));

-- ─── AUTO-CREATE PROFILE ON SIGNUP ─────────────────────────────────────────

CREATE OR REPLACE FUNCTION public.handle_new_user()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  INSERT INTO public.profiles (id, role, full_name)
  VALUES (NEW.id, 'customer', NEW.raw_user_meta_data->>'name')
  ON CONFLICT (id) DO NOTHING;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS on_auth_user_created ON auth.users;
CREATE TRIGGER on_auth_user_created
  AFTER INSERT ON auth.users
  FOR EACH ROW EXECUTE FUNCTION public.handle_new_user();

REVOKE EXECUTE ON FUNCTION public.handle_new_user() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.handle_new_user() TO authenticated;

-- ─── UPDATE updated_at ON PRODUCTS ─────────────────────────────────────────

CREATE OR REPLACE FUNCTION public.update_updated_at()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS products_updated_at ON products;
CREATE TRIGGER products_updated_at
  BEFORE UPDATE ON products
  FOR EACH ROW EXECUTE FUNCTION public.update_updated_at();

-- ─── STORAGE BUCKETS ───────────────────────────────────────────────────────

INSERT INTO storage.buckets (id, name, public) VALUES ('product-images', 'product-images', true)
  ON CONFLICT (id) DO NOTHING;
INSERT INTO storage.buckets (id, name, public) VALUES ('product-models', 'product-models', true)
  ON CONFLICT (id) DO NOTHING;

DROP POLICY IF EXISTS "public_read_product_storage" ON storage.objects;
CREATE POLICY "public_read_product_storage" ON storage.objects FOR SELECT
  TO anon, authenticated USING (bucket_id IN ('product-images', 'product-models'));

DROP POLICY IF EXISTS "owner_insert_product_storage" ON storage.objects;
CREATE POLICY "owner_insert_product_storage" ON storage.objects FOR INSERT
  TO authenticated WITH CHECK (
    bucket_id IN ('product-images', 'product-models') AND
    EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid() AND role = 'owner')
  );

DROP POLICY IF EXISTS "owner_update_product_storage" ON storage.objects;
CREATE POLICY "owner_update_product_storage" ON storage.objects FOR UPDATE
  TO authenticated USING (
    bucket_id IN ('product-images', 'product-models') AND
    EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid() AND role = 'owner')
  );

DROP POLICY IF EXISTS "owner_delete_product_storage" ON storage.objects;
CREATE POLICY "owner_delete_product_storage" ON storage.objects FOR DELETE
  TO authenticated USING (
    bucket_id IN ('product-images', 'product-models') AND
    EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid() AND role = 'owner')
  );


-- ============================================================================
-- SOURCE: 20261112193000_002_owner_access_and_profile_hardening.sql
-- ============================================================================

/*
# Lunder's 3D Studio — Owner access hardening (Phase 1)

## Why
Two defects were found in the Phase 0 audit:

1. CRITICAL — privilege escalation. `profiles` was granted table-wide UPDATE to
   `authenticated`, and the row policy only checked `auth.uid() = id`. RLS cannot
   restrict columns, so any signed-up user could run
   `UPDATE profiles SET role = 'owner' WHERE id = auth.uid()` and take over the
   store. The fix revokes the table-wide UPDATE and re-grants UPDATE on
   `full_name` only, so `role` can no longer be written by a client.

2. HIGH — the owner could not read their own back office data. The only SELECT
   policies on products / categories / product_images were the public ones
   (`status = 'published'`, `is_active = true`), so drafts and archived products
   were invisible in /admin and the dashboard counters reported 0.

## Changes
- New helper `public.is_owner()` (SECURITY DEFINER, STABLE) for owner checks.
- profiles: SELECT limited to own row or owner; UPDATE restricted to `full_name`.
- products / categories / product_images: added owner SELECT policies.
  Permissive policies are OR-ed, so public reads are unchanged.

## Notes
- No table, column or row is dropped. Existing RLS write policies are untouched.
- Owner role is still assigned out of band (no public UI), as before.
*/

-- ─── OWNER HELPER ──────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION public.is_owner()
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.profiles
    WHERE id = auth.uid() AND role = 'owner'
  );
$$;

REVOKE EXECUTE ON FUNCTION public.is_owner() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.is_owner() TO anon, authenticated;

-- ─── PROFILES: STOP ROLE ESCALATION ────────────────────────────────────────

-- Table-wide UPDATE let a client write `role`. Only `full_name` is user-editable.
REVOKE INSERT, UPDATE, DELETE ON profiles FROM anon, authenticated;
GRANT UPDATE (full_name) ON profiles TO authenticated;

DROP POLICY IF EXISTS "select_profiles" ON profiles;
DROP POLICY IF EXISTS "select_own_or_owner_profile" ON profiles;
CREATE POLICY "select_own_or_owner_profile" ON profiles FOR SELECT
  TO authenticated USING (auth.uid() = id OR public.is_owner());

DROP POLICY IF EXISTS "update_own_profile" ON profiles;
CREATE POLICY "update_own_profile" ON profiles FOR UPDATE
  TO authenticated
  USING (auth.uid() = id)
  WITH CHECK (auth.uid() = id);

-- Defence in depth: even a future grant change cannot flip a role from a client.
CREATE OR REPLACE FUNCTION public.prevent_role_change()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NEW.role IS DISTINCT FROM OLD.role
     AND current_user NOT IN ('postgres', 'supabase_admin', 'service_role', 'supabase_auth_admin') THEN
    RAISE EXCEPTION 'Le rôle du profil ne peut pas être modifié depuis le client.';
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS profiles_prevent_role_change ON profiles;
CREATE TRIGGER profiles_prevent_role_change
  BEFORE UPDATE ON profiles
  FOR EACH ROW EXECUTE FUNCTION public.prevent_role_change();

-- Une fonction de trigger ne peut pas être appelée directement ; on garde donc
-- EXECUTE pour `authenticated` afin de ne dépendre d'aucun cas particulier de
-- vérification de privilège au moment du déclenchement.
REVOKE EXECUTE ON FUNCTION public.prevent_role_change() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.prevent_role_change() TO authenticated;

-- ─── OWNER READ ACCESS (BACK OFFICE) ───────────────────────────────────────

DROP POLICY IF EXISTS "owner_read_products" ON products;
CREATE POLICY "owner_read_products" ON products FOR SELECT
  TO authenticated USING (public.is_owner());

DROP POLICY IF EXISTS "owner_read_categories" ON categories;
CREATE POLICY "owner_read_categories" ON categories FOR SELECT
  TO authenticated USING (public.is_owner());

DROP POLICY IF EXISTS "owner_read_product_images" ON product_images;
CREATE POLICY "owner_read_product_images" ON product_images FOR SELECT
  TO authenticated USING (public.is_owner());



-- ============================================================================
-- SOURCE: 20261112200000_003_catalog_variants_and_media_limits.sql
-- ============================================================================

/*
# Lunder's 3D Studio — Catalog variants and media limits (Phase 2)

## Why
Phase 0 found that product media accepted any file (extension taken from the
filename, no type/size/content check) and that the only product "option" was a
free-text `available_colors` array, which cannot express real manufacturable
combinations.

## Changes
1. Storage: hard limits on both buckets, enforced by the Storage API (not the
   browser). Images: 5 MiB, JPEG/PNG/WebP/AVIF. Models: 25 MiB,
   glTF binary/JSON.
2. New tables for explicit variants:
   - product_options        — e.g. « Couleur », « Taille »
   - product_option_values  — e.g. « Rouge », « 12 cm »
   - product_variants       — one real, manufacturable combination
   - product_variant_values — which option values a variant is made of
   Combinations are created by the owner, one row per combination. Nothing is
   generated by cartesian product.
3. RLS: public read only through a published product; owner-only writes;
   owner read of everything (needed by the back office).

## Depends on
Migration 002 (`public.is_owner()`).

## Notes
- No existing table, column or data is dropped. `products.available_colors`
  stays for backwards compatibility and is ignored when options exist.
- `product_variants.made_to_order = NULL` means "inherit the parent product".
- Duplicate combinations are blocked in the admin UI; there is no DB-level
  combination key yet (documented as a remaining limitation).
*/

-- ─── STORAGE LIMITS (SERVER-ENFORCED) ──────────────────────────────────────

UPDATE storage.buckets
SET file_size_limit = 5242880,
    allowed_mime_types = ARRAY['image/jpeg', 'image/png', 'image/webp', 'image/avif']
WHERE id = 'product-images';

UPDATE storage.buckets
SET file_size_limit = 26214400,
    allowed_mime_types = ARRAY['model/gltf-binary', 'model/gltf+json', 'application/octet-stream']
WHERE id = 'product-models';

-- ─── PRODUCT OPTIONS ───────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS product_options (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  product_id uuid NOT NULL REFERENCES products(id) ON DELETE CASCADE,
  name text NOT NULL CHECK (length(btrim(name)) BETWEEN 1 AND 60),
  sort_order integer NOT NULL DEFAULT 0,
  created_at timestamptz DEFAULT now(),
  UNIQUE (product_id, name)
);

CREATE TABLE IF NOT EXISTS product_option_values (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  option_id uuid NOT NULL REFERENCES product_options(id) ON DELETE CASCADE,
  value text NOT NULL CHECK (length(btrim(value)) BETWEEN 1 AND 60),
  price_delta_dzd integer NOT NULL DEFAULT 0,
  sort_order integer NOT NULL DEFAULT 0,
  is_active boolean NOT NULL DEFAULT true,
  created_at timestamptz DEFAULT now(),
  UNIQUE (option_id, value)
);

CREATE TABLE IF NOT EXISTS product_variants (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  product_id uuid NOT NULL REFERENCES products(id) ON DELETE CASCADE,
  sku text UNIQUE,
  label text,
  price_dzd integer CHECK (price_dzd IS NULL OR price_dzd >= 0),
  stock_quantity integer NOT NULL DEFAULT 0 CHECK (stock_quantity >= 0),
  made_to_order boolean,
  is_active boolean NOT NULL DEFAULT true,
  created_at timestamptz DEFAULT now(),
  updated_at timestamptz DEFAULT now()
);

CREATE TABLE IF NOT EXISTS product_variant_values (
  variant_id uuid NOT NULL REFERENCES product_variants(id) ON DELETE CASCADE,
  option_value_id uuid NOT NULL REFERENCES product_option_values(id) ON DELETE CASCADE,
  PRIMARY KEY (variant_id, option_value_id)
);

CREATE INDEX IF NOT EXISTS idx_product_options_product ON product_options(product_id);
CREATE INDEX IF NOT EXISTS idx_product_option_values_option ON product_option_values(option_id);
CREATE INDEX IF NOT EXISTS idx_product_variants_product ON product_variants(product_id);
CREATE INDEX IF NOT EXISTS idx_product_variant_values_value ON product_variant_values(option_value_id);

DROP TRIGGER IF EXISTS product_variants_updated_at ON product_variants;
CREATE TRIGGER product_variants_updated_at
  BEFORE UPDATE ON product_variants
  FOR EACH ROW EXECUTE FUNCTION public.update_updated_at();

-- ─── RLS ───────────────────────────────────────────────────────────────────

ALTER TABLE product_options ENABLE ROW LEVEL SECURITY;
ALTER TABLE product_option_values ENABLE ROW LEVEL SECURITY;
ALTER TABLE product_variants ENABLE ROW LEVEL SECURITY;
ALTER TABLE product_variant_values ENABLE ROW LEVEL SECURITY;

GRANT SELECT ON product_options, product_option_values, product_variants, product_variant_values TO anon, authenticated;
GRANT INSERT, UPDATE, DELETE ON product_options, product_option_values, product_variants, product_variant_values TO authenticated;

-- Options: visible with a published product, or to the owner.
DROP POLICY IF EXISTS "public_read_product_options" ON product_options;
CREATE POLICY "public_read_product_options" ON product_options FOR SELECT
  TO anon, authenticated USING (
    EXISTS (SELECT 1 FROM products WHERE products.id = product_options.product_id AND products.status = 'published')
  );

DROP POLICY IF EXISTS "owner_read_product_options" ON product_options;
CREATE POLICY "owner_read_product_options" ON product_options FOR SELECT
  TO authenticated USING (public.is_owner());

DROP POLICY IF EXISTS "owner_write_product_options" ON product_options;
CREATE POLICY "owner_write_product_options" ON product_options FOR ALL
  TO authenticated USING (public.is_owner()) WITH CHECK (public.is_owner());

-- Option values.
DROP POLICY IF EXISTS "public_read_product_option_values" ON product_option_values;
CREATE POLICY "public_read_product_option_values" ON product_option_values FOR SELECT
  TO anon, authenticated USING (
    is_active = true AND EXISTS (
      SELECT 1 FROM product_options
      JOIN products ON products.id = product_options.product_id
      WHERE product_options.id = product_option_values.option_id AND products.status = 'published'
    )
  );

DROP POLICY IF EXISTS "owner_read_product_option_values" ON product_option_values;
CREATE POLICY "owner_read_product_option_values" ON product_option_values FOR SELECT
  TO authenticated USING (public.is_owner());

DROP POLICY IF EXISTS "owner_write_product_option_values" ON product_option_values;
CREATE POLICY "owner_write_product_option_values" ON product_option_values FOR ALL
  TO authenticated USING (public.is_owner()) WITH CHECK (public.is_owner());

-- Variants.
DROP POLICY IF EXISTS "public_read_product_variants" ON product_variants;
CREATE POLICY "public_read_product_variants" ON product_variants FOR SELECT
  TO anon, authenticated USING (
    is_active = true AND EXISTS (
      SELECT 1 FROM products WHERE products.id = product_variants.product_id AND products.status = 'published'
    )
  );

DROP POLICY IF EXISTS "owner_read_product_variants" ON product_variants;
CREATE POLICY "owner_read_product_variants" ON product_variants FOR SELECT
  TO authenticated USING (public.is_owner());

DROP POLICY IF EXISTS "owner_write_product_variants" ON product_variants;
CREATE POLICY "owner_write_product_variants" ON product_variants FOR ALL
  TO authenticated USING (public.is_owner()) WITH CHECK (public.is_owner());

-- Variant ↔ option value links.
DROP POLICY IF EXISTS "public_read_product_variant_values" ON product_variant_values;
CREATE POLICY "public_read_product_variant_values" ON product_variant_values FOR SELECT
  TO anon, authenticated USING (
    EXISTS (
      SELECT 1 FROM product_variants
      JOIN products ON products.id = product_variants.product_id
      WHERE product_variants.id = product_variant_values.variant_id
        AND product_variants.is_active = true
        AND products.status = 'published'
    )
  );

DROP POLICY IF EXISTS "owner_read_product_variant_values" ON product_variant_values;
CREATE POLICY "owner_read_product_variant_values" ON product_variant_values FOR SELECT
  TO authenticated USING (public.is_owner());

DROP POLICY IF EXISTS "owner_write_product_variant_values" ON product_variant_values;
CREATE POLICY "owner_write_product_variant_values" ON product_variant_values FOR ALL
  TO authenticated USING (public.is_owner()) WITH CHECK (public.is_owner());



-- ============================================================================
-- SOURCE: 20261112210000_004_algeria_geography.sql
-- ============================================================================

/*
# Lunder's 3D Studio — Algeria geography (Phase 3)

## Dataset provenance (required by the specification)
- Source: "Algeria wilayas & communes" dataset, https://github.com/el-amin-dev/algeria-wilayas-communes
  (data/wilayas.json and data/communes.json), retrieved 2026-11-12.
- Legal structure: Loi n° 26-06 du 4 avril 2026 (Journal officiel n° 25 du 5 avril 2026),
  which sets Algeria's territorial division at 69 wilayas and 1 541 communes.
  Names/numbers of wilayas 59-69 fixed by décret présidentiel n° 26-206 du 25 mai 2026 (JO n° 40).
- Counts in this file: 69 wilayas, 1541 communes.

## Important
- Wilayas 59-69 are legally in force but administratively in transition until
  31 December 2026 (the mother wilayas still handle day-to-day management).
  They are seeded and can be disabled individually by the owner; no wilaya count
  is hardcoded anywhere in application or validation logic.
- Geography availability is NOT carrier coverage. Actual service is defined only by
  delivery_rates / pickup_points rows the owner configures (migration 005).
  Nothing here claims that any carrier serves any commune.
- No delivery price, transit time or pickup point is seeded: those are owner data.
*/

-- ─── WILAYAS ───────────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS wilayas (
  code smallint PRIMARY KEY,
  name_fr text NOT NULL,
  name_ar text,
  is_active boolean NOT NULL DEFAULT true,
  created_at timestamptz DEFAULT now()
);

ALTER TABLE wilayas ENABLE ROW LEVEL SECURITY;
GRANT SELECT ON wilayas TO anon, authenticated;
GRANT INSERT, UPDATE, DELETE ON wilayas TO authenticated;

DROP POLICY IF EXISTS "public_read_wilayas" ON wilayas;
CREATE POLICY "public_read_wilayas" ON wilayas FOR SELECT
  TO anon, authenticated USING (is_active = true);

DROP POLICY IF EXISTS "owner_read_wilayas" ON wilayas;
CREATE POLICY "owner_read_wilayas" ON wilayas FOR SELECT
  TO authenticated USING (public.is_owner());

DROP POLICY IF EXISTS "owner_write_wilayas" ON wilayas;
CREATE POLICY "owner_write_wilayas" ON wilayas FOR ALL
  TO authenticated USING (public.is_owner()) WITH CHECK (public.is_owner());

-- ─── COMMUNES ──────────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS communes (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  wilaya_code smallint NOT NULL REFERENCES wilayas(code) ON DELETE CASCADE,
  name_fr text NOT NULL,
  name_ar text,
  postal_code text,
  is_active boolean NOT NULL DEFAULT true,
  created_at timestamptz DEFAULT now(),
  UNIQUE (wilaya_code, name_fr)
);

CREATE INDEX IF NOT EXISTS idx_communes_wilaya ON communes(wilaya_code);

ALTER TABLE communes ENABLE ROW LEVEL SECURITY;
GRANT SELECT ON communes TO anon, authenticated;
GRANT INSERT, UPDATE, DELETE ON communes TO authenticated;

DROP POLICY IF EXISTS "public_read_communes" ON communes;
CREATE POLICY "public_read_communes" ON communes FOR SELECT
  TO anon, authenticated USING (is_active = true);

DROP POLICY IF EXISTS "owner_read_communes" ON communes;
CREATE POLICY "owner_read_communes" ON communes FOR SELECT
  TO authenticated USING (public.is_owner());

DROP POLICY IF EXISTS "owner_write_communes" ON communes;
CREATE POLICY "owner_write_communes" ON communes FOR ALL
  TO authenticated USING (public.is_owner()) WITH CHECK (public.is_owner());

-- ─── SEED: WILAYAS ─────────────────────────────────────────────────────────

INSERT INTO wilayas (code, name_fr, name_ar) VALUES
  (1, 'Adrar', 'أدرار'),
  (2, 'Chlef', 'الشلف'),
  (3, 'Laghouat', 'الأغواط'),
  (4, 'Oum El Bouaghi', 'أم البواقي'),
  (5, 'Batna', 'باتنة'),
  (6, 'Bejaia', 'بجاية'),
  (7, 'Biskra', 'بسكرة'),
  (8, 'Bechar', 'بشار'),
  (9, 'Blida', 'البليدة'),
  (10, 'Bouira', 'البويرة'),
  (11, 'Tamanrasset', 'تمنراست'),
  (12, 'Tebessa', 'تبسة'),
  (13, 'Tlemcen', 'تلمسان'),
  (14, 'Tiaret', 'تيارت'),
  (15, 'Tizi Ouzou', 'تيزي وزو'),
  (16, 'Alger', 'الجزائر'),
  (17, 'Djelfa', 'الجلفة'),
  (18, 'Jijel', 'جيجل'),
  (19, 'Setif', 'سطيف'),
  (20, 'Saida', 'سعيدة'),
  (21, 'Skikda', 'سكيكدة'),
  (22, 'Sidi Bel Abbes', 'سيدي بلعباس'),
  (23, 'Annaba', 'عنابة'),
  (24, 'Guelma', 'قالمة'),
  (25, 'Constantine', 'قسنطينة'),
  (26, 'Medea', 'المدية'),
  (27, 'Mostaganem', 'مستغانم'),
  (28, 'M''Sila', 'المسيلة'),
  (29, 'Mascara', 'معسكر'),
  (30, 'Ouargla', 'ورقلة'),
  (31, 'Oran', 'وهران'),
  (32, 'El Bayadh', 'البيض'),
  (33, 'Illizi', 'إليزي'),
  (34, 'Bordj Bou Arreridj', 'برج بوعريريج'),
  (35, 'Boumerdes', 'بومرداس'),
  (36, 'El Tarf', 'الطارف'),
  (37, 'Tindouf', 'تندوف'),
  (38, 'Tissemsilt', 'تيسمسيلت'),
  (39, 'El Oued', 'الوادي'),
  (40, 'Khenchela', 'خنشلة'),
  (41, 'Souk Ahras', 'سوق أهراس'),
  (42, 'Tipaza', 'تيبازة'),
  (43, 'Mila', 'ميلة'),
  (44, 'Ain Defla', 'عين الدفلى'),
  (45, 'Naama', 'النعامة'),
  (46, 'Ain Temouchent', 'عين تموشنت'),
  (47, 'Ghardaia', 'غرداية'),
  (48, 'Relizane', 'غليزان'),
  (49, 'Timimoun', 'تيميمون'),
  (50, 'Bordj Badji Mokhtar', 'برج باجي مختار'),
  (51, 'Ouled Djellal', 'أولاد جلال'),
  (52, 'Beni Abbes', 'بني عباس'),
  (53, 'In Salah', 'عين صالح'),
  (54, 'In Guezzam', 'عين قزام'),
  (55, 'Touggourt', 'تقرت'),
  (56, 'Djanet', 'جانت'),
  (57, 'El M''Ghair', 'المغير'),
  (58, 'El Meniaa', 'المنيعة'),
  (59, 'Aflou', 'أفلو'),
  (60, 'El Abiodh Sidi Cheikh', 'الأبيض سيدي الشيخ'),
  (61, 'El Aricha', 'العريشة'),
  (62, 'El Kantara', 'القنطرة'),
  (63, 'Barika', 'بريكة'),
  (64, 'Bou Saada', 'بوسعادة'),
  (65, 'Bir El Ater', 'بير العاتر'),
  (66, 'Ksar El Boukhari', 'قصر البخاري'),
  (67, 'Ksar Chellala', 'قصر الشلالة'),
  (68, 'Ain Oussara', 'عين وسارة'),
  (69, 'Messaad', 'مسعد')
ON CONFLICT (code) DO NOTHING;

-- ─── SEED: COMMUNES ────────────────────────────────────────────────────────

INSERT INTO communes (wilaya_code, name_fr, name_ar, postal_code) VALUES
  (1, 'Timekten', 'تيمقتن', '01041'),
  (1, 'Tit', 'تيت', '01031'),
  (1, 'Akabli', 'اقبلي', '01044'),
  (1, 'Aoulef', 'أولف', '01003'),
  (1, 'Bouda', 'بودة', '01023'),
  (1, 'Ouled Ahmed Timmi', 'أولاد أحمد تيمي', '01025'),
  (1, 'Adrar', 'أدرار', '01000'),
  (1, 'Fenoughil', 'فنوغيل', '01008'),
  (1, 'Tamest', 'تامست', '01020'),
  (1, 'Tamantit', 'تامنطيط', '01021'),
  (1, 'In Zghmir', 'إن زغمير', '01047'),
  (1, 'Zaouiet Kounta', 'زاوية كنتة', '01007'),
  (1, 'Reggane', 'رقان', '01004'),
  (1, 'Sali', 'سالي', '01009'),
  (1, 'Sebaa', 'السبع', '01022'),
  (1, 'Tsabit', 'تسابيت', '01011'),
  (2, 'Talassa', 'تلعصة', '02065'),
  (2, 'Tadjena', 'تاجنة', '02043'),
  (2, 'Abou El Hassane', 'أبو الحسن', '02018'),
  (2, 'Zeboudja', 'الزبوجة', '02014'),
  (2, 'Bouzeghaia', 'بوزغاية', '02019'),
  (2, 'Benairia', 'بنايرية', '02039'),
  (2, 'El Hadjadj', 'الحجاج', '02050'),
  (2, 'Ouled Ben Abdelkader', 'أولاد بن عبد القادر', '02037'),
  (2, 'Ain Merane', 'عين مران', '02004'),
  (2, 'Herenfa', 'الهرانفة', '02038'),
  (2, 'Breira', 'بريرة', '02070'),
  (2, 'Beni Haoua', 'بني حواء', '02017'),
  (2, 'Oued Goussine', 'وادي قوسين', '02061'),
  (2, 'Ouled Abbes', 'أولاد عباس', '02029'),
  (2, 'Oued Fodda', 'وادي الفضة', '02001'),
  (2, 'Beni Rached', 'بني راشد', '02035'),
  (2, 'El Marsa', 'المرسى', '02015'),
  (2, 'Moussadek', 'مصدق', '02060'),
  (2, 'Chlef', 'الشلف', '02000'),
  (2, 'Oum Drou', 'أم الدروع', '02024'),
  (2, 'Sendjas', 'سنجاس', '02025'),
  (2, 'Sidi Abderrahmane', 'سيدي عبد الرحمن', '02066'),
  (2, 'Sidi Akkacha', 'سيدي عكاشة', '02009'),
  (2, 'Tenes', 'تنس', '02006'),
  (2, 'Beni  Bouattab', 'بني بوعتاب', '02071'),
  (2, 'El Karimia', 'الكريمية', '02008'),
  (2, 'Harchoun', 'حرشون', '02031'),
  (2, 'Taougrit', 'تاوقريت', '02012'),
  (2, 'Dahra', 'الظهرة', '02032'),
  (2, 'Chettia', 'الشطية', '02007'),
  (2, 'Ouled Fares', 'أولاد فارس', '02010'),
  (2, 'Labiod Medjadja', 'الأبيض مجاجة', '02073'),
  (2, 'Boukadir', 'بوقادير', '02002'),
  (2, 'Oued Sly', 'وادي سلي', '02011'),
  (2, 'Sobha', 'الصبحة', '02030'),
  (3, 'Tadjemout', 'تاجموت', '03007'),
  (3, 'Tadjrouna', 'تاجرونة', '03011'),
  (3, 'Ain Madhi', 'عين ماضي', '03012'),
  (3, 'El Haouaita', 'الحويطة', '03040'),
  (3, 'Kheneg', 'الخنق', '03010'),
  (3, 'Laghouat', 'الأغواط', '03000'),
  (3, 'Ksar El Hirane', 'قصر الحيران', '03003'),
  (3, 'Benacer Benchohra', 'بن ناصر بن شهرة', '03033'),
  (3, 'El Assafia', 'العسافية', '03014'),
  (3, 'Sidi Makhlouf', 'سيدي مخلوف', '03019'),
  (3, 'Hassi Delaa', 'حاسي الدلاعة', '03022'),
  (3, 'Hassi R''mel', 'حاسي الرمل', '03004'),
  (4, 'Fkirina', 'فكيرينة', '04013'),
  (4, 'Oued Nini', 'وادي نيني', '04047'),
  (4, 'El Fedjoudj Boughrara Sa', 'الفجوج بوغرارة سعودي', '04042'),
  (4, 'Ain Fekroun', 'عين فكرون', '04005'),
  (4, 'Rahia', 'الرحية', '04045'),
  (4, 'Meskiana', 'مسكيانة', '04004'),
  (4, 'El Belala', 'البلالة', '04044'),
  (4, 'Behir Chergui', 'بحير الشرقي', '04026'),
  (4, 'Ksar Sbahi', 'قصر الصباحي', '04018'),
  (4, 'Souk Naamane', 'سوق نعمان', '04010'),
  (4, 'Ouled Zouai', 'أولاد زواي', NULL),
  (4, 'Bir Chouhada', 'بئر الشهداء', '04021'),
  (4, 'Oum El Bouaghi', 'أم البواقي', '04000'),
  (4, 'Ain Zitoun', 'عين الزيتون', '04023'),
  (4, 'Ain Babouche', 'عين ببوش', '04020'),
  (4, 'Ain Diss', 'عين الديس', '04025'),
  (4, 'Ain Beida', 'عين البيضاء', '04001'),
  (4, 'Berriche', 'بريش', '04022'),
  (4, 'Zorg', 'الزرق', '04024'),
  (4, 'Ain M''lila', 'عين مليلة', '04002'),
  (4, 'Ouled Gacem', 'أولاد قاسم', '04041'),
  (4, 'Ouled Hamla', 'أولاد حملة', '04019'),
  (4, 'El Amiria', 'العامرية', '04038'),
  (4, 'Sigus', 'سيقوس', '04011'),
  (4, 'Dhalaa', 'الضلعة', '04008'),
  (4, 'El Djazia', 'الجازية', '04040'),
  (4, 'Ain Kercha', 'عين كرشة', '04006'),
  (4, 'El Harmilia', 'الحرملية', '04032'),
  (4, 'Hanchir Toumghani', 'هنشير تومغني', '04012'),
  (5, 'Maafa', 'معافة', '05123'),
  (5, 'Ain Touta', 'عين التوتة', '05002'),
  (5, 'Beni Foudhala El Hakania', 'بني فضالة الحقانية', '05141'),
  (5, 'Ouled Aouf', 'أولاد عوف', '05122'),
  (5, 'Gosbat', 'القصبات', '05090'),
  (5, 'Talkhamt', 'تالخمت', NULL),
  (5, 'Ras El Aioun', 'رأس العيون', '05009'),
  (5, 'Rahbat', 'الرحبات', '05091'),
  (5, 'Ouled Sellem', 'أولاد سلام', '05044'),
  (5, 'Guigba', 'القيقبة', '05067'),
  (5, 'Timgad', 'تيمقاد', '05023'),
  (5, 'Ouled Fadel', 'أولاد فاضل', '05063'),
  (5, 'Taxlent', 'تاكسلانت', '05055'),
  (5, 'Ouled Si Slimane', 'أولاد سي سليمان', '05066'),
  (5, 'Lemcene', 'لمسان', NULL),
  (5, 'Teniet El Abed', 'ثنية العابد', '05035'),
  (5, 'Chir', 'شير', '05038'),
  (5, 'Oued Taga', 'وادي الطاقة', '05036'),
  (5, 'Batna', 'باتنة', '05000'),
  (5, 'Fesdis', 'فسديس', '05077'),
  (5, 'Oued Chaaba', 'وادي الشعبة', '05054'),
  (5, 'Hidoussa', 'حيدوسة', '05033'),
  (5, 'Ksar Bellezma', 'قصر بلزمة', '05047'),
  (5, 'Merouana', 'مروانة', '05013'),
  (5, 'Oued El Ma', 'وادي الماء', '05016'),
  (5, 'Lazrou', 'لازرو', '05117'),
  (5, 'Seriana', 'سريانة', '05025'),
  (5, 'Zanet El Beida', 'زانة البيضاء', '05071'),
  (5, 'Menaa', 'منعة', '05012'),
  (5, 'Tigharghar', 'تغرغار', '05059'),
  (5, 'Ain Yagout', 'عين ياقوت', '05031'),
  (5, 'Boumia', 'بومية', '05104'),
  (5, 'Djerma', 'جرمة', '05105'),
  (5, 'El Madher', 'المعذر', '05015'),
  (5, 'Ouyoun El Assafir', 'عيون العصافير', '05069'),
  (5, 'Tazoult', 'تازولت', '05011'),
  (5, 'Boumagueur', 'بومقر', '05057'),
  (5, 'N Gaous', 'نقاوس', '05004'),
  (5, 'Sefiane', 'سفيان', '05064'),
  (5, 'Arris', 'أريس', '05007'),
  (5, 'Tighanimine', 'تيغانمين', '05060'),
  (5, 'Ain Djasser', 'عين جاسر', '05032'),
  (5, 'El Hassi', 'الحاسي', '05116'),
  (5, 'Foum Toub', 'فم الطوب', '05049'),
  (5, 'Ichemoul', 'إشمول', '05026'),
  (5, 'Inoughissen', 'إينوغيسن', '05083'),
  (5, 'Bouzina', 'بوزينة', '05041'),
  (5, 'Larbaa', 'لارباع', '09002'),
  (5, 'Boulhilat', 'بولهيلات', '05062'),
  (5, 'Chemora', 'الشمرة', '05039'),
  (5, 'Ghassira', 'غسيرة', '05043'),
  (5, 'Kimmel', 'كيمل', '05079'),
  (5, 'T Kout', 'تكوت', '05020'),
  (6, 'Sidi Ayad', 'سيدي عياد', '06085'),
  (6, 'Leflaye', 'الفلاي', '06043'),
  (6, 'Sidi-Aich', 'سيدي عيش', '06005'),
  (6, 'Tifra', 'تيفرة', '06028'),
  (6, 'Tinebdar', 'تينبدار', '06037')
ON CONFLICT (wilaya_code, name_fr) DO NOTHING;

INSERT INTO communes (wilaya_code, name_fr, name_ar, postal_code) VALUES
  (6, 'Barbacha', 'برباشة', '06009'),
  (6, 'Kendira', 'كنديرة', '06032'),
  (6, 'El Kseur', 'القصر', '06003'),
  (6, 'Fenaia Il Maten', 'فناية الماثن', '06041'),
  (6, 'Toudja', 'توجة', '06030'),
  (6, 'Dra El Caid', 'ذراع القايد', '06070'),
  (6, 'Kherrata', 'خراطة', '06004'),
  (6, 'Bejaia', 'بجاية', '06000'),
  (6, 'Oued Ghir', 'وادي غير', '06017'),
  (6, 'Benimaouche', 'بني معوش', '06024'),
  (6, 'Beni Djellil', 'بني جليل', '06067'),
  (6, 'Feraoun', 'فرعون', '06033'),
  (6, 'Smaoun', 'سمعون', '06020'),
  (6, 'Amizour', 'أميزور', '06008'),
  (6, 'Timezrit', 'تيمزريت', '06019'),
  (6, 'Melbou', 'مالبو', '06076'),
  (6, 'Souk El Tenine', 'سوق لإثنين', '06012'),
  (6, 'Tamridjet', 'تامريجت', '06077'),
  (6, 'Boukhelifa', 'بوخليفة', '06059'),
  (6, 'Tala Hamza', 'تالة حمزة', '06066'),
  (6, 'Tichy', 'تيشي', '06023'),
  (6, 'Ait R''zine', 'أيت رزين', '06013'),
  (6, 'Ighil-Ali', 'إغيل علي', '06014'),
  (6, 'Ait-Smail', 'أيت إسماعيل', '06044'),
  (6, 'Darguina', 'درقينة', '06016'),
  (6, 'Taskriout', 'تاسكريوت', '06015'),
  (6, 'Aokas', 'أوقاس', '06007'),
  (6, 'Tizi-N''berber', 'تيزي نبربر', '06058'),
  (6, 'Adekar', 'أدكار', '06021'),
  (6, 'Beni K''sila', 'بني كسيلة', '06027'),
  (6, 'Taourit Ighil', 'تاوريرت إغيل', '06035'),
  (6, 'Akbou', 'أقبو', '06001'),
  (6, 'Chellata', 'شلاطة', '06052'),
  (6, 'Ighram', 'اغرم', '06048'),
  (6, 'Tamokra', 'تامقرة', '06053'),
  (6, 'Amalou', 'أمالو', '06034'),
  (6, 'Bouhamza', 'بوحمزة', '06031'),
  (6, 'M''cisna', 'مسيسنة', '06038'),
  (6, 'Seddouk', 'صدوق', '06011'),
  (6, 'Beni-Mallikeche', 'بني مليكش', '06039'),
  (6, 'Boudjellil', 'بو جليل', '06018'),
  (6, 'Tazmalt', 'تازمالت', '06006'),
  (6, 'Akfadou', 'أكفادو', '06025'),
  (6, 'Chemini', 'شميني', '06022'),
  (6, 'Souk Oufella', 'سوق اوفلا', '06036'),
  (6, 'Tibane', 'طيبان', '06087'),
  (6, 'Ouzellaguen', 'أوزلاقن', '06010'),
  (7, 'El Feidh', 'الفيض', '07026'),
  (7, 'Khenguet Sidi Nadji', 'خنقة سيدي ناجي', '07032'),
  (7, 'Zeribet El Oued', 'زريبة الوادي', '07012'),
  (7, 'Meziraa', 'المزيرعة', '07043'),
  (7, 'Lichana', 'ليشانة', '07009'),
  (7, 'Bouchakroun', 'بوشقرون', '07022'),
  (7, 'Bordj Ben Azzouz', 'برج بن عزوز', '07021'),
  (7, 'Tolga', 'طولقة', '07003'),
  (7, 'Mekhadma', 'مخادمة', '07034'),
  (7, 'M''lili', 'مليلي', '07068'),
  (7, 'Ourlal', 'أورلال', '07011'),
  (7, 'Oumache', 'أوماش', '07035'),
  (7, 'Lioua', 'ليوة', '07033'),
  (7, 'Biskra', 'بسكرة', '07000'),
  (7, 'El Hadjab', 'الحاجب', '07037'),
  (7, 'Foughala', 'فوغالة', '07031'),
  (7, 'El Ghrous', 'الغروس', '07027'),
  (7, 'Ain Naga', 'عين الناقة', '07039'),
  (7, 'Chetma', 'شتمة', '07024'),
  (7, 'El Haouch', 'الحوش', '07028'),
  (7, 'Sidi Okba', 'سيدي عقبة', '07005'),
  (7, 'M''chouneche', 'مشونش', '07010'),
  (8, 'Bechar', 'بشار', '08000'),
  (8, 'Boukais', 'بوكايس', '08034'),
  (8, 'Lahmar', 'لحمر', '08026'),
  (8, 'Mogheul', 'موغل', '08042'),
  (8, 'Meridja', 'المريجة', '08041'),
  (8, 'Kenadsa', 'القنادسة', '08011'),
  (8, 'Taghit', 'تاغيت', '08030'),
  (8, 'Abadla', 'العبادلة', '08003'),
  (8, 'Erg-Ferradj', 'عرق فراج', '08023'),
  (8, 'Machraa-Houari-Boumediene', 'مشرع هواري بومدين', '08027'),
  (8, 'Beni-Ounif', 'بني ونيف', '08010'),
  (8, 'Tabelbala', 'تبلبالة', '08029'),
  (9, 'Beni Mered', 'بني مراد', '09003'),
  (9, 'Ouled Yaich', 'أولاد يعيش', '09015'),
  (9, 'Chrea', 'الشريعة', '09027'),
  (9, 'Ouled Slama', 'اولاد سلامة', '09033'),
  (9, 'Hammam Elouane', 'حمام ملوان', '09030'),
  (9, 'Bougara', 'بوقرة', '09008'),
  (9, 'Mouzaia', 'موزاية', '09013'),
  (9, 'Chiffa', 'الشفة', '09010'),
  (9, 'Ain Romana', 'عين الرمانة', '09023'),
  (9, 'Souhane', 'صوحان', '09034'),
  (9, 'Larbaa', 'الأربعاء', '09002'),
  (9, 'Soumaa', 'الصومعة', '09022'),
  (9, 'Guerrouaou', 'قرواو', '09029'),
  (9, 'Boufarik', 'بوفاريك', '09001'),
  (9, 'Meftah', 'مفتاح', '09012'),
  (9, 'Djebabra', 'جبابرة', '09028'),
  (9, 'Oued  Djer', 'وادي جر', '09032'),
  (9, 'El-Affroun', 'العفرون', '09011'),
  (9, 'Oued El Alleug', 'وادي العلايق', '09014'),
  (9, 'Benkhelil', 'بن خليل', '09025'),
  (9, 'Beni-Tamou', 'بني تامو', '09024'),
  (9, 'Chebli', 'الشبلي', '09009'),
  (9, 'Bouinan', 'بوعينان', '09020'),
  (9, 'Bouarfa', 'بوعرفة', '09019'),
  (9, 'Blida', 'البليدة', '09000'),
  (10, 'Ain Laloui', 'عين العلوي', '10032'),
  (10, 'Ain El Hadjar', 'عين الحجر', '10031'),
  (10, 'Ain-Bessem', 'عين بسام', '10005'),
  (10, 'Hadjera Zerga', 'الحجرة الزرقاء', '10065'),
  (10, 'Mezdour', 'مزدور', '10040'),
  (10, 'Taguedite', 'تاقديت', '10045'),
  (10, 'Bordj Okhriss', 'برج أوخريص', '10014'),
  (10, 'Ridane', 'ريدان', '10083'),
  (10, 'Maamora', 'المعمورة', '10071'),
  (10, 'El-Hakimia', 'الحاكمية', '10058'),
  (10, 'Dirah', 'ديرة', '10020'),
  (10, 'Dechmia', 'الدشمية', '10057'),
  (10, 'Sour El Ghozlane', 'سور الغزلان', '10004'),
  (10, 'Ahl El Ksar', 'أهل القصر', '10008'),
  (10, 'Bechloul', 'بشلول', '10012'),
  (10, 'El Adjiba', 'العجيبة', '10021'),
  (10, 'El Asnam', 'الأسنام', '10022'),
  (10, 'Ouled Rached', 'أولاد راشد', NULL),
  (10, 'Ath Mansour', 'آث  منصور', '10011'),
  (10, 'Saharidj', 'سحاريج', '10043'),
  (10, 'M Chedallah', 'أمشدالة', '10003'),
  (10, 'Hanif', 'حنيف', '10030'),
  (10, 'Chorfa', 'شرفة', '10019'),
  (10, 'Aghbalou', 'أغبالو', '10007'),
  (10, 'Raouraoua', 'روراوة', '10042'),
  (10, 'El Khabouzia', 'الخبوزية', '10038'),
  (10, 'Bir Ghbalou', 'بئر غبالو', '10013'),
  (10, 'Bouira', 'البويرة', '10000'),
  (10, 'Ain Turk', 'عين الترك', '10033'),
  (10, 'Ait Laaziz', 'أيت لعزيز', '10034'),
  (10, 'El-Mokrani', 'المقراني', '10060'),
  (10, 'Souk El Khemis', 'سوق الخميس', '10044'),
  (10, 'Aomar', 'أعمر', '10010'),
  (10, 'Djebahia', 'جباحية', '10036'),
  (10, 'Kadiria', 'قادرية', '10006'),
  (10, 'El Hachimia', 'الهاشمية', '10023'),
  (10, 'Oued El Berdi', 'وادي البردي', '10075'),
  (10, 'Haizer', 'حيزر', '10024'),
  (10, 'Taghzout', 'تاغزوت', '10055'),
  (10, 'Bouderbala', 'بودربالة', '10016'),
  (10, 'Boukram', 'بوكرم', '10054'),
  (10, 'Guerrouma', 'قرومة', '10037'),
  (10, 'Lakhdaria', 'الأخضرية', '10002'),
  (10, 'Maala', 'معلة', '10039')
ON CONFLICT (wilaya_code, name_fr) DO NOTHING;

INSERT INTO communes (wilaya_code, name_fr, name_ar, postal_code) VALUES
  (10, 'Z''barbar (El Isseri )', 'زبربر', '10047'),
  (11, 'Tazrouk', 'تاظروك', '11010'),
  (11, 'Idles', 'أدلس', '11013'),
  (11, 'Abelsa', 'ابلسة', '11007'),
  (11, 'Tamanrasset', 'تمنراست', '11000'),
  (11, 'Ain Amguel', 'عين امقل', '11003'),
  (12, 'El-Houidjbet', 'الحويجبات', '12038'),
  (12, 'El Malabiod', 'الماء الابيض', '12014'),
  (12, 'El-Aouinet', 'العوينات', '12005'),
  (12, 'Boukhadra', 'بوخضرة', '12012'),
  (12, 'Bir Mokkadem', 'بئر مقدم', '12011'),
  (12, 'Guorriguer', 'قريقر', '12046'),
  (12, 'Hammamet', 'الحمامات', '12016'),
  (12, 'Bir Dheheb', 'بئر الذهب', '12031'),
  (12, 'Morsott', 'مرسط', '12017'),
  (12, 'Saf Saf El Ouesra', 'صفصاف الوسرى', '12037'),
  (12, 'Oum Ali', 'أم علي', '12027'),
  (12, 'Bekkaria', 'بكارية', '12019'),
  (12, 'Boulhaf Dyr', 'بولحاف الدير', '12039'),
  (12, 'El Kouif', 'الكويف', '12006'),
  (12, 'Ouenza', 'الونزة', '12003'),
  (12, 'El Meridj', 'المريج', '12023'),
  (12, 'Ain Zerga', 'عين الزرقاء', '12008'),
  (12, 'Stah Guentis', 'سطح قنطيس', '12032'),
  (12, 'El Ogla', 'العقلة', '12015'),
  (12, 'El Mezeraa', 'المزرعة', '12042'),
  (12, 'Bedjene', 'بجن', '12035'),
  (12, 'Telidjen', 'ثليجان', '12053'),
  (12, 'Cheria', 'الشريعة', '12002'),
  (12, 'Tebessa', 'تبسة', '12000'),
  (13, 'Bab El Assa', 'باب العسة', '13014'),
  (13, 'Souk Tleta', 'سوق الثلاثاء', '13078'),
  (13, 'Souani', 'السواني', '13046'),
  (13, 'Terny Beni Hediel', 'تيرني بني هديل', '13079'),
  (13, 'Mansourah', 'منصورة', '13062'),
  (13, 'Beni Mester', 'بني مستر', '13038'),
  (13, 'Ain Ghoraba', 'عين غرابة', '13023'),
  (13, 'Chetouane', 'شتوان', '13048'),
  (13, 'Amieur', 'عمير', '13058'),
  (13, 'Ain Fezza', 'عين فزة', '13022'),
  (13, 'Honnaine', 'هنين', '13015'),
  (13, 'Beni Khellad', 'بني خلاد', '13074'),
  (13, 'Nedroma', 'ندرومة', '13004'),
  (13, 'Djebala', 'جبالة', '13029'),
  (13, 'M''sirda Fouaga', 'مسيردة الفواقة', '13024'),
  (13, 'Marsa Ben M''hidi', 'مرسى بن مهيدي', '13017'),
  (13, 'Sidi Medjahed', 'سيدي مجاهد', '13044'),
  (13, 'Beni Boussaid', 'بني بوسعيد', NULL),
  (13, 'Sebdou', 'سبدو', '13006'),
  (13, 'Bouhlou', 'بوحلو', '13026'),
  (13, 'Sabra', 'صبرة', '13011'),
  (13, 'Maghnia', 'مغنية', '13001'),
  (13, 'Hammam Boughrara', 'حمام بوغرارة', '13036'),
  (13, 'Zenata', 'زناتة', '13051'),
  (13, 'Ouled Riyah', 'أولاد رياح', '13070'),
  (13, 'Hennaya', 'الحناية', '13009'),
  (13, 'Sidi Abdelli', 'سيدي العبدلي', '13019'),
  (13, 'Bensekrane', 'بن سكران', '13008'),
  (13, 'Fellaoucene', 'فلاوسن', '13035'),
  (13, 'Ain Kebira', 'عين الكبيرة', '13049'),
  (13, 'Ain Fetah', 'عين فتاح', '13028'),
  (13, 'Tlemcen', 'تلمسان', '13000'),
  (13, 'Ain Nehala', 'عين النحالة', '13054'),
  (13, 'Ain Tellout', 'عين تالوت', '13012'),
  (13, 'Ain Youcef', 'عين يوسف', '13013'),
  (13, 'Beni Ouarsous', 'بني وارسوس', '13025'),
  (13, 'El Fehoul', 'الفحول', '13033'),
  (13, 'Remchi', 'الرمشي', '13005'),
  (13, 'Sebbaa Chioukh', 'سبعة شيوخ', '13042'),
  (13, 'Dar Yaghmoracen', 'دار يغمراسن', '13032'),
  (13, 'Ghazaouet', 'الغزوات', '13002'),
  (13, 'Souahlia', 'السواحلية', '13020'),
  (13, 'Tianet', 'تيانت', '13047'),
  (13, 'Beni Smiel', 'بني صميل', '13083'),
  (13, 'Oued Lakhdar', 'وادي الخضر', '13068'),
  (13, 'Ouled Mimoun', 'أولاد ميمون', '13010'),
  (13, 'Beni Bahdel', 'بني بهدل', '13060'),
  (13, 'Beni Snous', 'بني سنوس', '13037'),
  (13, 'Azail', 'العزايل', '13080'),
  (14, 'Mahdia', 'مهدية', '14004'),
  (14, 'Ain Dzarit', 'عين دزاريت', '14017'),
  (14, 'Sebaine', 'السبعين', '14030'),
  (14, 'Nadorah', 'الناظورة', '14058'),
  (14, 'Faidja', 'الفايجة', '14049'),
  (14, 'Si Abdelghani', 'سي عبد الغني', '14027'),
  (14, 'Sougueur', 'السوقر', '14003'),
  (14, 'Tousnina', 'توسنينة', '14037'),
  (14, 'Meghila', 'مغيلة', '14024'),
  (14, 'Sebt', 'السبت', '21018'),
  (14, 'Sidi Hosni', 'سيدي حسني', '14029'),
  (14, 'Ain El Hadid', 'عين الحديد', '14008'),
  (14, 'Frenda', 'فرندة', '14001'),
  (14, 'Takhemaret', 'تخمرت', '14015'),
  (14, 'Ain Kermes', 'عين كرمس', '14009'),
  (14, 'Djebilet Rosfa', 'جبيلات الرصفاء', '14061'),
  (14, 'Madna', 'مادنة', '14055'),
  (14, 'Medrissa', 'مدريسة', '14013'),
  (14, 'Sidi Abderrahmane', 'سيدي عبد الرحمن', '02066'),
  (14, 'Guertoufa', 'قرطوفة', '14019'),
  (14, 'Rahouia', 'الرحوية', '14005'),
  (14, 'Oued Lilli', 'وادي ليلي', '14014'),
  (14, 'Sidi Ali Mellal', 'سيدي علي ملال', '14064'),
  (14, 'Tidda', 'تيدة', '14071'),
  (14, 'Djillali Ben Amar', 'جيلالي بن عمار', '14016'),
  (14, 'Mechraa Safa', 'مشرع الصفا', '14012'),
  (14, 'Tagdempt', 'تاقدمت', '14068'),
  (14, 'Tiaret', 'تيارت', '14000'),
  (14, 'Medroussa', 'مدروسة', '14023'),
  (14, 'Mellakou', 'ملاكو', '14025'),
  (14, 'Sidi Bakhti', 'سيدي بختي', '14065'),
  (14, 'Ain Deheb', 'عين الذهب', '14007'),
  (14, 'Chehaima', 'شحيمة', '14046'),
  (14, 'Naima', 'النعيمة', '14060'),
  (14, 'Ain Bouchekif', 'عين بوشقيف', '14040'),
  (14, 'Dahmouni', 'دحموني', '14010'),
  (15, 'Mizrana', 'ميزرانـــة', '15061'),
  (15, 'Iflissen', 'إفليـــسن', '15068'),
  (15, 'Tigzirt', 'تيقـزيرت', '15019'),
  (15, 'Idjeur', 'إيجــار', '15035'),
  (15, 'Beni-Zikki', 'بني زيكــي', '15118'),
  (15, 'Illoula Oumalou', 'إيلولة أومـــالو', '15037'),
  (15, 'Bouzeguene', 'بوزقــن', '15009'),
  (15, 'Beni-Douala', 'بني دوالة', '15011'),
  (15, 'Beni-Aissi', 'بني عيسي', '15069'),
  (15, 'Ait-Mahmoud', 'أيت محمود', '15044'),
  (15, 'Beni Zmenzer', 'بنــــي زمنزار', '15028'),
  (15, 'Agouni-Gueghrane', 'أقني قغران', '15022'),
  (15, 'Ait Bouaddou', 'أيت بــوادو', '15024'),
  (15, 'Ouadhias', 'واضية', '15016'),
  (15, 'Tizi N''tleta', 'تيزي نثلاثة', '15049'),
  (15, 'Aghribs', 'أغريب', '15021'),
  (15, 'Ait-Chafaa', 'أيت شافع', '15059'),
  (15, 'Akerrou', 'أقرو', '15027'),
  (15, 'Azeffoun', 'أزفون', '15010'),
  (15, 'Assi-Youcef', 'أسي يوسف', '15025'),
  (15, 'Boghni', 'بوغني', '15003'),
  (15, 'Bounouh', 'بونوح', '15031'),
  (15, 'Mechtras', 'مشطراس', '15041'),
  (15, 'Draa-Ben-Khedda', 'ذراع بن خدة', '15004'),
  (15, 'Sidi Namane', 'سيدي نعمان', '15042'),
  (15, 'Tadmait', 'تادمايت', '15018'),
  (15, 'Tirmitine', 'تيرمتين', '15048'),
  (15, 'Ait Boumahdi', 'أيت بومهدي', '15084'),
  (15, 'Ait-Toudert', 'أيت تودرت', '15062'),
  (15, 'Ouacif', 'واسيف', '15015'),
  (15, 'Ait Khellili', 'أيت خليلي', '15079'),
  (15, 'Mekla', 'مقــلع', '15014'),
  (15, 'Souama', 'صوامـــع', '15043'),
  (15, 'Beni-Yenni', 'بني يني', '15029'),
  (15, 'Iboudrarene', 'إبودرارن', '15073')
ON CONFLICT (wilaya_code, name_fr) DO NOTHING;

INSERT INTO communes (wilaya_code, name_fr, name_ar, postal_code) VALUES
  (15, 'Yatafene', 'يطــافن', '15052'),
  (15, 'Tizi-Ouzou', 'تيزي وزو', '15000'),
  (15, 'Abi-Youcef', 'أبي يوسف', NULL),
  (15, 'Ain-El-Hammam', 'عين الحمام', '15002'),
  (15, 'Ait-Yahia', 'أيت يحيى', '15072'),
  (15, 'Akbil', 'اقبيل', '15092'),
  (15, 'Boudjima', 'بوجيمة', '15030'),
  (15, 'Makouda', 'ماكودة', '15040'),
  (15, 'Ain-Zaouia', 'عين الزاوية', '15055'),
  (15, 'Ait Yahia Moussa', 'أيت يحي موسى', '15026'),
  (15, 'Draa-El-Mizan', 'ذراع الميزان', '15005'),
  (15, 'Frikat', 'فريقات', '15067'),
  (15, 'M''kira', 'مكيرة', '15046'),
  (15, 'Tizi-Gheniff', 'تيزي غنيف', '15020'),
  (15, 'Illilten', 'إيلـيــلتـن', '15036'),
  (15, 'Imsouhal', 'إمســوحال', '15023'),
  (15, 'Iferhounene', 'إفــرحــونان', '15013'),
  (15, 'Azazga', 'عزازقة', '15001'),
  (15, 'Freha', 'فريحة', '15012'),
  (15, 'Ifigha', 'إيفيغاء', '15034'),
  (15, 'Yakourene', 'إعــكورن', '15051'),
  (15, 'Zekri', 'زكري', '15076'),
  (15, 'Ait Aggouacha', 'أيت عقـواشة', '15058'),
  (15, 'Irdjen', 'إيرجـــن', '15038'),
  (15, 'Larbaa Nath Irathen', 'الأربعــاء ناث إيراثن', '15006'),
  (15, 'Ait-Oumalou', 'أيت  أومالو', NULL),
  (15, 'Tizi-Rached', 'تيزي راشد', '15050'),
  (15, 'Ait-Aissa-Mimoun', 'أيت عيسى ميمون', '15032'),
  (15, 'Ouaguenoun', 'واقنون', '15045'),
  (15, 'Timizart', 'تيمـيزار', '15039'),
  (15, 'Maatkas', 'معـــاتقة', '15017'),
  (15, 'Souk-El-Tenine', 'سوق الإثنين', '15123'),
  (16, 'Hussein Dey', 'حسين داي', '16005'),
  (16, 'Kouba', 'القبة', '16006'),
  (16, 'Mohamed Belouzdad', 'محمد بلوزداد', '16151'),
  (16, 'El Magharia', 'المغارية', '16053'),
  (16, 'Les Eucalyptus', 'الكاليتوس', '16057'),
  (16, 'Sidi Moussa', 'سيدي موسى', '16189'),
  (16, 'Baraki', 'براقي', '16027'),
  (16, 'Ain Taya', 'عين طاية', '16019'),
  (16, 'Bab Ezzouar', 'باب الزوار', '16024'),
  (16, 'Bordj El Kiffan', 'برج الكيفان', '16031'),
  (16, 'Dar El Beida', 'الدار البيضاء', '16033'),
  (16, 'Mohammadia', 'المحمدية', '16058'),
  (16, 'Bordj El Bahri', 'برج البحري', '16046'),
  (16, 'El Marsa', 'المرسى', '02015'),
  (16, 'Bir Touta', 'بئر توتة', '16045'),
  (16, 'Ouled Chebel', 'اولاد شبل', '16118'),
  (16, 'Tessala El Merdja', 'تسالة المرجة', '16099'),
  (16, 'Herraoua', 'هراوة', '16116'),
  (16, 'Reghaia', 'رغاية', '16036'),
  (16, 'Rouiba', 'الرويبة', '16017'),
  (16, 'Maalma', 'المعالمة', '16093'),
  (16, 'Rahmania', 'الرحمانية', '16121'),
  (16, 'Souidania', 'سويدانية', '16097'),
  (16, 'Staoueli', 'سطاوالي', '16062'),
  (16, 'Zeralda', 'زرالدة', '16063'),
  (16, 'Baba Hassen', 'بابا حسن', '16081'),
  (16, 'Douira', 'الدويرة', '16049'),
  (16, 'Draria', 'الدرارية', '16050'),
  (16, 'El Achour', 'العاشور', '16104'),
  (16, 'Khraissia', 'الخرايسية', '16091'),
  (16, 'Ain Benian', 'عين بنيان', '16018'),
  (16, 'Cheraga', 'الشراقة', '16014'),
  (16, 'Dely Ibrahim', 'دالي ابراهيم', '16047'),
  (16, 'Ouled Fayet', 'اولاد فايت', '16094'),
  (16, 'Hammamet', 'الحمامات', '12016'),
  (16, 'Alger Centre', 'الجزائر الوسطى', '16000'),
  (16, 'El Madania', 'المدنية', '16015'),
  (16, 'El Mouradia', 'المرادية', '16035'),
  (16, 'Sidi M''hamed', 'سيدي امحمد', '16002'),
  (16, 'Sehaoula', 'السحاولة', '16095'),
  (16, 'Bir Mourad Rais', 'بئر مراد رايس', '16013'),
  (16, 'Birkhadem', 'بئر خادم', '16029'),
  (16, 'Djasr Kasentina', 'جسر قسنطينة', '16048'),
  (16, 'Hydra', 'حيدرة', '16016'),
  (16, 'Bologhine Ibnou Ziri', 'بولوغين بن زيري', '16030'),
  (16, 'Casbah', 'القصبة', '16001'),
  (16, 'Oued Koriche', 'وادي قريش', '16182'),
  (16, 'Rais Hamidou', 'الرايس حميدو', '16060'),
  (16, 'Bab El Oued', 'باب الوادي', '16008'),
  (16, 'Ben Aknoun', 'ابن عكنون', '16028'),
  (16, 'Beni Messous', 'بني مسوس', '16044'),
  (16, 'Bouzareah', 'بوزريعة', '16032'),
  (16, 'El Biar', 'الابيار', '16003'),
  (16, 'Bachedjerah', 'باش جراح', '16026'),
  (16, 'Bourouba', 'بوروبة', '16054'),
  (16, 'El Harrach', 'الحراش', '16004'),
  (16, 'Oued Smar', 'وادي السمار', '16059'),
  (17, 'Hassi El Euch', 'حاسي العش', '17032'),
  (17, 'Zaafrane', 'زعفران', '17038'),
  (17, 'Ain Maabed', 'عين معبد', '17025'),
  (17, 'Hassi Bahbah', 'حاسي بحبح', '17002'),
  (17, 'Ain El Ibel', 'عين الإبل', '17011'),
  (17, 'Taadmit', 'تعظميت', '17037'),
  (17, 'Zaccar', 'زكار', '17065'),
  (17, 'Moudjebara', 'مجبارة', '17058'),
  (17, 'El Guedid', 'القديد', '17019'),
  (17, 'Charef', 'الشارف', '17015'),
  (17, 'Benyagoub', 'بن يعقوب', '17026'),
  (17, 'Sidi Baizid', 'سيدي بايزيد', '17052'),
  (17, 'M''liliha', 'مليليحة', '17036'),
  (17, 'Dar Chioukh', 'دار الشيوخ', '17006'),
  (17, 'Douis', 'دويس', '17030'),
  (17, 'El Idrissia', 'الادريسية', '17020'),
  (17, 'Ain Chouhada', 'عين الشهداء', '17039'),
  (17, 'Djelfa', 'الجلفة', '17000'),
  (18, 'Jijel', 'جيجل', '18000'),
  (18, 'El Aouana', 'العوانة', '18005'),
  (18, 'Selma Benziada', 'سلمى بن زيادة', '18049'),
  (18, 'Erraguene Souissi', 'أراقن سويسي', '18032'),
  (18, 'Ziama Mansouriah', 'زيامة منصورية', '18007'),
  (18, 'Boussif Ouled Askeur', 'بوسيف أولاد عسكر', '18036'),
  (18, 'Chahna', 'الشحنة', '18027'),
  (18, 'Emir Abdelkader', 'الامير عبد القادر', '18010'),
  (18, 'Oudjana', 'وجانة', '18047'),
  (18, 'Taher', 'الطاهير', '18002'),
  (18, 'Chekfa', 'الشقفة', '18003'),
  (18, 'El Kennar Nouchfi', 'القنار نشفي', '18030'),
  (18, 'Sidi Abdelaziz', 'سيدي عبد العزيز', '18017'),
  (18, 'Bordj T''har', 'برج الطهر', '18041'),
  (18, 'El Milia', 'الميلية', '18001'),
  (18, 'Ouled Yahia Khadrouch', 'أولاد يحيى خدروش', '18021'),
  (18, 'Ouled Rabah', 'أولاد رابح', '18046'),
  (18, 'Sidi Marouf', 'سيدي معروف', '18018'),
  (18, 'Ghebala', 'غبالة', '18026'),
  (18, 'Settara', 'السطارة', '18016'),
  (18, 'Bouraoui Belhadef', 'بوراوي بلهادف', '18023'),
  (18, 'El Ancer', 'العنصر', '18004'),
  (18, 'Khiri Oued Adjoul', 'خيري واد عجول', '18024'),
  (18, 'Djemaa Beni Habibi', 'الجمعة بني حبيبي', '18029'),
  (18, 'Djimla', 'جيملة', '18031'),
  (18, 'Boudria Beniyadjis', 'بودريعة بني  ياجيس', '18025'),
  (18, 'Kaous', 'قاوس', '18015'),
  (18, 'Texenna', 'تاكسنة', '18006'),
  (19, 'Rosfa', 'الرصفة', '19060'),
  (19, 'Boutaleb', 'بوطالب', '19089'),
  (19, 'Hamma', 'الحامة', '19015'),
  (19, 'Ouled Tebben', 'أولاد تبان', '19030'),
  (19, 'Salah Bey', 'صالح باي', '19013'),
  (19, 'Oued El Bared', 'واد البارد', '19115'),
  (19, 'Tizi N''bechar', 'تيزي نبشار', '19068'),
  (19, 'Amoucha', 'عموشة', '19009'),
  (19, 'Mezloug', 'مزلوق', '19056'),
  (19, 'El Ouricia', 'أوريسيا', '19047'),
  (19, 'Ain Abessa', 'عين عباسة', '19016'),
  (19, 'Ain Arnat', 'عين أرنات', '19017'),
  (19, 'Guellal', 'قلال', '19050'),
  (19, 'Kasr El Abtal', 'قصر الابطال', '19054'),
  (19, 'Ouled Si Ahmed', 'أولاد سي أحمد', '19121')
ON CONFLICT (wilaya_code, name_fr) DO NOTHING;

INSERT INTO communes (wilaya_code, name_fr, name_ar, postal_code) VALUES
  (19, 'Ain Oulmene', 'عين ولمان', '19002'),
  (19, 'Ait Naoual Mezada', 'أيت نوال مزادة', '19076'),
  (19, 'Ait-Tizi', 'ايت تيزي', '19077'),
  (19, 'Bouandas', 'بوعنداس', '19012'),
  (19, 'Bousselam', 'بوسلام', '19052'),
  (19, 'Hamam Soukhna', 'حمام السخنة', '19059'),
  (19, 'Taya', 'الطاية', '19067'),
  (19, 'Tella', 'التلة', '19087'),
  (19, 'Ain Azel', 'عين أزال', '19007'),
  (19, 'Ain Lahdjar', 'عين الحجر', '19018'),
  (19, 'Beidha Bordj', 'بيضاء برج', '19021'),
  (19, 'Bir Haddada', 'بئر حدادة', '19039'),
  (19, 'Guenzet', 'قنزات', '19026'),
  (19, 'Harbil', 'حربيل', '19032'),
  (19, 'Ain-Roua', 'عين الروى', '19019'),
  (19, 'Beni Oussine', 'بني وسين', '19037'),
  (19, 'Bougaa', 'بوقاعة', '19003'),
  (19, 'Draa-Kebila', 'ذراع قبيلة', '19029'),
  (19, 'Hammam Guergour', 'حمام قرقور', '19051'),
  (19, 'Setif', 'سطيف', '19000'),
  (19, 'Ain El Kebira', 'عين الكبيرة', '19008'),
  (19, 'Dehamcha', 'الدهامشة', '19041'),
  (19, 'Ouled Addouane', 'أولاد عدوان', '19053'),
  (19, 'Ain-Sebt', 'عين السبت', '19033'),
  (19, 'Beni-Aziz', 'بني عزيز', '19010'),
  (19, 'Maaouia', 'معاوية', '19055'),
  (19, 'Bellaa', 'بلاعة', '19022'),
  (19, 'Bir-El-Arch', 'بئر العرش', '19024'),
  (19, 'El-Ouldja', 'الولجة', '19046'),
  (19, 'Tachouda', 'تاشودة', '19125'),
  (19, 'Tala-Ifacene', 'تالة إيفاسن', '19069'),
  (19, 'Maouaklane', 'ماوكلان', '19028'),
  (19, 'Serdj-El-Ghoul', 'سرج الغول', '19086'),
  (19, 'Babor', 'بابور', '19020'),
  (19, 'Guidjel', 'قجال', '19027'),
  (19, 'Ouled Sabor', 'أولاد صابر', '19120'),
  (19, 'Bazer-Sakra', 'بازر سكرة', '19036'),
  (19, 'El Eulma', 'العلمة', '19001'),
  (19, 'Guelta Zerka', 'قلتة زرقاء', NULL),
  (19, 'Beni Fouda', 'بني فودة', '19023'),
  (19, 'Djemila', 'جميلة', '19025'),
  (19, 'Ain-Legradj', 'عين لقراج', '19035'),
  (19, 'Beni Chebana', 'بني شبانة', '19031'),
  (19, 'Beni Ourtilane', 'بني ورتيلان', '19011'),
  (19, 'Beni-Mouhli', 'بني موحلي', '19038'),
  (20, 'Saida', 'سعيدة', '20000'),
  (20, 'Tircine', 'تيرسين', '20035'),
  (20, 'Ouled Brahim', 'أولاد إبراهيم', '20002'),
  (20, 'Ain Soltane', 'عين السلطان', '20029'),
  (20, 'Maamora', 'المعمورة', '10071'),
  (20, 'El Hassasna', 'الحساسنة', '20003'),
  (20, 'Ain Sekhouna', 'عين السخونة', '20009'),
  (20, 'Sidi Boubekeur', 'سيدي بوبكر', '20007'),
  (20, 'Ouled Khaled', 'أولاد خالد', '20004'),
  (20, 'Hounet', 'هونت', '20025'),
  (20, 'Sidi Amar', 'سيدي عمر', '20019'),
  (20, 'Youb', 'يوب', '20008'),
  (20, 'Doui Thabet', 'دوي ثابت', '20023'),
  (20, 'Sidi Ahmed', 'سيدي احمد', '20012'),
  (20, 'Moulay Larbi', 'مولاي العربي', '20014'),
  (20, 'Ain El Hadjar', 'عين الحجر', '10031'),
  (21, 'Ain Bouziane', 'عين بوزيان', '21031'),
  (21, 'Beni Oulbane', 'بني ولبان', '21011'),
  (21, 'Sidi Mezghiche', 'سيدي مزغيش', '21023'),
  (21, 'Salah Bouchaour', 'صالح بو الشعور', '21022'),
  (21, 'Zerdezas', 'زردازة', '21047'),
  (21, 'Ouled Habbaba', 'أولاد حبابة', '21043'),
  (21, 'Emjez Edchich', 'مجاز الدشيش', '21017'),
  (21, 'El Arrouch', 'الحروش', '21003'),
  (21, 'El Hadaiek', 'الحدائق', '21015'),
  (21, 'Bouchetata', 'بوشطاطة', '21053'),
  (21, 'Ain Zouit', 'عين زويت', '21051'),
  (21, 'Beni Bechir', 'بني بشير', '21033'),
  (21, 'Ramdane Djamel', 'رمضان جمال', '21004'),
  (21, 'Bin El Ouiden', 'بين الويدان', '21052'),
  (21, 'Tamalous', 'تمالوس', '21005'),
  (21, 'Kerkara', 'الكركرة', '21019'),
  (21, 'Ain Kechra', 'عين قشرة', '21007'),
  (21, 'Ouldja Boulbalout', 'الولجة بولبلوط', NULL),
  (21, 'Oum Toub', 'أم الطوب', '21020'),
  (21, 'El Ghedir', 'الغدير', '21057'),
  (21, 'Es Sebt', 'السبت', '21018'),
  (21, 'Ain Charchar', 'عين شرشار', '21006'),
  (21, 'Azzaba', 'عزابة', '21001'),
  (21, 'Djendel Saadi Mohamed', 'جندل سعدي محمد', '21037'),
  (21, 'Zitouna', 'الزيتونة', '21028'),
  (21, 'Kanoua', 'قنواع', '21062'),
  (21, 'Ouled Attia', 'أولاد عطية', '21012'),
  (21, 'Oued Zhour', 'وادي الزهور', '21040'),
  (21, 'Khenag Maoune', 'خناق مايو', '21059'),
  (21, 'Collo', 'القل', '21002'),
  (21, 'Cheraia', 'الشرايع', '21030'),
  (21, 'Beni Zid', 'بني زيد', '21016'),
  (21, 'El Marsa', 'المرسى', '02015'),
  (21, 'Ben Azzouz', 'بن عزوز', '21010'),
  (21, 'Bekkouche Lakhdar', 'بكوش لخضر', '21009'),
  (21, 'Filfila', 'فلفلة', '21042'),
  (21, 'Hammadi Krouma', 'حمادي كرومة', '21038'),
  (21, 'Skikda', 'سكيكدة', '21000'),
  (22, 'Sidi Ali Benyoub', 'سيدي علي بن يوب', '22028'),
  (22, 'Tabia', 'طابية', '22032'),
  (22, 'Boukhanefis', 'بوخنفيس', '22008'),
  (22, 'Moulay Slissen', 'مولاي سليسن', '22026'),
  (22, 'El Hacaiba', 'الحصيبة', '22047'),
  (22, 'Ain Tindamine', 'عين تندمين', '22036'),
  (22, 'Tenira', 'تنيرة', '22021'),
  (22, 'Oued Sefioun', 'وادي سفيون', '22055'),
  (22, 'Hassi Dahou', 'حاسي دحو', '22049'),
  (22, 'Benachiba Chelia', 'بن عشيبة شلية', '22040'),
  (22, 'Oued Taourira', 'وادي تاوريرة', '22056'),
  (22, 'Merine', 'مرين', '22012'),
  (22, 'Tefessour', 'تفسور', '22065'),
  (22, 'Taoudmout', 'تاودموت', '22064'),
  (22, 'Sidi Yacoub', 'سيدي يعقوب', '22063'),
  (22, 'Sidi Lahcene', 'سيدي لحسن', '22020'),
  (22, 'Sidi Khaled', 'سيدي خالد', '07004'),
  (22, 'Amarnas', 'العمارنة', '22074'),
  (22, 'Sidi Brahim', 'سيدي ابراهيم', '22029'),
  (22, 'Sidi Hamadouche', 'سيدي حمادوش', '22019'),
  (22, 'Makedra', 'مكدرة', '22051'),
  (22, 'Ain El Berd', 'عين البرد', '22022'),
  (22, 'Hassi Zahana', 'حاسي زهانة', '22010'),
  (22, 'Chetouane Belaila', 'شيطوان البلايلة', '22039'),
  (22, 'Ben Badis', 'بن باديس', '22004'),
  (22, 'Bedrabine El Mokrani', 'بضرابين المقراني', '22038'),
  (22, 'Sfisef', 'سفيزف', '22001'),
  (22, 'M''cid', 'مسيد', '22052'),
  (22, 'Boudjebaa El Bordj', 'بوجبهة البرج', '22043'),
  (22, 'Ain- Adden', 'عين أدن', '22034'),
  (22, 'Sidi Chaib', 'سيدي شعيب', '22061'),
  (22, 'Marhoum', 'مرحوم', '22011'),
  (22, 'Bir El Hammam', 'بئر الحمام', '22041'),
  (22, 'Redjem Demouche', 'رجم دموش', '22058'),
  (22, 'Ras El Ma', 'راس الماء', '22069'),
  (22, 'Oued Sebaa', 'وادي السبع', '22054'),
  (22, 'Sidi Bel-Abbes', 'سيدي بلعباس', '22000'),
  (22, 'Ain Thrid', 'عين الثريد', '22037'),
  (22, 'Sehala Thaoura', 'السهالة الثورة', '22060'),
  (22, 'Tessala', 'تسالة', '22033'),
  (22, 'Belarbi', 'بلعربي', '22023'),
  (22, 'Mostefa  Ben Brahim', 'مصطفى بن ابراهيم', '22013'),
  (22, 'Tilmouni', 'تلموني', '22044'),
  (22, 'Zerouala', 'زروالة', '22068'),
  (22, 'Dhaya', 'الضاية', '22009'),
  (22, 'Mezaourou', 'مزاورو', '22025'),
  (22, 'Teghalimet', 'تغاليمت', '22066'),
  (22, 'Telagh', 'تلاغ', '22007'),
  (22, 'Ain Kada', 'عين قادة', '22035'),
  (22, 'Lamtar', 'لمطار', '22024'),
  (22, 'Sidi Ali Boussidi', 'سيدي علي بوسيدي', '22014')
ON CONFLICT (wilaya_code, name_fr) DO NOTHING;

INSERT INTO communes (wilaya_code, name_fr, name_ar, postal_code) VALUES
  (22, 'Sidi Dahou Zairs', 'سيدي دحو الزاير', '22062'),
  (23, 'Annaba', 'عنابة', '23000'),
  (23, 'Seraidi', 'سرايدي', '23015'),
  (23, 'Berrahal', 'برحال', '23009'),
  (23, 'Oued El Aneb', 'واد العنب', '23021'),
  (23, 'Treat', 'التريعات', NULL),
  (23, 'El Hadjar', 'الحجار', '23004'),
  (23, 'Sidi Amar', 'سيدي عمار', '23028'),
  (23, 'El Bouni', 'البوني', '23010'),
  (23, 'Ain El Berda', 'عين الباردة', '23006'),
  (23, 'Cheurfa', 'الشرفة', '23025'),
  (23, 'El Eulma', 'العلمة', '19001'),
  (23, 'Chetaibi', 'شطايبي', '23014'),
  (24, 'Nechmaya', 'نشماية', '24027'),
  (24, 'Boumahra Ahmed', 'بومهرة أحمد', '24005'),
  (24, 'Djeballah Khemissi', 'جبالة الخميسي', '24039'),
  (24, 'Belkheir', 'بلخير', '24015'),
  (24, 'Beni Mezline', 'بني مزلين', NULL),
  (24, 'Guelaat Bou Sbaa', 'قلعة بوصبع', '24020'),
  (24, 'Bou Hamdane', 'بوحمدان', NULL),
  (24, 'Hammam Debagh', 'حمام دباغ', '24007'),
  (24, 'Roknia', 'الركنية', '24028'),
  (24, 'Dahouara', 'الدهوارة', '24031'),
  (24, 'Hammam N''bail', 'حمام النبايل', '24024'),
  (24, 'Oued Cheham', 'وادي الشحم', '24009'),
  (24, 'Guelma', 'قالمة', '24000'),
  (24, 'Bendjarah', 'بن جراح', '24034'),
  (24, 'Ain Ben Beida', 'عين بن بيضاء', '24011'),
  (24, 'Bouchegouf', 'بوشقوف', '24002'),
  (24, 'Medjez Sfa', 'مجاز الصفاء', '24026'),
  (24, 'Oued Ferragha', 'وادي فراغة', '24038'),
  (24, 'Bouati Mahmoud', 'بوعاتي محمود', '24018'),
  (24, 'El Fedjoudj', 'الفجوج', '24019'),
  (24, 'Heliopolis', 'هيليوبوليس', '24008'),
  (24, 'Medjez Amar', 'مجاز عمار', '24043'),
  (24, 'Houari Boumedienne', 'هواري بومدين', '24025'),
  (24, 'Ras El Agba', 'رأس العقبة', '24049'),
  (24, 'Sellaoua Announa', 'سلاوة عنونة', '24029'),
  (24, 'Bordj Sabath', 'برج صباط', '24017'),
  (24, 'Oued Zenati', 'وادي الزناتي', '24001'),
  (24, 'Ain Regada', 'عين رقادة', '24014'),
  (24, 'Ain Larbi', 'عين العربي', '24012'),
  (24, 'Ain Makhlouf', 'عين مخلوف', '24013'),
  (24, 'Tamlouka', 'تاملوكة', '24010'),
  (24, 'Ain Sandel', 'عين صندل', '24032'),
  (24, 'Bou Hachana', 'بوحشانة', '24037'),
  (24, 'Khezaras', 'لخزارة', NULL),
  (25, 'Didouche Mourad', 'ديدوش مراد', '25024'),
  (25, 'Hamma Bouziane', 'حامة بوزيان', '25013'),
  (25, 'Beni Hamidane', 'بني حميدان', '25035'),
  (25, 'Zighoud Youcef', 'زيغود يوسف', '25014'),
  (25, 'Ain Smara', 'عين السمارة', '25006'),
  (25, 'El Khroub', 'الخروب', '25005'),
  (25, 'Ouled Rahmoun', 'أولاد رحمون', '25028'),
  (25, 'Ain Abid', 'عين عبيد', '25015'),
  (25, 'Ben Badis', 'أبن باديس الهرية', '25037'),
  (25, 'Ibn Ziad', 'ابن زياد', '25027'),
  (25, 'Messaoud Boudjeriou', 'بوجريو مسعود', '25032'),
  (25, 'Constantine', 'قسنطينة', '25000'),
  (26, 'Souagui', 'السواقي', '26020'),
  (26, 'Djouab', 'جواب', '26016'),
  (26, 'Sidi Zahar', 'سيدي زهار', '26072'),
  (26, 'Sidi Ziane', 'سيدي زيان', NULL),
  (26, 'El Azizia', 'العزيزية', '26018'),
  (26, 'Maghraoua', 'مغراوة', '26063'),
  (26, 'Mihoub', 'ميهوب', '26032'),
  (26, 'Hannacha', 'حناشة', '26027'),
  (26, 'Ouamri', 'عوامري', '26034'),
  (26, 'Oued Harbil', 'وادي حربيل', '26061'),
  (26, 'Beni Slimane', 'بني سليمان', '26001'),
  (26, 'Bouskene', 'بوسكن', '26025'),
  (26, 'Sidi Rabie', 'سيدي الربيع', '26070'),
  (26, 'Bouaichoune', 'بوعيشون', '26055'),
  (26, 'Ouled Bouachra', 'أولاد بوعشرة', '26064'),
  (26, 'Si Mahdjoub', 'سي المحجوب', '26045'),
  (26, 'Berrouaghia', 'البرواقية', '26002'),
  (26, 'Ouled Deid', 'أولاد دايد', '26044'),
  (26, 'Rebaia', 'الربعية', '26039'),
  (26, 'Medjebar', 'مجبر', '26033'),
  (26, 'Tletat Ed Douair', 'ثلاث دوائر', '26046'),
  (26, 'Zoubiria', 'الزبيرية', '26021'),
  (26, 'Seghouane', 'سغوان', '26041'),
  (26, 'Aissaouia', 'العيساوية', '26022'),
  (26, 'El Haoudane', 'الحوضان', '26058'),
  (26, 'Mezerana', 'مزغنة', NULL),
  (26, 'Tablat', 'تابلاط', '26004'),
  (26, 'Draa Esmar', 'ذراع السمار', '26017'),
  (26, 'Medea', 'المدية', '26000'),
  (26, 'Tamesguida', 'تمسقيدة', '26075'),
  (26, 'Ben Chicao', 'بن شكاو', '26012'),
  (26, 'El Hamdania', 'الحمدانية', '26060'),
  (26, 'Ouzera', 'وزرة', '26019'),
  (26, 'Tizi Mahdi', 'تيزي مهدي', '26076'),
  (26, 'Baata', 'بعطة', '26050'),
  (26, 'El Omaria', 'العمارية', '26008'),
  (26, 'Ouled Brahim', 'أولاد إبراهيم', '20002'),
  (26, 'Bir Ben Laabed', 'بئر بن عابد', '26053'),
  (26, 'El Guelbelkebir', 'القلب الكبير', '26030'),
  (26, 'Sedraya', 'سدراية', '26068'),
  (26, 'Bouchrahil', 'بوشراحيل', '26014'),
  (26, 'Khams Djouamaa', 'خمس جوامع', '26062'),
  (26, 'Sidi Naamane', 'سيدي نعمان', '26071'),
  (27, 'Fornaka', 'فرناقة', '27014'),
  (27, 'Hassiane', 'الحسيان (بني ياحي', '27033'),
  (27, 'Ain-Nouissy', 'عين نويسي', '27010'),
  (27, 'Oued El Kheir', 'وادي الخير', '27020'),
  (27, 'Ain-Tedles', 'عين تادلس', '27001'),
  (27, 'Sidi Belaattar', 'سيدي بلعطار', '27029'),
  (27, 'Sour', 'سور', '27022'),
  (27, 'Hassi Mameche', 'حاسي ماماش', '27004'),
  (27, 'Mazagran', 'مزغران', '27017'),
  (27, 'Stidia', 'ستيدية', '27023'),
  (27, 'Ain-Boudinar', 'عين بودينار', '27031'),
  (27, 'Kheir-Eddine', 'خير الدين', '27016'),
  (27, 'Sayada', 'صيادة', '27045'),
  (27, 'Sidi Ali', 'سيدي علي', '27032'),
  (27, 'Tazgait', 'تزقايت', '27047'),
  (27, 'Ouled-Maalah', 'أولاد مع الله', '27028'),
  (27, 'Benabdelmalek Ramdane', 'بن عبد المالك رمضان', '27008'),
  (27, 'Hadjadj', 'حجاج', '27015'),
  (27, 'Sidi-Lakhdar', 'سيدي لخضر', '27007'),
  (27, 'Mostaganem', 'مستغانم', '27000'),
  (27, 'Achaacha', 'عشعاشة', '27009'),
  (27, 'Khadra', 'خضرة', '27005'),
  (27, 'Nekmaria', 'نكمارية', '27026'),
  (27, 'Ouled Boughalem', 'أولاد بوغالم', '27027'),
  (27, 'Bouguirat', 'بوقيراط', '27003'),
  (27, 'Safsaf', 'صفصاف', NULL),
  (27, 'Sirat', 'سيرات', '27021'),
  (27, 'Souaflia', 'السوافلية', '27046'),
  (27, 'Ain-Sidi Cherif', 'عين سيدي الشريف', '27024'),
  (27, 'Mesra', 'ماسرة', '27018'),
  (27, 'Touahria', 'الطواهرية', '27013'),
  (27, 'Mansourah', 'منصورة', '13062'),
  (28, 'Chellal', 'شلال', '28014'),
  (28, 'Ouled Madhi', 'أولاد ماضي', '28047'),
  (28, 'Khettouti Sed-El-Jir', 'خطوطي سد الجير', '28056'),
  (28, 'Belaiba', 'بلعايبة', '28026'),
  (28, 'Berhoum', 'برهوم', '28010'),
  (28, 'Dehahna', 'دهاهنة', '28048'),
  (28, 'Magra', 'مقرة', '28006'),
  (28, 'Ain Khadra', 'عين الخضراء', '28008'),
  (28, 'Beni Ilmane', 'بني يلمان', '28027'),
  (28, 'Bouti Sayeh', 'بوطي السايح', '28042'),
  (28, 'Sidi Aissa', 'سيدي عيسى', '28002'),
  (28, 'Ain El Hadjel', 'عين الحجل', '28003'),
  (28, 'Djebel Messaad', 'جبل مساعد', '28024'),
  (28, 'M''sila', 'المسيلة', '28000'),
  (28, 'Hammam Dalaa', 'حمام الضلعة', '28005'),
  (28, 'Ouanougha', 'ونوغة', '28017')
ON CONFLICT (wilaya_code, name_fr) DO NOTHING;

INSERT INTO communes (wilaya_code, name_fr, name_ar, postal_code) VALUES
  (28, 'Ouled Mansour', 'أولاد منصور', '28060'),
  (28, 'Tarmount', 'تارمونت', '28038'),
  (28, 'Ouled Derradj', 'أولاد دراج', '28022'),
  (28, 'Souamaa', 'السوامع', '28064'),
  (28, 'Ouled Addi Guebala', 'أولاد عدي لقبالة', '28021'),
  (28, 'El Houamed', 'الحوامد', NULL),
  (28, 'Khoubana', 'خبانة', '28030'),
  (28, 'M''cif', 'مسيف', '28029'),
  (29, 'Oued El Abtal', 'وادي الأبطال', '29016'),
  (29, 'Sidi Abdeldjebar', 'سيدي عبد الجبار', '29065'),
  (29, 'Ain Ferah', 'عين فراح', '29032'),
  (29, 'Sidi Abdelmoumene', 'سيدي عبد المومن', '29054'),
  (29, 'Sedjerara', 'سجرارة', '29062'),
  (29, 'Mocta-Douz', 'مقطع الدوز', '29027'),
  (29, 'Ferraguig', 'فراقيق', '29046'),
  (29, 'El Ghomri', 'الغمري', '29023'),
  (29, 'Mohammadia', 'المحمدية', '16058'),
  (29, 'Tighennif', 'تيغنيف', '29004'),
  (29, 'Sidi Kada', 'سيدي قادة', '29030'),
  (29, 'Sehailia', 'السهايلية', '29063'),
  (29, 'Zahana', 'زهانة', '29019'),
  (29, 'El Gaada', 'القعدة', '29041'),
  (29, 'Ras El Ain Amirouche', 'رأس عين عميروش', '29060'),
  (29, 'Oggaz', 'عقاز', '29029'),
  (29, 'Alaimia', 'العلايمية', '29036'),
  (29, 'Sig', 'سيق', '29001'),
  (29, 'Chorfa', 'الشرفاء', '29039'),
  (29, 'Bou Henni', 'بوهني', '29022'),
  (29, 'El Mamounia', 'المأمونية', '29056'),
  (29, 'El Gueitena', 'القطنة', '29042'),
  (29, 'Bouhanifia', 'بوحنيفية', '29005'),
  (29, 'Hacine', 'حسين', '29014'),
  (29, 'Ain Fares', 'عين فارس', '28023'),
  (29, 'Gharrous', 'غروس', '29047'),
  (29, 'Benian', 'بنيان', '29038'),
  (29, 'Aouf', 'عوف', '29021'),
  (29, 'Guerdjoum', 'قرجوم', '29050'),
  (29, 'Oued Taria', 'وادي التاغية', '29017'),
  (29, 'Ain Frass', 'عين أفرص', '29034'),
  (29, 'Ain Fekan', 'عين فكان', '29011'),
  (29, 'Khalouia', 'خلوية', '29025'),
  (29, 'El Menaouer', 'المنور', '29044'),
  (29, 'El Bordj', 'البرج', '29012'),
  (29, 'Sidi Boussaid', 'سيدي بوسعيد', '29069'),
  (29, 'Matemore', 'المطمور', '29026'),
  (29, 'Makhda', 'ماقضة', '29055'),
  (29, 'Ghriss', 'غريس', '29006'),
  (29, 'Maoussa', 'ماوسة', '29015'),
  (29, 'Mascara', 'معسكر', '29000'),
  (29, 'El Keurt', 'القرط', '29043'),
  (29, 'Froha', 'فروحة', '29024'),
  (29, 'Tizi', 'تيزي', NULL),
  (29, 'El Hachem', 'الحشم', '29013'),
  (29, 'Nesmot', 'نسمط', '29058'),
  (29, 'Zelamta', 'زلامطة', '29057'),
  (30, 'Ouargla', 'ورقلة', '30000'),
  (30, 'Rouissat', 'الرويسات', '30013'),
  (30, 'Hassi Messaoud', 'حاسي مسعود', '30001'),
  (30, 'Ain Beida', 'عين البيضاء', '04001'),
  (30, 'Hassi Ben Abdellah', 'حاسي بن عبد الله', '30052'),
  (30, 'Sidi Khouiled', 'سيدي خويلد', '30035'),
  (30, 'El Borma', 'البرمة', '30025'),
  (30, 'N''goussa', 'انقوسة', '30026'),
  (31, 'Sidi Chami', 'سيدي الشحمي', '31038'),
  (31, 'El Kerma', 'الكرمة', '31026'),
  (31, 'Es Senia', 'السانية', '31005'),
  (31, 'Hassi Mefsoukh', 'حاسي مفسوخ', '31046'),
  (31, 'Gdyel', 'قديل', '31017'),
  (31, 'Ben Freha', 'بن فريحة', '31027'),
  (31, 'Bir El Djir', 'بئر الجير', '31001'),
  (31, 'Hassi Ben Okba', 'حاسي بن عقبة', '31049'),
  (31, 'Hassi Bounif', 'حاسي بونيف', '31028'),
  (31, 'Arzew', 'أرزيو', '31004'),
  (31, 'Sidi Ben Yebka', 'سيدي بن يبقى', '31058'),
  (31, 'Ain Biya', 'عين البية', '31040'),
  (31, 'Bethioua', 'بطيوة', '31015'),
  (31, 'Marsat El Hadjadj', 'مرسى الحجاج', '31030'),
  (31, 'Ain Turk', 'عين الترك', '10033'),
  (31, 'Oran', 'وهران', '31000'),
  (31, 'El Ancor', 'العنصر', '31043'),
  (31, 'Mers El Kebir', 'المرسى الكبير', '31019'),
  (31, 'Bousfer', 'بوسفر', '31025'),
  (31, 'Boufatis', 'بوفاتيس', '31024'),
  (31, 'El Braya', 'البراية', '31070'),
  (31, 'Oued Tlelat', 'وادي تليلات', '31037'),
  (31, 'Tafraoui', 'طفراوي', '31077'),
  (31, 'Ain Kerma', 'عين الكرمة', '31059'),
  (31, 'Boutlelis', 'بوتليليس', '31016'),
  (31, 'Messerghin', 'مسرغين', '31031'),
  (32, 'Ain El Orak', 'عين العراك', '32019'),
  (32, 'El Bnoud', 'البنود', '32025'),
  (32, 'Krakda', 'كراكدة', '32027'),
  (32, 'Sidi Slimane', 'سيدي سليمان', '30030'),
  (32, 'Boualem', 'بوعلام', '32006'),
  (32, 'Sidi Tiffour', 'سيدي طيفور', '32032'),
  (32, 'Stitten', 'ستيتن', '32033'),
  (32, 'Sidi Ameur', 'سيدي عامر', NULL),
  (32, 'Bougtoub', 'بوقطب', '32001'),
  (32, 'El Kheiter', 'الخيثر', '32011'),
  (32, 'Tousmouline', 'توسمولين', '32034'),
  (32, 'El Bayadh', 'البيض', '32000'),
  (32, 'Rogassa', 'رقاصة', '32018'),
  (32, 'Kef El Ahmar', 'الكاف الأحمر', '32013'),
  (32, 'El Mehara', 'المحرة', '32024'),
  (33, 'Bordj Omar Driss', 'برج عمر إدريس', '33003'),
  (33, 'Debdeb', 'دبداب', '33004'),
  (33, 'In Amenas', 'إن أمناس', '33001'),
  (33, 'Illizi', 'إيليزي', '33000'),
  (34, 'Elhammadia', 'الحمادية', NULL),
  (34, 'El Euch', 'العش', '34029'),
  (34, 'Ksour', 'القصور', '34048'),
  (34, 'Rabta', 'الرابطة', '34035'),
  (34, 'Ouled Sidi-Brahim', 'أولاد سيدي ابراهيم', '28032'),
  (34, 'Ain Taghrout', 'عين تاغروت', '34010'),
  (34, 'Tixter', 'تيكستار', '34022'),
  (34, 'Belimour', 'بليمور', '34025'),
  (34, 'El Annasseur', 'العناصر', '34030'),
  (34, 'Ghailasa', 'غيلاسة', '34031'),
  (34, 'Taglait', 'تقلعيت', '34059'),
  (34, 'Bordj Ghedir', 'برج الغدير', '34004'),
  (34, 'Sidi-Embarek', 'سيدي أمبارك', '34020'),
  (34, 'Khelil', 'خليل', '34028'),
  (34, 'Bir Kasdali', 'بئر قاصد علي', '34011'),
  (34, 'Tefreg', 'تفرق', '34061'),
  (34, 'El Main', 'الماين', '34018'),
  (34, 'Djaafra', 'جعافرة', '34016'),
  (34, 'Colla', 'القلة', '34015'),
  (34, 'Teniet En Nasr', 'ثنية النصر', '34021'),
  (34, 'El Achir', 'الياشير', '34006'),
  (34, 'Hasnaoua', 'حسناوة', '34068'),
  (34, 'Medjana', 'مجانة', '34009'),
  (34, 'El M''hir', 'المهير', '34019'),
  (34, 'Mansoura', 'المنصورة', '34008'),
  (34, 'Haraza', 'حرازة', '34047'),
  (34, 'Ben Daoud', 'بن داود', '34073'),
  (34, 'Ain Tesra', 'عين تسرة', '34027'),
  (34, 'Ouled Brahem', 'أولاد أبراهم', '34032'),
  (34, 'Ras El Oued', 'رأس الوادي', '34001'),
  (34, 'Bordj Zemmoura', 'برج زمورة', '34005'),
  (34, 'Ouled Dahmane', 'أولاد دحمان', '34033'),
  (34, 'Tassamert', 'تسامرت', '34026'),
  (34, 'B. B. Arreridj', 'برج بوعريرج', '34000'),
  (35, 'El Kharrouba', 'الخروبة', NULL),
  (35, 'Bouzegza Keddara', 'بوزقزة قدارة', '35038'),
  (35, 'Ouled Hedadj', 'أولاد هداج', '35052'),
  (35, 'Boudouaou', 'بودواو', '35003'),
  (35, 'Boudouaou El Bahri', 'بودواو البحري', '35023'),
  (35, 'Dellys', 'دلس', '35004'),
  (35, 'Ben Choud', 'بن شود', '35033'),
  (35, 'Afir', 'أعفير', '35022')
ON CONFLICT (wilaya_code, name_fr) DO NOTHING;

INSERT INTO communes (wilaya_code, name_fr, name_ar, postal_code) VALUES
  (35, 'Thenia', 'الثنية', '35005'),
  (35, 'Beni Amrane', 'بني عمران', '35006'),
  (35, 'Ammal', 'عمال', '35031'),
  (35, 'Souk El Had', 'سوق الحد', NULL),
  (35, 'Khemis El Khechna', 'خميس الخشنة', '35010'),
  (35, 'Larbatache', 'الاربعطاش', '35017'),
  (35, 'Ouled Moussa', 'أولاد موسى', '35011'),
  (35, 'Hammedi', 'حمادي', '35015'),
  (35, 'Timezrit', 'تيمزريت', '06019'),
  (35, 'Zemmouri', 'زموري', '35012'),
  (35, 'Leghata', 'لقاطة', '35026'),
  (35, 'Djinet', 'جنات', '35024'),
  (35, 'Bordj Menaiel', 'برج منايل', '35001'),
  (35, 'Isser', 'يسر', '35009'),
  (35, 'Chabet El Ameur', 'شعبة العامر', '35008'),
  (35, 'Si Mustapha', 'سي مصطفى', '35028'),
  (35, 'Ouled Aissa', 'أولاد عيسى', '01051'),
  (35, 'Naciria', 'الناصرية', '35018'),
  (35, 'Sidi Daoud', 'سيدي داود', '35019'),
  (35, 'Baghlia', 'بغلية', '35013'),
  (35, 'Taourga', 'تاورقة', '35029'),
  (35, 'Tidjelabine', 'تيجلابين', '35021'),
  (35, 'Boumerdes', 'بومرداس', '35000'),
  (35, 'Corso', 'قورصو', '35014'),
  (36, 'Ain El Assel', 'عين العسل', '36010'),
  (36, 'Bougous', 'بوقوس', '36029'),
  (36, 'El Tarf', 'الطارف', '36000'),
  (36, 'Zitouna', 'الزيتونة', '21028'),
  (36, 'Besbes', 'البسباس', '36017'),
  (36, 'Zerizer', 'زريزر', '36015'),
  (36, 'Asfour', 'عصفور', '36012'),
  (36, 'Ain Kerma', 'عين الكرمة', '31059'),
  (36, 'Bouhadjar', 'بوحجار', '36005'),
  (36, 'Hammam Beni Salah', 'حمام بني صالح', '36036'),
  (36, 'Oued Zitoun', 'وادي الزيتون', '36044'),
  (36, 'Ben M Hidi', 'بن مهيدي', '36003'),
  (36, 'Berrihane', 'بريحان', '36027'),
  (36, 'Echatt', 'الشط', '36025'),
  (36, 'Chebaita Mokhtar', 'شبيطة مختار', '36013'),
  (36, 'Chihani', 'شحاني', '36014'),
  (36, 'Drean', 'الذرعـان', '36001'),
  (36, 'El Aioun', 'العيون', '36018'),
  (36, 'El Kala', 'القالة', '36002'),
  (36, 'Souarekh', 'السوارخ', '36020'),
  (36, 'Raml Souk', 'رمل السوق', '36021'),
  (36, 'Bouteldja', 'بوثلجة', '36006'),
  (36, 'Chefia', 'الشافية', '36032'),
  (36, 'Lac Des Oiseaux', 'بحيرة الطيور', '36019'),
  (37, 'Tindouf', 'تندوف', '37000'),
  (37, 'Oum El Assel', 'أم العسل', '37003'),
  (38, 'Khemisti', 'خميستي', '38016'),
  (38, 'Layoune', 'العيون', '38007'),
  (38, 'Theniet El Had', 'ثنية الاحد', '38003'),
  (38, 'Sidi Boutouchent', 'سيدي بوتوشنت', '38026'),
  (38, 'Ouled Bessam', 'أولاد بسام', '38014'),
  (38, 'Tissemsilt', 'تيسمسيلت', '38000'),
  (38, 'Sidi Lantri', 'سيدي العنتري', '38027'),
  (38, 'Lardjem', 'لرجام', '38002'),
  (38, 'Melaab', 'الملعب', '38013'),
  (38, 'Tamellahet', 'تملاحت', '38029'),
  (38, 'Beni Chaib', 'بني شعيب', '38019'),
  (38, 'Beni Lahcene', 'بني لحسن', '38020'),
  (38, 'Bordj Bounaama', 'برج بونعامة', '38001'),
  (38, 'Sidi Abed', 'سيدي عابد', '38025'),
  (38, 'Ammari', 'عماري', '38012'),
  (38, 'Maacem', 'المعاصم', '38023'),
  (38, 'Sidi Slimane', 'سيدي سليمان', '30030'),
  (38, 'Boucaid', 'بوقائد', '38005'),
  (38, 'Lazharia', 'الأزهرية', '38008'),
  (38, 'Larbaa', 'الأربعاء', '09002'),
  (38, 'Youssoufia', 'اليوسفية', '38031'),
  (38, 'Bordj El Emir Abdelkader', 'برج الأمير عبد القادر', '38041'),
  (39, 'Douar El Maa', 'دوار الماء', '39024'),
  (39, 'Ben Guecha', 'بن  قشة', '39048'),
  (39, 'Taleb Larbi', 'الطالب العربي', '39019'),
  (39, 'El Ogla', 'العقلة', '12015'),
  (39, 'Magrane', 'المقرن', '39015'),
  (39, 'Sidi Aoun', 'سيدي عون', '39037'),
  (39, 'Mih Ouansa', 'اميه وانسة', '39030'),
  (39, 'Oued El Alenda', 'وادي العلندة', '39033'),
  (39, 'Kouinine', 'كوينين', '39014'),
  (39, 'El-Oued', 'الوادي', '39000'),
  (39, 'Bayadha', 'البياضة', '39007'),
  (39, 'Nakhla', 'النخلة', '39031'),
  (39, 'Robbah', 'الرباح', '39017'),
  (39, 'Guemar', 'قمار', '39002'),
  (39, 'Ourmes', 'ورماس', '39035'),
  (39, 'Taghzout', 'تغزوت', '39083'),
  (39, 'Hamraia', 'الحمراية', '39061'),
  (39, 'Reguiba', 'الرقيبة', '39016'),
  (39, 'Debila', 'الدبيلة', '39003'),
  (39, 'Hassani Abdelkrim', 'حساني عبد الكريم', '39020'),
  (39, 'Hassi Khalifa', 'حاسي خليفة', '39013'),
  (39, 'Trifaoui', 'الطريفاوي', '39044'),
  (40, 'Khirane', 'خيران', '40036'),
  (40, 'Djellal', 'جلال', '40015'),
  (40, 'El Oueldja', 'الولجة', '19046'),
  (40, 'Chechar', 'ششار', '40008'),
  (40, 'Babar', 'بابار', '40006'),
  (40, 'El Mahmal', 'المحمل', '40012'),
  (40, 'Ouled Rechache', 'أولاد رشاش', '40013'),
  (40, 'Yabous', 'يابوس', '40023'),
  (40, 'Chelia', 'شلية', '40030'),
  (40, 'Bouhmama', 'بوحمامة', '40007'),
  (40, 'M''sara', 'مصارة', '40039'),
  (40, 'Khenchela', 'خنشلة', '40000'),
  (40, 'Kais', 'قايس', '40001'),
  (40, 'Remila', 'الرميلة', '40041'),
  (40, 'Taouzianat', 'تاوزيانت', '40011'),
  (40, 'Baghai', 'بغاي', '40014'),
  (40, 'El Hamma', 'الحامة', '40031'),
  (40, 'Ensigha', 'انسيغة', '40043'),
  (40, 'Tamza', 'طامزة', '40024'),
  (40, 'Ain Touila', 'عين الطويلة', '40028'),
  (40, 'M''toussa', 'متوسة', '40021'),
  (41, 'Souk Ahras', 'سوق أهراس', '41000'),
  (41, 'Ain Soltane', 'عين سلطان', '20029'),
  (41, 'Sedrata', 'سدراتة', '41006'),
  (41, 'Khemissa', 'خميسة', '41031'),
  (41, 'Hanencha', 'الحنانشة', '41016'),
  (41, 'Machroha', 'المشروحة', '41010'),
  (41, 'Ain Zana', 'عين الزانة', '41027'),
  (41, 'Ouled Driss', 'أولاد إدريس', '41005'),
  (41, 'Terraguelt', 'ترقالت', '41037'),
  (41, 'Oum El Adhaim', 'أم العظايم', '41019'),
  (41, 'Oued Kebrit', 'وادي الكبريت', '41018'),
  (41, 'Tiffech', 'تيفاش', '41038'),
  (41, 'Ragouba', 'الراقوبة', '41033'),
  (41, 'M''daourouche', 'مداوروش', '41001'),
  (41, 'Drea', 'الدريعة', '41015'),
  (41, 'Taoura', 'تاورة', '41009'),
  (41, 'Zaarouria', 'الزعرورية', '41025'),
  (41, 'Haddada', 'الحدادة', '41012'),
  (41, 'Khedara', 'الخضارة', '41013'),
  (41, 'Ouled Moumen', 'أولاد مومن', '41034'),
  (41, 'Merahna', 'المراهنة', '41004'),
  (41, 'Ouillen', 'ويلان', '41029'),
  (41, 'Sidi Fredj', 'سيدي فرج', NULL),
  (41, 'Bir Bouhouche', 'بئر بوحوش', '41011'),
  (41, 'Safel El Ouiden', 'سافل الويدان', '41035'),
  (41, 'Zouabi', 'الزوابي', '41039'),
  (42, 'Hadjout', 'حجوط', '42001'),
  (42, 'Merad', 'مراد', '42019'),
  (42, 'Menaceur', 'مناصر', '42018'),
  (42, 'Nador', 'الناظور', '42039'),
  (42, 'Sidi-Amar', 'سيدي عامر', '20019'),
  (42, 'Aghbal', 'أغبال', '42035'),
  (42, 'Gouraya', 'قوراية', '42007'),
  (42, 'Messelmoun', 'مسلمون', '42036'),
  (42, 'Cherchell', 'شرشال', '42002')
ON CONFLICT (wilaya_code, name_fr) DO NOTHING;

INSERT INTO communes (wilaya_code, name_fr, name_ar, postal_code) VALUES
  (42, 'Hadjret Ennous', 'حجرة النص', '42029'),
  (42, 'Sidi Ghiles', 'سيدي غيلاس', '42021'),
  (42, 'Sidi Semiane', 'سيدي سميان', '42041'),
  (42, 'Damous', 'الداموس', '42014'),
  (42, 'Larhat', 'الأرهاط', '42017'),
  (42, 'Beni Mileuk', 'بني ميلك', '42024'),
  (42, 'Fouka', 'فوكة', '42006'),
  (42, 'Douaouda', 'دواودة', '42015'),
  (42, 'Ain Tagourait', 'عين تاقورايت', '42023'),
  (42, 'Bou Haroun', 'بوهارون', '42009'),
  (42, 'Bou Ismail', 'بواسماعيل', '42004'),
  (42, 'Khemisti', 'خميستي', '38016'),
  (42, 'Ahmer El Ain', 'أحمر العين', '42005'),
  (42, 'Bourkika', 'بورقيقة', '42011'),
  (42, 'Sidi Rached', 'سيدي راشد', '42040'),
  (42, 'Attatba', 'الحطاطبة', '42008'),
  (42, 'Chaiba', 'الشعيبة', '42047'),
  (42, 'Kolea', 'القليعة', '42003'),
  (42, 'Tipaza', 'تيبازة', '42000'),
  (43, 'El Mechira', 'مشيرة', '43026'),
  (43, 'Teleghma', 'التلاغمة', '43008'),
  (43, 'Oued Seguen', 'وادي سقان', '43031'),
  (43, 'El Ayadi Barbes', 'العياضي برباس', '43050'),
  (43, 'Ain Beida Harriche', ' عين البيضاء أحريش', '43014'),
  (43, 'Tassala Lematai', 'تسالة لمطاعي', '43034'),
  (43, 'Terrai Bainen', 'ترعي باينان', '43018'),
  (43, 'Amira Arres', 'اعميرة اراس', '43017'),
  (43, 'Tassadane Haddada', 'تسدان حدادة', '43033'),
  (43, 'Minar Zarza', 'مينار زارزة', '43036'),
  (43, 'Sidi Merouane', 'سيدي مروان', '43010'),
  (43, 'Chigara', 'الشيقارة', '43025'),
  (43, 'Hamala', 'حمالة', '43052'),
  (43, 'Grarem Gouga', 'القرارم قوقة', '43004'),
  (43, 'Tiberguent', 'تيبرقنت', '43035'),
  (43, 'Rouached', 'الرواشد', '43009'),
  (43, 'Derrahi Bousselah', 'دراحي بوصلاح', '43046'),
  (43, 'Bouhatem', 'بوحاتم', '43022'),
  (43, 'Zeghaia', 'زغاية', '43012'),
  (43, 'Oued Endja', 'وادي النجاء', '43006'),
  (43, 'Ahmed Rachedi', 'أحمد راشدي', '43013'),
  (43, 'Tadjenanet', 'تاجنانت', '43007'),
  (43, 'Ouled Khalouf', 'أولاد اخلوف', '43032'),
  (43, 'Benyahia Abderrahmane', 'بن يحي عبد الرحمن', '43020'),
  (43, 'Ain Mellouk', 'عين الملوك', '43015'),
  (43, 'Oued Athmenia', 'وادي العثمانية', '43005'),
  (43, 'Chelghoum Laid', 'شلغوم العيد', '43001'),
  (43, 'Ain Tine', 'عين التين', '43016'),
  (43, 'Sidi Khelifa', 'سيدي خليفة', '43058'),
  (43, 'Mila', 'ميلة', '43000'),
  (43, 'Yahia Beniguecha', 'يحي بني قشة', '43071'),
  (43, 'Ferdjioua', 'فرجيوة', '43002'),
  (44, 'Khemis-Miliana', 'خميس مليانة', '44001'),
  (44, 'Sidi-Lakhdar', 'سيدي الأخضر', '27007'),
  (44, 'Ain-Benian', 'عين البنيان', '44035'),
  (44, 'Ain-Torki', 'عين التركي', '44020'),
  (44, 'Hammam-Righa', 'حمام ريغة', '44023'),
  (44, 'Bourached', 'بوراشد', '44044'),
  (44, 'Djelida', 'جليدة', '44009'),
  (44, 'Djemaa Ouled Cheikh', 'جمعة أولاد الشيخ', '44047'),
  (44, 'Hoceinia', 'الحسينية', '44048'),
  (44, 'Boumedfaa', 'بومدفع', '44004'),
  (44, 'Arib', 'عريب', '44008'),
  (44, 'El-Amra', 'العامرة', '44010'),
  (44, 'Mekhatria', 'المخاطرية', '44050'),
  (44, 'El-Attaf', 'العطاف', '44002'),
  (44, 'Tiberkanine', 'تبركانين', '44030'),
  (44, 'Ain-Bouyahia', 'عين بويحيى', '44032'),
  (44, 'El-Abadia', 'العبادية', '44006'),
  (44, 'Tacheta Zegagha', 'تاشتة زقاغة', '44028'),
  (44, 'Birbouche', 'بربوش', '44042'),
  (44, 'Djendel', 'جندل', '44005'),
  (44, 'Oued Chorfa', 'وادي الشرفاء', '44024'),
  (44, 'Ben Allal', 'بن علال', '44040'),
  (44, 'Miliana', 'مليانة', '44003'),
  (44, 'Ain-Lechiakh', 'عين الاشياخ', '44018'),
  (44, 'Oued Djemaa', 'واد الجمعة', '44049'),
  (44, 'Ain-Soltane', 'عين السلطان', '20029'),
  (44, 'El-Maine', 'الماين', '44051'),
  (44, 'Rouina', 'الروينة', '44017'),
  (44, 'Zeddine', 'زدين', '44031'),
  (44, 'Bir-Ould-Khelifa', 'بئر ولد خليفة', '44043'),
  (44, 'Bordj-Emir-Khaled', 'برج الأمير خالد', '44021'),
  (44, 'Tarik-Ibn-Ziad', 'طارق بن زياد', '44029'),
  (44, 'Bathia', 'بطحية', '44041'),
  (44, 'Belaas', 'بلعاص', '44038'),
  (44, 'Hassania', 'الحسانية', '44022'),
  (44, 'Ain-Defla', 'عين الدفلى', '44000'),
  (45, 'Tiout', 'تيوت', '45030'),
  (45, 'Ain Sefra', 'عين الصفراء', '45001'),
  (45, 'Moghrar', 'مغرار', '45014'),
  (45, 'Djenienne Bourezg', 'جنين بورزق', '45013'),
  (45, 'Asla', 'عسلة', '45012'),
  (45, 'Kasdir', 'القصدير', '45024'),
  (45, 'Makmen Ben Amar', 'مكمن بن عمار', '45005'),
  (45, 'Mecheria', 'المشرية', '45002'),
  (45, 'El Biodh', 'البيوض', '45004'),
  (45, 'Ain Ben Khelil', 'عين بن خليل', '45008'),
  (45, 'Naama', 'النعامة', '45000'),
  (45, 'Sfissifa', 'سفيسيفة', '45021'),
  (46, 'Sidi Boumediene', 'سيدي بومدين', '46051'),
  (46, 'Tamzoura', 'تامزورة', '46026'),
  (46, 'Oued Sebbah', 'وادي الصباح', '46023'),
  (46, 'Ain El Arbaa', 'عين الأربعاء', '46009'),
  (46, 'Chaabat El Ham', 'شعبة اللحم', '46011'),
  (46, 'El Maleh', 'المالح', '46067'),
  (46, 'Ouled Kihal', 'أولاد الكيحل', '46038'),
  (46, 'Terga', 'تارقة', '46015'),
  (46, 'Chentouf', 'شنتوف', NULL),
  (46, 'Hassasna', 'الحساسنة', '20003'),
  (46, 'Oued Berkeche', 'وادي برقش', '46022'),
  (46, 'Hammam Bou Hadjar', 'حمام بوحجر', '46005'),
  (46, 'El Amria', 'العامرية', '46006'),
  (46, 'Hassi El Ghella', 'حاسي الغلة', '46012'),
  (46, 'Ouled Boudjemaa', 'أولاد بوجمعة', '46043'),
  (46, 'El Messaid', 'المساعيد', '46035'),
  (46, 'Bouzedjar', 'بوزجار', '46033'),
  (46, 'Aghlal', 'أغلال', '46016'),
  (46, 'Ain Kihal', 'عين الكيحل', '46008'),
  (46, 'Ain Tolba', 'عين الطلبة', '46010'),
  (46, 'Aoubellil', 'عقب الليل', '46017'),
  (46, 'Beni Saf', 'بني صاف', '46001'),
  (46, 'Sidi Safi', 'سيدي صافي', '46025'),
  (46, 'Emir Abdelkader', 'الأمير عبد القادر', '18010'),
  (46, 'Oulhaca El Gheraba', 'ولهاصة الغرابة', '46053'),
  (46, 'Sidi Ouriache', 'سيدي ورياش', '46024'),
  (46, 'Sidi Ben Adda', 'سيدي بن عدة', '46013'),
  (46, 'Ain Temouchent', 'عين تموشنت', '46000'),
  (47, 'Dhayet Bendhahoua', 'ضاية بن ضحوة', '47011'),
  (47, 'Mansoura', 'المنصورة', '34008'),
  (47, 'El Atteuf', 'العطف', '47012'),
  (47, 'Bounoura', 'بونورة', '47005'),
  (47, 'Zelfana', 'زلفانة', '47007'),
  (47, 'El Guerrara', 'القرارة', '47004'),
  (47, 'Sebseb', 'سبسب', '47025'),
  (47, 'Metlili', 'متليلي', '47002'),
  (47, 'Berriane', 'بريان', '47003'),
  (47, 'Ghardaia', 'غرداية', '47000'),
  (48, 'El-Guettar', 'القطار', '48016'),
  (48, 'Mazouna', 'مازونة', '48002'),
  (48, 'Ouled Aiche', 'أولاد يعيش', '48019'),
  (48, 'Ammi Moussa', 'عمي موسى', '48004'),
  (48, 'Beni Dergoun', 'بني درقن', '48039'),
  (48, 'Dar Ben Abdelah', 'دار بن عبد الله', '48044'),
  (48, 'Zemmoura', 'زمورة', '48008'),
  (48, 'Djidiouia', 'جديوية', '48005'),
  (48, 'Hamri', 'حمري', '48051'),
  (48, 'Ouled Sidi Mihoub', 'أولاد سيدي الميهوب', '48061'),
  (48, 'Belaassel Bouzagza', 'بلعسل بوزقزة', '48036'),
  (48, 'El-Matmar', 'المطمر', '48009'),
  (48, 'Sidi Khettab', 'سيدي  خطاب', '48029')
ON CONFLICT (wilaya_code, name_fr) DO NOTHING;

INSERT INTO communes (wilaya_code, name_fr, name_ar, postal_code) VALUES
  (48, 'Sidi M''hamed Benaouda', 'سيدي امحمد بن عودة', '48030'),
  (48, 'Ain-Tarek', 'عين طارق', '48015'),
  (48, 'Had Echkalla', 'حد الشكالة', '48050'),
  (48, 'El Ouldja', 'الولجة', '19046'),
  (48, 'Ain Rahma', 'عين الرحمة', '48033'),
  (48, 'Kalaa', 'القلعة', '48018'),
  (48, 'Sidi Saada', 'سيدي سعادة', '48067'),
  (48, 'Yellel', 'يلل', '48006'),
  (48, 'Souk El Had', 'سوق الحد', NULL),
  (48, 'Mendes', 'منداس', '48012'),
  (48, 'Oued Essalem', 'وادي السلام', '48022'),
  (48, 'Sidi Lazreg', 'سيدي لزرق', '48065'),
  (48, 'Ouarizane', 'واريزان', '48013'),
  (48, 'Merdja Sidi Abed', 'مرجة سيدي عابد', '48056'),
  (48, 'Oued-Rhiou', 'وادي رهيو', '48001'),
  (48, 'Lahlef', 'لحلاف', '48020'),
  (48, 'Bendaoud', 'بن داود', '48053'),
  (48, 'Relizane', 'غليزان', '48000'),
  (48, 'El Hassi', 'الحاسي', '05116'),
  (48, 'Sidi M''hamed Benali', 'سيدي أمحمد بن علي', '48003'),
  (48, 'Mediouna', 'مديونة', '48011'),
  (48, 'Beni Zentis', 'بني زنطيس', '48041'),
  (48, 'Oued El Djemaa', 'وادي الجمعة', '48021'),
  (48, 'El H''madna', 'الحمادنة', '48017'),
  (48, 'Ramka', 'الرمكة', '48024'),
  (49, 'Tinerkouk', 'تنركوك', '01013'),
  (49, 'Ksar Kaddour', 'قصر قدور', '01035'),
  (49, 'Timimoun', 'تيميمون', '01001'),
  (49, 'Ouled Said', 'أولاد السعيد', '01039'),
  (49, 'Metarfa', 'المطارفة', '01033'),
  (49, 'Aougrout', 'أوقروت', '01012'),
  (49, 'Talmine', 'طالمين', '01034'),
  (49, 'Charouine', 'شروين', '01014'),
  (49, 'Ouled Aissa', 'أولاد عيسى', '01051'),
  (49, 'Deldoul', 'دلدول', '17046'),
  (50, 'Timiaouine', 'تيمياوين', '01042'),
  (50, 'Bordj Badji Mokhtar', 'برج باجي مختار', '01010'),
  (51, 'Ras El Miad', 'رأس الميعاد', '07062'),
  (51, 'Besbes', 'بسباس', '07044'),
  (51, 'Sidi Khaled', 'سيدي  خالد', '07004'),
  (51, 'Doucen', 'الدوسن', '07007'),
  (51, 'Ouled Djellal', 'أولاد جلال', '07002'),
  (51, 'Chaiba', 'الشعيبة', '42047'),
  (52, 'Beni-Abbes', 'بني عباس', '08002'),
  (52, 'Tamtert', 'تامترت', '08046'),
  (52, 'Igli', 'إقلي', '08021'),
  (52, 'El Ouata', 'الواتة', '08020'),
  (52, 'Ouled-Khodeir', 'أولاد خضير', '08028'),
  (52, 'Ksabi', 'القصابي', '08039'),
  (52, 'Kerzaz', 'كرزاز', '08022'),
  (52, 'Timoudi', 'تيمودي', '08031'),
  (52, 'Beni-Ikhlef', 'بن يخلف', '08025'),
  (53, 'Inghar', 'إينغر', '11004'),
  (53, 'Ain Salah', 'عين صالح', '11001'),
  (53, 'Foggaret Ezzoua', 'فقارة الزوى', '11016'),
  (54, 'Tin Zouatine', 'تين زواتين', '11011'),
  (54, 'Ain Guezzam', 'عين قزام', '11005'),
  (55, 'Temacine', 'تماسين', '30003'),
  (55, 'Blidet Amor', 'بلدة اعمر', '30005'),
  (55, 'Sidi Slimane', 'سيدي سليمان', '30030'),
  (55, 'Megarine', 'المقارين', '30009'),
  (55, 'Nezla', 'النزلة', '30004'),
  (55, 'Tebesbest', 'تبسبست', '30058'),
  (55, 'Touggourt', 'تقرت', '30002'),
  (55, 'Zaouia El Abidia', 'الزاوية العابدية', '30018'),
  (55, 'Taibet', 'الطيبات', '30015'),
  (55, 'Benaceur', 'بن ناصر', '30020'),
  (55, 'M''naguer', 'المنقر', '30029'),
  (55, 'El Alia', 'العالية', '30023'),
  (55, 'El-Hadjira', 'الحجيرة', '30006'),
  (56, 'Djanet', 'جانت', '33002'),
  (56, 'Bordj El Haouass', 'برج الحواس', '33008'),
  (57, 'Oum Touyour', 'أم الطيور', '39034'),
  (57, 'El-M''ghaier', 'المغير', '39005'),
  (57, 'Still', 'سطيل', '39039'),
  (57, 'Sidi Khelil', 'سيدي خليل', '39038'),
  (57, 'Sidi Amrane', 'سيدي عمران', '39021'),
  (57, 'M''rara', 'المرارة', '39067'),
  (57, 'Djamaa', 'جامعة', '39004'),
  (57, 'Tenedla', 'تندلة', '39042'),
  (58, 'El Meniaa', 'المنيعة', '47001'),
  (58, 'Hassi Gara', 'حاسي القارة', '47006'),
  (58, 'Hassi Fehal', 'حاسي الفحل', '47021'),
  (59, 'El Beidha', 'البيضاء', '03013'),
  (59, 'Gueltat Sidi Saad', 'قلتة سيدي سعد', '03025'),
  (59, 'Ain Sidi Ali', 'عين سيدي علي', '03028'),
  (59, 'Brida', 'بريدة', '03005'),
  (59, 'Hadj Mechri', 'الحاج مشري', '03038'),
  (59, 'Taouiala', 'تاويالة', '03026'),
  (59, 'El Ghicha', 'الغيشة', '03023'),
  (59, 'Sebgag', 'سبقاق', '03034'),
  (59, 'Sidi Bouzid', 'سيدي بوزيد', '03024'),
  (59, 'Aflou', 'أفلو', '03001'),
  (59, 'Oued Morra', 'وادي مرة', '03027'),
  (59, 'Oued M''zi', 'وادي مزي', '03041'),
  (60, 'Brezina', 'بريزينة', '32002'),
  (60, 'Ghassoul', 'الغاسول', '32017'),
  (60, 'Labiodh Sidi Cheikh', 'الأبيض سيدي الشيخ', '32003'),
  (60, 'Arbaouat', 'اربوات', '32005'),
  (60, 'Boussemghoun', 'بوسمغون', '32014'),
  (60, 'Cheguig', 'الشقيق', '32022'),
  (60, 'Chellala', 'شلالة', '32015'),
  (61, 'Sidi Djillali', 'سيدي الجيلالي', '13043'),
  (61, 'Bouihi', 'البويهي', '13030'),
  (61, 'El Gor', 'القور', '13034'),
  (61, 'El Aricha', 'العريشة', '13031'),
  (62, 'Djemorah', 'جمورة', '07025'),
  (62, 'Branis', 'برانيس', '07023'),
  (62, 'El Outaya', 'الوطاية', '07030'),
  (62, 'El Kantara', 'القنطرة', '07008'),
  (62, 'Ain Zaatout', 'عين زعطوط', '07013'),
  (63, 'Seggana', 'سقانة', '05027'),
  (63, 'Tilatou', 'تيلاطو', '05127'),
  (63, 'Barika', 'بريكة', '05001'),
  (63, 'Bitam', 'بيطام', '05045'),
  (63, 'M Doukal', 'إمدوكل', '05037'),
  (63, 'Azil Abedelkader', 'عزيل عبد القادر', '05087'),
  (63, 'Djezzar', 'الجزار', '05046'),
  (63, 'Ouled Ammar', 'أولاد عمار', '05121'),
  (64, 'Sidi Hadjeres', 'سيدي هجرس', '28036'),
  (64, 'Bou Saada', 'بوسعادة', '28001'),
  (64, 'El Hamel', 'الهامل', '28015'),
  (64, 'Oulteme', 'ولتام', '28054'),
  (64, 'Benzouh', 'بن زوه', '28028'),
  (64, 'Ouled Sidi Brahim', 'أولاد سيدي ابراهيم', '28032'),
  (64, 'Sidi Ameur', 'سيدي عامر', NULL),
  (64, 'Tamsa', 'تامسة', '28065'),
  (64, 'Ben Srour', 'بن سرور', '28009'),
  (64, 'Mohamed Boudiaf', 'محمد بوضياف', '28033'),
  (64, 'Ouled Slimane', 'أولاد سليمان', '28031'),
  (64, 'Zarzour', 'زرزور', '28067'),
  (64, 'Ain El Melh', 'عين الملح', '28004'),
  (64, 'Ain Fares', 'عين فارس', '28023'),
  (64, 'Ain Rich', 'عين الريش', '28025'),
  (64, 'Bir Foda', 'بئر فضة', '28043'),
  (64, 'Sidi M''hamed', 'سيدي امحمد', '16002'),
  (64, 'Medjedel', 'امجدل', '28016'),
  (64, 'Menaa', 'مناعة', '05012'),
  (64, 'Slim', 'سليم', '28037'),
  (64, 'Maadid', 'المعاضيد', '28011'),
  (64, 'M''tarfa', 'المطارفة', '01033'),
  (64, 'Maarif', 'معاريف', '28041'),
  (65, 'Ferkane', 'فركان', '12044'),
  (65, 'Negrine', 'نقرين', '12024'),
  (65, 'El Ogla El Malha', 'العقلة المالحة', '12043'),
  (65, 'Bir-El-Ater', 'بئر العاتر', '12001'),
  (66, 'Ouled Hellal', 'أولاد هلال', '26037'),
  (66, 'Boghar', 'بوغار', '26013'),
  (66, 'Ouled Antar', 'أولاد عنتر', '26035'),
  (66, 'Ksar El Boukhari', 'قصر البخاري', '26003')
ON CONFLICT (wilaya_code, name_fr) DO NOTHING;

INSERT INTO communes (wilaya_code, name_fr, name_ar, postal_code) VALUES
  (66, 'M''fatha', 'مفاتحة', '26049'),
  (66, 'Saneg', 'السانق', '26067'),
  (66, 'Bouaiche', 'بوعيش', NULL),
  (66, 'Boughzoul', 'بوغزول', '26023'),
  (66, 'Chabounia', 'الشهبونية', '26026'),
  (66, 'Ain Boucif', 'عين بوسيف', '26005'),
  (66, 'El Ouinet', 'العوينات', '12005'),
  (66, 'Kef Lakhdar', 'الكاف الاخضر', '26051'),
  (66, 'Ouled Emaaraf', 'أولاد امعرف', '26038'),
  (66, 'Sidi Demed', 'سيدي دامد', '26069'),
  (66, 'Ain Ouksir', 'عين اقصير', '26048'),
  (66, 'Chelalet El Adhaoura', 'شلالة العذاورة', '26007'),
  (66, 'Cheniguel', 'شنيقل', '26057'),
  (66, 'Tafraout', 'تفراوت', '26074'),
  (66, 'Aziz', 'عزيز', '26040'),
  (66, 'Derrag', 'دراق', '26015'),
  (66, 'Oum El Djellil', 'أم الجليل', '26042'),
  (67, 'Ksar Chellala', 'قصر الشلالة', '14002'),
  (67, 'Serghine', 'سرغين', '14051'),
  (67, 'Zmalet El Emir Abdelkade', 'زمالة  الأمير عبد القادر', '14038'),
  (67, 'Bougara', 'بوقرة', '09008'),
  (67, 'Hamadia', 'حمادية', '14020'),
  (67, 'Rechaiga', 'الرشايقة', '14026'),
  (68, 'Had Sahary', 'حد الصحاري', '17022'),
  (68, 'Bouira Lahdab', 'بويرة الأحداب', '17044'),
  (68, 'Ain Fekka', 'عين فقه', '17040'),
  (68, 'Sidi Laadjel', 'سيدي لعجال', '17024'),
  (68, 'Hassi Fedoul', 'حاسي فدول', '17056'),
  (68, 'El Khemis', 'الخميس', '17051'),
  (68, 'Birine', 'بيرين', '17014'),
  (68, 'Benhar', 'بنهار', '17043'),
  (68, 'Guernini', 'قرنيني', '17054'),
  (68, 'Ain Oussera', 'عين وسارة', '17001'),
  (69, 'Selmana', 'سلمانة', '17063'),
  (69, 'Sed Rahal', 'سد الرحال', '17062'),
  (69, 'Messaad', 'مسعد', '17003'),
  (69, 'Guettara', 'قطارة', '17055'),
  (69, 'Deldoul', 'دلدول', '17046'),
  (69, 'Oum Laadham', 'أم العظام', '17061'),
  (69, 'Faidh El Botma', 'فيض البطمة', '17021'),
  (69, 'Amourah', 'عمورة', '17042')
ON CONFLICT (wilaya_code, name_fr) DO NOTHING;




-- ============================================================================
-- SOURCE: 20261112211000_005_delivery_and_orders.sql
-- ============================================================================

/*
# Lunder's 3D Studio — Delivery, COD checkout and guest tracking (Phase 3)

## What this adds
- delivery_rates  : owner-configured prices per wilaya (or per commune), per method.
- pickup_points   : owner-configured relay/stop-desk points.
- orders / order_items / order_status_history : immutable price and address snapshots.
- Trusted server-side functions (SECURITY DEFINER, `search_path` pinned):
  - quote_delivery      — the only way a delivery price is produced.
  - create_guest_order  — validates commune/wilaya, availability, delivery and prices
                          from the database, then creates order + items + history and
                          reserves stock in one transaction.
  - track_order         — order number + phone, rate limited, minimal fields only.
  - get_order_by_token  — full detail through the high-entropy tracking token.
  - set_order_status    — owner-only, validates every transition, restores stock once.

## Invariants enforced here
- No client-supplied price, total, delivery charge or status is ever trusted: the
  browser only sends {product_id, variant_id, quantity} plus addresses.
- No active rate ⇒ `LIVRAISON_INDISPONIBLE`. Delivery is never free by default.
- A commune that does not belong to the selected wilaya is rejected.
- `idempotency_key` is unique and guarded by an advisory lock: retries and
  double-clicks produce exactly one order.
- Product rows are locked FOR UPDATE, so the last item cannot be oversold.
- Cancelling releases a reservation exactly once (transition map forbids re-cancel).

## Depends on
Migrations 002 (is_owner) and 004 (wilayas/communes).
*/

-- ─── DELIVERY RATES ────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS delivery_rates (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  wilaya_code smallint NOT NULL REFERENCES wilayas(code) ON DELETE CASCADE,
  commune_id uuid REFERENCES communes(id) ON DELETE CASCADE,
  method text NOT NULL CHECK (method IN ('domicile', 'stopdesk')),
  price_dzd integer NOT NULL CHECK (price_dzd >= 0),
  carrier text,
  estimated_days_min integer CHECK (estimated_days_min IS NULL OR estimated_days_min >= 0),
  estimated_days_max integer CHECK (estimated_days_max IS NULL OR estimated_days_max >= 0),
  is_active boolean NOT NULL DEFAULT true,
  created_at timestamptz DEFAULT now(),
  updated_at timestamptz DEFAULT now(),
  CONSTRAINT delivery_eta_order CHECK (
    estimated_days_min IS NULL OR estimated_days_max IS NULL OR estimated_days_max >= estimated_days_min
  )
);

-- Rejects ambiguous overlapping rules: one wilaya-wide rate and one per commune,
-- per method. A commune rate always wins over the wilaya-wide rate.
CREATE UNIQUE INDEX IF NOT EXISTS uniq_delivery_rate_wilaya
  ON delivery_rates (wilaya_code, method) WHERE commune_id IS NULL;
CREATE UNIQUE INDEX IF NOT EXISTS uniq_delivery_rate_commune
  ON delivery_rates (commune_id, method) WHERE commune_id IS NOT NULL;

DROP TRIGGER IF EXISTS delivery_rates_updated_at ON delivery_rates;
CREATE TRIGGER delivery_rates_updated_at
  BEFORE UPDATE ON delivery_rates
  FOR EACH ROW EXECUTE FUNCTION public.update_updated_at();

ALTER TABLE delivery_rates ENABLE ROW LEVEL SECURITY;
GRANT SELECT ON delivery_rates TO authenticated;
GRANT INSERT, UPDATE, DELETE ON delivery_rates TO authenticated;

DROP POLICY IF EXISTS "owner_read_delivery_rates" ON delivery_rates;
CREATE POLICY "owner_read_delivery_rates" ON delivery_rates FOR SELECT
  TO authenticated USING (public.is_owner());

DROP POLICY IF EXISTS "owner_write_delivery_rates" ON delivery_rates;
CREATE POLICY "owner_write_delivery_rates" ON delivery_rates FOR ALL
  TO authenticated USING (public.is_owner()) WITH CHECK (public.is_owner());

-- ─── PICKUP POINTS ─────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS pickup_points (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  wilaya_code smallint NOT NULL REFERENCES wilayas(code) ON DELETE CASCADE,
  commune_id uuid REFERENCES communes(id) ON DELETE SET NULL,
  name text NOT NULL,
  address text,
  is_active boolean NOT NULL DEFAULT true,
  created_at timestamptz DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_pickup_points_wilaya ON pickup_points(wilaya_code);

ALTER TABLE pickup_points ENABLE ROW LEVEL SECURITY;
GRANT SELECT ON pickup_points TO anon, authenticated;
GRANT INSERT, UPDATE, DELETE ON pickup_points TO authenticated;

DROP POLICY IF EXISTS "public_read_pickup_points" ON pickup_points;
CREATE POLICY "public_read_pickup_points" ON pickup_points FOR SELECT
  TO anon, authenticated USING (is_active = true);

DROP POLICY IF EXISTS "owner_read_pickup_points" ON pickup_points;
CREATE POLICY "owner_read_pickup_points" ON pickup_points FOR SELECT
  TO authenticated USING (public.is_owner());

DROP POLICY IF EXISTS "owner_write_pickup_points" ON pickup_points;
CREATE POLICY "owner_write_pickup_points" ON pickup_points FOR ALL
  TO authenticated USING (public.is_owner()) WITH CHECK (public.is_owner());

-- ─── ORDERS ────────────────────────────────────────────────────────────────

CREATE SEQUENCE IF NOT EXISTS order_number_seq START 1;

CREATE OR REPLACE FUNCTION public.next_order_number()
RETURNS text
LANGUAGE sql
VOLATILE
AS $$
  SELECT 'LND-' || to_char(now(), 'YYYY') || '-' || lpad(nextval('order_number_seq')::text, 5, '0');
$$;

CREATE TABLE IF NOT EXISTS orders (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  order_number text NOT NULL UNIQUE,
  tracking_token uuid NOT NULL UNIQUE DEFAULT gen_random_uuid(),
  idempotency_key text NOT NULL UNIQUE,
  status text NOT NULL DEFAULT 'pending'
    CHECK (status IN ('pending', 'confirmed', 'shipped', 'delivered', 'cancelled')),
  payment_method text NOT NULL DEFAULT 'cod' CHECK (payment_method = 'cod'),
  customer_name text NOT NULL,
  phone text NOT NULL,
  email text,
  wilaya_code smallint NOT NULL REFERENCES wilayas(code),
  commune_id uuid REFERENCES communes(id),
  wilaya_name text NOT NULL,
  commune_name text NOT NULL,
  delivery_method text NOT NULL CHECK (delivery_method IN ('domicile', 'stopdesk')),
  delivery_carrier text,
  delivery_eta_min integer,
  delivery_eta_max integer,
  address text,
  pickup_point_id uuid REFERENCES pickup_points(id) ON DELETE SET NULL,
  pickup_point_snapshot text,
  note text,
  subtotal_dzd integer NOT NULL CHECK (subtotal_dzd >= 0),
  delivery_dzd integer NOT NULL CHECK (delivery_dzd >= 0),
  total_dzd integer NOT NULL CHECK (total_dzd >= 0),
  created_at timestamptz DEFAULT now(),
  updated_at timestamptz DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_orders_status ON orders(status);
CREATE INDEX IF NOT EXISTS idx_orders_created ON orders(created_at DESC);

DROP TRIGGER IF EXISTS orders_updated_at ON orders;
CREATE TRIGGER orders_updated_at
  BEFORE UPDATE ON orders
  FOR EACH ROW EXECUTE FUNCTION public.update_updated_at();

CREATE TABLE IF NOT EXISTS order_items (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  order_id uuid NOT NULL REFERENCES orders(id) ON DELETE CASCADE,
  product_id uuid REFERENCES products(id) ON DELETE SET NULL,
  variant_id uuid REFERENCES product_variants(id) ON DELETE SET NULL,
  product_name text NOT NULL,
  variant_label text,
  sku text,
  unit_price_dzd integer NOT NULL CHECK (unit_price_dzd >= 0),
  quantity integer NOT NULL CHECK (quantity > 0),
  line_total_dzd integer NOT NULL CHECK (line_total_dzd >= 0),
  created_at timestamptz DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_order_items_order ON order_items(order_id);

CREATE TABLE IF NOT EXISTS order_status_history (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  order_id uuid NOT NULL REFERENCES orders(id) ON DELETE CASCADE,
  from_status text,
  to_status text NOT NULL,
  actor text NOT NULL DEFAULT 'system',
  created_at timestamptz DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_order_history_order ON order_status_history(order_id, created_at);

-- Rate limiting for the minimal guest lookup (§12).
CREATE TABLE IF NOT EXISTS tracking_attempts (
  id bigserial PRIMARY KEY,
  order_number text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_tracking_attempts_order
  ON tracking_attempts(order_number, created_at DESC);

-- ─── RLS: NO DIRECT CLIENT ACCESS TO ORDERS ────────────────────────────────

ALTER TABLE orders ENABLE ROW LEVEL SECURITY;
ALTER TABLE order_items ENABLE ROW LEVEL SECURITY;
ALTER TABLE order_status_history ENABLE ROW LEVEL SECURITY;
ALTER TABLE tracking_attempts ENABLE ROW LEVEL SECURITY;

-- Reads for the back office only. There is no anon grant at all: guests reach
-- their own order exclusively through the functions below.
GRANT SELECT ON orders, order_items, order_status_history TO authenticated;

DROP POLICY IF EXISTS "owner_read_orders" ON orders;
CREATE POLICY "owner_read_orders" ON orders FOR SELECT
  TO authenticated USING (public.is_owner());

DROP POLICY IF EXISTS "owner_read_order_items" ON order_items;
CREATE POLICY "owner_read_order_items" ON order_items FOR SELECT
  TO authenticated USING (public.is_owner());

DROP POLICY IF EXISTS "owner_read_order_history" ON order_status_history;
CREATE POLICY "owner_read_order_history" ON order_status_history FOR SELECT
  TO authenticated USING (public.is_owner());

-- ─── DELIVERY QUOTE ────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION public.quote_delivery(
  p_wilaya_code smallint,
  p_commune_id uuid,
  p_method text
)
RETURNS TABLE (
  price_dzd integer,
  estimated_days_min integer,
  estimated_days_max integer,
  carrier text
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_rate record;
BEGIN
  IF p_method NOT IN ('domicile', 'stopdesk') THEN
    RAISE EXCEPTION 'METHODE_LIVRAISON_INVALIDE';
  END IF;

  IF p_commune_id IS NOT NULL THEN
    IF NOT EXISTS (
      SELECT 1 FROM communes c
      WHERE c.id = p_commune_id AND c.wilaya_code = p_wilaya_code AND c.is_active
    ) THEN
      RAISE EXCEPTION 'COMMUNE_INVALIDE';
    END IF;
  END IF;

  SELECT r.price_dzd, r.estimated_days_min, r.estimated_days_max, r.carrier
    INTO v_rate
  FROM delivery_rates r
  WHERE r.is_active
    AND r.method = p_method
    AND (
      (p_commune_id IS NOT NULL AND r.commune_id = p_commune_id)
      OR (r.commune_id IS NULL AND r.wilaya_code = p_wilaya_code)
    )
  ORDER BY (r.commune_id IS NOT NULL) DESC
  LIMIT 1;

  IF v_rate.price_dzd IS NULL THEN
    RAISE EXCEPTION 'LIVRAISON_INDISPONIBLE';
  END IF;

  price_dzd := v_rate.price_dzd;
  estimated_days_min := v_rate.estimated_days_min;
  estimated_days_max := v_rate.estimated_days_max;
  carrier := v_rate.carrier;
  RETURN NEXT;
END;
$$;

REVOKE EXECUTE ON FUNCTION public.quote_delivery(smallint, uuid, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.quote_delivery(smallint, uuid, text) TO anon, authenticated;

-- ─── CREATE GUEST ORDER (ATOMIC) ───────────────────────────────────────────

CREATE OR REPLACE FUNCTION public.create_guest_order(p_payload jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_key text := nullif(btrim(coalesce(p_payload->>'idempotency_key', '')), '');
  v_existing orders%ROWTYPE;
  v_name text := btrim(coalesce(p_payload->>'customer_name', ''));
  v_phone text;
  v_email text := nullif(btrim(coalesce(p_payload->>'email', '')), '');
  v_wilaya smallint;
  v_commune uuid;
  v_method text := coalesce(p_payload->>'delivery_method', '');
  v_address text := nullif(btrim(coalesce(p_payload->>'address', '')), '');
  v_pickup uuid := nullif(p_payload->>'pickup_point_id', '')::uuid;
  v_pickup_name text;
  v_note text := nullif(btrim(coalesce(p_payload->>'note', '')), '');
  v_items jsonb := coalesce(p_payload->'items', '[]'::jsonb);
  v_item jsonb;
  v_lines jsonb := '[]'::jsonb;
  v_qty integer;
  v_product products%ROWTYPE;
  v_variant product_variants%ROWTYPE;
  v_variant_id uuid;
  v_unit integer;
  v_made_to_order boolean;
  v_track_stock boolean;
  v_subtotal integer := 0;
  v_rate record;
  v_order_id uuid;
  v_number text;
  v_token uuid;
  v_wilaya_name text;
  v_commune_name text;
  v_order_name text;
  v_line record;
BEGIN
  IF v_key IS NULL THEN
    RAISE EXCEPTION 'CLE_IDEMPOTENCE_MANQUANTE';
  END IF;

  -- Serialise retries of the same submission (double-click, network retry).
  PERFORM pg_advisory_xact_lock(hashtextextended(v_key, 0));

  SELECT * INTO v_existing FROM orders WHERE idempotency_key = v_key;
  IF FOUND THEN
    RETURN jsonb_build_object(
      'order_number', v_existing.order_number,
      'tracking_token', v_existing.tracking_token,
      'total_dzd', v_existing.total_dzd,
      'already_exists', true
    );
  END IF;

  IF v_name = '' THEN
    RAISE EXCEPTION 'NOM_REQUIS';
  END IF;

  -- Algerian phone normalisation (+213, 00213, 9 digits).
  v_phone := regexp_replace(coalesce(p_payload->>'phone', ''), '\D', '', 'g');
  IF left(v_phone, 2) = '00' THEN
    v_phone := substr(v_phone, 3);
  END IF;
  IF left(v_phone, 3) = '213' THEN
    v_phone := '0' || substr(v_phone, 4);
  END IF;
  IF length(v_phone) = 9 AND left(v_phone, 1) IN ('5', '6', '7') THEN
    v_phone := '0' || v_phone;
  END IF;
  IF v_phone !~ '^0[5-7][0-9]{8}$' THEN
    RAISE EXCEPTION 'TELEPHONE_INVALIDE';
  END IF;

  v_wilaya := nullif(p_payload->>'wilaya_code', '')::smallint;
  IF v_wilaya IS NULL THEN
    RAISE EXCEPTION 'WILAYA_REQUISE';
  END IF;

  SELECT name_fr INTO v_wilaya_name FROM wilayas WHERE code = v_wilaya AND is_active;
  IF v_wilaya_name IS NULL THEN
    RAISE EXCEPTION 'WILAYA_INVALIDE';
  END IF;

  v_commune := nullif(p_payload->>'commune_id', '')::uuid;
  IF v_commune IS NULL THEN
    RAISE EXCEPTION 'COMMUNE_REQUISE';
  END IF;

  SELECT name_fr INTO v_commune_name
  FROM communes
  WHERE id = v_commune AND wilaya_code = v_wilaya AND is_active;
  IF v_commune_name IS NULL THEN
    RAISE EXCEPTION 'COMMUNE_INVALIDE';
  END IF;

  IF jsonb_typeof(v_items) <> 'array' OR jsonb_array_length(v_items) = 0 THEN
    RAISE EXCEPTION 'PANIER_VIDE';
  END IF;
  IF jsonb_array_length(v_items) > 20 THEN
    RAISE EXCEPTION 'PANIER_TROP_GRAND';
  END IF;

  -- Pass 1: validate availability and compute every line from database prices.
  FOR v_item IN SELECT * FROM jsonb_array_elements(v_items) LOOP
    v_qty := coalesce((v_item->>'quantity')::integer, 0);
    IF v_qty < 1 OR v_qty > 10 THEN
      RAISE EXCEPTION 'QUANTITE_INVALIDE';
    END IF;

    SELECT * INTO v_product
    FROM products
    WHERE id = nullif(v_item->>'product_id', '')::uuid
    FOR UPDATE;

    IF NOT FOUND OR v_product.status <> 'published' THEN
      RAISE EXCEPTION 'PRODUIT_INDISPONIBLE';
    END IF;

    -- Réinitialisé à chaque ligne : sinon la variante de la ligne précédente
    -- resterait attachée au calcul du prix et du stock.
    v_variant := NULL;
    v_variant_id := nullif(v_item->>'variant_id', '')::uuid;
    v_unit := v_product.price_dzd;
    v_made_to_order := v_product.made_to_order;

    IF v_variant_id IS NOT NULL THEN
      SELECT * INTO v_variant
      FROM product_variants
      WHERE id = v_variant_id AND product_id = v_product.id AND is_active;
      IF NOT FOUND THEN
        RAISE EXCEPTION 'VARIANTE_INDISPONIBLE';
      END IF;
      IF v_variant.price_dzd IS NOT NULL THEN
        v_unit := v_variant.price_dzd;
      END IF;
      IF v_variant.made_to_order IS NOT NULL THEN
        v_made_to_order := v_variant.made_to_order;
      END IF;
    END IF;

    v_track_stock := NOT v_made_to_order;
    IF v_track_stock THEN
      IF coalesce(v_variant.stock_quantity, v_product.stock_quantity) < v_qty THEN
        RAISE EXCEPTION 'STOCK_INSUFFISANT';
      END IF;
    END IF;

    v_subtotal := v_subtotal + (v_unit * v_qty);
    v_lines := v_lines || jsonb_build_object(
      'product_id', v_product.id,
      'variant_id', v_variant_id,
      'product_name', v_product.name,
      'variant_label', v_variant.label,
      'sku', coalesce(v_variant.sku, v_product.sku),
      'unit_price_dzd', v_unit,
      'quantity', v_qty,
      'line_total_dzd', v_unit * v_qty,
      'track_stock', v_track_stock
    );
  END LOOP;

  -- Delivery price comes only from the database (never from the browser).
  SELECT * INTO v_rate FROM quote_delivery(v_wilaya, v_commune, v_method);

  IF v_method = 'stopdesk' THEN
    IF v_pickup IS NULL THEN
      RAISE EXCEPTION 'POINT_RELAIS_REQUIS';
    END IF;
    SELECT name INTO v_pickup_name
    FROM pickup_points
    WHERE id = v_pickup AND wilaya_code = v_wilaya AND is_active;
    IF v_pickup_name IS NULL THEN
      RAISE EXCEPTION 'POINT_RELAIS_INVALIDE';
    END IF;
  ELSE
    IF v_address IS NULL THEN
      RAISE EXCEPTION 'ADRESSE_REQUISE';
    END IF;
  END IF;

  v_number := public.next_order_number();

  INSERT INTO orders (
    order_number, idempotency_key, customer_name, phone, email,
    wilaya_code, commune_id, wilaya_name, commune_name,
    delivery_method, delivery_carrier, delivery_eta_min, delivery_eta_max,
    address, pickup_point_id, pickup_point_snapshot, note,
    subtotal_dzd, delivery_dzd, total_dzd
  ) VALUES (
    v_number, v_key, v_name, v_phone, v_email,
    v_wilaya, v_commune, v_wilaya_name, v_commune_name,
    v_method, v_rate.carrier, v_rate.estimated_days_min, v_rate.estimated_days_max,
    v_address, v_pickup, v_pickup_name, v_note,
    v_subtotal, v_rate.price_dzd, v_subtotal + v_rate.price_dzd
  )
  RETURNING id, tracking_token, customer_name INTO v_order_id, v_token, v_order_name;

  -- Pass 2: snapshot lines, then reserve stock (the rows are still locked).
  FOR v_line IN SELECT * FROM jsonb_array_elements(v_lines) LOOP
    INSERT INTO order_items (
      order_id, product_id, variant_id, product_name, variant_label, sku,
      unit_price_dzd, quantity, line_total_dzd
    ) VALUES (
      v_order_id,
      (v_line.value->>'product_id')::uuid,
      nullif(v_line.value->>'variant_id', '')::uuid,
      v_line.value->>'product_name',
      v_line.value->>'variant_label',
      v_line.value->>'sku',
      (v_line.value->>'unit_price_dzd')::integer,
      (v_line.value->>'quantity')::integer,
      (v_line.value->>'line_total_dzd')::integer
    );

    IF (v_line.value->>'track_stock')::boolean THEN
      -- Le stock décrémenté est exactement celui qui a été vérifié : la variante
      -- si la ligne en porte une, sinon le produit. Jamais les deux.
      IF nullif(v_line.value->>'variant_id', '') IS NOT NULL THEN
        UPDATE product_variants
        SET stock_quantity = stock_quantity - (v_line.value->>'quantity')::integer
        WHERE id = (v_line.value->>'variant_id')::uuid;
      ELSE
        UPDATE products
        SET stock_quantity = stock_quantity - (v_line.value->>'quantity')::integer
        WHERE id = (v_line.value->>'product_id')::uuid;
      END IF;
    END IF;
  END LOOP;

  INSERT INTO order_status_history (order_id, from_status, to_status, actor)
  VALUES (v_order_id, NULL, 'pending', 'client');

  RETURN jsonb_build_object(
    'order_number', v_number,
    'tracking_token', v_token,
    'total_dzd', v_subtotal + v_rate.price_dzd,
    'already_exists', false
  );
END;
$$;

REVOKE EXECUTE ON FUNCTION public.create_guest_order(jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.create_guest_order(jsonb) TO anon, authenticated;

-- ─── GUEST TRACKING ────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION public.track_order(p_order_number text, p_phone text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_number text := upper(btrim(coalesce(p_order_number, '')));
  v_phone text := right(regexp_replace(coalesce(p_phone, ''), '\D', '', 'g'), 9);
  v_attempts integer;
  v_result jsonb;
BEGIN
  IF v_number = '' OR length(v_phone) <> 9 THEN
    RAISE EXCEPTION 'COMMANDE_INTROUVABLE';
  END IF;

  SELECT count(*) INTO v_attempts
  FROM tracking_attempts
  WHERE order_number = v_number AND created_at > now() - interval '15 minutes';

  IF v_attempts >= 8 THEN
    RAISE EXCEPTION 'TROP_DE_TENTATIVES';
  END IF;

  INSERT INTO tracking_attempts (order_number) VALUES (v_number);

  SELECT jsonb_build_object(
    'order_number', o.order_number,
    'status', o.status,
    'created_at', o.created_at,
    'total_dzd', o.total_dzd,
    'wilaya', o.wilaya_name,
    'commune', o.commune_name,
    'delivery_method', o.delivery_method,
    'items_count', (SELECT count(*) FROM order_items i WHERE i.order_id = o.id)
  )
  INTO v_result
  FROM orders o
  WHERE o.order_number = v_number
    AND right(regexp_replace(o.phone, '\D', '', 'g'), 9) = v_phone;

  IF v_result IS NULL THEN
    RAISE EXCEPTION 'COMMANDE_INTROUVABLE';
  END IF;

  RETURN v_result;
END;
$$;

REVOKE EXECUTE ON FUNCTION public.track_order(text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.track_order(text, text) TO anon, authenticated;

CREATE OR REPLACE FUNCTION public.get_order_by_token(p_token uuid)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_result jsonb;
BEGIN
  IF p_token IS NULL THEN
    RAISE EXCEPTION 'COMMANDE_INTROUVABLE';
  END IF;

  SELECT jsonb_build_object(
    'order_number', o.order_number,
    'status', o.status,
    'created_at', o.created_at,
    'payment_method', o.payment_method,
    'customer_name', o.customer_name,
    'phone', o.phone,
    'wilaya', o.wilaya_name,
    'commune', o.commune_name,
    'delivery_method', o.delivery_method,
    'delivery_carrier', o.delivery_carrier,
    'delivery_eta_min', o.delivery_eta_min,
    'delivery_eta_max', o.delivery_eta_max,
    'address', o.address,
    'pickup_point', o.pickup_point_snapshot,
    'note', o.note,
    'subtotal_dzd', o.subtotal_dzd,
    'delivery_dzd', o.delivery_dzd,
    'total_dzd', o.total_dzd,
    'items', coalesce((
      SELECT jsonb_agg(jsonb_build_object(
        'product_name', i.product_name,
        'variant_label', i.variant_label,
        'sku', i.sku,
        'unit_price_dzd', i.unit_price_dzd,
        'quantity', i.quantity,
        'line_total_dzd', i.line_total_dzd
      ) ORDER BY i.created_at)
      FROM order_items i WHERE i.order_id = o.id
    ), '[]'::jsonb)
  )
  INTO v_result
  FROM orders o
  WHERE o.tracking_token = p_token;

  IF v_result IS NULL THEN
    RAISE EXCEPTION 'COMMANDE_INTROUVABLE';
  END IF;

  RETURN v_result;
END;
$$;

REVOKE EXECUTE ON FUNCTION public.get_order_by_token(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_order_by_token(uuid) TO anon, authenticated;

-- ─── OWNER STATUS TRANSITIONS ──────────────────────────────────────────────

CREATE OR REPLACE FUNCTION public.set_order_status(p_order_id uuid, p_status text)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_order orders%ROWTYPE;
  v_item record;
BEGIN
  IF NOT public.is_owner() THEN
    RAISE EXCEPTION 'ACCES_REFUSE';
  END IF;

  SELECT * INTO v_order FROM orders WHERE id = p_order_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'COMMANDE_INTROUVABLE';
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

  -- Release the reservation exactly once: only a cancellation releases stock.
  IF p_status = 'cancelled' THEN
    FOR v_item IN
      SELECT i.product_id, i.variant_id, i.quantity,
             p.made_to_order AS product_mto,
             pv.made_to_order AS variant_mto
      FROM order_items i
      JOIN products p ON p.id = i.product_id
      LEFT JOIN product_variants pv ON pv.id = i.variant_id
      WHERE i.order_id = p_order_id AND i.product_id IS NOT NULL
    LOOP
      -- On ne restitue que ce qui avait été réservé : la variante si sa propre
      -- politique de stock s'appliquait, sinon le produit.
      IF v_item.variant_id IS NOT NULL THEN
        UPDATE product_variants
        SET stock_quantity = stock_quantity + v_item.quantity
        WHERE id = v_item.variant_id
          AND coalesce(v_item.variant_mto, v_item.product_mto) = false;
      ELSE
        UPDATE products
        SET stock_quantity = stock_quantity + v_item.quantity
        WHERE id = v_item.product_id AND v_item.product_mto = false;
      END IF;
    END LOOP;
  END IF;

  UPDATE orders SET status = p_status WHERE id = p_order_id;

  INSERT INTO order_status_history (order_id, from_status, to_status, actor)
  VALUES (p_order_id, v_order.status, p_status, 'proprietaire');
END;
$$;

REVOKE EXECUTE ON FUNCTION public.set_order_status(uuid, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.set_order_status(uuid, text) TO authenticated;



-- ============================================================================
-- SOURCE: 20261112220000_006_custom_requests_and_quotes.sql
-- ============================================================================

/*
# Lunder's 3D Studio — Custom requests and quotations (Phase 4)

## Flow
1. A guest uploads reference photos and/or 3D files to the **private** bucket
   `custom-requests`, then `create_custom_request` records the request and its
   file metadata (idempotent, phone validated, objects verified to exist).
2. The owner reviews feasibility and issues a **versioned** quote
   (`create_custom_quote`). Issuing a new version expires the previous one, so at
   most one quote is ever approvable.
3. The guest sees their quotes through the request tracking token and approves
   **one specific quote version** (`approve_custom_quote`), which creates exactly
   one COD order — even on retry or double-click.

## Privacy
- Bucket is private. There is **no anon SELECT** policy: files are not readable by
  URL. The owner reads them through short-lived signed URLs (authenticated SELECT).
- Guests may INSERT into the bucket only (upload), never read others' files.
- Guests reach their own request exclusively through the high-entropy request token.

## Depends on
Migrations 002 (is_owner), 003 (products/variants), 004 (geography), 005 (orders,
quote_delivery, next_order_number).
*/

-- ─── PRIVATE STORAGE ───────────────────────────────────────────────────────

INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES (
  'custom-requests', 'custom-requests', false, 26214400,
  ARRAY['image/jpeg', 'image/png', 'image/webp', 'image/avif',
        'model/gltf-binary', 'model/gltf+json', 'model/stl', 'model/obj',
        'application/octet-stream', 'text/plain']
)
ON CONFLICT (id) DO UPDATE
  SET public = false,
      file_size_limit = EXCLUDED.file_size_limit,
      allowed_mime_types = EXCLUDED.allowed_mime_types;

DROP POLICY IF EXISTS "guest_upload_custom_requests" ON storage.objects;
CREATE POLICY "guest_upload_custom_requests" ON storage.objects FOR INSERT
  TO anon, authenticated WITH CHECK (bucket_id = 'custom-requests');

DROP POLICY IF EXISTS "owner_read_custom_requests" ON storage.objects;
CREATE POLICY "owner_read_custom_requests" ON storage.objects FOR SELECT
  TO authenticated USING (bucket_id = 'custom-requests' AND public.is_owner());

DROP POLICY IF EXISTS "owner_delete_custom_requests" ON storage.objects;
CREATE POLICY "owner_delete_custom_requests" ON storage.objects FOR DELETE
  TO authenticated USING (bucket_id = 'custom-requests' AND public.is_owner());

-- ─── TABLES ────────────────────────────────────────────────────────────────

CREATE SEQUENCE IF NOT EXISTS custom_request_seq START 1;

CREATE TABLE IF NOT EXISTS custom_requests (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  request_number text NOT NULL UNIQUE,
  tracking_token uuid NOT NULL UNIQUE DEFAULT gen_random_uuid(),
  idempotency_key text NOT NULL UNIQUE,
  customer_name text NOT NULL,
  phone text NOT NULL,
  email text,
  title text NOT NULL,
  description text NOT NULL,
  intended_use text,
  dimensions text,
  dimension_unit text NOT NULL DEFAULT 'mm' CHECK (dimension_unit IN ('mm', 'cm', 'm')),
  material_preference text,
  color_preference text,
  quantity integer NOT NULL DEFAULT 1 CHECK (quantity BETWEEN 1 AND 500),
  status text NOT NULL DEFAULT 'new'
    CHECK (status IN ('new', 'reviewing', 'quoted', 'approved', 'rejected', 'closed')),
  created_at timestamptz DEFAULT now(),
  updated_at timestamptz DEFAULT now()
);

CREATE TABLE IF NOT EXISTS custom_request_files (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  request_id uuid NOT NULL REFERENCES custom_requests(id) ON DELETE CASCADE,
  kind text NOT NULL CHECK (kind IN ('image', 'model')),
  storage_path text NOT NULL UNIQUE,
  original_name text NOT NULL,
  mime_type text,
  size_bytes bigint CHECK (size_bytes IS NULL OR size_bytes >= 0),
  created_at timestamptz DEFAULT now()
);

CREATE TABLE IF NOT EXISTS custom_quotes (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  request_id uuid NOT NULL REFERENCES custom_requests(id) ON DELETE CASCADE,
  version integer NOT NULL CHECK (version > 0),
  public_token uuid NOT NULL UNIQUE DEFAULT gen_random_uuid(),
  price_dzd integer NOT NULL CHECK (price_dzd >= 0),
  production_lead_days integer CHECK (production_lead_days IS NULL OR production_lead_days >= 0),
  valid_until date NOT NULL,
  terms text,
  status text NOT NULL DEFAULT 'sent'
    CHECK (status IN ('sent', 'approved', 'rejected', 'expired')),
  order_id uuid UNIQUE REFERENCES orders(id) ON DELETE SET NULL,
  created_at timestamptz DEFAULT now(),
  decided_at timestamptz,
  UNIQUE (request_id, version)
);

CREATE TABLE IF NOT EXISTS custom_quote_events (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  request_id uuid NOT NULL REFERENCES custom_requests(id) ON DELETE CASCADE,
  quote_id uuid REFERENCES custom_quotes(id) ON DELETE SET NULL,
  action text NOT NULL CHECK (action IN ('created', 'sent', 'approved', 'expired', 'status_changed', 'file_added')),
  actor text NOT NULL DEFAULT 'proprietaire',
  note text,
  created_at timestamptz DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_request_files_request ON custom_request_files(request_id);
CREATE INDEX IF NOT EXISTS idx_quotes_request ON custom_quotes(request_id, version DESC);
CREATE INDEX IF NOT EXISTS idx_quote_events_request ON custom_quote_events(request_id, created_at);

DROP TRIGGER IF EXISTS custom_requests_updated_at ON custom_requests;
CREATE TRIGGER custom_requests_updated_at
  BEFORE UPDATE ON custom_requests
  FOR EACH ROW EXECUTE FUNCTION public.update_updated_at();

-- ─── RLS: BACK OFFICE ONLY ─────────────────────────────────────────────────

ALTER TABLE custom_requests ENABLE ROW LEVEL SECURITY;
ALTER TABLE custom_request_files ENABLE ROW LEVEL SECURITY;
ALTER TABLE custom_quotes ENABLE ROW LEVEL SECURITY;
ALTER TABLE custom_quote_events ENABLE ROW LEVEL SECURITY;

GRANT SELECT ON custom_requests, custom_request_files, custom_quotes, custom_quote_events TO authenticated;

DROP POLICY IF EXISTS "owner_read_custom_requests" ON custom_requests;
CREATE POLICY "owner_read_custom_requests" ON custom_requests FOR SELECT
  TO authenticated USING (public.is_owner());

DROP POLICY IF EXISTS "owner_read_custom_request_files" ON custom_request_files;
CREATE POLICY "owner_read_custom_request_files" ON custom_request_files FOR SELECT
  TO authenticated USING (public.is_owner());

DROP POLICY IF EXISTS "owner_read_custom_quotes" ON custom_quotes;
CREATE POLICY "owner_read_custom_quotes" ON custom_quotes FOR SELECT
  TO authenticated USING (public.is_owner());

DROP POLICY IF EXISTS "owner_read_custom_quote_events" ON custom_quote_events;
CREATE POLICY "owner_read_custom_quote_events" ON custom_quote_events FOR SELECT
  TO authenticated USING (public.is_owner());

-- No INSERT/UPDATE/DELETE grants: quotes and requests are only written through
-- the SECURITY DEFINER functions below, which keeps versions and history honest.

-- ─── GUEST INTAKE ──────────────────────────────────────────────────────────

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
  v_title text := btrim(coalesce(p_payload->>'title', ''));
  v_description text := btrim(coalesce(p_payload->>'description', ''));
  v_quantity integer := coalesce((p_payload->>'quantity')::integer, 1);
  v_unit text := coalesce(p_payload->>'dimension_unit', 'mm');
  v_files jsonb := coalesce(p_payload->'files', '[]'::jsonb);
  v_file jsonb;
  v_request custom_requests%ROWTYPE;
  v_number text;
  v_exists boolean;
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
  IF left(v_phone, 2) = '00' THEN
    v_phone := substr(v_phone, 3);
  END IF;
  IF left(v_phone, 3) = '213' THEN
    v_phone := '0' || substr(v_phone, 4);
  END IF;
  IF length(v_phone) = 9 AND left(v_phone, 1) IN ('5', '6', '7') THEN
    v_phone := '0' || v_phone;
  END IF;
  IF v_phone !~ '^0[5-7][0-9]{8}$' THEN
    RAISE EXCEPTION 'TELEPHONE_INVALIDE';
  END IF;

  IF length(v_title) < 3 THEN
    RAISE EXCEPTION 'TITRE_REQUIS';
  END IF;
  IF length(v_description) < 20 THEN
    RAISE EXCEPTION 'DESCRIPTION_TROP_COURTE';
  END IF;
  IF v_quantity < 1 OR v_quantity > 500 THEN
    RAISE EXCEPTION 'QUANTITE_INVALIDE';
  END IF;
  IF v_unit NOT IN ('mm', 'cm', 'm') THEN
    RAISE EXCEPTION 'UNITE_INVALIDE';
  END IF;
  IF jsonb_typeof(v_files) <> 'array' OR jsonb_array_length(v_files) > 10 THEN
    RAISE EXCEPTION 'FICHIERS_INVALIDES';
  END IF;

  v_number := 'DEM-' || to_char(now(), 'YYYY') || '-' ||
              lpad(nextval('custom_request_seq')::text, 5, '0');

  INSERT INTO custom_requests (
    request_number, idempotency_key, customer_name, phone, email,
    title, description, intended_use, dimensions, dimension_unit,
    material_preference, color_preference, quantity
  ) VALUES (
    v_number, v_key, v_name, v_phone, nullif(btrim(coalesce(p_payload->>'email', '')), ''),
    v_title, v_description, nullif(btrim(coalesce(p_payload->>'intended_use', '')), ''),
    nullif(btrim(coalesce(p_payload->>'dimensions', '')), ''),
    v_unit,
    nullif(btrim(coalesce(p_payload->>'material_preference', '')), ''),
    nullif(btrim(coalesce(p_payload->>'color_preference', '')), ''),
    v_quantity
  )
  RETURNING * INTO v_request;

  FOR v_file IN SELECT * FROM jsonb_array_elements(v_files) LOOP
    -- L'objet doit réellement exister dans le bucket privé : on ne fait pas
    -- confiance au chemin envoyé par le navigateur.
    SELECT EXISTS (
      SELECT 1 FROM storage.objects
      WHERE bucket_id = 'custom-requests'
        AND name = (v_file->>'path')
    ) INTO v_exists;

    IF NOT v_exists THEN
      RAISE EXCEPTION 'FICHIER_INTROUVABLE';
    END IF;

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
    'already_exists', false
  );
END;
$$;

REVOKE EXECUTE ON FUNCTION public.create_custom_request(jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.create_custom_request(jsonb) TO anon, authenticated;

-- ─── GUEST VIEW + QUOTE EXPIRY ─────────────────────────────────────────────

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

  -- Les devis dont la validité est dépassée ne sont plus approuvables.
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

-- ─── OWNER: ISSUE A VERSIONED QUOTE ────────────────────────────────────────

CREATE OR REPLACE FUNCTION public.create_custom_quote(
  p_request_id uuid,
  p_price_dzd integer,
  p_lead_days integer,
  p_valid_until date,
  p_terms text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_request custom_requests%ROWTYPE;
  v_version integer;
  v_quote custom_quotes%ROWTYPE;
BEGIN
  IF NOT public.is_owner() THEN
    RAISE EXCEPTION 'ACCES_REFUSE';
  END IF;

  SELECT * INTO v_request FROM custom_requests WHERE id = p_request_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'DEMANDE_INTROUVABLE';
  END IF;
  IF v_request.status IN ('approved', 'closed') THEN
    RAISE EXCEPTION 'DEMANDE_CLOTUREE';
  END IF;
  IF p_price_dzd IS NULL OR p_price_dzd < 0 THEN
    RAISE EXCEPTION 'PRIX_INVALIDE';
  END IF;
  IF p_valid_until IS NULL OR p_valid_until < current_date THEN
    RAISE EXCEPTION 'VALIDITE_INVALIDE';
  END IF;

  -- Un seul devis approuvable à la fois : les versions précédentes expirent.
  UPDATE custom_quotes
  SET status = 'expired', decided_at = now()
  WHERE request_id = p_request_id AND status = 'sent';

  SELECT coalesce(max(version), 0) + 1 INTO v_version
  FROM custom_quotes WHERE request_id = p_request_id;

  INSERT INTO custom_quotes (request_id, version, price_dzd, production_lead_days, valid_until, terms)
  VALUES (p_request_id, v_version, p_price_dzd, p_lead_days, p_valid_until, nullif(btrim(coalesce(p_terms, '')), ''))
  RETURNING * INTO v_quote;

  UPDATE custom_requests SET status = 'quoted' WHERE id = p_request_id;

  INSERT INTO custom_quote_events (request_id, quote_id, action, actor, note)
  VALUES (p_request_id, v_quote.id, 'sent', 'proprietaire', 'Version ' || v_version);

  RETURN jsonb_build_object(
    'version', v_version,
    'public_token', v_quote.public_token,
    'valid_until', v_quote.valid_until,
    'price_dzd', v_quote.price_dzd
  );
END;
$$;

REVOKE EXECUTE ON FUNCTION public.create_custom_quote(uuid, integer, integer, date, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.create_custom_quote(uuid, integer, integer, date, text) TO authenticated;

-- ─── GUEST: APPROVE ONE QUOTE → EXACTLY ONE ORDER ──────────────────────────

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

  -- Idempotence : un devis ne produit jamais deux commandes.
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
    subtotal_dzd, delivery_dzd, total_dzd
  ) VALUES (
    v_number, 'devis:' || v_quote.id, v_request.customer_name, v_request.phone, v_request.email,
    v_wilaya, v_commune, v_wilaya_name, v_commune_name,
    v_method, v_rate.carrier, v_rate.estimated_days_min, v_rate.estimated_days_max,
    v_address, v_pickup, v_pickup_name,
    'Devis sur mesure ' || v_request.request_number || ' (version ' || v_quote.version || ')',
    v_quote.price_dzd, v_rate.price_dzd, v_quote.price_dzd + v_rate.price_dzd
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

-- ─── OWNER: REQUEST WORKFLOW ───────────────────────────────────────────────

CREATE OR REPLACE FUNCTION public.set_custom_request_status(p_request_id uuid, p_status text)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_current text;
BEGIN
  IF NOT public.is_owner() THEN
    RAISE EXCEPTION 'ACCES_REFUSE';
  END IF;
  IF p_status NOT IN ('new', 'reviewing', 'quoted', 'approved', 'rejected', 'closed') THEN
    RAISE EXCEPTION 'STATUT_INVALIDE';
  END IF;
  IF p_status IN ('approved', 'quoted') THEN
    -- Ces statuts découlent d'un devis, pas d'un choix manuel.
    RAISE EXCEPTION 'STATUT_INVALIDE';
  END IF;

  SELECT status INTO v_current FROM custom_requests WHERE id = p_request_id FOR UPDATE;
  IF v_current IS NULL THEN
    RAISE EXCEPTION 'DEMANDE_INTROUVABLE';
  END IF;

  UPDATE custom_requests SET status = p_status WHERE id = p_request_id;
  INSERT INTO custom_quote_events (request_id, action, actor, note)
  VALUES (p_request_id, 'status_changed', 'proprietaire', v_current || ' → ' || p_status);
END;
$$;

REVOKE EXECUTE ON FUNCTION public.set_custom_request_status(uuid, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.set_custom_request_status(uuid, text) TO authenticated;



-- ============================================================================
-- SOURCE: 20261112230000_007_costs_settings_and_audit.sql
-- ============================================================================

/*
# Lunder's 3D Studio — Costs, settings and audit log (Phase 5)

## Cost model (estimates, never accounting)
Every component is counted exactly once:
  material = (print_grams / 1000) × material.cost_per_kg_dzd
  machine  = print_hours × machine_hour_rate_dzd
  labour   = (labour_minutes / 60) × labour_hour_rate_dzd
  failures = (material + machine + labour) × failure_rate_pct / 100
  packaging, return_reserve = as configured
  total    = material + machine + labour + failures + packaging + return_reserve
- Markup and margin are reported separately and never conflated:
  markup_pct = (price − total) / total ; margin_pct = (price − total) / price.
- A missing material cost is reported as `material_manquante` rather than
  silently costing zero.
- All costs are OWNER-ONLY data and are estimates, not verified accounting.

## Settings
`store_settings` is a key/value table split by `is_public`. Public rows are
readable by anyone (contact, social links, policies, SEO). Nothing secret belongs
here: API keys and service credentials live in the host's secret store, never in
this table.

## Audit
`audit_log` is append-only: no client INSERT/UPDATE/DELETE grant and no such
policy. Rows are written by SECURITY DEFINER trigger functions on the business
tables, plus `log_owner_event` for owner sign-in/out (client-asserted but
restricted to the owner).

## Depends on
Migrations 002 (is_owner), 003-006 (catalog, orders, quotes).
*/

-- ─── MATERIALS ─────────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS materials (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name text NOT NULL UNIQUE CHECK (length(btrim(name)) BETWEEN 1 AND 60),
  cost_per_kg_dzd integer NOT NULL CHECK (cost_per_kg_dzd >= 0),
  notes text,
  is_active boolean NOT NULL DEFAULT true,
  created_at timestamptz DEFAULT now()
);

ALTER TABLE materials ENABLE ROW LEVEL SECURITY;
GRANT SELECT, INSERT, UPDATE, DELETE ON materials TO authenticated;

DROP POLICY IF EXISTS "owner_all_materials" ON materials;
CREATE POLICY "owner_all_materials" ON materials FOR ALL
  TO authenticated USING (public.is_owner()) WITH CHECK (public.is_owner());

-- ─── PER-PRODUCT COST INPUTS ───────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS product_costs (
  product_id uuid PRIMARY KEY REFERENCES products(id) ON DELETE CASCADE,
  material_id uuid REFERENCES materials(id) ON DELETE SET NULL,
  print_grams numeric(10,2) NOT NULL DEFAULT 0 CHECK (print_grams >= 0),
  print_hours numeric(6,2) NOT NULL DEFAULT 0 CHECK (print_hours >= 0),
  machine_hour_rate_dzd integer NOT NULL DEFAULT 0 CHECK (machine_hour_rate_dzd >= 0),
  labor_minutes integer NOT NULL DEFAULT 0 CHECK (labor_minutes >= 0),
  labor_hour_rate_dzd integer NOT NULL DEFAULT 0 CHECK (labor_hour_rate_dzd >= 0),
  packaging_dzd integer NOT NULL DEFAULT 0 CHECK (packaging_dzd >= 0),
  failure_rate_pct numeric(5,2) NOT NULL DEFAULT 0
    CHECK (failure_rate_pct >= 0 AND failure_rate_pct <= 100),
  return_reserve_dzd integer NOT NULL DEFAULT 0 CHECK (return_reserve_dzd >= 0),
  updated_at timestamptz DEFAULT now()
);

DROP TRIGGER IF EXISTS product_costs_updated_at ON product_costs;
CREATE TRIGGER product_costs_updated_at
  BEFORE UPDATE ON product_costs
  FOR EACH ROW EXECUTE FUNCTION public.update_updated_at();

ALTER TABLE product_costs ENABLE ROW LEVEL SECURITY;
GRANT SELECT, INSERT, UPDATE, DELETE ON product_costs TO authenticated;

DROP POLICY IF EXISTS "owner_all_product_costs" ON product_costs;
CREATE POLICY "owner_all_product_costs" ON product_costs FOR ALL
  TO authenticated USING (public.is_owner()) WITH CHECK (public.is_owner());

CREATE OR REPLACE FUNCTION public.product_cost_estimate(p_product_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_cost product_costs%ROWTYPE;
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
BEGIN
  IF NOT public.is_owner() THEN
    RAISE EXCEPTION 'ACCES_REFUSE';
  END IF;

  SELECT * INTO v_cost FROM product_costs WHERE product_id = p_product_id;
  SELECT price_dzd INTO v_price FROM products WHERE id = p_product_id;
  IF v_price IS NULL THEN
    RAISE EXCEPTION 'PRODUIT_INTROUVABLE';
  END IF;

  IF FOUND AND v_cost.material_id IS NOT NULL THEN
    SELECT cost_per_kg_dzd INTO v_cost_per_kg FROM materials WHERE id = v_cost.material_id;
    v_material_cost := coalesce(v_cost_per_kg, 0) * v_cost.print_grams / 1000.0;
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
    'material_manquante', v_cost.product_id IS NULL OR v_cost.material_id IS NULL,
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

-- ─── STORE SETTINGS ────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS store_settings (
  key text PRIMARY KEY CHECK (key ~ '^[a-z0-9_]{2,60}$'),
  value text,
  is_public boolean NOT NULL DEFAULT true,
  updated_at timestamptz DEFAULT now()
);

DROP TRIGGER IF EXISTS store_settings_updated_at ON store_settings;
CREATE TRIGGER store_settings_updated_at
  BEFORE UPDATE ON store_settings
  FOR EACH ROW EXECUTE FUNCTION public.update_updated_at();

ALTER TABLE store_settings ENABLE ROW LEVEL SECURITY;
GRANT SELECT ON store_settings TO anon, authenticated;
GRANT INSERT, UPDATE, DELETE ON store_settings TO authenticated;

DROP POLICY IF EXISTS "public_read_store_settings" ON store_settings;
CREATE POLICY "public_read_store_settings" ON store_settings FOR SELECT
  TO anon, authenticated USING (is_public = true);

DROP POLICY IF EXISTS "owner_read_store_settings" ON store_settings;
CREATE POLICY "owner_read_store_settings" ON store_settings FOR SELECT
  TO authenticated USING (public.is_owner());

DROP POLICY IF EXISTS "owner_write_store_settings" ON store_settings;
CREATE POLICY "owner_write_store_settings" ON store_settings FOR ALL
  TO authenticated USING (public.is_owner()) WITH CHECK (public.is_owner());

INSERT INTO store_settings (key, value, is_public) VALUES
  ('store_name', 'LUNDER''S 3D STUDIO', true),
  ('phone', NULL, true),
  ('whatsapp', NULL, true),
  ('email', NULL, true),
  ('address', NULL, true),
  ('instagram_url', NULL, true),
  ('facebook_url', NULL, true),
  ('tiktok_url', NULL, true),
  ('seo_title', NULL, true),
  ('seo_description', NULL, true),
  ('policy_returns', NULL, true),
  ('policy_privacy', NULL, true),
  ('policy_terms', NULL, true)
ON CONFLICT (key) DO NOTHING;

-- ─── AUDIT LOG ─────────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS audit_log (
  id bigserial PRIMARY KEY,
  actor_id uuid,
  action text NOT NULL,
  entity text NOT NULL,
  entity_id text,
  details jsonb,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_audit_log_created ON audit_log(created_at DESC);
CREATE INDEX IF NOT EXISTS idx_audit_log_entity ON audit_log(entity, entity_id);

ALTER TABLE audit_log ENABLE ROW LEVEL SECURITY;

-- Lecture seule, pour le propriétaire. Aucun grant d'écriture : le journal est
-- alimenté par des fonctions SECURITY DEFINER.
GRANT SELECT ON audit_log TO authenticated;

DROP POLICY IF EXISTS "owner_read_audit_log" ON audit_log;
CREATE POLICY "owner_read_audit_log" ON audit_log FOR SELECT
  TO authenticated USING (public.is_owner());

CREATE OR REPLACE FUNCTION public.audit_row()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_details jsonb;
  v_entity_id text;
BEGIN
  IF TG_OP = 'DELETE' THEN
    v_entity_id := coalesce(to_jsonb(OLD)->>'id', to_jsonb(OLD)->>'key');
    v_details := jsonb_build_object('supprime', true);
  ELSIF TG_OP = 'INSERT' THEN
    v_entity_id := coalesce(to_jsonb(NEW)->>'id', to_jsonb(NEW)->>'key');
    v_details := jsonb_build_object('cree', true);
  ELSE
    v_entity_id := coalesce(to_jsonb(NEW)->>'id', to_jsonb(NEW)->>'key');
    SELECT jsonb_object_agg(n.key, jsonb_build_object('avant', o.value, 'apres', n.value))
      INTO v_details
    FROM jsonb_each(to_jsonb(NEW)) n
    JOIN jsonb_each(to_jsonb(OLD)) o ON o.key = n.key
    WHERE n.value IS DISTINCT FROM o.value;
  END IF;

  INSERT INTO audit_log (actor_id, action, entity, entity_id, details)
  VALUES (auth.uid(), lower(TG_TABLE_NAME) || '.' || lower(TG_OP), TG_TABLE_NAME, v_entity_id, v_details);

  RETURN NULL;
END;
$$;

REVOKE EXECUTE ON FUNCTION public.audit_row() FROM PUBLIC;

DROP TRIGGER IF EXISTS audit_products ON products;
CREATE TRIGGER audit_products
  AFTER INSERT OR UPDATE OR DELETE ON products
  FOR EACH ROW EXECUTE FUNCTION public.audit_row();

DROP TRIGGER IF EXISTS audit_delivery_rates ON delivery_rates;
CREATE TRIGGER audit_delivery_rates
  AFTER INSERT OR UPDATE OR DELETE ON delivery_rates
  FOR EACH ROW EXECUTE FUNCTION public.audit_row();

DROP TRIGGER IF EXISTS audit_store_settings ON store_settings;
CREATE TRIGGER audit_store_settings
  AFTER INSERT OR UPDATE OR DELETE ON store_settings
  FOR EACH ROW EXECUTE FUNCTION public.audit_row();

DROP TRIGGER IF EXISTS audit_custom_quotes ON custom_quotes;
CREATE TRIGGER audit_custom_quotes
  AFTER INSERT OR UPDATE OR DELETE ON custom_quotes
  FOR EACH ROW EXECUTE FUNCTION public.audit_row();

DROP TRIGGER IF EXISTS audit_orders ON orders;
CREATE TRIGGER audit_orders
  AFTER UPDATE OR DELETE ON orders
  FOR EACH ROW EXECUTE FUNCTION public.audit_row();

-- Événements qui ne modifient aucune table métier (connexion / déconnexion du
-- propriétaire). Le nom d'action est restreint pour éviter les entrées fantaisie.
CREATE OR REPLACE FUNCTION public.log_owner_event(p_action text, p_details jsonb DEFAULT NULL)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NOT public.is_owner() THEN
    RAISE EXCEPTION 'ACCES_REFUSE';
  END IF;
  IF p_action NOT IN ('proprietaire.connexion', 'proprietaire.deconnexion') THEN
    RAISE EXCEPTION 'ACTION_INVALIDE';
  END IF;

  INSERT INTO audit_log (actor_id, action, entity, entity_id, details)
  VALUES (auth.uid(), p_action, 'auth', auth.uid()::text, p_details);
END;
$$;

REVOKE EXECUTE ON FUNCTION public.log_owner_event(text, jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.log_owner_event(text, jsonb) TO authenticated;



-- ============================================================================
-- SOURCE: 20261113140000_008_auto_manufacturing_pricing.sql
-- ============================================================================

-- ═══════════════════════════════════════════════════════════════════════════
-- 008 — TARIFICATION AUTOMATIQUE DE LA FABRICATION SUR MESURE
--
-- La propriétaire configure une fois les matières et les règles de calcul ;
-- le client soumet ses mesures et reçoit un devis chiffré immédiatement.
-- Le prix n'est jamais calculé par le navigateur : `quote_custom_manufacturing`
-- relit les règles en base, applique exactement la même formule que
-- `src/lib/manufacturing-pricing.ts` et fige la ventilation dans le devis.
--
-- Accepter un devis réutilise `approve_custom_quote` : une seule transaction,
-- une seule commande, même protection contre les doubles clics.
-- ═══════════════════════════════════════════════════════════════════════════

-- ─── MATIÈRES ──────────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS manufacturing_materials (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name text NOT NULL UNIQUE,
  price_per_gram_dzd integer NOT NULL CHECK (price_per_gram_dzd >= 0),
  multiplier numeric(5, 3) NOT NULL DEFAULT 1 CHECK (multiplier > 0 AND multiplier <= 10),
  colors text[] NOT NULL DEFAULT '{}',
  is_available boolean NOT NULL DEFAULT true,
  sort_order integer NOT NULL DEFAULT 0,
  created_at timestamptz DEFAULT now(),
  updated_at timestamptz DEFAULT now()
);

-- ─── RÈGLES GÉNÉRALES (ligne unique) ───────────────────────────────────────

CREATE TABLE IF NOT EXISTS manufacturing_pricing (
  id boolean PRIMARY KEY DEFAULT true CHECK (id),
  price_per_hour_dzd integer NOT NULL DEFAULT 0 CHECK (price_per_hour_dzd >= 0),
  machine_hourly_cost_dzd integer NOT NULL DEFAULT 0 CHECK (machine_hourly_cost_dzd >= 0),
  electricity_per_hour_dzd integer NOT NULL DEFAULT 0 CHECK (electricity_per_hour_dzd >= 0),
  minimum_print_charge_dzd integer NOT NULL DEFAULT 0 CHECK (minimum_print_charge_dzd >= 0),
  extra_production_dzd integer NOT NULL DEFAULT 0 CHECK (extra_production_dzd >= 0),
  design_preparation_fee_dzd integer NOT NULL DEFAULT 0 CHECK (design_preparation_fee_dzd >= 0),
  modeling_fee_dzd integer NOT NULL DEFAULT 0 CHECK (modeling_fee_dzd >= 0),
  assembly_fee_dzd integer NOT NULL DEFAULT 0 CHECK (assembly_fee_dzd >= 0),
  finishing_fee_dzd integer NOT NULL DEFAULT 0 CHECK (finishing_fee_dzd >= 0),
  painting_fee_dzd integer NOT NULL DEFAULT 0 CHECK (painting_fee_dzd >= 0),
  margin_percent integer NOT NULL DEFAULT 0 CHECK (margin_percent >= 0 AND margin_percent <= 200),
  minimum_order_dzd integer NOT NULL DEFAULT 0 CHECK (minimum_order_dzd >= 0),
  complexity_fee_dzd integer NOT NULL DEFAULT 0 CHECK (complexity_fee_dzd >= 0),
  waste_percent integer NOT NULL DEFAULT 0 CHECK (waste_percent >= 0 AND waste_percent <= 100),
  quantity_discounts jsonb NOT NULL DEFAULT '[]'::jsonb,
  rush_fee_percent integer NOT NULL DEFAULT 0 CHECK (rush_fee_percent >= 0 AND rush_fee_percent <= 200),
  validity_days integer NOT NULL DEFAULT 14 CHECK (validity_days BETWEEN 1 AND 180),
  updated_at timestamptz DEFAULT now()
);

INSERT INTO manufacturing_pricing (id) VALUES (true) ON CONFLICT (id) DO NOTHING;

-- ─── DEVIS : SNAPSHOT ET ORIGINE ───────────────────────────────────────────

ALTER TABLE custom_quotes
  ADD COLUMN IF NOT EXISTS source text NOT NULL DEFAULT 'manual'
    CHECK (source IN ('manual', 'automatic')),
  ADD COLUMN IF NOT EXISTS pricing_snapshot jsonb,
  ADD COLUMN IF NOT EXISTS breakdown jsonb;

COMMENT ON COLUMN custom_quotes.pricing_snapshot IS
  'Règles et matières utilisées au moment du calcul : modifier les tarifs ensuite ne change jamais ce devis.';

-- ─── RLS ───────────────────────────────────────────────────────────────────

ALTER TABLE manufacturing_materials ENABLE ROW LEVEL SECURITY;
ALTER TABLE manufacturing_pricing ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Lecture publique des matières disponibles" ON manufacturing_materials;
CREATE POLICY "Lecture publique des matières disponibles" ON manufacturing_materials
  FOR SELECT USING (is_available OR public.is_owner());

DROP POLICY IF EXISTS "Gestion des matières par la propriétaire" ON manufacturing_materials;
CREATE POLICY "Gestion des matières par la propriétaire" ON manufacturing_materials
  FOR ALL USING (public.is_owner()) WITH CHECK (public.is_owner());

DROP POLICY IF EXISTS "Lecture publique de la tarification" ON manufacturing_pricing;
CREATE POLICY "Lecture publique de la tarification" ON manufacturing_pricing
  FOR SELECT USING (true);

DROP POLICY IF EXISTS "Gestion de la tarification par la propriétaire" ON manufacturing_pricing;
CREATE POLICY "Gestion de la tarification par la propriétaire" ON manufacturing_pricing
  FOR ALL USING (public.is_owner()) WITH CHECK (public.is_owner());

-- ─── CALCUL AUTOMATIQUE ────────────────────────────────────────────────────

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

  -- Meilleur palier atteint : la remise la plus forte, pas la dernière.
  SELECT coalesce(max((tier->>'percent')::integer), 0) INTO v_discount_pct
  FROM jsonb_array_elements(v_rules.quantity_discounts) AS tier
  WHERE (tier->>'minQuantity')::integer <= v_quantity
    AND (tier->>'percent')::integer > 0;

  v_discount := round(v_subtotal * v_discount_pct::numeric / 100);
  IF coalesce(p_rush, false) THEN
    v_rush := round((v_subtotal - v_discount) * v_rules.rush_fee_percent::numeric / 100);
  END IF;
  v_total := greatest(v_subtotal - v_discount + v_rush, v_rules.minimum_order_dzd);

  -- Les lignes du détail sont construites après coup pour rester dans l'ordre
  -- d'affichage, la matière et l'impression d'abord.
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

  -- Un seul devis valable à la fois : les précédents expirent.
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
GRANT EXECUTE ON FUNCTION public.quote_custom_manufacturing(uuid, text, numeric, numeric, jsonb, boolean) TO anon, authenticated;

-- ─── DÉCISION DU CLIENT : ACCEPTER OU ANNULER ──────────────────────────────

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
    -- Une commande déjà créée ne peut pas être annulée par ce chemin : elle se
    -- gère depuis le suivi de commande, pour ne jamais laisser un devis
    -- « annulé » associé à une commande active.
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

  -- Acceptation : déléguée au chemin existant, atomique et idempotent, qui
  -- recalcule les frais de livraison et crée au plus une commande.
  RETURN public.approve_custom_quote(p_quote_token, coalesce(p_delivery, '{}'::jsonb));
END;
$$;

REVOKE EXECUTE ON FUNCTION public.decide_custom_quote(uuid, text, jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.decide_custom_quote(uuid, text, jsonb) TO anon, authenticated;

-- Le changement de statut d'une demande ne doit pas permettre de repasser une
-- demande déjà acceptée en « quoted » depuis l'interface propriétaire.
CREATE OR REPLACE FUNCTION public.guard_custom_request_status()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF old.status = 'approved' AND new.status <> 'approved' THEN
    RAISE EXCEPTION 'DEMANDE_CLOTUREE';
  END IF;
  RETURN new;
END;
$$;

DROP TRIGGER IF EXISTS custom_requests_status_guard ON custom_requests;
CREATE TRIGGER custom_requests_status_guard
  BEFORE UPDATE OF status ON custom_requests
  FOR EACH ROW EXECUTE FUNCTION public.guard_custom_request_status();

-- ─── SUPPRESSION D'UNE COMMANDE (PROPRIÉTAIRE UNIQUEMENT) ──────────────────

CREATE OR REPLACE FUNCTION public.delete_order(p_order_id uuid)
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

  -- Une commande livrée est un document comptable : on la garde. Les statuts
  -- antérieurs peuvent être supprimés, et l'action reste tracée.
  IF v_order.status IN ('delivered', 'shipped') THEN
    RAISE EXCEPTION 'COMMANDE_NON_SUPPRIMABLE';
  END IF;

  DELETE FROM orders WHERE id = p_order_id;

  PERFORM public.log_owner_event(
    'order.deleted',
    jsonb_build_object(
      'order_id', v_order.id,
      'order_number', v_order.order_number,
      'status', v_order.status,
      'total_dzd', v_order.total_dzd
    )
  );

  RETURN jsonb_build_object('deleted', true, 'order_number', v_order.order_number);
END;
$$;

REVOKE EXECUTE ON FUNCTION public.delete_order(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.delete_order(uuid) TO authenticated;

-- ─── RAFRAÎCHISSEMENT updated_at ───────────────────────────────────────────

DROP TRIGGER IF EXISTS manufacturing_materials_updated_at ON manufacturing_materials;
CREATE TRIGGER manufacturing_materials_updated_at
  BEFORE UPDATE ON manufacturing_materials
  FOR EACH ROW EXECUTE FUNCTION public.update_updated_at();

DROP TRIGGER IF EXISTS manufacturing_pricing_updated_at ON manufacturing_pricing;
CREATE TRIGGER manufacturing_pricing_updated_at
  BEFORE UPDATE ON manufacturing_pricing
  FOR EACH ROW EXECUTE FUNCTION public.update_updated_at();

CREATE INDEX IF NOT EXISTS idx_manufacturing_materials_available
  ON manufacturing_materials (is_available, sort_order);


-- <<< END CONSOLIDATED MIGRATIONS 001–008


-- >>> BEGIN CONSOLIDATED MIGRATIONS 009–016



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


-- <<< END CONSOLIDATED MIGRATIONS 009–016


-- >>> BEGIN CONSOLIDATED MIGRATIONS 017–023 + ACCESS REVOCATION



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


-- <<< END CONSOLIDATED MIGRATIONS 017–023 + ACCESS REVOCATION


-- >>> BEGIN CONSOLIDATED MIGRATIONS 024–030



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


-- <<< END CONSOLIDATED MIGRATIONS 024–030
