-- 15_finance_expense_requests.sql

-- UUID eklentisi
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";

CREATE SCHEMA IF NOT EXISTS finance;

-- 1. TİPLERİ KONTROL ET VE OLUŞTUR (Core şemasında merkezi yönetim)
DO $$
BEGIN
    -- Harcama Türü: Avans mı yoksa Gerçek Fiş/Fatura mı?
    IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'expense_type') THEN
        CREATE TYPE core.expense_type AS ENUM ('ADVANCE', 'ACTUAL_EXPENSE');
    END IF;

    -- İstek Durumu (İzinlerde kullandığın Enum ile aynı)
    IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'request_status') THEN
        CREATE TYPE core.request_status AS ENUM ('PENDING', 'APPROVED', 'REJECTED', 'CANCELLED');
    END IF;
END $$;

-- 2. TABLOYU OLUŞTUR
DROP TABLE IF EXISTS finance.expense_requests CASCADE;

CREATE TABLE finance.expense_requests (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),

    -- Kim harcama yaptı? (UUID)
    profile_id UUID NOT NULL REFERENCES core.profiles(id) ON DELETE CASCADE,

    -- Hangi kurala/limite tabi? (Örn: MEAL_DAILY politikası)
    policy_id UUID REFERENCES finance.expense_policies(id) ON DELETE SET NULL,

    -- Talep türü (Avans veya Gerçek Harcama)
    request_type core.expense_type NOT NULL,

    -- Bağlantılı Talep: Avans kapatma işlemi için önemli
    parent_request_id UUID REFERENCES finance.expense_requests(id),

    amount DECIMAL(12,2) NOT NULL,
    currency VARCHAR(3) DEFAULT 'TRY',

    description TEXT,

    -- Backend kontrolü sonucu limit aşımı var mı?
    is_over_limit BOOLEAN DEFAULT FALSE,

    status core.request_status NOT NULL DEFAULT 'PENDING',

    -- Onaylayan yönetici (UUID)
    approved_by UUID REFERENCES core.profiles(id),

    -- !!! YENİ: Onaylanma tarihi.
    -- PENDING -> APPROVED geçişinde trigger NOW() ile doldurur.
    -- ADVANCE türü talepler için "+1 ay fatura yükleme son tarihi"
    -- bu alana referans alınarak hesaplanır:
    --     deadline = approved_at + INTERVAL '1 month'
    -- (Hem trigger içinde bildirim mesajında, hem ileride zamanlanmış
    -- görevlerde kullanılacak.)
    approved_at TIMESTAMP WITH TIME ZONE,

    rejection_reason TEXT,

    -- Ödeme durumu (Muhasebe için)
    is_paid BOOLEAN DEFAULT FALSE,
    paid_at TIMESTAMP WITH TIME ZONE,

    -- Fiş/Fatura belgesinin URL'si (S3, Cloudinary vb. depolanan görsel)
    receipt_url TEXT,

    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),

    CONSTRAINT expense_amount_positive CHECK (amount > 0)
);

-- Performans için index (Özellikle avans-harcama eşleşmelerini hızlı sorgulamak için)
CREATE INDEX IF NOT EXISTS idx_expense_requests_parent  ON finance.expense_requests(parent_request_id);
CREATE INDEX IF NOT EXISTS idx_expense_requests_profile ON finance.expense_requests(profile_id);

-- "Onay bekleyen tüm masraf talepleri" sorgusu yöneticilerin panelinde sürekli atılır.
CREATE INDEX IF NOT EXISTS idx_expense_requests_status  ON finance.expense_requests(status);

-- ============================================================
-- 15_finance_expense_requests.sql - RLS (ROW LEVEL SECURITY)
-- ============================================================

-- 1. RLS AKTİVASYONU
ALTER TABLE finance.expense_requests ENABLE ROW LEVEL SECURITY;

-- 2. POLİTİKALAR (Temizlik)
DROP POLICY IF EXISTS expense_requests_select_policy ON finance.expense_requests;
DROP POLICY IF EXISTS expense_requests_insert_policy ON finance.expense_requests;
DROP POLICY IF EXISTS expense_requests_update_policy ON finance.expense_requests;
DROP POLICY IF EXISTS expense_requests_delete_policy ON finance.expense_requests;

-- ------------------------------------------------------------
-- POLİTİKA TANIMLARI
-- ------------------------------------------------------------

-- 1) GÖRÜNTÜLEME (SELECT):
--    * İK ve Admin: Tüm masraf taleplerini ve fişleri görebilir.
--    * Kişi: Sadece kendi oluşturduğu talepleri görebilir.
CREATE POLICY expense_requests_select_policy ON finance.expense_requests
    FOR SELECT
    USING (
        core.current_user_role() IN ('HR', 'ADMIN') 
        OR 
        profile_id = (NULLIF(current_setting('app.current_user_id', TRUE), '')::UUID)
    );

-- 2) EKLEME (INSERT):
--    * İK ve Admin: Herkes adına masraf girebilir (veya manuel düzeltme yapabilir).
--    * Kişi: Sadece kendi profil ID'si ile talep oluşturabilir.
CREATE POLICY expense_requests_insert_policy ON finance.expense_requests
    FOR INSERT
    WITH CHECK (
        core.current_user_role() IN ('HR', 'ADMIN') 
        OR 
        profile_id = (NULLIF(current_setting('app.current_user_id', TRUE), '')::UUID)
    );

-- 3) GÜNCELLEME (UPDATE):
--    * İK ve Admin: Her aşamada güncelleyebilir (Onaylama, reddetme, ödeme işaretleme).
--    * Kişi: Sadece KENDİ talebini ve sadece DURUM 'PENDING' (Beklemede) ise güncelleyebilir.
--    * (Onaylanmış veya ödenmiş masraf kullanıcı tarafından değiştirilemez).
CREATE POLICY expense_requests_update_policy ON finance.expense_requests
    FOR UPDATE
    USING (
        core.current_user_role() IN ('HR', 'ADMIN') 
        OR 
        (profile_id = (NULLIF(current_setting('app.current_user_id', TRUE), '')::UUID) AND status = 'PENDING')
    );

-- 4) SİLME (DELETE):
--    * İK ve Admin: Herhangi bir talebi silebilir.
--    * Kişi: Sadece KENDİ talebini ve sadece DURUM 'PENDING' (Beklemede) ise silebilir.
CREATE POLICY expense_requests_delete_policy ON finance.expense_requests
    FOR DELETE
    USING (
        core.current_user_role() IN ('HR', 'ADMIN') 
        OR 
        (profile_id = (NULLIF(current_setting('app.current_user_id', TRUE), '')::UUID) AND status = 'PENDING')
    );