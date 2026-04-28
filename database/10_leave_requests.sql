-- 10_leave_requests.sql

-- 1. UUID Eklentisi (Her ihtimale karşı)
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";

CREATE SCHEMA IF NOT EXISTS leave;

-- 2. ENUM Tipi Kontrolü (Zaten oluşturmuştun ama UUID uyumlu şemada kalmalı)
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'request_status') THEN
        CREATE TYPE core.request_status AS ENUM ('PENDING', 'APPROVED', 'REJECTED', 'CANCELLED');
    END IF;
END $$;

-- 3. İzin Talepleri Tablosu
DROP TABLE IF EXISTS leave.leave_requests CASCADE;

CREATE TABLE leave.leave_requests (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),

    -- Talebi yapan personel (Artık UUID)
    profile_id UUID NOT NULL REFERENCES core.profiles(id) ON DELETE CASCADE,

    -- İzin türü referansı (Artık UUID ve leave_types'a bağlı)
    leave_type_id UUID NOT NULL REFERENCES leave.leave_types(id),

    -- Durum (Enum: PENDING, APPROVED, REJECTED, CANCELLED)
    status core.request_status NOT NULL DEFAULT 'PENDING',

    -- İzin tarihleri
    start_date DATE NOT NULL,
    end_date DATE NOT NULL,

    -- Tatiller ve hafta sonları düşülmüş, backend tarafından hesaplanan net gün
    -- DECIMAL(4,1) yarım gün izinleri (0.5) desteklemek için idealdir.
    total_days DECIMAL(4,1) NOT NULL,

    reason TEXT, -- İzin açıklası

    -- Onaylayan kişi (Genelde Yönetici veya İK)
    approved_by UUID REFERENCES core.profiles(id),
    rejection_reason TEXT, -- Reddedilirse neden reddedildi?

    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),

    CONSTRAINT leave_dates_check CHECK (end_date >= start_date),

    CONSTRAINT leave_total_days_check CHECK (total_days >= 0)
);

-- "İrem'in tüm izin geçmişi" tarzı sorgular seq scan yerine index scan kullansın diye.
CREATE INDEX IF NOT EXISTS idx_leave_requests_profile ON leave.leave_requests(profile_id);

CREATE INDEX IF NOT EXISTS idx_leave_requests_status ON leave.leave_requests(status);


-- ============================================================
--  RLS POLİTİKALARI (Row Level Security)
-- ============================================================

-- 1. RLS AKTİVASYONU
ALTER TABLE leave.leave_requests ENABLE ROW LEVEL SECURITY;

-- 2. POLİTİKALAR (Temizlik)
DROP POLICY IF EXISTS leave_requests_select_policy ON leave.leave_requests;
DROP POLICY IF EXISTS leave_requests_insert_self ON leave.leave_requests;
DROP POLICY IF EXISTS leave_requests_update_policy ON leave.leave_requests;
DROP POLICY IF EXISTS leave_requests_delete_admin ON leave.leave_requests;

-- ------------------------------------------------------------
-- POLİTİKA TANIMLARI
-- ------------------------------------------------------------

-- 1) GÖRÜNTÜLEME (SELECT)
-- Hiyerarşi + Vekalet kontrolü eklenmiş hali
CREATE POLICY leave_requests_select_policy ON leave.leave_requests
    FOR SELECT
    USING (
        core.current_user_role() IN ('HR', 'ADMIN') 
        OR profile_id = (NULLIF(current_setting('app.current_user_id', TRUE), '')::UUID)
        OR (core.current_user_role() = 'TEAM_LEAD' AND profile_id IN (
            -- Kendi takımı
            SELECT id FROM core.profiles WHERE team_id = (SELECT team_id FROM core.profiles WHERE id = (NULLIF(current_setting('app.current_user_id', TRUE), '')::UUID))
        ))
        OR (core.current_user_role() = 'DIRECTOR' AND profile_id IN (
            -- Kendi departmanı
            SELECT id FROM core.profiles WHERE department_id = (SELECT department_id FROM core.profiles WHERE id = (NULLIF(current_setting('app.current_user_id', TRUE), '')::UUID))
            UNION
            -- VEKALET: Eğer bir Takım Lideri bu direktöre vekalet verdiyse, o liderin takımını da görsün
            SELECT id FROM core.profiles WHERE team_id IN (
                SELECT team_id FROM core.profiles WHERE id IN (
                    -- vekalet sadece LEAVE veya ALL modülünü kapsıyorsa devreye girer.
                    SELECT grantor_id FROM core.user_delegations
                    WHERE grantee_id = (NULLIF(current_setting('app.current_user_id', TRUE), '')::UUID)
                    AND is_active = TRUE AND NOW() BETWEEN start_date AND end_date
                    AND module IN ('LEAVE', 'ALL')
                )
            )
        ))
    );
-- 2) EKLEME (INSERT)
-- Sadece çalışan kendi adına talep oluşturabilir.
CREATE POLICY leave_requests_insert_self ON leave.leave_requests
    FOR INSERT
    WITH CHECK (profile_id = (NULLIF(current_setting('app.current_user_id', TRUE), '')::UUID));

-- 3) GÜNCELLEME (UPDATE) - ONAY VE BOZMA
-- Vekalet ile yetki devri eklenmiş hali
CREATE POLICY leave_requests_update_policy ON leave.leave_requests
    FOR UPDATE
    USING (
        core.current_user_role() = 'ADMIN' 
        OR 
        -- Takım Lideri kendi takımını veya vekalet aldığı takımı yönetir
        (core.current_user_role() = 'TEAM_LEAD' AND profile_id IN (
            SELECT id FROM core.profiles WHERE team_id = (SELECT team_id FROM core.profiles WHERE id = (NULLIF(current_setting('app.current_user_id', TRUE), '')::UUID))
        ))
        OR
        -- Direktör kendi departmanını veya vekalet aldığı takımları onaylar
        (core.current_user_role() = 'DIRECTOR' AND profile_id IN (
            SELECT id FROM core.profiles WHERE department_id = (SELECT department_id FROM core.profiles WHERE id = (NULLIF(current_setting('app.current_user_id', TRUE), '')::UUID))
            UNION
            -- VEKALET: TL izne çıktığında yetkisi buraya akar
            SELECT id FROM core.profiles WHERE team_id IN (
                SELECT team_id FROM core.profiles WHERE id IN (
                    SELECT grantor_id FROM core.user_delegations 
                    WHERE grantee_id = (NULLIF(current_setting('app.current_user_id', TRUE), '')::UUID)
                    AND is_active = TRUE AND NOW() BETWEEN start_date AND end_date
                )
            )
        ))
        OR
        (profile_id = (NULLIF(current_setting('app.current_user_id', TRUE), '')::UUID) AND status = 'PENDING')
    );
    -- 4) SİLME (DELETE)
    -- Veritabanından satırı tamamen silme yetkisi SADECE ADMIN'dedir.
    -- Diğer roller (İK dahil) asla satır silemez.
    CREATE POLICY leave_requests_delete_admin ON leave.leave_requests
        FOR DELETE
        USING (core.current_user_role() = 'ADMIN');