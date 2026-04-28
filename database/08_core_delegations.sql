DROP TABLE IF EXISTS core.user_delegations CASCADE;

CREATE TABLE core.user_delegations (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    
    -- Vekaleti veren (Asıl yetki sahibi)
    grantor_id UUID NOT NULL REFERENCES core.profiles(id) ON DELETE CASCADE,
    
    -- Vekaleti alan (Geçici yetkili)
    grantee_id UUID NOT NULL REFERENCES core.profiles(id) ON DELETE CASCADE,
    
    -- module artık 'LEAVE', 'EXPENSE' veya 'ALL' değerleriyle sınırlı.
    -- Böylece bir vekalet kaydının yalnız hangi modülü kapsadığı net olur 
    module VARCHAR(20) DEFAULT 'ALL'
        CHECK (module IN ('LEAVE', 'EXPENSE', 'ALL')),
    start_date TIMESTAMP WITH TIME ZONE NOT NULL,
    end_date TIMESTAMP WITH TIME ZONE NOT NULL,
    
    is_active BOOLEAN DEFAULT TRUE,
    reason TEXT,
    
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    
    CONSTRAINT dates_check CHECK (end_date > start_date),
    --bitiş tarihi, başlangıçtan sonra olmalı
    -- Bir kişi kendi kendine vekalet veremesin
    CONSTRAINT self_delegation_check CHECK (grantor_id <> grantee_id)
);

-- ============================================================
-- RLS (VEKALET YÖNETİMİ)
-- ============================================================

ALTER TABLE core.user_delegations ENABLE ROW LEVEL SECURITY;

-- 1) GÖRÜNTÜLEME (SELECT):
--    * Herkes kendi verdiği (grantor) veya kendisine verilen (grantee) vekaletleri görebilir.
--    * İK ve Admin tüm vekaletleri denetleyebilir.
CREATE POLICY delegations_select_policy ON core.user_delegations
    FOR SELECT
    USING (
        core.current_user_role() IN ('HR', 'ADMIN') 
        OR grantor_id = (NULLIF(current_setting('app.current_user_id', TRUE), '')::UUID)
        OR grantee_id = (NULLIF(current_setting('app.current_user_id', TRUE), '')::UUID)
    );

-- 2) VEKALET TANIMLAMA (INSERT):
--    * Kişi sadece kendisi adına (grantor_id kendisi olacak şekilde) vekalet verebilir.
--    * İK ve Admin manuel vekalet atayabilir.
CREATE POLICY delegations_insert_policy ON core.user_delegations
    FOR INSERT
    WITH CHECK (
        core.current_user_role() IN ('HR', 'ADMIN') 
        OR grantor_id = (NULLIF(current_setting('app.current_user_id', TRUE), '')::UUID)
    );

-- 3) GÜNCELLEME/İPTAL (UPDATE):
--    * Sadece vekaleti veren kişi veya İK/Admin vekaleti erkenden bitirebilir (is_active = false).
CREATE POLICY delegations_update_policy ON core.user_delegations
    FOR UPDATE
    USING (
        core.current_user_role() IN ('HR', 'ADMIN')
        OR grantor_id = (NULLIF(current_setting('app.current_user_id', TRUE), '')::UUID)
    );

-- SİLME (DELETE) POLİTİKASI
--    * Vekaleti veren kişi veya İK/Admin
--      gerektiğinde kaydı tamamen silebilmelidir.
DROP POLICY IF EXISTS delegations_delete_policy ON core.user_delegations;
CREATE POLICY delegations_delete_policy ON core.user_delegations
    FOR DELETE
    USING (
        core.current_user_role() IN ('HR', 'ADMIN')
        OR grantor_id = (NULLIF(current_setting('app.current_user_id', TRUE), '')::UUID)
    );