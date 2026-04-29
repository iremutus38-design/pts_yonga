-- 14_finance_expense_policies.sql

-- 1. UUID ve Şema Hazırlığı
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE SCHEMA IF NOT EXISTS finance;

-- 2. Periyot Tiplerini ENUM olarak tanımlıyoruz
-- Bu sayede backend'deki Enum yapınla veritabanı birebir eşleşir.
DO $$ 
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'expense_period') THEN
        CREATE TYPE finance.expense_period AS ENUM ('DAILY', 'WEEKLY', 'MONTHLY', 'YEARLY', 'PER_EXPENSE');
    END IF;
END $$;

DROP TABLE IF EXISTS finance.expense_policies CASCADE;

-- 3. Tablo Oluşturma
CREATE TABLE finance.expense_policies (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    
    -- Backend'de kontrol edeceğin anahtar (Örn: 'MEAL_POLICY')
    policy_key VARCHAR(50) UNIQUE NOT NULL, 
    
    category_name VARCHAR(100) NOT NULL,
    max_amount DECIMAL(12,2) NOT NULL,
    currency VARCHAR(3) DEFAULT 'TRY', 
    
    period finance.expense_period NOT NULL DEFAULT 'DAILY', 
    
    is_hard_limit BOOLEAN DEFAULT FALSE, 
    description TEXT,
    is_active BOOLEAN DEFAULT TRUE,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

-- 4. Örnek Veri Ekleme
INSERT INTO finance.expense_policies (policy_key, category_name, max_amount, currency, period, is_hard_limit) 
VALUES 
('DAILY_MEAL', 'Günlük Yemek Limiti', 500.00, 'TRY', 'DAILY', TRUE),
('MONTHLY_INTERNET', 'Aylık İnternet Desteği', 1000.00, 'TRY', 'MONTHLY', TRUE),
('HOTEL_ABROAD', 'Yurt Dışı Konaklama', 200.00, 'EUR', 'PER_EXPENSE', FALSE);

-- ============================================================
-- finance.expense_policies - RLS (ROW LEVEL SECURITY) BÖLÜMÜ
-- ============================================================

-- 1. RLS AKTİVASYONU
ALTER TABLE finance.expense_policies ENABLE ROW LEVEL SECURITY;

-- 2. POLİTİKALAR (Temizlik)
DROP POLICY IF EXISTS expense_policies_select_public ON finance.expense_policies;
DROP POLICY IF EXISTS expense_policies_modify_hr_admin ON finance.expense_policies;

-- ------------------------------------------------------------
-- POLİTİKA TANIMLARI
-- ------------------------------------------------------------

-- 1) GÖRÜNTÜLEME (SELECT) KURALI:
--    * Şirketteki tüm çalışanlar güncel harcama limitlerini görebilmelidir.
--    * Bu, personelin harcama yapmadan önce limitleri bilmesini sağlar.
CREATE POLICY expense_policies_select_public ON finance.expense_policies
    FOR SELECT
    USING (TRUE);

-- 2) YÖNETİM (INSERT, UPDATE, DELETE) KURALI:
--    * Yeni limit tanımlama, mevcut tutarları (max_amount) güncelleme 
--    * veya bir politikayı pasife çekme (is_active) SADECE HR ve ADMIN yetkisindedir.
CREATE POLICY expense_policies_modify_hr_admin ON finance.expense_policies
    FOR ALL 
    TO public
    USING (core.current_user_role() IN ('HR', 'ADMIN'))
    WITH CHECK (core.current_user_role() IN ('HR', 'ADMIN'));