-- ============================================================
-- 22_triggers_finance.sql
-- ------------------------------------------------------------
-- ============================================================
-- A) FİNANSA ÖZEL TRIGGER FONKSİYONLARI
-- ============================================================


-- ------------------------------------------------------------
-- A.1) finance.preprocess_expense_request()
-- ------------------------------------------------------------
-- BEFORE INSERT/UPDATE'te çalışır. Üç ana iş:
--   1) Limit kontrolü:  policy_id varsa policy.max_amount ile
--      NEW.amount karşılaştırılır; aşılıyorsa is_over_limit = TRUE,
--      aşılmıyorsa FALSE.
--   2) Parent sanity:   parent_request_id verilmişse parent kaydının
--      ADVANCE türü VE aynı kişi VE APPROVED durumda olduğu kontrol
--      edilir. Aksi halde hata fırlatılır.
--   3) approved_at:     PENDING -> APPROVED geçişinde NOW() ile
--      doldurulur (sadece UPDATE; INSERT'te HR direkt APPROVED
--      eklerse de doldurulur).
-- ------------------------------------------------------------

CREATE OR REPLACE FUNCTION finance.preprocess_expense_request()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    v_max_amount       DECIMAL(12,2);
    v_parent_status    core.request_status;
    v_parent_type      core.expense_type;
    v_parent_profile   UUID;
BEGIN
    -- ============================================================
    -- 1) LİMİT KONTROLÜ
    -- ------------------------------------------------------------
    -- policy_id verilmişse ilgili politikanın max_amount'u çekilir

    IF NEW.policy_id IS NOT NULL THEN
        SELECT max_amount INTO v_max_amount
          FROM finance.expense_policies
         WHERE id = NEW.policy_id
           AND is_active = TRUE;

        IF v_max_amount IS NOT NULL AND NEW.amount > v_max_amount THEN
            NEW.is_over_limit := TRUE;
        ELSE
            NEW.is_over_limit := FALSE;
        END IF;
    ELSE
        NEW.is_over_limit := FALSE;
    END IF;

    -- ============================================================
    -- 2) PARENT (EK SATIR) SANITY CHECK
    -- ------------------------------------------------------------
    -- parent_request_id verilmişse:
    --   - Ana kayıt VAR olmalı

    IF NEW.parent_request_id IS NOT NULL THEN
        SELECT request_type, status, profile_id
          INTO v_parent_type, v_parent_status, v_parent_profile
          FROM finance.expense_requests
         WHERE id = NEW.parent_request_id;

        IF v_parent_type IS NULL THEN
            RAISE EXCEPTION
                'parent_request_id (%) bulunamadı.', NEW.parent_request_id;
        END IF;

        IF v_parent_type <> 'ADVANCE' THEN
            RAISE EXCEPTION
                'Ek harcama satırı yalnızca ADVANCE türü talebe bağlanabilir (parent türü: %).',
                v_parent_type;
        END IF;

        IF v_parent_profile <> NEW.profile_id THEN
            RAISE EXCEPTION
                'Ek satırın profil_id''si ana avansın sahibiyle eşleşmeli.';
        END IF;

        IF v_parent_status <> 'APPROVED' THEN
            RAISE EXCEPTION
                'Ek satır yalnızca APPROVED durumdaki avansa eklenebilir (parent durumu: %).',
                v_parent_status;
        END IF;
    END IF;

    -- ============================================================
    -- 3) approved_at OTOMATİK DOLDURMA
    -- ------------------------------------------------------------
    -- Hem INSERT hem UPDATE'te status APPROVED ise ve approved_at
    -- henüz boşsa NOW() ile doldur.
    -- ============================================================
    IF NEW.status = 'APPROVED' AND NEW.approved_at IS NULL THEN
        NEW.approved_at := NOW();
    END IF;
    RETURN NEW;
END;
$$;


-- ------------------------------------------------------------
-- A.2) finance.notify_pending_to_approvers()
-- ------------------------------------------------------------
-- AFTER INSERT'te tetiklenir.
-- Yeni masraf/avans talebi oluştuğunda HR ve ADMIN rolündeki
-- TÜM kullanıcılara INFO bildirimi gönderir.
--
-- Talep INSERT anında APPROVED olarak gelmişse (ör. HR direkt
-- onaylı eklediyse) onay duyurusu göndermeye gerek yok; erken
-- çıkar.
-- ------------------------------------------------------------

CREATE OR REPLACE FUNCTION finance.notify_pending_to_approvers()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    v_employee_name TEXT;
    v_type_label    TEXT;
    v_msg           TEXT;
BEGIN
    IF NEW.status <> 'PENDING' THEN
        RETURN NEW;
    END IF;

    SELECT first_name || ' ' || last_name
      INTO v_employee_name
      FROM core.profiles
     WHERE id = NEW.profile_id;

    -- Talep türünü Türkçe etikete çevir
    v_type_label := CASE NEW.request_type
        WHEN 'ADVANCE'         THEN 'avans'
        WHEN 'ACTUAL_EXPENSE'  THEN 'masraf'
        ELSE NEW.request_type::TEXT
    END;

    v_msg := v_employee_name || ' yeni bir ' || v_type_label
             || ' talebi oluşturdu. Tutar: '
             || NEW.amount::TEXT || ' ' || COALESCE(NEW.currency, 'TRY')
             || '. Onayınız bekleniyor.';

    -- HR ve ADMIN rollerindeki TÜM kullanıcılara aynı bildirim.
    -- system.notify_role tek tek profile gezip notify_user çağırıyor.
    PERFORM system.notify_role(
        'HR',
        'Masraf Onayı Bekliyor',
        v_msg,
        'INFO'::system.notification_type,
        '/masraf/' || NEW.id::TEXT
    );
    PERFORM system.notify_role(
        'ADMIN',
        'Masraf Onayı Bekliyor',
        v_msg,
        'INFO'::system.notification_type,
        '/masraf/' || NEW.id::TEXT
    );

    RETURN NEW;
END;
$$;


-- ------------------------------------------------------------
-- A.3) finance.notify_on_status_change()
-- ------------------------------------------------------------
-- Hem INSERT (limit aşımı uyarısı) hem UPDATE (status değişimi
-- ve ödeme bildirimi) için bildirim üretir.


CREATE OR REPLACE FUNCTION finance.notify_on_status_change()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    v_employee_name TEXT;
    v_msg           TEXT;
    v_deadline_text TEXT;
BEGIN
    SELECT first_name || ' ' || last_name
      INTO v_employee_name
      FROM core.profiles
     WHERE id = COALESCE(NEW.profile_id, OLD.profile_id);

    -- ============================================================
    -- INSERT: Limit Aşımı Uyarısı
    -- ============================================================
    IF TG_OP = 'INSERT' THEN
        IF NEW.is_over_limit THEN
            -- Talep sahibine popup tetikleyici WARNING
            PERFORM system.notify_user(
                NEW.profile_id,
                'Bütçe Limiti Aşıldı',
                'Oluşturduğunuz talep tutarı, bağlı olduğu politikanın limitini aşıyor. ' ||
                'HR ekibi inceleyip karar verecektir.',
                'WARNING'::system.notification_type,
                '/masraf/' || NEW.id::TEXT
            );

            -- HR ve ADMIN'e WARNING
            v_msg := v_employee_name || ' adlı çalışan limit aşan bir talep oluşturdu. '
                     || 'Tutar: ' || NEW.amount::TEXT || ' ' || COALESCE(NEW.currency, 'TRY') || '.';

            PERFORM system.notify_role(
                'HR', 'Limit Aşan Masraf Talebi',
                v_msg, 'WARNING'::system.notification_type,
                '/masraf/' || NEW.id::TEXT
            );
            PERFORM system.notify_role(
                'ADMIN', 'Limit Aşan Masraf Talebi',
                v_msg, 'WARNING'::system.notification_type,
                '/masraf/' || NEW.id::TEXT
            );
        END IF;

        RETURN NEW;
    END IF;

    -- ============================================================
    -- UPDATE: Status Değişimi
    -- ============================================================
    IF TG_OP = 'UPDATE' AND OLD.status <> NEW.status THEN
        -- PENDING -> APPROVED
        IF OLD.status = 'PENDING' AND NEW.status = 'APPROVED' THEN
            v_msg := 'Talebiniz onaylandı. Tutar: '
                     || NEW.amount::TEXT || ' ' || COALESCE(NEW.currency, 'TRY') || '.';

            -- ADVANCE ise + 1 ay fatura son tarihi belirt
            IF NEW.request_type = 'ADVANCE' THEN
                v_deadline_text := TO_CHAR(
                    COALESCE(NEW.approved_at, NOW()) + INTERVAL '1 month',
                    'DD.MM.YYYY'
                );
                v_msg := v_msg || ' Lütfen ' || v_deadline_text
                         || ' tarihine kadar faturayı sisteme yükleyin.';
            END IF;

            PERFORM system.notify_user(
                NEW.profile_id,
                'Masraf Talebiniz Onaylandı',
                v_msg,
                'SUCCESS'::system.notification_type,
                '/masraf/' || NEW.id::TEXT
            );

        -- PENDING -> REJECTED
        ELSIF OLD.status = 'PENDING' AND NEW.status = 'REJECTED' THEN
            PERFORM system.notify_user(
                NEW.profile_id,
                'Masraf Talebiniz Reddedildi',
                COALESCE('Sebep: ' || NEW.rejection_reason, 'Talebiniz reddedildi.'),
                'WARNING'::system.notification_type,
                '/masraf/' || NEW.id::TEXT
            );

        -- APPROVED -> CANCELLED
        ELSIF OLD.status = 'APPROVED' AND NEW.status = 'CANCELLED' THEN
            PERFORM system.notify_user(
                NEW.profile_id,
                'Onaylı Masraf İptal Edildi',
                'Daha önce onaylanan talebiniz iptal edildi.',
                'WARNING'::system.notification_type,
                '/masraf/' || NEW.id::TEXT
            );
        END IF;
    END IF;

    -- ============================================================
    -- UPDATE: ÖDEME BİLDİRİMİ (is_paid FALSE -> TRUE)
    -- ============================================================
    IF TG_OP = 'UPDATE'
       AND COALESCE(OLD.is_paid, FALSE) = FALSE
       AND COALESCE(NEW.is_paid, FALSE) = TRUE
    THEN
        PERFORM system.notify_user(
            NEW.profile_id,
            'Ödeme Yapıldı',
            'Onaylı masrafınız ödendi. Tutar: '
                || NEW.amount::TEXT || ' ' || COALESCE(NEW.currency, 'TRY') || '.',
            'SUCCESS'::system.notification_type,
            '/masraf/' || NEW.id::TEXT
        );
    END IF;

    RETURN NEW;
END;
$$;


-- ------------------------------------------------------------
-- A.4) finance.notify_receipt_uploaded()
-- ------------------------------------------------------------
-- AFTER INSERT on finance.receipts.
-- Çalışan fatura yüklediğinde HR'a bildirim gönderir.


CREATE OR REPLACE FUNCTION finance.notify_receipt_uploaded()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    v_uploader_name  TEXT;
    v_expense_type   core.expense_type;
    v_expense_amount DECIMAL(12,2);
    v_currency       VARCHAR(3);
    v_diff           DECIMAL(12,2);
    v_msg            TEXT;
    v_diff_note      TEXT := '';
BEGIN
    -- Fatura yükleyenin adı (yoksa "Bilinmiyor")
    SELECT first_name || ' ' || last_name
      INTO v_uploader_name
      FROM core.profiles
     WHERE id = NEW.uploaded_by;
    v_uploader_name := COALESCE(v_uploader_name, 'Bilinmeyen kullanıcı');

    -- Bağlı talebin tipi ve tutarı
    SELECT request_type, amount, currency
      INTO v_expense_type, v_expense_amount, v_currency
      FROM finance.expense_requests
     WHERE id = NEW.expense_id;

    -- ADVANCE için fatura/avans farkını mesaja iliştir
    IF v_expense_type = 'ADVANCE'
       AND NEW.total_amount IS NOT NULL
       AND v_expense_amount IS NOT NULL
    THEN
        v_diff := NEW.total_amount - v_expense_amount;

        IF v_diff > 0 THEN
            v_diff_note := ' Fatura avansı '
                || v_diff::TEXT || ' ' || COALESCE(v_currency, 'TRY')
                || ' aşıyor; ek satır gerekebilir.';
        ELSIF v_diff < 0 THEN
            v_diff_note := ' Fatura avanstan '
                || ABS(v_diff)::TEXT || ' ' || COALESCE(v_currency, 'TRY')
                || ' düşük; iade/mahsup gerekebilir.';
        ELSE
            v_diff_note := ' Avans ile fatura tutarı eşit.';
        END IF;
    END IF;

    v_msg := v_uploader_name || ' fatura yükledi. Fatura tutarı: '
             || COALESCE(NEW.total_amount::TEXT, 'belirtilmedi')
             || COALESCE(' ' || v_currency, '')
             || '.' || v_diff_note;

    PERFORM system.notify_role(
        'HR',
        'Yeni Fatura Yüklendi',
        v_msg,
        'INFO'::system.notification_type,
        '/masraf/' || NEW.expense_id::TEXT
    );

    RETURN NEW;
END;
$$;


-- ============================================================
-- B) TRIGGER BAĞLAMALARI
-- ============================================================


-- 1) finance.expense_policies                          (14)

DROP TRIGGER IF EXISTS trg_expense_policies_set_updated_at ON finance.expense_policies;
CREATE TRIGGER trg_expense_policies_set_updated_at
    BEFORE UPDATE ON finance.expense_policies
    FOR EACH ROW
    EXECUTE FUNCTION core.set_updated_at();

DROP TRIGGER IF EXISTS trg_expense_policies_audit ON finance.expense_policies;
CREATE TRIGGER trg_expense_policies_audit
    AFTER INSERT OR UPDATE OR DELETE ON finance.expense_policies
    FOR EACH ROW
    EXECUTE FUNCTION system.audit_trigger_func();


-- ------------------------------------------------------------
-- 2) finance.expense_requests                          (15)
-- ------------------------------------------------------------

-- (BEFORE INSERT/UPDATE) ön işleme: limit, parent check, approved_at
DROP TRIGGER IF EXISTS trg_expense_requests_preprocess ON finance.expense_requests;
CREATE TRIGGER trg_expense_requests_preprocess
    BEFORE INSERT OR UPDATE ON finance.expense_requests
    FOR EACH ROW
    EXECUTE FUNCTION finance.preprocess_expense_request();

-- (BEFORE UPDATE) updated_at
DROP TRIGGER IF EXISTS trg_expense_requests_set_updated_at ON finance.expense_requests;
CREATE TRIGGER trg_expense_requests_set_updated_at
    BEFORE UPDATE ON finance.expense_requests
    FOR EACH ROW
    EXECUTE FUNCTION core.set_updated_at();

-- (AFTER) audit
DROP TRIGGER IF EXISTS trg_expense_requests_audit ON finance.expense_requests;
CREATE TRIGGER trg_expense_requests_audit
    AFTER INSERT OR UPDATE OR DELETE ON finance.expense_requests
    FOR EACH ROW
    EXECUTE FUNCTION system.audit_trigger_func();

-- (AFTER INSERT) yeni talep -> HR/ADMIN'e duyuru
DROP TRIGGER IF EXISTS trg_expense_requests_pending_notify ON finance.expense_requests;
CREATE TRIGGER trg_expense_requests_pending_notify
    AFTER INSERT ON finance.expense_requests
    FOR EACH ROW
    EXECUTE FUNCTION finance.notify_pending_to_approvers();

-- (AFTER INSERT/UPDATE) durum/limit/ödeme bildirimleri
DROP TRIGGER IF EXISTS trg_expense_requests_notify ON finance.expense_requests;
CREATE TRIGGER trg_expense_requests_notify
    AFTER INSERT OR UPDATE ON finance.expense_requests
    FOR EACH ROW
    EXECUTE FUNCTION finance.notify_on_status_change();


-- ------------------------------------------------------------
-- 3) finance.receipts                                  (16)
-- ------------------------------------------------------------

-- receipts tablosunda updated_at SÜTUNU YOK; set_updated_at bağlanmaz.
-- Yalnız audit ve fatura yüklendi bildirimi bağlanır.

DROP TRIGGER IF EXISTS trg_receipts_audit ON finance.receipts;
CREATE TRIGGER trg_receipts_audit
    AFTER INSERT OR UPDATE OR DELETE ON finance.receipts
    FOR EACH ROW
    EXECUTE FUNCTION system.audit_trigger_func();

-- (AFTER INSERT) fatura yüklendi -> HR'a bildirim
DROP TRIGGER IF EXISTS trg_receipts_uploaded_notify ON finance.receipts;
CREATE TRIGGER trg_receipts_uploaded_notify
    AFTER INSERT ON finance.receipts
    FOR EACH ROW
    EXECUTE FUNCTION finance.notify_receipt_uploaded();

