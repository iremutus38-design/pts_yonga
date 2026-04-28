-- 12_company_holidays.sql

CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE SCHEMA IF NOT EXISTS core;

DROP TABLE IF EXISTS core.company_holidays CASCADE;

CREATE TABLE core.company_holidays (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    holiday_name VARCHAR(100) NOT NULL,
    holiday_date DATE NOT NULL UNIQUE,
    is_recurring BOOLEAN DEFAULT TRUE,
    description TEXT,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

-- 2026 Tatilleri
INSERT INTO core.company_holidays (holiday_name, holiday_date, is_recurring) VALUES
('Yılbaşı', '2026-01-01', TRUE),
('Ulusal Egemenlik ve Çocuk Bayramı', '2026-04-23', TRUE),
('Emek ve Dayanışma Günü (1 Mayıs)', '2026-05-01', TRUE)
ON CONFLICT (holiday_date) DO NOTHING;

-- ============================================================
-- RLS (ROW LEVEL SECURITY) BÖLÜMÜ
-- ============================================================

-- 1. RLS AKTİVASYONU
ALTER TABLE core.company_holidays ENABLE ROW LEVEL SECURITY;

-- 2. POLİTİKALAR (Temizlik)
DROP POLICY IF EXISTS company_holidays_select_policy ON core.company_holidays;
DROP POLICY IF EXISTS company_holidays_modify_hr_admin ON core.company_holidays;

-- ------------------------------------------------------------
-- POLİTİKA TANIMLARI
-- ------------------------------------------------------------

-- 1) GÖRÜNTÜLEME (SELECT) KURALI:
--    * Tüm çalışanlar resmi tatilleri görebilmelidir. 
--    * Bu, takvim planlaması ve izin bakiyesi hesaplaması için gereklidir.
CREATE POLICY company_holidays_select_policy ON core.company_holidays
    FOR SELECT
    USING (TRUE);

-- 2) YÖNETİM (INSERT, UPDATE, DELETE) KURALI:
--    * Tatil ekleme (örneğin köprü gün ilan edilmesi) veya tarih değiştirme
--    * Sadece HR ve ADMIN yetkisindedir.
CREATE POLICY company_holidays_modify_hr_admin ON core.company_holidays
    FOR ALL 
    TO public
    USING (core.current_user_role() IN ('HR', 'ADMIN'))
    WITH CHECK (core.current_user_role() IN ('HR', 'ADMIN'));