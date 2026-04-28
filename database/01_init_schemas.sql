-- Odalarımızı (Schema) oluşturalım
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE SCHEMA IF NOT EXISTS core;    -- Organizasyon ve Yetki
CREATE SCHEMA IF NOT EXISTS leave;   -- İzin Yönetimi
CREATE SCHEMA IF NOT EXISTS finance; -- Finans ve Masraf
CREATE SCHEMA IF NOT EXISTS system;  -- Bildirim ve Log