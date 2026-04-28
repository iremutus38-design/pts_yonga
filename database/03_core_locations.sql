-- 03_core_locations.sql

CREATE EXTENSION IF NOT EXISTS "uuid-ossp";

CREATE TABLE IF NOT EXISTS core.locations (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    name VARCHAR(100) UNIQUE NOT NULL, 
    address TEXT,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

TRUNCATE core.locations CASCADE;

INSERT INTO core.locations (name, address) VALUES 
('Ankara YDA Center', 'Çankaya/Ankara - Genel Merkez'),
('İstanbul Teknopark', 'Pendik/İstanbul - Teknopark Ofisi')
ON CONFLICT (name) DO NOTHING;

-- ============================================================
-- RLS (ROW LEVEL SECURITY) BÖLÜMÜ
-- ============================================================

-- 1. RLS AKTİVASYONU
ALTER TABLE core.locations ENABLE ROW LEVEL SECURITY;

-- 2. POLİTİKALAR (Temizlik)
DROP POLICY IF EXISTS locations_select_all ON core.locations;
DROP POLICY IF EXISTS locations_insert_hr_admin ON core.locations;
DROP POLICY IF EXISTS locations_update_hr_admin ON core.locations;
DROP POLICY IF EXISTS locations_delete_hr_admin ON core.locations;

-- ------------------------------------------------------------
-- POLİTİKA TANIMLARI
-- ------------------------------------------------------------

-- 1) HERKES OKUYABİLİR
-- Tüm çalışanlar şirketin hangi lokasyonları olduğunu görmelidir.
CREATE POLICY locations_select_all ON core.locations
    FOR SELECT
    USING (TRUE);

-- 2) SADECE HR VEYA ADMIN EKLEYEBİLİR
-- Yeni bir ofis veya şube açma yetkisi üst yönetimdedir.
CREATE POLICY locations_insert_hr_admin ON core.locations
    FOR INSERT
    WITH CHECK (core.current_user_role() IN ('HR', 'ADMIN'));

-- 3) SADECE HR VEYA ADMIN GÜNCELLEYEBİLİR
CREATE POLICY locations_update_hr_admin ON core.locations
    FOR UPDATE
    USING      (core.current_user_role() IN ('HR', 'ADMIN'))
    WITH CHECK (core.current_user_role() IN ('HR', 'ADMIN'));

-- 4) SADECE HR VEYA ADMIN SİLEBİLİR
CREATE POLICY locations_delete_hr_admin ON core.locations
    FOR DELETE
    USING (core.current_user_role() IN ('HR', 'ADMIN'));