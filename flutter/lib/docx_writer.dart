import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';

/// Penulis DOCX minimal (tanpa dependensi native).
abstract class DocxItem {}

class DocxPara extends DocxItem {
  final String text;
  final double sizePt;
  final bool bold;
  final String align; // left | center | right
  final double indentPt;
  final double beforePt;
  final double? exactLinePt;
  DocxPara(this.text,
      {this.sizePt = 11,
      this.bold = false,
      this.align = 'left',
      this.indentPt = 0,
      this.beforePt = 0,
      this.exactLinePt});
}

class DocxPic extends DocxItem {
  final Uint8List jpeg;
  final double wPt;
  final double hPt;
  final double indentPt;
  final double beforePt;
  DocxPic(this.jpeg, this.wPt, this.hPt, {this.indentPt = 0, this.beforePt = 0});
}

class DocxPage {
  final double wPt, hPt;
  final double left, right, top, bottom;
  final List<DocxItem> items;
  DocxPage(this.wPt, this.hPt, this.items,
      {this.left = 36, this.right = 36, this.top = 36, this.bottom = 14});
}

String _esc(String s) => s
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll(RegExp(r'[\u0000-\u0008\u000B\u000C\u000E-\u001F]'), '');

int _tw(double pt) => (pt * 20).round();
int _emu(double pt) => (pt * 12700).round();

Uint8List buildDocx(List<DocxPage> pages) {
  final media = <String, Uint8List>{};
  final rels = StringBuffer();
  var imgN = 0;
  final body = StringBuffer();

  String sect(DocxPage pg) =>
      '<w:sectPr><w:pgSz w:w="${_tw(pg.wPt)}" w:h="${_tw(pg.hPt)}"'
      '${pg.wPt > pg.hPt ? ' w:orient="landscape"' : ''}/>'
      '<w:pgMar w:top="${_tw(pg.top)}" w:right="${_tw(pg.right)}" '
      'w:bottom="${_tw(pg.bottom)}" w:left="${_tw(pg.left)}" '
      'w:header="0" w:footer="0" w:gutter="0"/></w:sectPr>';

  for (var pi = 0; pi < pages.length; pi++) {
    final pg = pages[pi];
    final isLastPage = pi == pages.length - 1;
    final items = pg.items.isEmpty ? <DocxItem>[DocxPara('')] : pg.items;
    for (var ii = 0; ii < items.length; ii++) {
      final it = items[ii];
      final sectXml = (ii == items.length - 1 && !isLastPage) ? sect(pg) : '';
      if (it is DocxPara) {
        final line = it.exactLinePt != null
            ? ' w:line="${_tw(it.exactLinePt!)}" w:lineRule="exact"'
            : '';
        final jc = it.align == 'left' ? '' : '<w:jc w:val="${it.align}"/>';
        final ind = it.indentPt > 0 ? '<w:ind w:left="${_tw(it.indentPt)}"/>' : '';
        final sz = (it.sizePt * 2).round().clamp(12, 144);
        body.write('<w:p><w:pPr><w:spacing w:before="${_tw(it.beforePt)}" '
            'w:after="0"$line/>$ind$jc$sectXml</w:pPr>');
        if (it.text.isNotEmpty) {
          body.write('<w:r><w:rPr><w:rFonts w:ascii="Arial" w:hAnsi="Arial" '
              'w:cs="Arial"/>${it.bold ? '<w:b/>' : ''}<w:sz w:val="$sz"/></w:rPr>'
              '<w:t xml:space="preserve">${_esc(it.text)}</w:t></w:r>');
        }
        body.write('</w:p>');
      } else if (it is DocxPic) {
        imgN++;
        final name = 'image$imgN.jpg';
        media[name] = it.jpeg;
        rels.write('<Relationship Id="rIdImg$imgN" '
            'Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/image" '
            'Target="media/$name"/>');
        final cx = _emu(it.wPt), cy = _emu(it.hPt);
        final ind = it.indentPt > 0 ? '<w:ind w:left="${_tw(it.indentPt)}"/>' : '';
        body.write('<w:p><w:pPr><w:spacing w:before="${_tw(it.beforePt)}" w:after="0"/>'
            '$ind$sectXml</w:pPr><w:r><w:drawing>'
            '<wp:inline distT="0" distB="0" distL="0" distR="0">'
            '<wp:extent cx="$cx" cy="$cy"/><wp:docPr id="$imgN" name="Gambar $imgN"/>'
            '<a:graphic xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main">'
            '<a:graphicData uri="http://schemas.openxmlformats.org/drawingml/2006/picture">'
            '<pic:pic xmlns:pic="http://schemas.openxmlformats.org/drawingml/2006/picture">'
            '<pic:nvPicPr><pic:cNvPr id="$imgN" name="$name"/><pic:cNvPicPr/></pic:nvPicPr>'
            '<pic:blipFill><a:blip r:embed="rIdImg$imgN"/><a:stretch><a:fillRect/></a:stretch></pic:blipFill>'
            '<pic:spPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="$cx" cy="$cy"/></a:xfrm>'
            '<a:prstGeom prst="rect"><a:avLst/></a:prstGeom></pic:spPr>'
            '</pic:pic></a:graphicData></a:graphic></wp:inline></w:drawing></w:r></w:p>');
      }
    }
  }
  body.write(sect(pages.last));

  const ns = 'xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main" '
      'xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" '
      'xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing"';
  final documentXml =
      '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><w:document $ns><w:body>$body</w:body></w:document>';
  const contentTypes =
      '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
      '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">'
      '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>'
      '<Default Extension="xml" ContentType="application/xml"/>'
      '<Default Extension="jpg" ContentType="image/jpeg"/>'
      '<Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>'
      '</Types>';
  const rootRels =
      '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
      '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
      '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>'
      '</Relationships>';
  final docRels =
      '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
      '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">$rels</Relationships>';

  final ar = Archive();
  void add(String name, List<int> data) =>
      ar.addFile(ArchiveFile(name, data.length, data));
  add('[Content_Types].xml', utf8.encode(contentTypes));
  add('_rels/.rels', utf8.encode(rootRels));
  add('word/document.xml', utf8.encode(documentXml));
  add('word/_rels/document.xml.rels', utf8.encode(docRels));
  media.forEach((k, v) => add('word/media/$k', v));
  final bytes = ZipEncoder().encode(ar)!;
  return Uint8List.fromList(bytes);
}
