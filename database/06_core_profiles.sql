-- 06_core_profiles.sql

DROP TABLE IF EXISTS core.profiles CASCADE;

CREATE TABLE core.profiles (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    role_id UUID REFERENCES core.roles(id) ON DELETE SET NULL,
    location_id UUID REFERENCES core.locations(id) ON DELETE SET NULL,
    department_id UUID REFERENCES core.departments(id) ON DELETE SET NULL,
    team_id UUID REFERENCES core.teams(id) ON DELETE SET NULL,

    -- Doğrudan rapor verdiği yönetici (recursive / self-referential).
    manager_id UUID REFERENCES core.profiles(id) ON DELETE SET NULL,

    first_name VARCHAR(50) NOT NULL,
    last_name VARCHAR(50) NOT NULL,
    birth_date DATE,
    hire_date DATE, -- işe giriş tarihi
    -- Özel anlaşma ile verilen yıllık izin hakkı (Opsiyonel)
    contractual_leave_days INTEGER DEFAULT NULL,
    phone VARCHAR(20),
    title VARCHAR(100),
    is_active BOOLEAN DEFAULT TRUE,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),

    -- Kendi kendine yönetici olamaz
    CONSTRAINT no_self_manager CHECK (manager_id IS NULL OR manager_id <> id)
);

-- Hiyerarşik (recursive CTE) sorgular ve RLS policy'leri için zorunlu performans indeksi.
-- Özellikle izin onay süreçlerinde, bir çalışanın yöneticilerini hızlıca bulmak için 
CREATE INDEX IF NOT EXISTS idx_profiles_manager_id ON core.profiles(manager_id);

-- Örnek Veri Ekleme (Anlaşmalı İzinli)
DO $$
DECLARE
    v_admin_role_id   UUID;
    v_loc_ankara_id   UUID;
    v_dept_yazilim_id UUID;
BEGIN
    SELECT id INTO v_admin_role_id   FROM core.roles       WHERE role_name = 'ADMIN';
    SELECT id INTO v_loc_ankara_id   FROM core.locations   WHERE name      = 'Ankara YDA Center';
    SELECT id INTO v_dept_yazilim_id FROM core.departments WHERE name      = 'Yazılım Geliştirme Direktörlüğü';

    INSERT INTO core.profiles (
        first_name, last_name, role_id, location_id, department_id,
        title, contractual_leave_days, hire_date, manager_id
    )
    VALUES (
        'İrem', 'Utuş', v_admin_role_id, v_loc_ankara_id, v_dept_yazilim_id,
        'Yazılım Direktörü', 20, '2025-01-01', NULL
    );
END $$;

-- ============================================================
--  RLS (ROW LEVEL SECURITY) BÖLÜMÜ
-- ============================================================

-- 1. RLS AKTİVASYONU
ALTER TABLE core.profiles ENABLE ROW LEVEL SECURITY;

-- 2. POLİTİKALAR (Temizlik)
DROP POLICY IF EXISTS profiles_select_policy ON core.profiles;
DROP POLICY IF EXISTS profiles_modify_hr_admin ON core.profiles;

-- ------------------------------------------------------------
-- POLİTİKA TANIMLARI
-- ------------------------------------------------------------

-- 1) GÖRÜNTÜLEME (SELECT) KURALI:
--    * İK ve Admin: Tüm personelin profillerini görebilir.
--    * Personel: Sadece KENDİ profil satırını görebilir.
CREATE POLICY profiles_select_policy ON core.profiles
    FOR SELECT
    USING (
        core.current_user_role() IN ('HR', 'ADMIN')
        OR
        id = (NULLIF(current_setting('app.current_user_id', TRUE), '')::UUID)
    );

-- 2) YÖNETİM (INSERT, UPDATE, DELETE) KURALI:
--    * Profil oluşturma (İşe alım), Silme (İşten çıkarma) ve Güncelleme (Terfi vb.)
--    * SADECE HR ve ADMIN tarafından yapılabilir.
CREATE POLICY profiles_modify_hr_admin ON core.profiles
    FOR ALL
    TO public
    USING (core.current_user_role() IN ('HR', 'ADMIN'))
    WITH CHECK (core.current_user_role() IN ('HR', 'ADMIN'));


ALTER TABLE core.departments
    DROP CONSTRAINT IF EXISTS fk_departments_director; -- departments tablosundaki director ile ilgili eski foreign key’i kaldır
ALTER TABLE core.departments
    ADD CONSTRAINT fk_departments_director
    FOREIGN KEY (director_id) REFERENCES core.profiles(id) ON DELETE SET NULL;

ALTER TABLE core.teams
    DROP CONSTRAINT IF EXISTS fk_teams_team_lead;
ALTER TABLE core.teams
    ADD CONSTRAINT fk_teams_team_lead
    FOREIGN KEY (team_lead_id) REFERENCES core.profiles(id) ON DELETE SET NULL;