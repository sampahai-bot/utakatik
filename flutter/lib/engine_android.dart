import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:archive/archive_io.dart';
import 'package:flutter/foundation.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';

import 'docx_writer.dart';
import 'engine.dart';

Uint8List _pngToJpg(List<dynamic> a) {
  final src = img.decodePng(a[0] as Uint8List)!;
  final bg = img.Image(width: src.width, height: src.height, numChannels: 3);
  img.fill(bg, color: img.ColorRgb8(255, 255, 255));
  img.compositeImage(bg, src);
  return Uint8List.fromList(img.encodeJpg(bg, quality: a[1] as int));
}

Uint8List _pngToPng(List<dynamic> a) {
  final src = img.decodePng(a[0] as Uint8List)!;
  final bg = img.Image(width: src.width, height: src.height, numChannels: 3);
  img.fill(bg, color: img.ColorRgb8(255, 255, 255));
  img.compositeImage(bg, src);
  return Uint8List.fromList(img.encodePng(bg));
}

class _Pg {
  final Uint8List jpeg;
  final int w, h;
  _Pg(this.jpeg, this.w, this.h);
}

class _Ln {
  final String text;
  final double x0, x1, top, bottom;
  double size;
  _Ln(this.text, this.x0, this.x1, this.top, this.bottom, this.size);
}

/// Engine Dart murni untuk Android: render dengan Printing.raster,
/// OCR dengan ML Kit (offline di perangkat).
class AndroidEngine implements Engine {
  double _pseudo(int n) => 1 - 1 / (1 + n * 0.12);

  Stream<_Pg> _pages(Uint8List pdf, double dpi, int quality, ProgressCb cb,
      String label) async* {
    var n = 0;
    await for (final r in Printing.raster(pdf, dpi: dpi)) {
      final png = await r.toPng();
      final jpg = await compute(_pngToJpg, [png, quality]);
      n++;
      cb(_pseudo(n) * 0.85, '$label halaman $n');
      yield _Pg(jpg, r.width, r.height);
    }
  }

  @override
  Future<JobResult> run(JobKind kind, String srcPath, String outDir,
      JobOptions o, ProgressCb cb) async {
    await Directory(outDir).create(recursive: true);
    final bytes = await File(srcPath).readAsBytes();
    final base = p.basenameWithoutExtension(srcPath);
    final tag = stamp();
    switch (kind) {
      case JobKind.pdfToImages:
        final dir = p.join(outDir, '${base}_$tag');
        await Directory(dir).create(recursive: true);
        var n = 0;
        await for (final r in Printing.raster(bytes, dpi: o.dpi.toDouble())) {
          final png = await r.toPng();
          n++;
          final name = 'halaman_${n.toString().padLeft(4, '0')}';
          if (o.imageFormat == 'png') {
            final out = await compute(_pngToPng, [png]);
            await File(p.join(dir, '$name.png')).writeAsBytes(out);
          } else {
            final out = await compute(_pngToJpg, [png, 92]);
            await File(p.join(dir, '$name.jpg')).writeAsBytes(out);
          }
          cb(_pseudo(n), 'Halaman $n');
        }
        if (n == 0) throw Exception('PDF tidak dapat dibaca.');
        return JobResult(dir, isDir: true);

      case JobKind.compress:
        const presets = {
          'low': [150.0, 85],
          'medium': [110.0, 70],
          'high': [80.0, 55],
        };
        final pr = presets[o.level]!;
        final dpi = pr[0] as double;
        final doc = pw.Document();
        var n = 0;
        await for (final pg in _pages(bytes, dpi, pr[1] as int, cb, 'Kompres')) {
          n++;
          final fmt = PdfPageFormat(pg.w * 72 / dpi, pg.h * 72 / dpi);
          final image = pw.MemoryImage(pg.jpeg);
          doc.addPage(pw.Page(
            pageFormat: fmt,
            margin: pw.EdgeInsets.zero,
            build: (_) => pw.Image(image, fit: pw.BoxFit.fill),
          ));
        }
        if (n == 0) throw Exception('PDF tidak dapat dibaca.');
        final out = p.join(outDir, '${base}_kompres_$tag.pdf');
        final res = await doc.save();
        if (res.length >= bytes.length) {
          await File(srcPath).copy(out);
          return JobResult(out,
              note: 'File sudah efisien; hasil tidak lebih kecil sehingga '
                  'salinan asli disimpan.');
        }
        await File(out).writeAsBytes(res);
        return JobResult(out,
            note: 'Di Android, kompres mengubah halaman menjadi gambar '
                '(teks tidak lagi dapat dipilih/dicari).');

      case JobKind.pdfToDocx:
        final out = p.join(outDir, '${base}_$tag.docx');
        final tmp = await getTemporaryDirectory();
        final recognizer = TextRecognizer(script: TextRecognitionScript.latin);
        final pages = <DocxPage>[];
        var n = 0;
        try {
          await for (final pg in _pages(bytes, 200, 90, cb, 'OCR')) {
            n++;
            pages.add(await _buildPage(pg, 200, o.layout, recognizer, tmp, n));
          }
        } finally {
          await recognizer.close();
        }
        if (pages.isEmpty) throw Exception('PDF tidak dapat dibaca.');
        await File(out).writeAsBytes(buildDocx(pages));
        return JobResult(out,
            note: 'Di Android teks dibaca dengan OCR; periksa kembali ejaan '
                'dan tabel pada hasilnya.');
    }
  }

  @override
  Future<JobResult> scanToDocx(
      String imagePath, String outDir, JobOptions o, ProgressCb cb) async {
    await Directory(outDir).create(recursive: true);
    final bytes = await File(imagePath).readAsBytes();
    final codec = await ui.instantiateImageCodec(bytes);
    final frame = await codec.getNextFrame();
    final w = frame.image.width, h = frame.image.height;
    cb(0.2, 'Membaca teks…');
    final recognizer = TextRecognizer(script: TextRecognitionScript.latin);
    try {
      final dpi = math.max(w, h) / 11.0; // anggap sisi panjang ~ A4
      final tmp = await getTemporaryDirectory();
      final pg = await _buildPage(
          _Pg(bytes, w, h), dpi, o.layout == 'visual' ? 'visual' : 'editable',
          recognizer, tmp, 0, pathOverride: imagePath);
      final tag = stamp();
      final docx = p.join(outDir, 'scan_$tag.docx');
      await File(docx).writeAsBytes(buildDocx([pg]));
      // PDF dari foto
      final doc = pw.Document();
      final image = pw.MemoryImage(bytes);
      doc.addPage(pw.Page(
        pageFormat: PdfPageFormat(w * 72 / dpi, h * 72 / dpi),
        margin: pw.EdgeInsets.zero,
        build: (_) => pw.Image(image, fit: pw.BoxFit.fill),
      ));
      final pdfPath = p.join(outDir, 'scan_$tag.pdf');
      await File(pdfPath).writeAsBytes(await doc.save());
      cb(1, 'Selesai');
      return JobResult(docx, note: 'PDF foto juga disimpan: ${p.basename(pdfPath)}');
    } finally {
      await recognizer.close();
    }
  }

  Future<DocxPage> _buildPage(_Pg pg, double dpi, String layout,
      TextRecognizer rec, Directory tmp, int no,
      {String? pathOverride}) async {
    final k = 72 / dpi;
    final pw_ = pg.w * k, ph_ = pg.h * k;
    if (layout == 'visual') {
      return DocxPage(pw_, ph_, [DocxPic(pg.jpeg, pw_, ph_ - 2)],
          left: 0, right: 0, top: 0, bottom: 0);
    }
    var path = pathOverride;
    File? tmpFile;
    if (path == null) {
      tmpFile = File(p.join(tmp.path, 'ocr_$no.jpg'));
      await tmpFile.writeAsBytes(pg.jpeg);
      path = tmpFile.path;
    }
    final result = await rec.processImage(InputImage.fromFilePath(path));
    if (tmpFile != null && tmpFile.existsSync()) tmpFile.deleteSync();

    final lines = <_Ln>[];
    for (final b in result.blocks) {
      for (final l in b.lines) {
        final r = l.boundingBox;
        final t = l.text.trim();
        if (t.isEmpty) continue;
        lines.add(_Ln(t, r.left * k, r.right * k, r.top * k, r.bottom * k,
            math.max(6.0, r.height * k * 0.8)));
      }
    }
    if (lines.isEmpty) {
      return DocxPage(pw_, ph_, [DocxPic(pg.jpeg, pw_ - 72, (ph_ - 72) * 1.0)]);
    }
    lines.sort((a, b) => a.top.compareTo(b.top));
    final sizes = lines.map((e) => e.size).toList()..sort();
    final med = sizes[sizes.length ~/ 2];
    for (final l in lines) {
      if (l.size >= 0.7 * med && l.size <= 1.3 * med) l.size = med;
    }
    var left = lines.map((e) => e.x0).reduce(math.min);
    var right = pw_ - lines.map((e) => e.x1).reduce(math.max);
    final top = math.max(14.0, lines.first.top);
    left = math.max(14.0, left);
    right = math.max(14.0, right);
    if (left + right > pw_ * 0.6) {
      left = 36;
      right = 36;
    }
    final textW = pw_ - left - right;
    final items = <DocxItem>[];
    _Ln? prev;
    var cursor = top;
    final preserve = layout == 'preserve';
    DocxPara? cur;
    final curText = StringBuffer();
    void flush() {
      if (cur != null) {
        final c = cur!;
        items.add(DocxPara(curText.toString(),
            sizePt: c.sizePt,
            bold: c.bold,
            align: c.align,
            indentPt: c.indentPt,
            beforePt: c.beforePt));
        cur = null;
        curText.clear();
      }
    }

    for (final l in lines) {
      final center = (l.x0 + l.x1) / 2;
      var align = 'left';
      if ((center - (left + textW / 2)).abs() < textW * 0.03 &&
          (l.x1 - l.x0) < textW * 0.85 &&
          l.x0 - left > textW * 0.05) {
        align = 'center';
      } else if ((left + textW) - l.x1 < textW * 0.02 &&
          l.x0 - left > textW * 0.25) {
        align = 'right';
      }
      if (preserve) {
        items.add(DocxPara(l.text,
            sizePt: l.size,
            align: align,
            indentPt: align == 'left' ? math.max(0, l.x0 - left) : 0,
            beforePt: math.max(0, l.top - cursor),
            exactLinePt: math.max(6, l.size * 1.15)));
        cursor = math.max(cursor, l.top) + math.max(6, l.size * 1.15);
      } else {
        var cont = false;
        if (cur != null && prev != null) {
          final gap = l.top - prev.bottom;
          cont = gap < l.size * 0.6 &&
              (l.size - prev.size).abs() < 1.2 &&
              prev.x1 >= left + textW * 0.8 &&
              (l.x0 - prev.x0) <= l.size * 1.5 &&
              align == 'left' &&
              cur!.align == 'left';
        }
        if (cont) {
          final s = curText.toString();
          if (s.endsWith('-') && s.length > 1) {
            curText
              ..clear()
              ..write(s.substring(0, s.length - 1))
              ..write(l.text);
          } else {
            curText
              ..write(' ')
              ..write(l.text);
          }
        } else {
          flush();
          cur = DocxPara('',
              sizePt: l.size,
              align: align,
              indentPt:
                  (align == 'left' && l.x0 - left > l.size * 1.2) ? l.x0 - left : 0,
              beforePt: prev == null
                  ? 0
                  : math.min(24.0, math.max(2.0, l.top - prev.bottom)));
          curText.write(l.text);
        }
      }
      prev = l;
    }
    flush();
    return DocxPage(pw_, ph_, items,
        left: left, right: right, top: top, bottom: 14);
  }
}

/// Zip sebuah folder (untuk menyimpan hasil gambar di Android).
Future<Uint8List> zipDirectory(String dir) async {
  final ar = Archive();
  for (final f in Directory(dir).listSync().whereType<File>()) {
    final data = await f.readAsBytes();
    ar.addFile(ArchiveFile(p.basename(f.path), data.length, data));
  }
  return Uint8List.fromList(ZipEncoder().encode(ar)!);
}
