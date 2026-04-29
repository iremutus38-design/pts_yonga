-- ============================================================
-- 23_triggers_system.sql
-- ------------------------------------------------------------

CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE SCHEMA IF NOT EXISTS system;


-- ============================================================
-- 1) system.set_notification_read_at()
--    Amaç : Kullanıcı bildirimi "okundu" olarak işaretlediğinde
--           (is_read = TRUE) read_at sütununu otomatik doldurmak;
--           tekrar "okunmadı" yaptığında ise read_at'i NULL'a çekmek.
-- ============================================================

CREATE OR REPLACE FUNCTION system.set_notification_read_at()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    -- DURUM 1: FALSE -> TRUE (okunmamıştan okunduya geçiş)
    IF COALESCE(OLD.is_read, FALSE) = FALSE
       AND COALESCE(NEW.is_read, FALSE) = TRUE
    THEN
        IF NEW.read_at IS NULL THEN
            NEW.read_at := NOW();
        END IF;

    -- DURUM 2: TRUE -> FALSE (geri "okunmadı" yapılıyor)
    -- read_at'i temizle ki tutarlı kalsın.
    ELSIF COALESCE(OLD.is_read, FALSE) = TRUE
          AND COALESCE(NEW.is_read, FALSE) = FALSE
    THEN
        NEW.read_at := NULL;
    END IF;

    -- BEFORE trigger; NEW dönmek zorunlu, aksi halde UPDATE iptal olur.
    RETURN NEW;
END;
$$;

-- ============================================================
-- 2) system.prevent_audit_log_modification()
--    Amaç : audit_logs tablosundaki herhangi bir kaydın UPDATE
--           veya DELETE ile değiştirilmesini KESİNLİKLE engellemek.
-- ============================================================

CREATE OR REPLACE FUNCTION system.prevent_audit_log_modification()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    -- TG_OP: UPDATE veya DELETE olduğunda bu fonksiyon çalışır.
    -- Hangi işlem olursa olsun açık ve net mesaj veriyoruz.
    IF TG_OP = 'UPDATE' THEN
        RAISE EXCEPTION
            'system.audit_logs kaydı güncellenemez. Audit kayıtları immutable''dır. (record_id=%)',
            OLD.id
            USING ERRCODE = '42501'; -- hata mesajıdır ve anlamı: “Bu işlemi yapmak için yetkin yok”
    ELSIF TG_OP = 'DELETE' THEN
        RAISE EXCEPTION
            'system.audit_logs kaydı silinemez. Audit kayıtları immutable''dır. (record_id=%)',
            OLD.id
            USING ERRCODE = '42501';
    END IF;

    -- Buraya teorik olarak ulaşılmaz; yine de PL/pgSQL fonksiyonu
    -- her path'te bir RETURN beklediği için defansif olarak yazıyoruz.
    RETURN NULL;
END;
$$;



-- ============================================================
-- TRIGGER BAĞLAMALARI
-- ============================================================

-- ------------------------------------------------------------
-- system.notifications
-- ------------------------------------------------------------
-- Bağlanan trigger:
--   * BEFORE UPDATE OF is_read -> set_notification_read_at

-- ------------------------------------------------------------

DROP TRIGGER IF EXISTS trg_notifications_set_read_at ON system.notifications;

CREATE TRIGGER trg_notifications_set_read_at
BEFORE UPDATE OF is_read ON system.notifications
FOR EACH ROW
EXECUTE FUNCTION system.set_notification_read_at();

-- ------------------------------------------------------------
-- system.audit_logs
-- ------------------------------------------------------------
-- Bağlanan trigger'lar:
--   * BEFORE UPDATE -> prevent_audit_log_modification
--   * BEFORE DELETE -> prevent_audit_log_modification
--
-- ------------------------------------------------------------

DROP TRIGGER IF EXISTS trg_audit_logs_no_update ON system.audit_logs;

CREATE TRIGGER trg_audit_logs_no_update
BEFORE UPDATE ON system.audit_logs
FOR EACH ROW
EXECUTE FUNCTION system.prevent_audit_log_modification();


DROP TRIGGER IF EXISTS trg_audit_logs_no_delete ON system.audit_logs;

CREATE TRIGGER trg_audit_logs_no_delete
BEFORE DELETE ON system.audit_logs
FOR EACH ROW
EXECUTE FUNCTION system.prevent_audit_log_modification();
