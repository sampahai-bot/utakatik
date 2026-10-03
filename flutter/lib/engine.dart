import 'dart:io';

import 'engine_android.dart';
import 'engine_windows.dart';

enum JobKind { pdfToDocx, pdfToImages, compress }

class JobOptions {
  final String ocrLang; // ind+eng | ind | eng
  final String layout; // editable | preserve | visual
  final String level; // low | medium | high
  final int dpi;
  final String imageFormat; // jpg | png

  const JobOptions({
    this.ocrLang = 'ind+eng',
    this.layout = 'preserve',
    this.level = 'medium',
    this.dpi = 180,
    this.imageFormat = 'jpg',
  });
}

class JobResult {
  final String path; // file atau folder hasil
  final bool isDir;
  final String? note;
  const JobResult(this.path, {this.isDir = false, this.note});
}

typedef ProgressCb = void Function(double progress, String message);

abstract class Engine {
  Future<JobResult> run(
      JobKind kind, String srcPath, String outDir, JobOptions o, ProgressCb cb);

  /// Foto/scan gambar -> DOCX (OCR). Hanya Android.
  Future<JobResult> scanToDocx(
      String imagePath, String outDir, JobOptions o, ProgressCb cb);

  static Engine create() =>
      Platform.isWindows ? WindowsEngine() : AndroidEngine();
}

String stamp() {
  final n = DateTime.now();
  String t(int v) => v.toString().padLeft(2, '0');
  return '${n.year}${t(n.month)}${t(n.day)}_${t(n.hour)}${t(n.minute)}${t(n.second)}';
}
