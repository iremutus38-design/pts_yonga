-- ============================================================
-- 21_triggers_leave.sql
-- ------------------------------------------------------------
--
-- BU DOSYADA TANIMLANAN İZNE ÖZEL FONKSİYONLAR:
--   * leave.preprocess_leave_request()
--       BEFORE INSERT/UPDATE.
--       - SICK ise medical_report_url zorunlu, status otomatik APPROVED.
--       - DUAL APPROVAL: UPDATE sırasında iki onay alanı da dolduysa
--         ve eski status PENDING ise NEW.status := 'APPROVED'.
--       - 6 ay kuralı: hire_date'i kontrol eder, is_under_tenure flag.
--       - Bakiye kontrolü: kalan günden fazla isterse is_over_balance flag.
--       - total_days NULL veya 0 ise core.calculate_leave_days ile hesaplar.
--
--   * leave.adjust_balance_on_status_change()
--       AFTER INSERT/UPDATE/DELETE.
--       - Normal izin APPROVED'a girince used_days += total_days.
--       - APPROVED'dan çıkınca used_days -= total_days (geri ekleme).
--       - OVERTIME_COMP onaylanırsa ANNUAL.total_accrued += total_days
--         (mesai saati 8'e bölünüp gün olarak yıllık izine eklenir;
--         total_days hesabı preprocess içinde overtime_hours/8 olarak
--         kuruluyor).
--
--   * leave.notify_on_status_change()
--       AFTER INSERT/UPDATE.
--       - PENDING -> APPROVED  : çalışana SUCCESS bildirimi.
--       - PENDING -> REJECTED  : çalışana WARNING bildirimi.
--       - APPROVED -> CANCELLED: çalışana WARNING bildirimi.
--       - INSERT'te is_over_balance veya is_under_tenure TRUE ise TL
--         ve Direktöre WARNING bildirimi (uyarı; talebi engellemez).
--
--   * leave.notify_pending_request_to_approvers()
--       AFTER INSERT.
--       - SICK DIŞINDAKİ tüm tiplerde yeni talep TL ve Direktöre
--         INFO bildirimi olarak düşer (çift onay sürecini başlatır).
-- ============================================================


-- ============================================================
-- A) İZNE ÖZEL TRIGGER FONKSİYONLARI
-- ============================================================


-- ------------------------------------------------------------
-- A.1) leave.preprocess_leave_request()
-- ------------------------------------------------------------
-- BEFORE INSERT/UPDATE'te çalışır. Dört ana iş yapar:
--   1) İzin tipini bulur (SICK, OVERTIME_COMP, vs.).
--   2) total_days null/0 ise hafta sonu+tatil düşülmüş net günü hesaplar.
--   3) İş kurallarını uygular (INSERT odaklı):
--      - SICK ise medical_report_url ZORUNLU; status otomatik APPROVED.
--      - 6 ay kuralı: kişi hire_date'inden 6 ay geçmemişse
--        is_under_tenure = TRUE (talep yine girer, sadece bayrak).
--      - Bakiye kontrolü: leave_balances'taki kalan günden fazla isterse
--        is_over_balance = TRUE (yine girer, sadece bayrak).
--   4) DUAL APPROVAL (UPDATE odaklı):
--      - SICK olmayan ve OLD.status='PENDING' bir talepte
--        tl_approved_at VE director_approved_at alanlarının ikisi de
--        artık dolu ise NEW.status := 'APPROVED' yap. Onay sırası
--        önemli değil; son onay durumu çevirir.
-- ------------------------------------------------------------

CREATE OR REPLACE FUNCTION leave.preprocess_leave_request()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    v_type_key      VARCHAR(50);
    v_hire_date     DATE;
    v_year          INT;
    v_remaining     DECIMAL(5,2);
BEGIN
    -- 1) İzin tipinin "type_key"ini bul (ANNUAL/SICK/...)
    SELECT type_key INTO v_type_key
      FROM leave.leave_types
     WHERE id = NEW.leave_type_id;

    -- 2) total_days hesapla (boş ya da 0 geldiyse)
    --    OVERTIME_COMP: kişi mesai saatini overtime_hours olarak veriyor;
    --    bu durumda total_days = overtime_hours / 8 (gün cinsinden).
    --    Diğer tipler: start-end aralığında hafta sonu + tatil dışı net gün.
    IF NEW.total_days IS NULL OR NEW.total_days = 0 THEN
        IF v_type_key = 'OVERTIME_COMP' AND NEW.overtime_hours IS NOT NULL THEN
            NEW.total_days := ROUND(NEW.overtime_hours / 8.0, 1);
        ELSE
            NEW.total_days := core.calculate_leave_days(
                NEW.start_date, NEW.end_date, NEW.profile_id
            );
        END IF;
    END IF;

    -- 3) SICK ise: rapor zorunlu, status otomatik APPROVED.
    --    Çift onay AKIŞI BURADA İŞLEMEZ; SICK kendi başına onaylanır.
    IF v_type_key = 'SICK' THEN
        IF NEW.medical_report_url IS NULL OR LENGTH(TRIM(NEW.medical_report_url)) = 0 THEN
            RAISE EXCEPTION
                'Hastalık izni için medical_report_url zorunludur.';
        END IF;

        -- INSERT'te otomatik APPROVED. UPDATE'te dokunma (manuel müdahale olabilir).
        IF TG_OP = 'INSERT' THEN
            NEW.status := 'APPROVED';
        END IF;

        RETURN NEW; -- SICK için tenure / bakiye / dual-approval uygulanmaz
    END IF;

    -- ============================================================
    -- 4) DUAL APPROVAL AUTO-FLIP (UPDATE'e özel)
    -- ------------------------------------------------------------
    -- TL veya Direktör onay alanını doldurduğunda buraya geliriz.
    -- Eğer iki alan da dolu VE eski durum PENDING ise status'u
    -- APPROVED yap. Bir alan eksikse durum PENDING kalır.
    --
    -- HR/ADMIN manuel olarak status='APPROVED' yapmak isterse bu
    -- blok onları engellemiyor; çünkü NEW.status zaten 'APPROVED'
    -- olarak gelmiş olur. RLS o kullanıcıya zaten doğrudan
    -- güncelleme izni veriyor.
    -- ============================================================
    IF TG_OP = 'UPDATE' --UPDATE sırasında gelen yeni veriyi kontrol ediyor.
       AND OLD.status = 'PENDING'
       AND NEW.tl_approved_at        IS NOT NULL
       AND NEW.director_approved_at  IS NOT NULL
       AND NEW.status = 'PENDING'  -- caller manuel APPROVED'a çevirmediyse
    THEN
        NEW.status := 'APPROVED';
    END IF;

    -- 5) 6 AY KURALI: hire_date kontrolü
    --    SICK dışındaki tüm izin tiplerine uygulanır.
    SELECT hire_date INTO v_hire_date
      FROM core.profiles
     WHERE id = NEW.profile_id;

    IF v_hire_date IS NOT NULL
       AND v_hire_date > (CURRENT_DATE - INTERVAL '6 months')
    THEN
        NEW.is_under_tenure := TRUE;
    ELSE
        NEW.is_under_tenure := FALSE;
    END IF;

    -- 6) BAKİYE KONTROLÜ: kalan günden fazla mı?
    --    OVERTIME_COMP gün kazanıyor; kontrolü atla.
    --    Diğer tipler (ANNUAL, CASUAL, UNPAID): leave_balances'a bak.
    IF v_type_key <> 'OVERTIME_COMP' THEN
        v_year := EXTRACT(YEAR FROM NEW.start_date);

        SELECT remaining_days INTO v_remaining
          FROM leave.leave_balances
         WHERE profile_id    = NEW.profile_id
           AND leave_type_id = NEW.leave_type_id
           AND year_period   = v_year;

        -- Cüzdan yoksa varsayılan 0 (yani aşılmış sayılır).
        v_remaining := COALESCE(v_remaining, 0);

        IF NEW.total_days > v_remaining THEN
            NEW.is_over_balance := TRUE;
        ELSE
            NEW.is_over_balance := FALSE;
        END IF;
    END IF;

    RETURN NEW;
END;
$$;


-- ------------------------------------------------------------
-- A.2) leave.adjust_balance_on_status_change()
-- ------------------------------------------------------------
-- AFTER INSERT/UPDATE/DELETE'te çalışır.
--   * Normal izin APPROVED durumuna girerse:
--       leave_balances.used_days += total_days
--   * Normal izin APPROVED durumundan çıkarsa:
--       leave_balances.used_days -= total_days
--   * OVERTIME_COMP APPROVED durumuna girerse:
--       leave_balances.total_accrued += total_days   (gün kazanır)
--       (tip ANNUAL'a kazandırıyoruz; mesai izni karşılığı yıllık izin
--       gününe ek)
--   * OVERTIME_COMP APPROVED durumundan çıkarsa:
--       leave_balances.total_accrued -= total_days
-- ------------------------------------------------------------

CREATE OR REPLACE FUNCTION leave.adjust_balance_on_status_change()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    v_old_approved   BOOLEAN := FALSE;
    v_new_approved   BOOLEAN := FALSE;
    v_delta          DECIMAL(5,2) := 0;
    v_profile_id     UUID;
    v_leave_type_id  UUID;
    v_type_key       VARCHAR(50);
    v_year           INT;
    v_days           DECIMAL(5,2);
    v_annual_type_id UUID;
BEGIN
    -- TG_OP'a göre OLD/NEW topla
    IF TG_OP = 'INSERT' THEN
        v_new_approved  := (NEW.status = 'APPROVED');
        v_profile_id    := NEW.profile_id;
        v_leave_type_id := NEW.leave_type_id;
        v_year          := EXTRACT(YEAR FROM NEW.start_date);
        v_days          := NEW.total_days;
    ELSIF TG_OP = 'UPDATE' THEN
        v_old_approved  := (OLD.status = 'APPROVED');
        v_new_approved  := (NEW.status = 'APPROVED');
        v_profile_id    := NEW.profile_id;
        v_leave_type_id := NEW.leave_type_id;
        v_year          := EXTRACT(YEAR FROM NEW.start_date);
        v_days          := NEW.total_days;
    ELSIF TG_OP = 'DELETE' THEN
        v_old_approved  := (OLD.status = 'APPROVED');
        v_profile_id    := OLD.profile_id;
        v_leave_type_id := OLD.leave_type_id;
        v_year          := EXTRACT(YEAR FROM OLD.start_date);
        v_days          := OLD.total_days;
    END IF;

    -- Net delta
    IF v_new_approved AND NOT v_old_approved THEN
        v_delta := v_days;
    ELSIF v_old_approved AND NOT v_new_approved THEN
        v_delta := -v_days;
    ELSE
        RETURN COALESCE(NEW, OLD); -- etkisiz durum
    END IF;

    -- Tip key'ini al
    SELECT type_key INTO v_type_key
      FROM leave.leave_types
     WHERE id = v_leave_type_id;

    -- ============================================================
    -- DURUM 1: OVERTIME_COMP (mesai izni)
    -- Onaylanırsa kişinin ANNUAL cüzdanına gün eklenir (kazanır).
    -- Yani used_days değil total_accrued artar.
    -- ============================================================
    IF v_type_key = 'OVERTIME_COMP' THEN
        SELECT id INTO v_annual_type_id
          FROM leave.leave_types
         WHERE type_key = 'ANNUAL';

        UPDATE leave.leave_balances
           SET total_accrued = total_accrued + v_delta,
               updated_at    = NOW()
         WHERE profile_id    = v_profile_id
           AND leave_type_id = v_annual_type_id
           AND year_period   = v_year;

        IF NOT FOUND THEN
            INSERT INTO leave.leave_balances (
                profile_id, leave_type_id, year_period, total_accrued, used_days
            ) VALUES (
                v_profile_id, v_annual_type_id, v_year, GREATEST(v_delta, 0), 0
            );
        END IF;

        RETURN COALESCE(NEW, OLD);
    END IF;

    -- ============================================================
    -- DURUM 2: Normal izinler (ANNUAL, CASUAL, SICK, UNPAID)
    -- used_days üzerinden çalışır.
    -- ============================================================
    UPDATE leave.leave_balances
       SET used_days  = used_days + v_delta,
           updated_at = NOW()
     WHERE profile_id    = v_profile_id
       AND leave_type_id = v_leave_type_id
       AND year_period   = v_year;

    IF NOT FOUND THEN
        INSERT INTO leave.leave_balances (
            profile_id, leave_type_id, year_period, total_accrued, used_days
        ) VALUES (
            v_profile_id, v_leave_type_id, v_year, 0, GREATEST(v_delta, 0)
        );
    END IF;

    RETURN COALESCE(NEW, OLD);
END;
$$;


-- ------------------------------------------------------------
-- A.3) leave.notify_on_status_change()
-- ------------------------------------------------------------
-- Hem INSERT (talep oluşturulduğunda flag uyarıları) hem UPDATE
-- (status değişiklikleri) için bildirim üretir.
-- ------------------------------------------------------------

CREATE OR REPLACE FUNCTION leave.notify_on_status_change()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    v_team_lead_id  UUID;
    v_director_id   UUID;
    v_employee_name TEXT;
BEGIN
    -- Talep sahibinin ad-soyadı (mesajlarda kullanmak için)
    SELECT first_name || ' ' || last_name
      INTO v_employee_name
      FROM core.profiles
     WHERE id = COALESCE(NEW.profile_id, OLD.profile_id);

    -- Talep sahibinin TL ve Director'unu bul
    v_team_lead_id := core.team_lead_of(COALESCE(NEW.profile_id, OLD.profile_id));
    v_director_id  := core.director_of(COALESCE(NEW.profile_id, OLD.profile_id));

    -- ============================================================
    -- INSERT: yeni talep oluşturuldu
    --   - is_over_balance veya is_under_tenure ise TL ve Director'e
    --     uyarı bildirimi gönder.
    -- ============================================================
    IF TG_OP = 'INSERT' THEN
        IF NEW.is_over_balance THEN
            PERFORM system.notify_user(
                v_team_lead_id,
                'Bakiye Aşımı Bildirimi',
                v_employee_name || ' adlı çalışan yıllık izin bakiyesini aşan bir talep oluşturdu.',
                'WARNING'::system.notification_type,
                '/izin/' || NEW.id::TEXT
            );
            PERFORM system.notify_user(
                v_director_id,
                'Bakiye Aşımı Bildirimi',
                v_employee_name || ' adlı çalışan yıllık izin bakiyesini aşan bir talep oluşturdu.',
                'WARNING'::system.notification_type,
                '/izin/' || NEW.id::TEXT
            );
        END IF;

        IF NEW.is_under_tenure THEN
            PERFORM system.notify_user(
                v_team_lead_id,
                'Kıdem Yetersiz Bildirimi',
                v_employee_name || ' adlı çalışan 6 ay kıdemini doldurmadan izin talep etti.',
                'WARNING'::system.notification_type,
                '/izin/' || NEW.id::TEXT
            );
            PERFORM system.notify_user(
                v_director_id,
                'Kıdem Yetersiz Bildirimi',
                v_employee_name || ' adlı çalışan 6 ay kıdemini doldurmadan izin talep etti.',
                'WARNING'::system.notification_type,
                '/izin/' || NEW.id::TEXT
            );
        END IF;

        RETURN NEW;
    END IF;

    -- ============================================================
    -- UPDATE: status değişimi
    -- ============================================================
    IF TG_OP = 'UPDATE' AND OLD.status <> NEW.status THEN
        -- PENDING -> APPROVED
        IF OLD.status = 'PENDING' AND NEW.status = 'APPROVED' THEN
            PERFORM system.notify_user(
                NEW.profile_id,
                'İzin Talebiniz Onaylandı',
                'İzin talebiniz onaylandı. Tarih aralığı: '
                    || NEW.start_date::TEXT || ' - ' || NEW.end_date::TEXT,
                'SUCCESS'::system.notification_type,
                '/izin/' || NEW.id::TEXT
            );

        -- PENDING -> REJECTED
        ELSIF OLD.status = 'PENDING' AND NEW.status = 'REJECTED' THEN
            PERFORM system.notify_user(
                NEW.profile_id,
                'İzin Talebiniz Reddedildi',
                COALESCE('Sebep: ' || NEW.rejection_reason, 'Talebiniz reddedildi.'),
                'WARNING'::system.notification_type,
                '/izin/' || NEW.id::TEXT
            );

        -- APPROVED -> CANCELLED  (TL/Director sonradan iptal etti)
        ELSIF OLD.status = 'APPROVED' AND NEW.status = 'CANCELLED' THEN
            PERFORM system.notify_user(
                NEW.profile_id,
                'Onaylı İzniniz İptal Edildi',
                'Yöneticiniz daha önce onaylanan izninizi iptal etti.',
                'WARNING'::system.notification_type,
                '/izin/' || NEW.id::TEXT
            );

        -- PENDING -> CANCELLED (kullanıcı kendi iptal etti, sessiz)
        END IF;
    END IF;

    RETURN NEW;
END;
$$;


-- ------------------------------------------------------------
-- A.4) leave.notify_pending_request_to_approvers()
-- ------------------------------------------------------------
-- SICK DIŞINDAKİ tüm izin tipleri için (ANNUAL, CASUAL, UNPAID,
-- OVERTIME_COMP) yeni talep oluşturulduğunda TL ve Direktör'e
-- INFO bildirimi gönderir; çift onay sürecini başlatır.
--
-- SICK type'ı için bu fonksiyon NEW'i değiştirmeden döner: çünkü
-- SICK preprocess içinde anında APPROVED'a geçer, onay akışı
-- işlemez.
--
-- Bildirim metni izin tipine göre farklılaştırılır:
--   * OVERTIME_COMP: "X mesai izni talep etti, mesai tarihi/saat..."
--   * Diğer tipler:  "X izin talep etti, tarih aralığı..."
-- ------------------------------------------------------------

CREATE OR REPLACE FUNCTION leave.notify_pending_request_to_approvers()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    v_type_key      VARCHAR(50);
    v_type_label    VARCHAR(100);
    v_team_lead_id  UUID;
    v_director_id   UUID;
    v_employee_name TEXT;
    v_title         TEXT;
    v_msg           TEXT;
BEGIN
    -- İzin tipini bul; SICK ise erken çıkış.
    SELECT type_key, name
      INTO v_type_key, v_type_label
      FROM leave.leave_types
     WHERE id = NEW.leave_type_id;

    IF v_type_key = 'SICK' THEN
        RETURN NEW;
    END IF;

    -- Talebin status'u APPROVED olarak gelmişse (örn. HR direkt
    -- onaylı ekledi) onay bildirimi göndermeye gerek yok.
    IF NEW.status <> 'PENDING' THEN
        RETURN NEW;
    END IF;

    SELECT first_name || ' ' || last_name
      INTO v_employee_name
      FROM core.profiles WHERE id = NEW.profile_id;

    v_team_lead_id := core.team_lead_of(NEW.profile_id);
    v_director_id  := core.director_of(NEW.profile_id);

    -- Tipe göre özelleştirilmiş başlık ve mesaj.
    IF v_type_key = 'OVERTIME_COMP' THEN
        v_title := 'Mesai İzni Onayı Bekliyor';
        v_msg := v_employee_name || ' mesai izni talep etti. Mesai tarihi: '
                 || COALESCE(NEW.overtime_date::TEXT, 'belirtilmemiş')
                 || ', süre: ' || COALESCE(NEW.overtime_hours::TEXT, '0')
                 || ' saat. Onayınız bekleniyor.';
    ELSE
        v_title := 'İzin Onayı Bekliyor';
        v_msg := v_employee_name || ' izin talep etti ('
                 || COALESCE(v_type_label, v_type_key) || '). Tarih aralığı: '
                 || NEW.start_date::TEXT || ' - ' || NEW.end_date::TEXT
                 || '. Onayınız bekleniyor.';
    END IF;

    -- TL ve Direktör'e bildirim gönder. core.team_lead_of /
    -- core.director_of NULL dönerse system.notify_user içindeki
    -- guard sayesinde bildirim oluşturulmaz.
    PERFORM system.notify_user(
        v_team_lead_id,
        v_title,
        v_msg,
        'INFO'::system.notification_type,
        '/izin/' || NEW.id::TEXT
    );
    PERFORM system.notify_user(
        v_director_id,
        v_title,
        v_msg,
        'INFO'::system.notification_type,
        '/izin/' || NEW.id::TEXT
    );

    RETURN NEW;
END;
$$;


-- ============================================================
-- B) TRIGGER BAĞLAMALARI
-- ============================================================


-- ------------------------------------------------------------
-- 1) leave.leave_types                                (09)
-- ------------------------------------------------------------

DROP TRIGGER IF EXISTS trg_leave_types_set_updated_at ON leave.leave_types;
CREATE TRIGGER trg_leave_types_set_updated_at
    BEFORE UPDATE ON leave.leave_types
    FOR EACH ROW
    EXECUTE FUNCTION core.set_updated_at();

DROP TRIGGER IF EXISTS trg_leave_types_audit ON leave.leave_types;
CREATE TRIGGER trg_leave_types_audit
    AFTER INSERT OR UPDATE OR DELETE ON leave.leave_types
    FOR EACH ROW
    EXECUTE FUNCTION system.audit_trigger_func();


-- ------------------------------------------------------------
-- 2) leave.leave_requests                             (10)
-- ------------------------------------------------------------
-- Bağlamalar BEFORE -> AFTER ve adlandırma alfabetik sırasına göre
-- mantıklı olacak şekilde düzenlendi.
-- ------------------------------------------------------------

-- (BEFORE INSERT/UPDATE) ön işleme
DROP TRIGGER IF EXISTS trg_leave_requests_preprocess ON leave.leave_requests;
CREATE TRIGGER trg_leave_requests_preprocess
    BEFORE INSERT OR UPDATE ON leave.leave_requests
    FOR EACH ROW
    EXECUTE FUNCTION leave.preprocess_leave_request();

-- (BEFORE UPDATE) updated_at
DROP TRIGGER IF EXISTS trg_leave_requests_set_updated_at ON leave.leave_requests;
CREATE TRIGGER trg_leave_requests_set_updated_at
    BEFORE UPDATE ON leave.leave_requests
    FOR EACH ROW
    EXECUTE FUNCTION core.set_updated_at();

-- (AFTER) audit
DROP TRIGGER IF EXISTS trg_leave_requests_audit ON leave.leave_requests;
CREATE TRIGGER trg_leave_requests_audit
    AFTER INSERT OR UPDATE OR DELETE ON leave.leave_requests
    FOR EACH ROW
    EXECUTE FUNCTION system.audit_trigger_func();

-- (AFTER) bakiye otomasyonu
DROP TRIGGER IF EXISTS trg_leave_requests_balance ON leave.leave_requests;
CREATE TRIGGER trg_leave_requests_balance
    AFTER INSERT OR UPDATE OR DELETE ON leave.leave_requests
    FOR EACH ROW
    EXECUTE FUNCTION leave.adjust_balance_on_status_change();

-- (AFTER INSERT/UPDATE) bildirimler
DROP TRIGGER IF EXISTS trg_leave_requests_notify ON leave.leave_requests;
CREATE TRIGGER trg_leave_requests_notify
    AFTER INSERT OR UPDATE ON leave.leave_requests
    FOR EACH ROW
    EXECUTE FUNCTION leave.notify_on_status_change();

-- (AFTER INSERT) yeni talep TL/Director'e duyuru (SICK hariç)
-- !!! YENİDEN ADLANDIRILDI: Eski "overtime_notify" sadece OVERTIME_COMP
-- için tetikleniyordu. Artık SICK dışı tüm tiplerde çift onay
-- başlatıyor; eski adı da düşürerek geçiş güvenli hale getirildi.
DROP TRIGGER IF EXISTS trg_leave_requests_overtime_notify ON leave.leave_requests;
DROP TRIGGER IF EXISTS trg_leave_requests_pending_notify  ON leave.leave_requests;
CREATE TRIGGER trg_leave_requests_pending_notify
    AFTER INSERT ON leave.leave_requests
    FOR EACH ROW
    EXECUTE FUNCTION leave.notify_pending_request_to_approvers();

-- !!! Eski fonksiyonu da düşür (idempotent ortam için).
DROP FUNCTION IF EXISTS leave.notify_overtime_request_to_approvers();


-- ------------------------------------------------------------
-- 3) leave.leave_balances                             (13)
-- ------------------------------------------------------------

DROP TRIGGER IF EXISTS trg_leave_balances_set_updated_at ON leave.leave_balances;
CREATE TRIGGER trg_leave_balances_set_updated_at
    BEFORE UPDATE ON leave.leave_balances
    FOR EACH ROW
    EXECUTE FUNCTION core.set_updated_at();

DROP TRIGGER IF EXISTS trg_leave_balances_audit ON leave.leave_balances;
CREATE TRIGGER trg_leave_balances_audit
    AFTER INSERT OR UPDATE OR DELETE ON leave.leave_balances
    FOR EACH ROW
    EXECUTE FUNCTION system.audit_trigger_func();


-- ============================================================
-- ÖZET (referans)
-- ------------------------------------------------------------
-- Tablo                | upd_at | audit | preprocess | balance | notify | pend-notify
-- ---------------------+--------+-------+------------+---------+--------+------------
-- leave.leave_types    |   ✓    |   ✓   |     -      |    -    |   -    |     -
-- leave.leave_requests |   ✓    |   ✓   |     ✓      |    ✓    |   ✓    |     ✓
-- leave.leave_balances |   ✓    |   ✓   |     -      |    -    |   -    |     -
--
-- DUAL APPROVAL AKIŞI (SICK hariç tüm tipler)
-- ------------------------------------------------------------
--   1. Çalışan talep oluşturur                     status=PENDING
--      -> pend-notify: TL ve Direktöre INFO gider
--   2. TL onaylar  -> tl_approved_at/by dolar      status=PENDING
--   3. Direktör onaylar -> director_approved_at/by status=APPROVED
--      (preprocess BEFORE UPDATE auto-flip)
--      -> notify: çalışana SUCCESS gider
--      -> balance: used_days veya total_accrued güncellenir
--   * Onay sırası ters de olabilir; son onay flip'i tetikler.
--   * SICK type'ı 1. adımda doğrudan APPROVED olur.
-- ============================================================