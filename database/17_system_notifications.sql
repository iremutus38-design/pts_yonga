-- 17_system_notifications.sql

CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE SCHEMA IF NOT EXISTS system;

-- 1. BİLDİRİM TİPİ ENUM TANIMI (UUID standartlarına uygun şemada)
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'notification_type') THEN
        CREATE TYPE system.notification_type AS ENUM ('INFO', 'SUCCESS', 'WARNING', 'ERROR', 'ACTION');
    END IF;
END $$;

-- 2. TABLOYU OLUŞTUR
DROP TABLE IF EXISTS system.notifications CASCADE;

CREATE TABLE system.notifications (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),

    -- Bildirimin sahibi (UUID)
    profile_id UUID NOT NULL REFERENCES core.profiles(id) ON DELETE CASCADE,

    title VARCHAR(255) NOT NULL,
    message TEXT NOT NULL,

    -- Bildirim türü (Rengini ve ikonunu frontend belirler)
    type system.notification_type NOT NULL DEFAULT 'INFO',

    -- Tıklandığında yönlendirilecek sayfa
    target_url TEXT,

    is_read BOOLEAN DEFAULT FALSE,
    read_at TIMESTAMP WITH TIME ZONE,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

-- Okunmamış bildirimleri hızlıca listelemek için performans indeksi
CREATE INDEX IF NOT EXISTS idx_notifications_profile_unread
    ON system.notifications(profile_id) WHERE is_read = FALSE;

    -- ============================================================
-- 17_system_notifications.sql - RLS (ROW LEVEL SECURITY)
-- ============================================================

-- 1. RLS AKTİVASYONU
ALTER TABLE system.notifications ENABLE ROW LEVEL SECURITY;

-- 2. POLİTİKALAR (Temizlik)
DROP POLICY IF EXISTS notifications_select_own ON system.notifications;
DROP POLICY IF EXISTS notifications_update_own ON system.notifications;
DROP POLICY IF EXISTS notifications_delete_own ON system.notifications;
DROP POLICY IF EXISTS notifications_insert_system_admin ON system.notifications;

-- ------------------------------------------------------------
-- POLİTİKA TANIMLARI
-- ------------------------------------------------------------

-- 1) GÖRÜNTÜLEME (SELECT):
--    * Her kullanıcı SADECE kendisine gelen bildirimleri görebilir.
--    * ADMIN ve HR bile olsa, başkasının bildirim kutusunu okuyamaz (Gizlilik gereği).
CREATE POLICY notifications_select_own ON system.notifications
    FOR SELECT
    USING (profile_id = (NULLIF(current_setting('app.current_user_id', TRUE), '')::UUID));

-- 2) EKLEME (INSERT):
--    * Bildirimleri genelde sistem tetikleyicileri (Triggers) veya Admin paneli oluşturur.
--    * Bir çalışan kendi kendine bildirim oluşturamaz.
CREATE POLICY notifications_insert_system_admin ON system.notifications
    FOR INSERT
    WITH CHECK (core.current_user_role() IN ('ADMIN', 'HR'));

-- 3) GÜNCELLEME (UPDATE):
--    * Kullanıcı sadece bildirimi "okundu" (is_read = TRUE) olarak işaretlemek için güncelleyebilir.
--    * Sadece kendi bildirimini güncelleyebilir.
CREATE POLICY notifications_update_own ON system.notifications
    FOR UPDATE
    USING (profile_id = (NULLIF(current_setting('app.current_user_id', TRUE), '')::UUID))
    WITH CHECK (profile_id = (NULLIF(current_setting('app.current_user_id', TRUE), '')::UUID));

-- 4) SİLME (DELETE):
--    * Kullanıcı kendi bildirimlerini temizleyebilir.
CREATE POLICY notifications_delete_own ON system.notifications
    FOR DELETE
    USING (profile_id = (NULLIF(current_setting('app.current_user_id', TRUE), '')::UUID));