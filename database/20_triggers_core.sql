-- ============================================================
-- 20_triggers_core.sql
-- ------------------------------------------------------------
-- Bu dosya "core" şemasındaki tabloların TRIGGER BAĞLAMALARINI
-- içerir. 


-- ============================================================
-- 1) core.roles                                       (02)
-- ------------------------------------------------------------

DROP TRIGGER IF EXISTS trg_roles_set_updated_at ON core.roles;
CREATE TRIGGER trg_roles_set_updated_at
    BEFORE UPDATE ON core.roles
    FOR EACH ROW
    EXECUTE FUNCTION core.set_updated_at();

DROP TRIGGER IF EXISTS trg_roles_audit ON core.roles;
CREATE TRIGGER trg_roles_audit
    AFTER INSERT OR UPDATE OR DELETE ON core.roles
    FOR EACH ROW
    EXECUTE FUNCTION system.audit_trigger_func();


-- ============================================================
-- 2) core.locations                                   (03)
-- ------------------------------------------------------------

DROP TRIGGER IF EXISTS trg_locations_set_updated_at ON core.locations;
CREATE TRIGGER trg_locations_set_updated_at
    BEFORE UPDATE ON core.locations
    FOR EACH ROW
    EXECUTE FUNCTION core.set_updated_at();

DROP TRIGGER IF EXISTS trg_locations_audit ON core.locations;
CREATE TRIGGER trg_locations_audit
    AFTER INSERT OR UPDATE OR DELETE ON core.locations
    FOR EACH ROW
    EXECUTE FUNCTION system.audit_trigger_func();


-- ============================================================
-- 3) core.departments                                 (04)
-- ------------------------------------------------------------

DROP TRIGGER IF EXISTS trg_departments_set_updated_at ON core.departments;
CREATE TRIGGER trg_departments_set_updated_at
    BEFORE UPDATE ON core.departments
    FOR EACH ROW
    EXECUTE FUNCTION core.set_updated_at();

DROP TRIGGER IF EXISTS trg_departments_audit ON core.departments;
CREATE TRIGGER trg_departments_audit
    AFTER INSERT OR UPDATE OR DELETE ON core.departments
    FOR EACH ROW
    EXECUTE FUNCTION system.audit_trigger_func();


-- ============================================================
-- 4) core.teams                                       (05)
-- ------------------------------------------------------------

DROP TRIGGER IF EXISTS trg_teams_set_updated_at ON core.teams;
CREATE TRIGGER trg_teams_set_updated_at
    BEFORE UPDATE ON core.teams
    FOR EACH ROW
    EXECUTE FUNCTION core.set_updated_at();

DROP TRIGGER IF EXISTS trg_teams_audit ON core.teams;
CREATE TRIGGER trg_teams_audit
    AFTER INSERT OR UPDATE OR DELETE ON core.teams
    FOR EACH ROW
    EXECUTE FUNCTION system.audit_trigger_func();


-- ============================================================
-- 5) core.profiles                                    (06)
-- ------------------------------------------------------------

-- a) updated_at otomatik güncelleme
DROP TRIGGER IF EXISTS trg_profiles_set_updated_at ON core.profiles;
CREATE TRIGGER trg_profiles_set_updated_at
    BEFORE UPDATE ON core.profiles
    FOR EACH ROW
    EXECUTE FUNCTION core.set_updated_at();

-- b) manager_id döngü engelleme
--    Sadece manager_id değiştiğinde ve INSERT'te tetiklenir.
--    Diğer alan değişiklikleri için boşuna çalışmaz.
DROP TRIGGER IF EXISTS trg_profiles_prevent_cycle ON core.profiles;
CREATE TRIGGER trg_profiles_prevent_cycle
    BEFORE INSERT OR UPDATE OF manager_id ON core.profiles
    FOR EACH ROW
    EXECUTE FUNCTION core.prevent_manager_cycle();

-- c) Audit log
DROP TRIGGER IF EXISTS trg_profiles_audit ON core.profiles;
CREATE TRIGGER trg_profiles_audit
    AFTER INSERT OR UPDATE OR DELETE ON core.profiles
    FOR EACH ROW
    EXECUTE FUNCTION system.audit_trigger_func();


-- ============================================================
-- 6) core.users                                       (07)
-- ------------------------------------------------------------

DROP TRIGGER IF EXISTS trg_users_set_updated_at ON core.users;
CREATE TRIGGER trg_users_set_updated_at
    BEFORE UPDATE ON core.users
    FOR EACH ROW
    EXECUTE FUNCTION core.set_updated_at();

DROP TRIGGER IF EXISTS trg_users_audit ON core.users;
CREATE TRIGGER trg_users_audit
    AFTER INSERT OR UPDATE OR DELETE ON core.users
    FOR EACH ROW
    EXECUTE FUNCTION system.audit_trigger_func();


-- ============================================================
-- 7) core.user_delegations                            (08)
-- ------------------------------------------------------------

DROP TRIGGER IF EXISTS trg_delegations_set_updated_at ON core.user_delegations;
CREATE TRIGGER trg_delegations_set_updated_at
    BEFORE UPDATE ON core.user_delegations
    FOR EACH ROW
    EXECUTE FUNCTION core.set_updated_at();

DROP TRIGGER IF EXISTS trg_delegations_audit ON core.user_delegations;
CREATE TRIGGER trg_delegations_audit
    AFTER INSERT OR UPDATE OR DELETE ON core.user_delegations
    FOR EACH ROW
    EXECUTE FUNCTION system.audit_trigger_func();


-- ============================================================
-- 8) core.company_holidays                            (12)
-- ------------------------------------------------------------

DROP TRIGGER IF EXISTS trg_holidays_set_updated_at ON core.company_holidays;
CREATE TRIGGER trg_holidays_set_updated_at
    BEFORE UPDATE ON core.company_holidays
    FOR EACH ROW
    EXECUTE FUNCTION core.set_updated_at();

DROP TRIGGER IF EXISTS trg_holidays_audit ON core.company_holidays;
CREATE TRIGGER trg_holidays_audit
    AFTER INSERT OR UPDATE OR DELETE ON core.company_holidays
    FOR EACH ROW
    EXECUTE FUNCTION system.audit_trigger_func();
