import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'engine.dart';

class HistoryItem {
  final String name;
  final String tool;
  final String path;
  final bool isDir;
  final int time;
  HistoryItem(this.name, this.tool, this.path, this.isDir, this.time);

  Map<String, dynamic> toJson() =>
      {'n': name, 't': tool, 'p': path, 'd': isDir, 'x': time};
  factory HistoryItem.fromJson(Map<String, dynamic> j) => HistoryItem(
      j['n'] as String, j['t'] as String, j['p'] as String, j['d'] as bool,
      j['x'] as int);
}

class Store {
  static late SharedPreferences _p;
  static Future<void> init() async => _p = await SharedPreferences.getInstance();

  static String get ocrLang => _p.getString('ocr') ?? 'ind+eng';
  static set ocrLang(String v) => _p.setString('ocr', v);
  static String get layout => _p.getString('layout') ?? 'preserve';
  static set layout(String v) => _p.setString('layout', v);
  static String get level => _p.getString('level') ?? 'medium';
  static set level(String v) => _p.setString('level', v);
  static int get dpi => _p.getInt('dpi') ?? 180;
  static set dpi(int v) => _p.setInt('dpi', v);
  static String get imageFormat => _p.getString('fmt') ?? 'jpg';
  static set imageFormat(String v) => _p.setString('fmt', v);

  static JobOptions get options => JobOptions(
      ocrLang: ocrLang, layout: layout, level: level, dpi: dpi, imageFormat: imageFormat);

  static List<HistoryItem> get history {
    final raw = _p.getStringList('history') ?? [];
    final out = <HistoryItem>[];
    for (final s in raw) {
      try {
        out.add(HistoryItem.fromJson(jsonDecode(s) as Map<String, dynamic>));
      } catch (_) {}
    }
    return out;
  }

  static Future<void> addHistory(HistoryItem h) async {
    final raw = _p.getStringList('history') ?? [];
    raw.insert(0, jsonEncode(h.toJson()));
    await _p.setStringList('history', raw.take(100).toList());
  }

  static Future<void> removeHistory(int index) async {
    final raw = _p.getStringList('history') ?? [];
    if (index < raw.length) raw.removeAt(index);
    await _p.setStringList('history', raw);
  }

  static Future<void> clearHistory() async => _p.remove('history');
}
