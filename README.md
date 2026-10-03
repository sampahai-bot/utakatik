# PDF Office Converter

Aplikasi offline untuk **Android** dan **Windows**: PDF → DOCX (+OCR), PDF → JPEG/PNG, kompres PDF, scan kamera (Android).

## Cara mendapatkan APK dan installer Windows (tanpa install apa pun di komputer)
1. Buat akun GitHub (gratis) dan repositori baru (boleh privat).
2. Unggah **seluruh isi** folder ini ke repositori (tombol *Add file → Upload files*; pastikan folder `.github` ikut terunggah).
3. Buka tab **Actions**. Build berjalan otomatis; atau pilih *Build PDF Office Converter → Run workflow*. Tunggu ±15–25 menit.
4. Buka tab **Releases** (sisi kanan halaman repositori). Unduh:
   - `PDF-Office-Converter.apk` → buka di Android (izinkan "install dari sumber ini").
   - `PDF-Office-Converter-Setup.exe` → jalankan di Windows (tanpa hak admin). Tersedia juga versi `Portable.zip`.

## Arsitektur
- `flutter/` — UI lintas platform. Folder `android/` dan `windows/` dibuat otomatis oleh CI (`flutter create`).
- Windows: UI memanggil engine Python `windows_engine/converter.py` (dibundel sebagai `engine/pdf_engine.exe` + Tesseract Indonesia/Inggris).
- Android: engine Dart murni (`engine_android.dart`) — render `printing`, OCR ML Kit di perangkat, penulis DOCX sendiri (`docx_writer.dart`).

## Mode PDF → DOCX
- **Editable**: teks mengalir sebagai alinea (heading, rata tengah/kanan, tabel pada Windows).
- **Pertahankan tata letak**: posisi baris, tab kolom, tabel, logo/stempel/tanda tangan, garis kop.
- **Visual persis**: gambar halaman penuh (tidak bisa diedit).
- Halaman hasil pindai otomatis di-OCR.

## Batasan yang jujur
- PDF → DOCX yang identik 100% dan sekaligus 100% editable tidak mungkin untuk semua PDF; gunakan mode Visual untuk kemiripan mutlak.
- Windows: kompres menyusun ulang struktur PDF dan mengecilkan gambar (teks tetap dapat dipilih). Android: kompres mengubah halaman menjadi gambar.
- Android: DOCX berasal dari OCR; tabel tidak dikenali sebagai tabel.
- Build CI belum pernah dijalankan oleh penyusun paket ini; jika ada langkah gagal, kirim log Actions-nya untuk diperbaiki.

Uji engine Windows (Python) telah dijalankan di Linux: 60 halaman → 60 halaman, OCR hasil pindai, tabel, stempel, kop surat, kompres PDF gambar 71 MB → 0,7–13 MB.
