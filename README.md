<p align="center"><img src="assets/ikon.png" width="96" alt="SSHManager"></p>

# SSHManager

**Menü çubuğundan tek tıkla SSH: macOS'un kendi Terminal'inde, parola yazmadan.**

Sunucularını menü çubuğuna ekle; tıklayınca bağlantı Terminal'de (ya da iTerm2'de) açılır. Parolalar macOS
Anahtar Zinciri'nde güvenle saklanır ve **terminale hiçbir zaman yazılmaz**: ssh parolayı doğrudan SSHManager'dan
ister (`SSH_ASKPASS`). "Dandik SSH uygulamaları" yerine sevdiğin terminali kullanmaya devam edersin.

## Neler yapar?

- **Tek tıkla bağlan.** Menü çubuğundaki simgeden sunucuyu seç; Terminal'de yeni sekmede açılır.
- **Parola terminale yazılmaz.** Parola Anahtar Zinciri'nden gelir; ekranda, kabuk geçmişinde ya da panoda görünmez.
  Yanlışsa native bir pencere doğrusunu sorar ve istersen kaydeder.
- **Touch ID ile bağlan** (isteğe bağlı). Kayıtlı parola kullanılmadan önce parmak izi sorulur.
- **Parolasız girişe geç.** Tek tıkla SSH anahtarın sunucuya yüklenir; sonrası parolasız. `scp`, `git`, `mc` da parolasız çalışır.
- **Hızlı bağlan: ⌃⌥S.** Spotlight gibi arama kutusu; birkaç harf yaz, Enter.
- **Terminalden `sshm`.** `sshm web` bağlanır, `sshm web 'df -h'` komut çalıştırır, `sshm` listeyi gösterir. Sekme tamamlama dahil.
- **Dosyalar (Midnight Commander).** Solda Mac'in, sağda sunucu; dosyaları iki panel arasında taşı.
- **Tüneller.** Sunucudaki veritabanını `localhost:5433`'e bağla; menüden aç/kapat.
- **Renkli terminal.** Canlı sunucular kırmızı, test sunucuları yeşil açılsın; yanlış sunucuda komut çalıştırma riski azalır.
- **Kopsa da devam (tmux).** Bağlantı koparsa kaldığın oturuma geri dönersin.
- **`~/.ssh/config`'ten içe aktar.** Mevcut sunucuların tek tıkla gelir.
- **Sağlık panosu (⌘D).** Her sunucunun diski, belleği, yükü, bekleyen güncellemeleri, yeniden başlatma ihtiyacı ve
  çöken servisleri tek tabloda. Menüde her sunucunun yanında yeşil / sarı / kırmızı nokta; arka planda belirli
  aralıklarla (varsayılan 15 dk) kontrol edilir, durum kötüleşince ya da düzelince bildirim gelir. Terminalden: `sshm durum`.
- **Tek tuşla güncelleme.** Ubuntu/Debian sunucularında önce neyin güncelleneceğini gösterir, sonra seçtiğin sunucularda
  güvenle `apt upgrade` yapar (yapılandırma dosyalarına dokunmaz, soru sormaz). **Sadece güvenlik güncellemeleri**
  seçeneği ve 1 dakika sonra (iptal edilebilir) yeniden başlatma dahil.
- **Komut kütüphanesi.** "Disk doluluğu", "En büyük klasörler", "Çöken servisler", "Nginx'i yeniden yükle" gibi hazır
  komutlar, kendi kaydettiğin komutlar; aynı anda birden çok sunucuda çalıştır, çıktıları sunucu sunucu gör.
- **sudo kendiliğinden çözülür.** root musun, parolasız sudo mu var, parola mı gerekiyor; SSHManager kendisi anlar.
  Gerekirse sudo parolası da Anahtar Zinciri'nden gelir, yanlışsa bir kez sorulur.
- **Raycast / Alfred / Kestirmeler:** `sshmanager://connect/web`, `sshmanager://files/web`, `sshmanager://quick`.

## Kurulum

Gerekenler: **macOS 13+** ve Swift (Xcode ya da `xcode-select --install`).

```bash
git clone https://github.com/benysff/ssh-manager.git
cd ssh-manager
./kur.command
```

Uygulama derlenir (Apple Silicon + Intel), **Uygulamalar** klasörüne kurulur ve menü çubuğunda belirir.
İlk bağlantıda macOS iki izin sorar:

- **Terminal'i kontrol etme (Otomasyon):** bağlantıyı Terminal'de açmak için.
- **Erişilebilirlik:** Terminal'de yeni *sekme* açmak için. Vermezsen her bağlantı yeni pencerede açılır.

Terminalden `sshm` komutunu kullanmak için menüden **Ayarlar → Terminal komutunu kur (sshm)**.

## Güvenlik

- Parolalar yalnızca macOS **Anahtar Zinciri**'nde durur (`com.yusuf.sshmanager` servisi, sadece bu cihaz).
  Sunucu listesi `~/Library/Application Support/SSHManager/servers.json` dosyasındadır ve parola içermez.
- **Tek kasa, tek izin.** Bütün sunucu parolaları Anahtar Zinciri'nde *tek bir kayıtta* ("kasa") durur. macOS izni
  kayıt başına sorduğu için 100 sunucun olsa da en fazla **bir kez** sorulur. Eski sürümden gelen sunucu başına
  kayıtlar ilk kullanımda kendiliğinden kasaya taşınır.
- Parola ssh'a `SSH_ASKPASS` üzerinden, doğrudan ve sadece istendiğinde verilir; terminale yazılmaz. Toplu işlerde
  (güncelleme kontrolü, komut çalıştırma) uygulama kasayı bir kez açar ve parolayı ssh'a tek kullanımlık, bellekte
  duran bir boruyla verir; diske yazılmaz, okununca silinir. Touch ID koruması açıksa bir onay bütün işe yeter.
- İlk bağlantıda sunucunun parmak izi native bir pencerede gösterilir ve onayın istenir.
- Anahtar Zinciri erişimi uygulamanın imzasına bağlıdır. Uygulamayı güncellediğinde (yeniden derlediğinde) menüde
  **Parolaların kilidini aç…** belirir; tıklayıp macOS'un sorusuna **Her Zaman İzin Ver** demen yeterli.
- Arka plandaki sağlık kontrolleri **asla pencere açmaz**: kasa kilitliyse ya da bilinmeyen bir parmak izi
  gerekiyorsa o sunucu gri görünür ("Arka planda giriş yapılamadı").
  Canlı (kırmızı temalı) sunucularda sistem değiştiren komutlar için "EVET" yazıp onaylaman istenir.

## Nasıl çalışır?

Aynı program dört rolde çalışır: menü çubuğu uygulaması, `sshm` komutu, ssh'ın parola sorduğu yardımcı
(`SSH_ASKPASS`) ve Midnight Commander için küçük bir ssh ara katmanı. Terminale sadece
`SSHManager connect <sunucu>` gibi kısa bir komut gönderilir; o da bağlantıyı `ssh` ile kurar.

| Klasör | Ne var |
|---|---|
| `Sources/SSHManagerKit` | Sunucu modeli, ssh komutu oluşturma, `~/.ssh/config` okuma, Anahtar Zinciri, uzak betikler (sağlık, güncelleme, sudo), komut kütüphanesi (test edilebilir çekirdek) |
| `Sources/SSHManager` | Menü çubuğu, terminal açıcı, askpass, `sshm`, tüneller, hızlı bağlan, anahtar kurulumu, sağlık izleme, komut ve güncelleme pencereleri |
| `Tests` | Birim testleri (`swift test`) |

Sadece Command Line Tools ile (Xcode'suz) testte "plugin for module 'TestingMacros' not found" hatası alırsan
eklenti klasörünü elle ver:
`swift test -Xswiftc -plugin-path -Xswiftc /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing`

## Lisans

[MIT](LICENSE)

---

### English

SSHManager is a macOS menu bar app that opens SSH connections in the native Terminal (or iTerm2) with one click.
Passwords live in the macOS Keychain and are handed to `ssh` through `SSH_ASKPASS`, so they are never typed into
the terminal. It also offers Touch ID, one-click SSH key setup, a quick-connect palette (⌃⌥S), an `sshm` CLI,
Midnight Commander file browsing, port-forwarding tunnels, colored terminals for production servers, tmux resume
and `~/.ssh/config` import. A health dashboard (⌘D, `sshm durum`) watches disk, memory, load, pending updates and
failed services in the background and notifies you on changes; Ubuntu/Debian servers can be updated safely with one
click (optionally security-only); a command library runs snippets on many servers at once, with sudo detected
automatically (root, passwordless or password sudo). All passwords live in a single Keychain item, so macOS asks
for permission once, not once per server. The UI is in Turkish. Install with `./kur.command` (macOS 13+, Swift required).
