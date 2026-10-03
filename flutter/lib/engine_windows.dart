import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'engine.dart';

/// Menjalankan engine Python (pdf_engine.exe) yang dibundel di folder `engine`
/// di sebelah aplikasi.
class WindowsEngine implements Engine {
  String get _exe => p.join(
      File(Platform.resolvedExecutable).parent.path, 'engine', 'pdf_engine.exe');

  @override
  Future<JobResult> run(JobKind kind, String srcPath, String outDir,
      JobOptions o, ProgressCb cb) async {
    final exe = _exe;
    if (!File(exe).existsSync()) {
      throw Exception('Engine tidak ditemukan: $exe. Pasang ulang aplikasi.');
    }
    final base = p.basenameWithoutExtension(srcPath);
    final tag = stamp();
    late List<String> args;
    late String out;
    var isDir = false;
    switch (kind) {
      case JobKind.pdfToDocx:
        out = p.join(outDir, '${base}_$tag.docx');
        args = ['pdf2docx', srcPath, out, '--ocr', o.ocrLang, '--layout', o.layout];
        break;
      case JobKind.pdfToImages:
        out = p.join(outDir, '${base}_$tag');
        isDir = true;
        args = [
          'pdf2images', srcPath, out,
          '--dpi', '${o.dpi}', '--format', o.imageFormat,
        ];
        break;
      case JobKind.compress:
        out = p.join(outDir, '${base}_kompres_$tag.pdf');
        args = ['compress', srcPath, out, '--level', o.level];
        break;
    }
    await Directory(outDir).create(recursive: true);
    final proc = await Process.start(exe, args,
        environment: {'PYTHONIOENCODING': 'utf-8'});
    String? error;
    final warnings = <String>[];
    final done = proc.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .forEach((line) {
      try {
        final m = jsonDecode(line) as Map<String, dynamic>;
        if (m['progress'] != null) {
          cb((m['progress'] as num).toDouble(), (m['msg'] ?? '') as String);
        } else if (m['warning'] != null) {
          warnings.add(m['warning'] as String);
        } else if (m['error'] != null) {
          error = m['error'] as String;
        }
      } catch (_) {}
    });
    final errText = proc.stderr.transform(utf8.decoder).join();
    final code = await proc.exitCode;
    await done;
    final stderrText = await errText;
    if (code != 0 || error != null) {
      throw Exception(error ?? 'Engine gagal (kode $code). $stderrText');
    }
    return JobResult(out,
        isDir: isDir, note: warnings.isEmpty ? null : warnings.join('\n'));
  }

  @override
  Future<JobResult> scanToDocx(
      String imagePath, String outDir, JobOptions o, ProgressCb cb) {
    throw UnsupportedError('Scan kamera hanya tersedia di Android.');
  }
}
