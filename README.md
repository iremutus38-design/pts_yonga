# PTS Yonga - Personel Takip Sistemi (Veritabanı Katmanı)

Bu proje, bir kurumun personel yönetimi, izin talepleri, finansal harcamalar ve sistem bildirimlerini yöneten gelişmiş bir PostgreSQL veritabanı mimarisini içerir.

## 🚀 Teknolojiler
* **Framework:** Next.js (Frontend/API)
* **Veritabanı:** PostgreSQL
* **Güvenlik:** Row Level Security (RLS)
* **Dil:** PL/pgSQL (Triggers & Functions)

## 📂 Veritabanı Yapısı
Proje, mantıksal olarak 4 ana şemaya bölünmüştür:

1. **core:** Personel profilleri, roller, departmanlar ve vekalet yönetimi.
2. **leave:** İzin türleri, kullanıcı bakiyeleri ve izin talepleri.
3. **finance:** Harcama politikaları, masraf talepleri ve fatura kayıtları.
4. **system:** Bildirimler ve tüm sistemin denetim günlükleri (audit logs).

## 🔒 Güvenlik Özellikleri
* Tüm tablolarda **RLS (Row Level Security)** aktif edilmiştir.
* Personel sadece kendi verilerini görebilir.
* Takım Liderleri ve Direktörler hiyerarşik onay yetkisine sahiptir.
* İK ve Admin sistem genelinde tam denetim yetkisine sahiptir.

## 🛠️ Kurulum Sıralaması
Veritabanını ayağa kaldırmak için SQL dosyaları `database/` klasöründeki numaralandırma sırasına göre çalıştırılmalıdır.
