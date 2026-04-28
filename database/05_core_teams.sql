-- UUID eklentisinin varlığından emin olalım
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";

-- Takımlar Tablosu
CREATE TABLE IF NOT EXISTS core.teams (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    name VARCHAR(150) NOT NULL,
    department_id UUID NOT NULL REFERENCES core.departments(id) ON DELETE CASCADE,
    team_lead_id UUID, 
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    -- Bir direktörlük altında aynı isimde iki takım olmaması için
    UNIQUE (name, department_id)
);

-- Mevcut verileri temizleyelim
TRUNCATE core.teams CASCADE;

DO $$ 
DECLARE 
    -- Departman UUID'lerini saklayacağımız değişkenler
    v_dept_mikro_id UUID;
    v_dept_haberlesme_id UUID;
    v_dept_yazilim_id UUID;
    v_dept_is_gel_id UUID;
    v_dept_operasyon_id UUID;
BEGIN
    -- 1. ADIM: Takımları temizle (Departmanlara dokunmuyoruz!)
    TRUNCATE core.teams CASCADE;
    
    SELECT id INTO v_dept_mikro_id FROM core.departments WHERE name = 'Mikroelektronik Direktörlüğü';
    SELECT id INTO v_dept_haberlesme_id FROM core.departments WHERE name = 'Haberleşme Direktörlüğü';
    SELECT id INTO v_dept_yazilim_id FROM core.departments WHERE name = 'Yazılım Geliştirme Direktörlüğü';
    SELECT id INTO v_dept_is_gel_id FROM core.departments WHERE name = 'İş Geliştirme Direktörlüğü';
    SELECT id INTO v_dept_operasyon_id FROM core.departments WHERE name = 'Operasyon Direktörlüğü';
    
    INSERT INTO core.teams (name, department_id) VALUES 
    ('Sayısal Tasarım Takımı', v_dept_mikro_id),
    ('Doğrulama Takımı', v_dept_mikro_id),
    ('Haberleşme Takımı', v_dept_haberlesme_id),
    ('Gömülü Yazılım Takımı', v_dept_yazilim_id),
    ('Yapay Zeka Takımı', v_dept_yazilim_id),
    ('Yazılım Takımı', v_dept_yazilim_id),
    ('Pazarlama Takımı', v_dept_is_gel_id),
    ('Saha Operasyon Takımı', v_dept_operasyon_id);

    RAISE NOTICE 'Takımlar mevcut departman UUID''leri ile başarıyla eşleştirildi.';
END $$;


-- ============================================================
--  RLS (ROW LEVEL SECURITY) BÖLÜMÜ
-- ============================================================

-- 1. RLS AKTİVASYONU
ALTER TABLE core.teams ENABLE ROW LEVEL SECURITY;

-- 2. POLİTİKALAR (Temizlik)
DROP POLICY IF EXISTS teams_select_policy ON core.teams;
DROP POLICY IF EXISTS teams_modify_hr_admin ON core.teams;

-- ------------------------------------------------------------
-- POLİTİKA TANIMLARI
-- ------------------------------------------------------------

-- 1) GÖRÜNTÜLEME (SELECT) KURALI:
CREATE POLICY teams_select_policy ON core.teams
    FOR SELECT
    USING (
        -- Kural A: Üst Yetkililer (HR/ADMIN)
        core.current_user_role() IN ('HR', 'ADMIN') 
        OR 
        -- Kural B: Direktörler (Departmanına bağlı her şeyi görür)
        department_id IN ( --Dış sorgudaki kaydın department_id değeri, İç sorgudan dönen değerler içinde mi?
            SELECT department_id FROM core.profiles 
            WHERE id = (NULLIF(current_setting('app.current_user_id', TRUE), '')::UUID)
            --Şu an login olan kullanıcının ID’si ile eşleşen satırı getir
            AND core.current_user_role() = 'DIRECTOR'
        )
        OR
        -- Kural C: Takım Liderleri ve Çalışanlar
        -- (Kendi profilindeki team_id ile takımın id'si eşleşmeli)
        id IN (
            SELECT team_id FROM core.profiles 
            WHERE id = (NULLIF(current_setting('app.current_user_id', TRUE), '')::UUID)
        )
    );

-- 2) YÖNETİM (INSERT, UPDATE, DELETE) KURALI:
--    * Sadece HR veya ADMIN takım oluşturabilir, silebilir veya ismini güncelleyebilir.
CREATE POLICY teams_modify_hr_admin ON core.teams
    FOR ALL 
    TO public
    USING (core.current_user_role() IN ('HR', 'ADMIN'))
    WITH CHECK (core.current_user_role() IN ('HR', 'ADMIN'));