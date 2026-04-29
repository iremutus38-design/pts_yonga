-- ============================================================
-- 19_helpers_and_triggers.sql
-- ------------------------------------------------------------

CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE SCHEMA IF NOT EXISTS core;
CREATE SCHEMA IF NOT EXISTS system;


-- ============================================================
-- 1) core.set_updated_at()
--    Amaç : Her UPDATE işleminde NEW.updated_at sütununu otomatik
--           olarak NOW() ile güncellemek.
-- ============================================================

CREATE OR REPLACE FUNCTION core.set_updated_at()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at := NOW();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- ============================================================
-- 2) core.prevent_manager_cycle()
--    Amaç : core.profiles.manager_id alanı üzerinde A -> B -> C -> A
--           gibi döngüleri ENGELLEMEK.
-- ============================================================

CREATE OR REPLACE FUNCTION core.prevent_manager_cycle()
RETURNS TRIGGER AS $$
DECLARE
    v_current UUID;
    v_depth   INT := 0;
BEGIN
    -- manager_id boşsa zincir yok demektir, kontrol gerekmez.
    IF NEW.manager_id IS NULL THEN
        RETURN NEW;
    END IF;

    -- Bir kişi kendini yönetici yapamaz.
    IF NEW.manager_id = NEW.id THEN
        RAISE EXCEPTION 'Bir kullanıcı kendi yöneticisi olamaz (id=%).', NEW.id;
    END IF;

    -- Yeni manager_id'den yukarı doğru zinciri takip ediyoruz.
    v_current := NEW.manager_id;

    WHILE v_current IS NOT NULL LOOP
        -- Eğer zincir bir noktada NEW.id'ye dönüyorsa döngü vardır.
        IF v_current = NEW.id THEN
            RAISE EXCEPTION
                'manager_id zinciri döngü oluşturuyor (id=%).', NEW.id;
        END IF;

        -- Aşırı derin zincirleri (yanlışlıkla sonsuz döngü) durdur.
        v_depth := v_depth + 1;
        IF v_depth > 50 THEN
            RAISE EXCEPTION
                'manager_id zinciri 50 seviyeyi aştı, olası veri hatası.';
        END IF;

        -- Bir üst yöneticiye geç.
        SELECT manager_id INTO v_current
        FROM core.profiles
        WHERE id = v_current;
    END LOOP;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- ============================================================
-- 3) core.calculate_leave_days
--    Amaç : İki tarih arasında HAFTA SONLARI ve RESMİ TATİLLERİ
--           düşerek net izin gününü hesaplamak.
-- ============================================================

CREATE OR REPLACE FUNCTION core.calculate_leave_days(
        p_start      DATE,
        p_end        DATE,
        p_profile_id UUID DEFAULT NULL
)
RETURNS DECIMAL(4,1)
LANGUAGE plpgsql
STABLE -- Veriyi değiştirmez; aynı sorgu içinde sonucu cache'lenebilir.
AS $$
DECLARE
    v_total INT := 0;
    v_day   DATE := p_start;
BEGIN
    -- Geçersiz aralık: bitiş, başlangıçtan önce ise 0 döner.
    IF p_end < p_start THEN
        RETURN 0;
    END IF;

    -- Başlangıçtan bitişe kadar gün gün ilerle.
    WHILE v_day <= p_end LOOP
        IF EXTRACT(ISODOW FROM v_day) NOT IN (6, 7)
           AND NOT EXISTS (
               SELECT 1 FROM core.company_holidays -- select 1 ile varsa var de yoksa yok anlamına geliyor.
               WHERE holiday_date = v_day
           )
        THEN
            v_total := v_total + 1;
        END IF;

        v_day := v_day + 1;
    END LOOP;

    -- DECIMAL(4,1) döndürüyoruz; ileride yarım gün desteği için
    RETURN v_total::DECIMAL(4,1);
END;
$$;

-- ============================================================
-- 4) system.audit_trigger_func()
--    Amaç : INSERT / UPDATE / DELETE işlemlerini system.audit_logs
--           tablosuna JSONB olarak yazmak.
-- ============================================================

CREATE OR REPLACE FUNCTION system.audit_trigger_func()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER --
AS $$
DECLARE
    v_actor      UUID;
    v_action     system.audit_action;
    v_old        JSONB;
    v_new        JSONB;
    v_record_id  UUID;
    v_ip         TEXT;
    v_user_agent TEXT;
BEGIN
    -- Oturum değişkeninden işlemi yapan kullanıcıyı oku; yoksa NULL bırak (sistem işlemi olabilir).
    v_actor      := NULLIF(current_setting('app.current_user_id', TRUE), '')::UUID;
    v_ip         := NULLIF(current_setting('app.client_ip',       TRUE), '');
    v_user_agent := NULLIF(current_setting('app.user_agent',      TRUE), '');

    -- TG_OP = “Trigger Operation” Bu trigger şu an hangi işlem için çalışıyor? (INSERT / UPDATE / DELETE)
    IF TG_OP = 'INSERT' THEN
        v_action    := 'INSERT';
        v_old       := NULL;
        v_new       := to_jsonb(NEW);
        v_record_id := NEW.id;
    ELSIF TG_OP = 'UPDATE' THEN
        v_action    := 'UPDATE';
        v_old       := to_jsonb(OLD);
        v_new       := to_jsonb(NEW);
        v_record_id := NEW.id;
    ELSIF TG_OP = 'DELETE' THEN
        v_action    := 'DELETE';
        v_old       := to_jsonb(OLD);
        v_new       := NULL;
        v_record_id := OLD.id;
    END IF;

    INSERT INTO system.audit_logs (
        profile_id, action_type, table_name, record_id, old_data, new_data, ip_address, user_agent
    ) VALUES (
        v_actor,
        v_action,
        TG_TABLE_SCHEMA || '.' || TG_TABLE_NAME,
        v_record_id,
        v_old,
        v_new,
        v_ip,
        v_user_agent
    );

    RETURN COALESCE(NEW, OLD); -- Verilen değerler arasında ilk NULL olmayan değeri döndürür
END;
$$;

-- ============================================================
-- 5) system.notify_user
--    Amaç : Trigger içinden veya backend'den, bir kullanıcıya
--           bildirim eklemek.
-- ============================================================

CREATE OR REPLACE FUNCTION system.notify_user(
    p_profile_id UUID,
    p_title      TEXT,
    p_message    TEXT,
    p_type       system.notification_type DEFAULT 'INFO',
    p_target_url TEXT DEFAULT NULL
)
RETURNS UUID --  Yeni eklenen bildirimin id'sini döndürür;
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    v_id UUID;
BEGIN
    -- Profil id boşsa bildirim oluşturma; sessizce NULL dön.
    IF p_profile_id IS NULL THEN
        RETURN NULL;
    END IF;

    INSERT INTO system.notifications (
        profile_id, title, message, type, target_url
    ) VALUES (
        p_profile_id, p_title, p_message, p_type, p_target_url
    )
    RETURNING id INTO v_id;

    RETURN v_id;
END;
$$;

-- ============================================================
-- 6) core.team_lead_of
--    Amaç : Verilen profilin BAĞLI OLDUĞU TAKIM LİDERİ id'sini
--           döndürmek.
-- ============================================================

CREATE OR REPLACE FUNCTION core.team_lead_of(p_profile_id UUID)
RETURNS UUID
LANGUAGE plpgsql
STABLE --     -> Veriyi değiştirmez; aynı sorgu içinde sonucu cache'lenebilir.
AS $$
DECLARE
    v_team_id      UUID;
    v_team_lead_id UUID;
BEGIN
    -- Profil yoksa NULL dön.
    IF p_profile_id IS NULL THEN
        RETURN NULL;
    END IF;

    -- Önce profilin team_id'sini al.
    SELECT team_id INTO v_team_id
      FROM core.profiles
     WHERE id = p_profile_id;

    -- Hiç takıma atanmamışsa TL yoktur.
    IF v_team_id IS NULL THEN
        RETURN NULL;
    END IF;

    -- O takımın lideri kim?
    SELECT team_lead_id INTO v_team_lead_id
      FROM core.teams
     WHERE id = v_team_id;

    -- Kişi kendi takımının lideri ise NULL döndürmek mantıklı:
    -- TL kendi izin talebi için kendisine bildirim almasın.
    IF v_team_lead_id = p_profile_id THEN
        RETURN NULL;
    END IF;

    RETURN v_team_lead_id;
END;
$$;

-- ============================================================
-- 7) core.director_of(p_profile_id)
--    Amaç : Verilen profilin BAĞLI OLDUĞU DEPARTMAN DİREKTÖRÜ
--           id'sini döndürmek.
-- ============================================================

CREATE OR REPLACE FUNCTION core.director_of(p_profile_id UUID)
RETURNS UUID
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_department_id UUID;
    v_director_id   UUID;
BEGIN
    -- Profil yoksa NULL dön.
    IF p_profile_id IS NULL THEN
        RETURN NULL;
    END IF;

    -- Önce profilin department_id'sini al.
    SELECT department_id INTO v_department_id
      FROM core.profiles
     WHERE id = p_profile_id;

    -- Departmana atanmamışsa direktör yoktur.
    IF v_department_id IS NULL THEN
        RETURN NULL;
    END IF;

    -- O departmanın direktörü kim?
    SELECT director_id INTO v_director_id
      FROM core.departments
     WHERE id = v_department_id;

    -- Kişi kendi departmanının direktörü ise NULL dön:
    -- Direktör, kendi izin talebi için kendisine bildirim almasın.
    IF v_director_id = p_profile_id THEN
        RETURN NULL;
    END IF;

    RETURN v_director_id;
END;
$$;

-- ============================================================
-- 8) system.notify_role(p_role_name, p_title, p_message, p_type, p_target_url)
--    Amaç : Verilen ROLE sahip TÜM kullanıcılara aynı bildirimi
--           toplu olarak göndermek.
--    Mantık: core.profiles -> core.users -> users.role_id -> roles.role_name
--           (mevcut şemada role profil yerine kullanıcı seviyesinde
--           tutulduğu için users tablosundan eşleştiriyoruz)
--           Sonra her bir profil için system.notify_user() çağırılır.
--    Kullanım: finance triggerlarında "tüm HR kullanıcılarına haber ver",
--           leave/duyuru sistemlerinde "tüm ADMIN'lere bildirim" gibi
--           senaryolar için.
-- ============================================================

CREATE OR REPLACE FUNCTION system.notify_role(
    p_role_name  TEXT,
    p_title      TEXT,
    p_message    TEXT,
    p_type       system.notification_type DEFAULT 'INFO',
    p_target_url TEXT DEFAULT NULL
)
RETURNS INT
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    v_count   INT := 0;
    v_profile RECORD;
BEGIN
    -- Rol bilgisi DOĞRUDAN core.profiles.role_id üzerinden okunuyor
    -- (current_user_role() fonksiyonu da aynı yolu kullanıyor; tutarlı kaldı).
    -- NOT: is_active filtresi istenirse "AND p.is_active = TRUE" eklenir.
    FOR v_profile IN
        SELECT p.id AS profile_id
          FROM core.profiles p
          JOIN core.roles    r ON r.id = p.role_id
         WHERE r.role_name = p_role_name
    LOOP
        PERFORM system.notify_user(
            v_profile.profile_id,
            p_title,
            p_message,
            p_type,
            p_target_url
        );
        v_count := v_count + 1;
    END LOOP;

    RETURN v_count;
END;
$$;

-- Satır satır açıklama:
-- p_role_name TEXT
--     -> Hedef rolün adı: 'HR', 'ADMIN', 'CEO' gibi.
-- RETURNS INT
--     -> Kaç kullanıcıya bildirim düşürüldüğünü döner; 0 olabilir.
-- SECURITY DEFINER
--     -> Trigger içinden RLS'e takılmadan profil/users okusun diye.
-- FOR v_profile IN SELECT ... LOOP
--     -> Hedef role sahip TÜM aktif kullanıcıların profil id'lerini
--        tek seferde çek; her biri için notify_user çağır.
-- system.notify_user(...)
--     -> Tek kişiye bildirim eklemenin TEKİL fonksiyonunu yeniden
--        kullanıyoruz (DRY); o fonksiyon NULL guard içeriyor.
-- v_count
--     -> Çağıran trigger'a "kaç kişiye gitti" bilgisini döner.
--        Loglama veya test asistı için faydalı.