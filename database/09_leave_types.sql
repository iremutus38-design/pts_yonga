-- 09_leave_types.sql

CREATE EXTENSION IF NOT EXISTS "uuid-ossp";

CREATE SCHEMA IF NOT EXISTS leave;

DROP TABLE IF EXISTS leave.leave_types CASCADE;

CREATE TABLE leave.leave_types (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    
    -- Örn: 'ANNUAL', 'OVERTIME_COMP', 'SICK'
    type_key VARCHAR(50) UNIQUE NOT NULL, 
    
    name VARCHAR(100) NOT NULL, 
    description TEXT,
    
    base_days INTEGER DEFAULT 0, 
    
    is_tenure_based BOOLEAN DEFAULT FALSE, 
    
    is_active BOOLEAN DEFAULT TRUE,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

-- Mantığı oturtman için Backend Dostu Insert İşlemleri
INSERT INTO leave.leave_types (type_key, name, description, base_days, is_tenure_based) VALUES 
('ANNUAL', 'Yıllık İzin', 'Yasal yıllık izin hakkı', 14, TRUE),
('CASUAL', 'Mazeret İzni', 'Şirket tarafından sağlanan kısa süreli izinler', 5, FALSE),
('SICK', 'Hastalık / Rapor', 'Doktor raporu gerektiren sağlık izinleri', NULL, FALSE),
('UNPAID', 'Ücretsiz İzin', 'Maaş kesintili uzun süreli izinler', NULL, FALSE),
('OVERTIME_COMP', 'Mesai Karşılığı İzin', 'Fazla mesailerin izne dönüştürülmüş hali', 0, FALSE);


-- ============================================================
-- 09_leave_types.sql - RLS (ROW LEVEL SECURITY) BÖLÜMÜ
-- ============================================================

-- 1. RLS AKTİVASYONU
ALTER TABLE leave.leave_types ENABLE ROW LEVEL SECURITY;

-- 2. POLİTİKALAR (Temizlik)
DROP POLICY IF EXISTS leave_types_select_public ON leave.leave_types;
DROP POLICY IF EXISTS leave_types_modify_hr_admin ON leave.leave_types;

-- ------------------------------------------------------------
-- POLİTİKA TANIMLARI
-- ------------------------------------------------------------

-- 1) GÖRÜNTÜLEME (SELECT) KURALI:
--    * Şirketteki tüm çalışanlar hangi izin türleri olduğunu görebilmelidir.
--    * Bu yüzden 'USING (TRUE)' diyerek herkese okuma yetkisi veriyoruz.
CREATE POLICY leave_types_select_public ON leave.leave_types
    FOR SELECT
    USING (TRUE);

-- 2) YÖNETİM (INSERT, UPDATE, DELETE) KURALI:
--    * İzin türlerini tanımlamak, temel gün sayılarını (base_days) değiştirmek
--    * veya yeni izin türü eklemek SADECE HR ve ADMIN yetkisindedir.
CREATE POLICY leave_types_modify_hr_admin ON leave.leave_types
    FOR ALL 
    TO public
    USING (core.current_user_role() IN ('HR', 'ADMIN'))
    WITH CHECK (core.current_user_role() IN ('HR', 'ADMIN'));