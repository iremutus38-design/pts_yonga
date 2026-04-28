-- 13_leave_balances.sql

CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE SCHEMA IF NOT EXISTS leave;

DROP TABLE IF EXISTS leave.leave_balances CASCADE;

CREATE TABLE leave.leave_balances (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    profile_id UUID NOT NULL REFERENCES core.profiles(id) ON DELETE CASCADE,
    leave_type_id UUID NOT NULL REFERENCES leave.leave_types(id) ON DELETE CASCADE,

    -- Hangi yıla ait bakiye?
    year_period INTEGER NOT NULL DEFAULT EXTRACT(YEAR FROM CURRENT_DATE),

    -- Backend'in hesaplayıp yazdığı toplam hak (Örn: 14.0)
    total_accrued DECIMAL(5,2) NOT NULL DEFAULT 0,

    -- Backend'in onaylanan izinlerden topladığı miktar (Örn: 3.5)
    used_days DECIMAL(5,2) NOT NULL DEFAULT 0,

    -- Otomatik hesaplanan kalan (SQL seviyesinde koruma)
    remaining_days DECIMAL(5,2) GENERATED ALWAYS AS (total_accrued - used_days) STORED,

    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),

    -- Veri bütünlüğü: Bir personelin aynı yıl için aynı tipte tek bir cüzdanı olabilir
    CONSTRAINT unique_profile_leave_year UNIQUE(profile_id, leave_type_id, year_period),

    CONSTRAINT balance_total_check CHECK (total_accrued >= 0),
    CONSTRAINT balance_used_check  CHECK (used_days     >= 0)
);

-- profile_id üzerinde index — "İrem'in tüm bakiyelerini getir"
-- sorgusu (dashboard'da kalan izinler kartı) seq scan yerine index scan kullansın
CREATE INDEX IF NOT EXISTS idx_leave_balances_profile ON leave.leave_balances(profile_id);

-- ============================================================
-- 13_leave_balances.sql - RLS (ROW LEVEL SECURITY) BÖLÜMÜ
-- ============================================================

-- 1. RLS AKTİVASYONU
ALTER TABLE leave.leave_balances ENABLE ROW LEVEL SECURITY;

-- 2. POLİTİKALAR (Temizlik)
DROP POLICY IF EXISTS leave_balances_select_policy ON leave.leave_balances;
DROP POLICY IF EXISTS leave_balances_modify_hr_admin ON leave.leave_balances;

-- ------------------------------------------------------------
-- POLİTİKA TANIMLARI
-- ------------------------------------------------------------

-- 1) GÖRÜNTÜLEME (SELECT) KURALI:
--    * İK ve Admin: Şirketteki herkesin izin cüzdanını görebilir.
--    * Personel: Sadece KENDİNE ait olan izin bakiyelerini (kalan günlerini) görebilir.
CREATE POLICY leave_balances_select_policy ON leave.leave_balances
    FOR SELECT
    USING (
        core.current_user_role() IN ('HR', 'ADMIN') 
        OR 
        profile_id = (NULLIF(current_setting('app.current_user_id', TRUE), '')::UUID)
    );

-- 2) YÖNETİM (INSERT, UPDATE, DELETE) KURALI:
--    * İzin haklarını tanımlama (total_accrued) veya kullanılan günleri manuel düzeltme
--    * SADECE HR ve ADMIN yetkisindedir.
CREATE POLICY leave_balances_modify_hr_admin ON leave.leave_balances
    FOR ALL 
    TO public
    USING (core.current_user_role() IN ('HR', 'ADMIN'))
    WITH CHECK (core.current_user_role() IN ('HR', 'ADMIN'));