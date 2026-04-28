-- UUID üretimi için gerekli eklentiyi aktif ediyoruz (PostgreSQL)
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";

-- Tabloyu yeniden oluşturuyoruz
CREATE TABLE IF NOT EXISTS core.roles (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(), -- SERIAL yerine UUID
    role_name VARCHAR(30) UNIQUE NOT NULL,
    description TEXT,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW() -- Güncelleme takibi için

);

-- Eski verileri temizleyelim
TRUNCATE core.roles CASCADE;

-- Yeni verileri ekleyelim (CEO ve CTO dahil)
INSERT INTO core.roles (role_name, description) VALUES
('ADMIN', 'Sistemin tüm ayarlarını ve kullanıcılarını yöneten üst yetkili.'),
('CEO', 'Chief Executive Officer; en üst düzey icra yetkilisi.'),
('CTO', 'Chief Technology Officer; teknoloji ve strateji yönetiminden sorumlu yetkili.'),
('HR', 'İnsan Kaynakları; personel ekleme ve genel raporlama yetkilisi.'),
('DIRECTOR', 'Üst düzey yönetici; yüksek tutarlı harcama ve kritik izin onay yetkilisi.'),
('BRANCH_MANAGER', 'Şube Müdürü; belirli bir lokasyondaki tüm personelden ve operasyondan sorumlu yönetici.'),
('TEAM_LEAD', 'Ekip lideri; kendi ekibindeki personelin taleplerini onaylar.'),
('EMPLOYEE', 'Standart personel; kendi izin ve masraf taleplerini yönetir.');


-- ============================================================
--  RLS (ROW LEVEL SECURITY) BÖLÜMÜ
-- ============================================================
CREATE OR REPLACE FUNCTION core.current_user_role()
RETURNS TEXT
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = core, pg_temp
AS $func$
DECLARE
    v_uid       TEXT;
    v_role_name TEXT;
BEGIN
    -- Session değişkeni okunur. İkinci parametre TRUE → değişken
    -- tanımlı değilse hata fırlatma, NULL dön.
    v_uid := current_setting('app.current_user_id', TRUE);

    IF v_uid IS NULL OR v_uid = '' THEN
        RETURN NULL; -- Oturum bilgisi yok → anonim kullanıcı
    END IF;

    SELECT r.role_name
      INTO v_role_name
      FROM core.profiles p
      JOIN core.roles    r ON r.id = p.role_id
     WHERE p.id = v_uid::UUID
     LIMIT 1;

    RETURN v_role_name;
END;
$func$;


-- ------------------------------------------------------------
-- RLS AKTİVASYONU
-- ------------------------------------------------------------

ALTER TABLE core.roles ENABLE ROW LEVEL SECURITY;


-- ------------------------------------------------------------
-- POLİTİKALAR (idempotent — varsa silip yeniden kur)
-- ------------------------------------------------------------
DROP POLICY IF EXISTS roles_select_all ON core.roles;
DROP POLICY IF EXISTS roles_insert_hr_admin ON core.roles;
DROP POLICY IF EXISTS roles_update_hr_admin ON core.roles;
DROP POLICY IF EXISTS roles_delete_hr_admin ON core.roles;


-- 1) HERKES OKUYABİLİR
--    USING (TRUE) → koşul her zaman geçerli, kimse satır filtresine takılmaz.
CREATE POLICY roles_select_all ON core.roles
    FOR SELECT
    USING (TRUE);


-- 2) SADECE HR EKLEYEBİLİR
--    WITH CHECK → INSERT'lerde yeni satırın izinli olup olmadığını denetler.
CREATE POLICY roles_insert_hr_admin ON core.roles
    FOR INSERT
    WITH CHECK (core.current_user_role() IN ('HR', 'ADMIN'));


-- 3) SADECE HR GÜNCELLEYEBİLİR
--    USING → hangi satırların güncellenebileceğini söyler (eski satıra bakar).
--    WITH CHECK → güncelleme sonrası satırın hâlâ politikaya uyduğunu doğrular.
CREATE POLICY roles_update_hr_admin ON core.roles
    FOR UPDATE
    USING      (core.current_user_role() IN ('HR', 'ADMIN'))
    WITH CHECK (core.current_user_role() IN ('HR', 'ADMIN'));


-- 4) SADECE HR SİLEBİLİR
CREATE POLICY roles_delete_hr_admin ON core.roles
    FOR DELETE
    USING (core.current_user_role() IN ('HR', 'ADMIN'));