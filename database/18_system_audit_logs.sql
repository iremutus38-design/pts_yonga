-- 18_system_audit_logs.sql

CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE SCHEMA IF NOT EXISTS system;

-- 1. İŞLEM TİPİ ENUM TANIMI
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'audit_action') THEN
        CREATE TYPE system.audit_action AS ENUM (
            'INSERT', 'UPDATE', 'DELETE',
            'LOGIN', 'LOGOUT', 'FAILED_LOGIN',
            'EXPORT_DATA'
        );
    END IF;
END $$;

-- 2. TABLOYU OLUŞTUR
DROP TABLE IF EXISTS system.audit_logs CASCADE;

CREATE TABLE system.audit_logs (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),

    -- İşlemi yapan kullanıcı (Eğer sistem yaptıysa veya silinmiş bir kullanıcıysa NULL olabilir)
    profile_id UUID REFERENCES core.profiles(id) ON DELETE SET NULL,

    -- Değişikliğin yapıldığı tablo (Örn: 'finance.expense_requests')
    table_name VARCHAR(100),

    -- Yapılan işlem türü
    action_type system.audit_action NOT NULL,

    -- Etkilenen kaydın UUID'si
    record_id UUID,

    -- JSONB formatında eski ve yeni veri (Kıyaslama için mükemmeldir)
    old_data JSONB,
    new_data JSONB,

    -- Güvenlik için IP adresi ve User Agent (Tarayıcı bilgisi)
    ip_address VARCHAR(45),
    user_agent TEXT,

    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

-- Belirli bir kaydın geçmişini hızlıca getirmek için index
CREATE INDEX IF NOT EXISTS idx_audit_logs_table_record ON system.audit_logs(table_name, record_id);
-- Belirli bir kullanıcının aktivitelerini görmek için index
CREATE INDEX IF NOT EXISTS idx_audit_logs_profile      ON system.audit_logs(profile_id);


-- ============================================================
-- 18_system_audit_logs.sql - RLS (DENETİM VE GÜVENLİK)
-- ============================================================

-- 1. RLS AKTİVASYONU
ALTER TABLE system.audit_logs ENABLE ROW LEVEL SECURITY;

-- 2. POLİTİKALAR (Temizlik)
DROP POLICY IF EXISTS audit_logs_select_admin_hr ON system.audit_logs;
DROP POLICY IF EXISTS audit_logs_insert_system ON system.audit_logs;
DROP POLICY IF EXISTS audit_logs_no_update ON system.audit_logs;
DROP POLICY IF EXISTS audit_logs_no_delete ON system.audit_logs;

-- ------------------------------------------------------------
-- POLİTİKA TANIMLARI
-- ------------------------------------------------------------

-- 1) GÖRÜNTÜLEME (SELECT):
--    * Sadece ADMIN ve HR tüm sistem hareketlerini görebilir.
--    * Normal çalışanlar kendi hareketleri olsa dahi bu tabloyu göremez (Sistem şeffaflığı vs. Gizlilik).
CREATE POLICY audit_logs_select_admin_hr ON system.audit_logs
    FOR SELECT
    USING (core.current_user_role() IN ('ADMIN', 'HR'));

-- 2) EKLEME (INSERT):
--    * Loglar genelde veritabanı trigger'ları veya sistem servisleri tarafından oluşturulur.
--    * Yine de sadece ADMIN/HR yetkisi altındaki işlemlerin loglanmasına izin veriyoruz.
CREATE POLICY audit_logs_insert_system ON system.audit_logs
    FOR INSERT
    WITH CHECK (core.current_user_role() IN ('ADMIN', 'HR'));

-- 3) GÜNCELLEME (UPDATE) - KESİNLİKLE YASAK:
--    * Hiç kimse oluşmuş bir logu değiştiremez.
--    * Bu kuralı boş bırakarak (veya USING FALSE diyerek) güncellemeyi tamamen kapatıyoruz.
CREATE POLICY audit_logs_no_update ON system.audit_logs
    FOR UPDATE
    USING (FALSE)
    WITH CHECK (FALSE);

-- 4) SİLME (DELETE) - KESİNLİKLE YASAK:
--    * Hiç kimse bir log kaydını silemez. 
--    * Admin bile olsa "ben bu hatayı yapmıştım, logu sileyim" diyemez.
CREATE POLICY audit_logs_no_delete ON system.audit_logs
    FOR DELETE
    USING (FALSE);