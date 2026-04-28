-- 07_core_users.sql

-- Önce eskiyi temizle
DROP TABLE IF EXISTS core.users CASCADE;

CREATE TABLE core.users (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    profile_id UUID UNIQUE NOT NULL REFERENCES core.profiles(id) ON DELETE CASCADE,
    email VARCHAR(150) UNIQUE NOT NULL,
    password_hash TEXT, -- Şifreler hashlenmiş olarak tutulacak
    verification_token TEXT,
    last_login TIMESTAMP WITH TIME ZONE,
    is_verified BOOLEAN DEFAULT FALSE, -- Hesabın onaylanıp onaylanmadığı
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

-- Dinamik Veri Ekleme Bloğu
DO $$
DECLARE 
    v_irem_profile_id UUID;
    v_ahmet_profile_id UUID;
BEGIN
    -- 1. ADIM: Profiller tablosundan İrem ve Ahmet'in UUID'lerini çekelim
    SELECT id INTO v_irem_profile_id FROM core.profiles WHERE first_name = 'İrem' AND last_name = 'Utuş';
    SELECT id INTO v_ahmet_profile_id FROM core.profiles WHERE first_name = 'Ahmet' AND last_name = 'Yılmaz';

    -- 2. ADIM: Bu ID'ler ile kullanıcı hesaplarını oluşturalım
    
    -- İrem'in Kullanıcı Hesabı
    IF v_irem_profile_id IS NOT NULL THEN
        INSERT INTO core.users (profile_id, email, verification_token, is_verified)
        VALUES (v_irem_profile_id, 'irem.utus@yongatech.com', 'token_irem_xyz', TRUE);
    END IF;

    -- Ahmet'in Kullanıcı Hesabı
    IF v_ahmet_profile_id IS NOT NULL THEN
        INSERT INTO core.users (profile_id, email, verification_token, is_verified)
        VALUES (v_ahmet_profile_id, 'ahmet.yilmaz@yongatech.com', 'token_ahmet_abc', TRUE);
    END IF;

    RAISE NOTICE 'Kullanıcı giriş bilgileri başarıyla oluşturuldu.';
END $$;

-- ============================================================
-- RLS BÖLÜMÜ
-- ============================================================

-- 1. RLS AKTİVASYONU
ALTER TABLE core.users ENABLE ROW LEVEL SECURITY;

-- 2. POLİTİKALAR (Temizlik)
DROP POLICY IF EXISTS users_select_policy ON core.users;
DROP POLICY IF EXISTS users_insert_hr_admin ON core.users;
DROP POLICY IF EXISTS users_update_self_or_hr ON core.users;
DROP POLICY IF EXISTS users_delete_hr_admin ON core.users;

-- ------------------------------------------------------------
-- POLİTİKA TANIMLARI
-- ------------------------------------------------------------

-- 1) GÖRÜNTÜLEME (SELECT): 
--    İK/Admin her şeyi, kullanıcı sadece kendi login bilgilerini görür.
CREATE POLICY users_select_policy ON core.users
    FOR SELECT
    USING (
        core.current_user_role() IN ('HR', 'ADMIN') 
        OR 
        profile_id = (NULLIF(current_setting('app.current_user_id', TRUE), '')::UUID)
    );

-- 2) EKLEME (INSERT): 
--    Sadece İK ve Admin yeni kullanıcı kaydı (email tanımlama) yapabilir.
CREATE POLICY users_insert_hr_admin ON core.users
    FOR INSERT
    WITH CHECK (core.current_user_role() IN ('HR', 'ADMIN'));

-- 3) GÜNCELLEME (UPDATE): 
--    * İK/Admin genel bilgileri güncelleyebilir.
--    * Kişi sadece KENDİ satırındaki bilgileri (Şifre, token vb.) güncelleyebilir.
CREATE POLICY users_update_self_or_hr ON core.users
    FOR UPDATE
    USING (
        core.current_user_role() IN ('HR', 'ADMIN') 
        OR 
        profile_id = (NULLIF(current_setting('app.current_user_id', TRUE), '')::UUID)
    );

-- 4) SİLME (DELETE): 
--    Sadece İK ve Admin hesap silebilir. Kişi kendi hesabını SİLEMEZ.
CREATE POLICY users_delete_hr_admin ON core.users
    FOR DELETE
    USING (core.current_user_role() IN ('HR', 'ADMIN'));