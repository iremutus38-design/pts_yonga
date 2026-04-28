-- UUID üretimi için eklentiyi kontrol ediyoruz
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";

-- Departmanlar (Direktörlükler) Tablosu
CREATE TABLE IF NOT EXISTS core.departments (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    name VARCHAR(150) UNIQUE NOT NULL,
    director_id UUID, -- Departmandan sorumlu Direktörün UUID'si
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW() -- Güncelleme takibi için
);

-- Mevcut verileri temizleyelim
TRUNCATE core.departments CASCADE;

-- Direktörlükleri Ekleyelim
INSERT INTO core.departments (name) VALUES 
('Mikroelektronik Direktörlüğü'),
('Haberleşme Direktörlüğü'),
('Yazılım Geliştirme Direktörlüğü'),
('İş Geliştirme Direktörlüğü'),
('Operasyon Direktörlüğü')
ON CONFLICT (name) DO NOTHING;


-- ============================================================
-- 04_core_departments.sql - RLS (ROW LEVEL SECURITY) BÖLÜMÜ
-- ============================================================

-- 1. RLS AKTİVASYONU
ALTER TABLE core.departments ENABLE ROW LEVEL SECURITY;

-- 2. POLİTİKALAR (Temizlik)
DROP POLICY IF EXISTS departments_select_policy ON core.departments;
DROP POLICY IF EXISTS departments_modify_hr_admin ON core.departments;

-- ------------------------------------------------------------
-- POLİTİKA TANIMLARI
-- ------------------------------------------------------------

-- 1) GÖRÜNTÜLEME (SELECT) KURALI:
--    * İK ve Admin tüm departmanları görebilir.
--    * Diğer herkes (Direktörler dahil) sadece bağlı oldukları departmanı görebilir.
CREATE POLICY departments_select_policy ON core.departments
    FOR SELECT
    USING (
        core.current_user_role() IN ('HR', 'ADMIN') 
        OR 
        id IN (
            SELECT department_id FROM core.profiles 
            WHERE id = (NULLIF(current_setting('app.current_user_id', TRUE), '')::UUID)
            --current_setting(...): O anki oturumdaki kullanıcı ID'sini alır.
            --NULLIF(..., ''): Eğer ID boş bir metinse, hata vermemesi için onu NULL yapar.
            --::UUID: Gelen metni veritabanı kimlik formatı olan UUID'ye dönüştürür.
        )
    );
-- 2) EKLEME, GÜNCELLEME VE SİLME KURALI:
CREATE POLICY departments_modify_hr_admin ON core.departments
    FOR ALL 
    TO public
    USING (core.current_user_role() IN ('HR', 'ADMIN'))
    WITH CHECK (core.current_user_role() IN ('HR', 'ADMIN'));