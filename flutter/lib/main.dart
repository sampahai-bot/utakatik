import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'engine.dart';
import 'engine_android.dart' show zipDirectory;
import 'store.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Store.init();
  runApp(const PdfOfficeConverter());
}

class PdfOfficeConverter extends StatelessWidget {
  const PdfOfficeConverter({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
        debugShowCheckedModeBanner: false,
        title: 'PDF Office Converter',
        theme: ThemeData(
            useMaterial3: true,
            colorSchemeSeed: const Color(0xFF174A7E),
            scaffoldBackgroundColor: const Color(0xFFF5F7FA)),
        home: const HomePage(),
      );
}

Future<String> outputDir() async {
  final base = Platform.isWindows
      ? await getApplicationDocumentsDirectory()
      : await getApplicationDocumentsDirectory();
  final d = Directory(p.join(base.path, 'PDF Office Converter', 'Output'));
  await d.create(recursive: true);
  return d.path;
}

Future<void> openResult(BuildContext context, String path, bool isDir) async {
  try {
    if (Platform.isWindows) {
      if (isDir) {
        await Process.run('explorer.exe', [path]);
      } else {
        await Process.run('explorer.exe', ['/select,', path]);
      }
    } else if (!isDir) {
      await OpenFilex.open(path);
    }
  } catch (e) {
    if (context.mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Gagal membuka: $e')));
    }
  }
}

/// Android: simpan ke lokasi pilihan pengguna (mis. Download).
Future<void> saveAs(BuildContext context, String path, bool isDir) async {
  try {
    final bytes = isDir ? await zipDirectory(path) : await File(path).readAsBytes();
    final name = isDir ? '${p.basename(path)}.zip' : p.basename(path);
    final res = await FilePicker.platform
        .saveFile(dialogTitle: 'Simpan hasil', fileName: name, bytes: bytes);
    if (res != null && context.mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Tersimpan.')));
    }
  } catch (e) {
    if (context.mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Gagal menyimpan: $e')));
    }
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});
  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  int tab = 0;
  final key = GlobalKey<_ConverterViewState>();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Colors.white,
        title: const Text('PDF Office Converter',
            style: TextStyle(fontWeight: FontWeight.w800)),
        actions: const [
          Padding(
              padding: EdgeInsets.only(right: 14),
              child: Chip(
                  avatar: Icon(Icons.lock_outline, size: 16),
                  label: Text('Offline')))
        ],
      ),
      body: IndexedStack(index: tab, children: [
        ConverterView(key: key, onDone: () => setState(() {})),
        HistoryView(visible: tab == 1),
        const SettingsView(),
      ]),
      bottomNavigationBar: NavigationBar(
        selectedIndex: tab,
        onDestinationSelected: (v) => setState(() => tab = v),
        destinations: const [
          NavigationDestination(icon: Icon(Icons.home_outlined), selectedIcon: Icon(Icons.home), label: 'Beranda'),
          NavigationDestination(icon: Icon(Icons.history), label: 'Riwayat'),
          NavigationDestination(icon: Icon(Icons.settings_outlined), selectedIcon: Icon(Icons.settings), label: 'Pengaturan'),
        ],
      ),
    );
  }
}

class ConverterView extends StatefulWidget {
  final VoidCallback onDone;
  const ConverterView({super.key, required this.onDone});
  @override
  State<ConverterView> createState() => _ConverterViewState();
}

class _ConverterViewState extends State<ConverterView> {
  JobKind kind = JobKind.pdfToDocx;
  String? filePath;
  String? fileName;
  bool processing = false;
  double progress = 0;
  String message = '';
  String? error;
  JobResult? result;
  late String layout = Store.layout;
  late String level = Store.level;
  late String imgFormat = Store.imageFormat;
  late int dpi = Store.dpi;

  String get toolName => switch (kind) {
        JobKind.pdfToDocx => 'PDF → DOCX',
        JobKind.pdfToImages => 'PDF → Gambar',
        JobKind.compress => 'Kompres PDF',
      };

  Future<void> pickPdf() async {
    final r = await FilePicker.platform.pickFiles(
        type: FileType.custom, allowedExtensions: ['pdf'], withData: false);
    final f = r?.files.single;
    if (f?.path != null) {
      setState(() {
        filePath = f!.path;
        fileName = f.name;
        result = null;
        error = null;
      });
    }
  }

  Future<void> run() async {
    if (filePath == null) {
      await pickPdf();
      if (filePath == null) return;
    }
    await _execute((engine, out, o, cb) => engine.run(kind, filePath!, out, o, cb),
        fileName ?? 'dokumen.pdf', toolName);
  }

  Future<void> scan() async {
    final x = await ImagePicker()
        .pickImage(source: ImageSource.camera, imageQuality: 92);
    if (x == null) return;
    await _execute((engine, out, o, cb) => engine.scanToDocx(x.path, out, o, cb),
        p.basename(x.path), 'Scan + OCR');
  }

  Future<void> _execute(
      Future<JobResult> Function(Engine, String, JobOptions, ProgressCb) job,
      String name,
      String tool) async {
    setState(() {
      processing = true;
      progress = 0;
      message = 'Memulai…';
      error = null;
      result = null;
    });
    try {
      final out = await outputDir();
      final o = JobOptions(
          ocrLang: Store.ocrLang, layout: layout, level: level, dpi: dpi, imageFormat: imgFormat);
      final res = await job(Engine.create(), out, o, (pr, msg) {
        if (mounted) {
          setState(() {
            progress = pr.clamp(0.0, 1.0);
            message = msg;
          });
        }
      });
      await Store.addHistory(HistoryItem(name, tool, res.path, res.isDir,
          DateTime.now().millisecondsSinceEpoch));
      if (mounted) setState(() => result = res);
      widget.onDone();
    } catch (e) {
      if (mounted) setState(() => error = e.toString().replaceFirst('Exception: ', ''));
    } finally {
      if (mounted) setState(() => processing = false);
    }
  }

  Widget toolCard(IconData icon, String title, String desc, JobKind k) {
    final sel = kind == k;
    return Card(
      elevation: 0,
      color: sel ? Theme.of(context).colorScheme.primaryContainer.withOpacity(.45) : Colors.white,
      shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(18),
          side: BorderSide(
              color: sel ? Theme.of(context).colorScheme.primary : Colors.grey.shade200,
              width: sel ? 2 : 1)),
      child: InkWell(
        borderRadius: BorderRadius.circular(18),
        onTap: processing ? null : () => setState(() { kind = k; result = null; error = null; }),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(children: [
            Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.primaryContainer,
                    borderRadius: BorderRadius.circular(14)),
                child: Icon(icon)),
            const SizedBox(width: 14),
            Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
              const SizedBox(height: 3),
              Text(desc, style: const TextStyle(color: Colors.black54)),
            ])),
            if (sel) const Icon(Icons.check_circle),
          ]),
        ),
      ),
    );
  }

  Widget seg(String label, List<(String, String)> opts, String value, void Function(String) on) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(label, style: const TextStyle(fontWeight: FontWeight.w600)),
      const SizedBox(height: 6),
      SegmentedButton<String>(
        showSelectedIcon: false,
        segments: [for (final o in opts) ButtonSegment(value: o.$1, label: Text(o.$2))],
        selected: {value},
        onSelectionChanged: processing ? null : (s) => setState(() => on(s.first)),
      ),
    ]);
  }

  Widget options() {
    switch (kind) {
      case JobKind.pdfToDocx:
        return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          seg('Mode hasil', const [
            ('editable', 'Editable'),
            ('preserve', 'Pertahankan tata letak'),
            ('visual', 'Visual persis'),
          ], layout, (v) => layout = v),
          const SizedBox(height: 6),
          Text(
              switch (layout) {
                'editable' => 'Teks mengalir sebagai alinea biasa — paling mudah diedit.',
                'visual' => 'Halaman sama persis sebagai gambar — tidak dapat diedit.',
                _ => 'Posisi teks, tabel, logo, dan stempel dipertahankan sedekat mungkin.',
              },
              style: const TextStyle(color: Colors.black54, fontSize: 12.5)),
        ]);
      case JobKind.pdfToImages:
        return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          seg('Format', const [('jpg', 'JPEG'), ('png', 'PNG')], imgFormat, (v) => imgFormat = v),
          const SizedBox(height: 12),
          seg('Resolusi', const [('120', '120 dpi'), ('180', '180 dpi'), ('300', '300 dpi')],
              '$dpi', (v) => dpi = int.parse(v)),
        ]);
      case JobKind.compress:
        return seg('Tingkat kompres', const [
          ('low', 'Rendah'),
          ('medium', 'Sedang'),
          ('high', 'Tinggi'),
        ], level, (v) => level = v);
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListView(padding: const EdgeInsets.fromLTRB(18, 18, 18, 30), children: [
      Text('Kelola dokumen lebih cepat',
          style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w800)),
      const SizedBox(height: 5),
      const Text('Konversi, OCR, scan, dan kompres dokumen di perangkat Anda.'),
      const SizedBox(height: 16),
      toolCard(Icons.description_outlined, 'PDF → DOCX + OCR',
          'Dokumen Word dengan pilihan tata letak.', JobKind.pdfToDocx),
      toolCard(Icons.image_outlined, 'PDF → JPEG / PNG',
          'Ekspor tiap halaman menjadi gambar.', JobKind.pdfToImages),
      toolCard(Icons.compress, 'Kompres PDF',
          'Kecilkan ukuran file untuk dikirim.', JobKind.compress),
      const SizedBox(height: 12),
      Card(
        elevation: 0,
        color: Colors.white,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              const Icon(Icons.picture_as_pdf_outlined),
              const SizedBox(width: 10),
              Expanded(
                  child: Text(fileName ?? 'Belum ada file dipilih',
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.w600))),
              TextButton(onPressed: processing ? null : pickPdf, child: const Text('Pilih PDF')),
            ]),
            const Divider(height: 24),
            options(),
          ]),
        ),
      ),
      const SizedBox(height: 14),
      FilledButton.icon(
        onPressed: processing ? null : run,
        icon: const Icon(Icons.play_arrow),
        label: Text('Mulai — $toolName'),
        style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
      ),
      if (Platform.isAndroid) ...[
        const SizedBox(height: 10),
        OutlinedButton.icon(
          onPressed: processing ? null : scan,
          icon: const Icon(Icons.document_scanner_outlined),
          label: const Text('Scan kamera + OCR → DOCX'),
          style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(48)),
        ),
      ],
      if (processing) ...[
        const SizedBox(height: 18),
        LinearProgressIndicator(value: progress > 0 ? progress : null),
        const SizedBox(height: 6),
        Text(message),
      ],
      if (error != null) ...[
        const SizedBox(height: 18),
        Card(
          color: Colors.red.shade50,
          elevation: 0,
          child: Padding(
              padding: const EdgeInsets.all(14),
              child: Text('Gagal: $error', style: TextStyle(color: Colors.red.shade900))),
        ),
      ],
      if (result != null) ...[
        const SizedBox(height: 18),
        Card(
          color: Colors.green.shade50,
          elevation: 0,
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('Selesai', style: TextStyle(fontWeight: FontWeight.w800)),
              const SizedBox(height: 4),
              Text(p.basename(result!.path)),
              if (result!.note != null) ...[
                const SizedBox(height: 6),
                Text(result!.note!, style: const TextStyle(fontSize: 12.5, color: Colors.black54)),
              ],
              const SizedBox(height: 10),
              Wrap(spacing: 8, children: [
                if (!result!.isDir || Platform.isWindows)
                  FilledButton.tonal(
                      onPressed: () => openResult(context, result!.path, result!.isDir),
                      child: Text(Platform.isWindows ? 'Tampilkan di folder' : 'Buka')),
                if (Platform.isAndroid)
                  FilledButton.tonal(
                      onPressed: () => saveAs(context, result!.path, result!.isDir),
                      child: const Text('Simpan ke…')),
              ]),
            ]),
          ),
        ),
      ],
    ]);
  }
}

class HistoryView extends StatefulWidget {
  final bool visible;
  const HistoryView({super.key, required this.visible});
  @override
  State<HistoryView> createState() => _HistoryViewState();
}

class _HistoryViewState extends State<HistoryView> {
  @override
  Widget build(BuildContext context) {
    final items = Store.history;
    if (items.isEmpty) {
      return const Center(child: Text('Belum ada riwayat.'));
    }
    return Column(children: [
      Align(
        alignment: Alignment.centerRight,
        child: TextButton(
            onPressed: () async {
              await Store.clearHistory();
              setState(() {});
            },
            child: const Text('Hapus semua')),
      ),
      Expanded(
        child: ListView.builder(
          itemCount: items.length,
          itemBuilder: (c, i) {
            final h = items[i];
            final t = DateTime.fromMillisecondsSinceEpoch(h.time);
            final exists = h.isDir ? Directory(h.path).existsSync() : File(h.path).existsSync();
            return ListTile(
              leading: Icon(h.isDir ? Icons.folder_outlined : Icons.insert_drive_file_outlined),
              title: Text(p.basename(h.path), overflow: TextOverflow.ellipsis),
              subtitle: Text('${h.tool} • ${t.day}/${t.month}/${t.year} '
                  '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}'
                  '${exists ? '' : ' • file tidak ada'}'),
              onTap: exists ? () => openResult(context, h.path, h.isDir) : null,
              trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                if (Platform.isAndroid && exists)
                  IconButton(
                      icon: const Icon(Icons.save_alt),
                      onPressed: () => saveAs(context, h.path, h.isDir)),
                IconButton(
                    icon: const Icon(Icons.delete_outline),
                    onPressed: () async {
                      await Store.removeHistory(i);
                      setState(() {});
                    }),
              ]),
            );
          },
        ),
      ),
    ]);
  }
}

class SettingsView extends StatefulWidget {
  const SettingsView({super.key});
  @override
  State<SettingsView> createState() => _SettingsViewState();
}

class _SettingsViewState extends State<SettingsView> {
  @override
  Widget build(BuildContext context) {
    return ListView(padding: const EdgeInsets.all(18), children: [
      const Text('Bahasa OCR', style: TextStyle(fontWeight: FontWeight.w700)),
      const SizedBox(height: 8),
      SegmentedButton<String>(
        showSelectedIcon: false,
        segments: const [
          ButtonSegment(value: 'ind+eng', label: Text('Indonesia + Inggris')),
          ButtonSegment(value: 'ind', label: Text('Indonesia')),
          ButtonSegment(value: 'eng', label: Text('Inggris')),
        ],
        selected: {Store.ocrLang},
        onSelectionChanged: (s) => setState(() => Store.ocrLang = s.first),
      ),
      if (Platform.isAndroid)
        const Padding(
          padding: EdgeInsets.only(top: 6),
          child: Text('Di Android, OCR otomatis mengenali huruf Latin (termasuk bahasa Indonesia).',
              style: TextStyle(color: Colors.black54, fontSize: 12.5)),
        ),
      const SizedBox(height: 24),
      const Text('Folder hasil', style: TextStyle(fontWeight: FontWeight.w700)),
      const SizedBox(height: 6),
      FutureBuilder<String>(
        future: outputDir(),
        builder: (c, s) => SelectableText(s.data ?? '…'),
      ),
      const SizedBox(height: 24),
      const Text('Privasi', style: TextStyle(fontWeight: FontWeight.w700)),
      const SizedBox(height: 6),
      const Text('Semua pemrosesan dilakukan di perangkat ini. Tidak ada file yang dikirim ke server.'),
      const SizedBox(height: 24),
      const Text('Versi 1.0.0'),
    ]);
  }
}
