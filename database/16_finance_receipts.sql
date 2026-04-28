-- 16_finance_receipts.sql

CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE SCHEMA IF NOT EXISTS finance;

DROP TABLE IF EXISTS finance.receipts CASCADE;

CREATE TABLE finance.receipts (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),

    -- Hangi harcama talebine ait? (UUID olarak güncelledik)
    expense_id UUID NOT NULL REFERENCES finance.expense_requests(id) ON DELETE CASCADE,

    -- Fatura/Fiş üzerindeki gerçek veriler 
    receipt_no VARCHAR(100),
    receipt_date DATE,
    total_amount DECIMAL(12,2),

    -- Dosya bilgileri
    file_url TEXT NOT NULL,
    file_type VARCHAR(50), -- 'image/jpeg', 'application/pdf'

    -- İleride dosyayı kimin yüklediğini takip etmek gerekebilir
    uploaded_by UUID REFERENCES core.profiles(id),

    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

-- Hızlı erişim için index
CREATE INDEX IF NOT EXISTS idx_receipts_expense_id ON finance.receipts(expense_id);

-- ============================================================
-- 16_finance_receipts.sql - RLS (ROW LEVEL SECURITY)
-- ============================================================

-- 1. RLS AKTİVASYONU
ALTER TABLE finance.receipts ENABLE ROW LEVEL SECURITY;

-- 2. POLİTİKALAR (Temizlik)
DROP POLICY IF EXISTS receipts_select_policy ON finance.receipts;
DROP POLICY IF EXISTS receipts_insert_policy ON finance.receipts;
DROP POLICY IF EXISTS receipts_update_policy ON finance.receipts;
DROP POLICY IF EXISTS receipts_delete_policy ON finance.receipts;

-- ------------------------------------------------------------
-- POLİTİKA TANIMLARI
-- ------------------------------------------------------------

-- 1) GÖRÜNTÜLEME (SELECT):
--    * İK ve Admin: Sistemdeki tüm fatura kayıtlarını görebilir.
--    * Kişi: Sadece kendi yüklediği (uploaded_by) faturaları görebilir.
CREATE POLICY receipts_select_policy ON finance.receipts
    FOR SELECT
    USING (
        core.current_user_role() IN ('HR', 'ADMIN')
        OR
        uploaded_by = (NULLIF(current_setting('app.current_user_id', TRUE), '')::UUID)
        OR
        expense_id IN (
            SELECT id FROM finance.expense_requests
            WHERE profile_id = (NULLIF(current_setting('app.current_user_id', TRUE), '')::UUID)
        )
    );

-- 2) EKLEME (INSERT):
--    * İK ve Admin: Herhangi bir masraf için fatura ekleyebilir.
--    * Kişi: Sadece kendi profil ID'si üzerinden fatura yükleyebilir.
CREATE POLICY receipts_insert_policy ON finance.receipts
    FOR INSERT
    WITH CHECK (
        core.current_user_role() IN ('HR', 'ADMIN') 
        OR 
        uploaded_by = (NULLIF(current_setting('app.current_user_id', TRUE), '')::UUID)
    );

-- 3) GÜNCELLEME (UPDATE):
--    * İK ve Admin: Hatalı girişleri veya dosya URL'lerini güncelleyebilir.
--    * Kişi: Sadece kendi yüklediği faturaları güncelleyebilir.
CREATE POLICY receipts_update_policy ON finance.receipts
    FOR UPDATE
    USING (
        core.current_user_role() IN ('HR', 'ADMIN') 
        OR 
        uploaded_by = (NULLIF(current_setting('app.current_user_id', TRUE), '')::UUID)
    );

-- 4) SİLME (DELETE):
--    * İK ve Admin: Herhangi bir faturayı silebilir.
--    * Kişi: Sadece kendi yüklediği faturayı silebilir.
CREATE POLICY receipts_delete_policy ON finance.receipts
    FOR DELETE
    USING (
        core.current_user_role() IN ('HR', 'ADMIN') 
        OR 
        uploaded_by = (NULLIF(current_setting('app.current_user_id', TRUE), '')::UUID)
    );