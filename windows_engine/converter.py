"""PDF Office Converter - engine lokal (offline).

Perintah:
  pdf2images SRC OUTDIR [--dpi 180] [--quality 92] [--format jpg|png]
  pdf2docx   SRC OUT.docx [--ocr ind+eng] [--layout editable|preserve|visual]
  compress   SRC OUT.pdf [--level low|medium|high]

Semua perintah mencetak satu objek JSON per baris ke stdout:
  {"progress": 0.4, "msg": "..."}  dan di akhir  {"done": true, "output": "..."}
atau {"error": "..."} dengan exit code 1.

Pustaka: pypdfium2 (render), pdfplumber (teks/tabel), python-docx, pikepdf,
Pillow, pytesseract (OCR). Semuanya berlisensi permisif.
"""
import argparse
import io
import json
import os
import statistics
import sys
import traceback
import warnings
from pathlib import Path

warnings.filterwarnings('ignore')
import pypdfium2 as pdfium
from PIL import Image


# --------------------------------------------------------------------------- util
def emit(**kw):
    print(json.dumps(kw), flush=True)


def _base_dir() -> Path:
    if getattr(sys, 'frozen', False):
        return Path(sys.executable).resolve().parent
    return Path(__file__).resolve().parent


def setup_tesseract():
    """Cari tesseract: env, folder 'tesseract' di sebelah engine, atau PATH."""
    import pytesseract
    cmd = os.environ.get('TESSERACT_CMD')
    if not cmd:
        for cand in (_base_dir() / 'tesseract' / 'tesseract.exe',
                     _base_dir() / 'tesseract' / 'tesseract'):
            if cand.exists():
                cmd = str(cand)
                break
    if cmd:
        pytesseract.pytesseract.tesseract_cmd = cmd
        td = Path(cmd).parent / 'tessdata'
        if td.exists():
            os.environ['TESSDATA_PREFIX'] = str(td)
    return pytesseract


def resolve_langs(pytesseract, wanted: str) -> str | None:
    try:
        have = set(pytesseract.get_languages(config=''))
    except Exception:
        return None
    use = [l for l in wanted.split('+') if l in have]
    if not use:
        use = [l for l in ('eng',) if l in have]
    return '+'.join(use) or None


def render_page(pdf, index, dpi):
    page = pdf[index]
    bmp = page.render(scale=dpi / 72)
    return bmp.to_pil().convert('RGB')


# --------------------------------------------------------------------- pdf2images
def pdf2images(src, outdir, dpi=180, quality=92, fmt='jpg'):
    outdir.mkdir(parents=True, exist_ok=True)
    pdf = pdfium.PdfDocument(str(src))
    n = len(pdf)
    for i in range(n):
        img = render_page(pdf, i, dpi)
        if fmt == 'png':
            img.save(outdir / f'halaman_{i + 1:04d}.png', 'PNG', optimize=True)
        else:
            img.save(outdir / f'halaman_{i + 1:04d}.jpg', 'JPEG', quality=quality, optimize=True)
        emit(progress=(i + 1) / n, msg=f'Halaman {i + 1}/{n}')
    pdf.close()
    return outdir


# ---------------------------------------------------------------------- pdf2docx
def _words_from_text_layer(plumber_page):
    words = plumber_page.extract_words(
        keep_blank_chars=False, use_text_flow=False, x_tolerance=1.5,
        y_tolerance=2, extra_attrs=['fontname', 'size'])
    out = []
    for w in words:
        out.append(dict(text=w['text'], x0=w['x0'], x1=w['x1'], top=w['top'],
                        bottom=w['bottom'], size=w.get('size') or (w['bottom'] - w['top']),
                        bold='bold' in (w.get('fontname') or '').lower() or 'black' in (w.get('fontname') or '').lower(),
                        italic='italic' in (w.get('fontname') or '').lower() or 'oblique' in (w.get('fontname') or '').lower(),
                        font=w.get('fontname') or ''))
    return out


def _words_from_ocr(img, page_w, page_h, pytesseract, lang):
    data = pytesseract.image_to_data(img, lang=lang, output_type=pytesseract.Output.DICT)
    sx = page_w / img.width
    sy = page_h / img.height
    out = []
    for i, t in enumerate(data['text']):
        t = (t or '').strip()
        try:
            conf = float(data['conf'][i])
        except Exception:
            conf = -1
        if not t or conf < 45:
            continue
        x, y, w, h = data['left'][i], data['top'][i], data['width'][i], data['height'][i]
        if not any(ch.isalnum() for ch in t):
            continue
        out.append(dict(text=t, x0=x * sx, x1=(x + w) * sx, top=y * sy, bottom=(y + h) * sy,
                        size=max(6.0, h * sy * 0.92), bold=False, italic=False, font=''))
    if out:
        med_h = statistics.median(w['bottom'] - w['top'] for w in out)
        out = [w for w in out if (w['bottom'] - w['top']) < med_h * 3.2]
    if out:
        med = statistics.median(w['size'] for w in out)
        for w in out:   # samakan ukuran huruf isi teks agar tidak bergelombang
            if 0.65 * med <= w['size'] <= 1.3 * med:
                w['size'] = med
    return out


def _group_lines(words):
    words = sorted(words, key=lambda w: (w['top'], w['x0']))
    lines = []
    for w in words:
        mid = (w['top'] + w['bottom']) / 2
        placed = False
        for ln in reversed(lines[-4:]):
            if ln['top'] - 1 <= mid <= ln['bottom'] + 1 and abs(w['size'] - ln['size']) < max(3, ln['size'] * 0.5):
                ln['words'].append(w)
                ln['top'] = min(ln['top'], w['top'])
                ln['bottom'] = max(ln['bottom'], w['bottom'])
                placed = True
                break
        if not placed:
            lines.append(dict(words=[w], top=w['top'], bottom=w['bottom'], size=w['size']))
    for ln in lines:
        ln['words'].sort(key=lambda w: w['x0'])
        ln['x0'] = ln['words'][0]['x0']
        ln['x1'] = max(w['x1'] for w in ln['words'])
        ln['size'] = statistics.median(w['size'] for w in ln['words'])
        # pecah menjadi segmen bila ada celah lebar (kolom/tab)
        gaps_thr = max(ln['size'] * 1.6, 9)
        segs, cur = [], [ln['words'][0]]
        for a, b in zip(ln['words'], ln['words'][1:]):
            if b['x0'] - a['x1'] > gaps_thr:
                segs.append(cur)
                cur = [b]
            else:
                cur.append(b)
        segs.append(cur)
        ln['segments'] = segs
    lines.sort(key=lambda l: (l['top'], l['x0']))
    return lines


def _font_name(font: str) -> str:
    f = font.lower()
    if 'times' in f or 'serif' in f and 'sans' not in f or 'garamond' in f or 'cambria' in f:
        return 'Times New Roman'
    if 'courier' in f or 'mono' in f or 'consolas' in f:
        return 'Courier New'
    return 'Arial'


def _add_runs(par, words, preserve_style=True):
    from docx.shared import Pt
    text = ' '.join(w['text'] for w in words)
    run = par.add_run(text)
    size = statistics.median(w['size'] for w in words)
    run.font.size = Pt(max(6, min(72, round(size * 2) / 2)))
    run.bold = sum(1 for w in words if w['bold']) > len(words) / 2
    run.italic = sum(1 for w in words if w['italic']) > len(words) / 2
    if preserve_style:
        fn = _font_name(words[0]['font'])
        run.font.name = fn
        rpr = run._element.get_or_add_rPr()
        rfonts = rpr.rFonts
        if rfonts is not None:
            rfonts.set('{http://schemas.openxmlformats.org/wordprocessingml/2006/main}eastAsia', fn)
    return run


def _line_text_words(ln):
    return [w for seg in ln['segments'] for w in seg]


def pdf2docx(src, out, lang_spec='ind+eng', layout='preserve'):
    from docx import Document
    from docx.enum.section import WD_ORIENT, WD_SECTION
    from docx.enum.text import WD_ALIGN_PARAGRAPH, WD_LINE_SPACING, WD_TAB_ALIGNMENT
    from docx.shared import Pt, Emu
    import pdfplumber

    pdf = pdfium.PdfDocument(str(src))
    plumber = pdfplumber.open(str(src))
    n = len(pdf)
    doc = Document()
    # buang paragraf kosong bawaan
    body = doc.element.body
    for p in list(body.findall('{http://schemas.openxmlformats.org/wordprocessingml/2006/main}p')):
        body.remove(p)

    tess = None
    ocr_lang = None
    ocr_warned = False

    for pno in range(n):
        pp = plumber.pages[pno]
        pw, ph = float(pp.width), float(pp.height)
        if pno == 0:
            sec = doc.sections[0]
        else:
            sec = doc.add_section(WD_SECTION.NEW_PAGE)
        sec.page_width = Pt(pw)
        sec.page_height = Pt(ph)
        sec.orientation = WD_ORIENT.LANDSCAPE if pw > ph else WD_ORIENT.PORTRAIT
        sec.header_distance = Pt(0)
        sec.footer_distance = Pt(0)

        # ---------- mode visual: gambar halaman penuh
        if layout == 'visual':
            img = render_page(pdf, pno, 150)
            buf = io.BytesIO()
            img.save(buf, 'JPEG', quality=88, optimize=True)
            buf.seek(0)
            sec.left_margin = sec.right_margin = sec.top_margin = sec.bottom_margin = Pt(0)
            par = doc.add_paragraph()
            par.paragraph_format.space_after = Pt(0)
            par.paragraph_format.line_spacing_rule = WD_LINE_SPACING.SINGLE
            par.add_run().add_picture(buf, width=Pt(pw), height=Pt(ph - 2))
            emit(progress=(pno + 1) / n, msg=f'Halaman {pno + 1}/{n}')
            continue

        words = _words_from_text_layer(pp)
        scanned = sum(len(w['text']) for w in words) < 15
        if scanned:
            if tess is None:
                try:
                    tess = setup_tesseract()
                    ocr_lang = resolve_langs(tess, lang_spec)
                except Exception:
                    tess, ocr_lang = False, None
            if tess and ocr_lang:
                try:
                    words = _words_from_ocr(render_page(pdf, pno, 300), pw, ph, tess, ocr_lang)
                except Exception as e:  # tesseract tidak bisa dijalankan
                    words = []
                    if not ocr_warned:
                        emit(warning=f'OCR gagal: {e}')
                        ocr_warned = True
            elif not ocr_warned:
                emit(warning='OCR tidak tersedia; halaman hasil pindai disisipkan sebagai gambar.')
                ocr_warned = True

        # ---------- tabel (hanya halaman berteks asli)
        tables = []
        if not scanned:
            try:
                for t in pp.find_tables():
                    rows = t.extract()
                    if rows and len(rows) >= 2 and max(len(r) for r in rows) >= 2:
                        tables.append((t.bbox, rows, t))
            except Exception:
                tables = []

        def in_table(w):
            cx, cy = (w['x0'] + w['x1']) / 2, (w['top'] + w['bottom']) / 2
            return any(b[0] - 1 <= cx <= b[2] + 1 and b[1] - 1 <= cy <= b[3] + 1 for b, _, _ in tables)

        flow_words = [w for w in words if not in_table(w)]
        lines = _group_lines(flow_words)

        # ---------- gambar (logo, stempel, tanda tangan, foto)
        pictures = []
        try:
            for im in pp.images:
                bw, bh = im['x1'] - im['x0'], im['bottom'] - im['top']
                if bw < 12 or bh < 12:
                    continue
                if bw * bh > 0.85 * pw * ph:   # latar belakang / halaman hasil pindai
                    continue
                pictures.append((im['x0'], im['top'], im['x1'], im['bottom']))
        except Exception:
            pictures = []
        if scanned and not words:
            pictures = [(0, 0, pw, ph)]

        # ---------- garis horizontal (kop surat, pemisah)
        hrules = []
        if not scanned:
            try:
                cand = [(l['x0'], l['top'], l['x1'], l['bottom']) for l in pp.lines]
                cand += [(r['x0'], r['top'], r['x1'], r['bottom']) for r in pp.rects]
                for x0_, t_, x1_, b_ in cand:
                    if (b_ - t_) <= 2.5 and (x1_ - x0_) > pw * 0.3:
                        if any(bb[0] - 2 <= x0_ and x1_ <= bb[2] + 2 and bb[1] - 2 <= t_ <= bb[3] + 2 for bb, _, _ in tables):
                            continue
                        hrules.append((x0_, t_, x1_, b_))
            except Exception:
                hrules = []

        # ---------- margin
        if lines or tables or pictures:
            xs0 = [l['x0'] for l in lines] + [b[0] for b, _, _ in tables] + [p[0] for p in pictures]
            xs1 = [l['x1'] for l in lines] + [b[2] for b, _, _ in tables] + [p[2] for p in pictures]
            tops = [l['top'] for l in lines] + [b[1] for b, _, _ in tables] + [p[1] for p in pictures]
            left = max(14.0, min(xs0))
            right = max(14.0, pw - max(xs1))
            top = max(14.0, min(tops))
        else:
            left = right = top = 36.0
        if left + right > pw * 0.6:
            left = right = 36.0
        sec.left_margin, sec.right_margin = Pt(left), Pt(right)
        sec.top_margin, sec.bottom_margin = Pt(top), Pt(14)
        text_w = pw - left - right
        body_size = statistics.median([l['size'] for l in lines]) if lines else 10

        # ---------- kumpulkan item berurutan
        items = []
        for l in lines:
            items.append(('line', l['top'], l))
        for b, rows, t in tables:
            items.append(('table', b[1], (b, rows, t)))
        for p in pictures:
            items.append(('pic', p[1], p))
        for hr in hrules:
            items.append(('hr', hr[1], hr))
        items.sort(key=lambda x: (x[1], 0 if x[0] != 'line' else 1))

        page_img = None
        cursor = top
        prev_line = None
        para = None  # paragraf yang sedang dirangkai (mode editable)

        def flush_para():
            nonlocal para
            para = None

        for kind, itop, obj in items:
            if kind == 'pic':
                x0, t0, x1, b1 = obj
                if page_img is None:
                    page_img = render_page(pdf, pno, 150)
                sc = page_img.width / pw
                crop = page_img.crop((int(x0 * sc), int(t0 * sc), int(x1 * sc), int(b1 * sc)))
                buf = io.BytesIO()
                crop.save(buf, 'JPEG', quality=88)
                buf.seek(0)
                par_ = doc.add_paragraph()
                pf = par_.paragraph_format
                pf.space_before = Pt(max(0, t0 - cursor)) if layout == 'preserve' else Pt(2)
                pf.space_after = Pt(0)
                pf.left_indent = Pt(max(0, x0 - left))
                pf.line_spacing_rule = WD_LINE_SPACING.SINGLE
                width = min(x1 - x0, text_w)
                par_.add_run().add_picture(buf, width=Pt(width))
                cursor = max(cursor, t0) + (b1 - t0)
                prev_line = None
                flush_para()
                continue

            if kind == 'hr':
                x0_, t_, x1_, b_ = obj
                from docx.oxml import OxmlElement
                from docx.oxml.ns import qn
                hp = doc.add_paragraph()
                hf = hp.paragraph_format
                hf.space_after = Pt(0)
                hf.space_before = Pt(max(0, t_ - cursor)) if layout == 'preserve' else Pt(1)
                hf.line_spacing_rule = WD_LINE_SPACING.EXACTLY
                hf.line_spacing = Pt(1)
                hf.left_indent = Pt(max(0, x0_ - left))
                hf.right_indent = Pt(max(0, (left + text_w) - x1_))
                ppr = hp._p.get_or_add_pPr()
                bd = OxmlElement('w:pBdr')
                bt = OxmlElement('w:bottom')
                bt.set(qn('w:val'), 'single'); bt.set(qn('w:sz'), str(max(4, int(round(max(b_ - t_, 0.5) * 8)))))
                bt.set(qn('w:space'), '0'); bt.set(qn('w:color'), '000000')
                bd.append(bt); ppr.append(bd)
                cursor = max(cursor, t_) + 1
                prev_line = None
                flush_para()
                continue

            if kind == 'table':
                b, rows, t = obj
                if layout == 'editable' and prev_line is not None:
                    gp = doc.add_paragraph()
                    gp.paragraph_format.space_after = Pt(0)
                    gp.paragraph_format.line_spacing_rule = WD_LINE_SPACING.EXACTLY
                    gp.paragraph_format.line_spacing = Pt(8)
                if layout == 'preserve' and b[1] - cursor > 2:
                    gp = doc.add_paragraph()
                    gp.paragraph_format.space_before = Pt(0)
                    gp.paragraph_format.space_after = Pt(0)
                    gp.paragraph_format.line_spacing_rule = WD_LINE_SPACING.EXACTLY
                    gp.paragraph_format.line_spacing = Pt(round(b[1] - cursor, 1))
                ncols = max(len(r) for r in rows)
                tb = doc.add_table(rows=len(rows), cols=ncols)
                tb.style = 'Table Grid'
                tb.autofit = False
                try:
                    first = t.rows[0].cells
                    widths = [(c[2] - c[0]) if c else (b[2] - b[0]) / ncols for c in first]
                    if len(widths) != ncols:
                        raise ValueError
                except Exception:
                    widths = [(b[2] - b[0]) / ncols] * ncols
                from docx.enum.table import WD_ROW_HEIGHT_RULE
                for ri, trow in enumerate(tb.rows):
                    try:
                        rb = t.rows[ri].bbox
                        trow.height = Pt(max(8, rb[3] - rb[1]))
                        trow.height_rule = WD_ROW_HEIGHT_RULE.AT_LEAST
                    except Exception:
                        pass
                for ri, row in enumerate(rows):
                    for ci in range(ncols):
                        cell = tb.cell(ri, ci)
                        cell.width = Pt(widths[ci])
                        txt = (row[ci] if ci < len(row) else '') or ''
                        cell.text = ''
                        p0 = cell.paragraphs[0]
                        p0.paragraph_format.space_after = Pt(0)
                        r_ = p0.add_run(txt.replace('\n', ' ').strip())
                        r_.font.size = Pt(max(6, round(body_size * 2) / 2))
                # paragraf pemisah kecil setelah tabel agar tabel berikutnya tidak menyatu
                sp = doc.add_paragraph()
                sp.paragraph_format.space_after = Pt(0)
                sp.paragraph_format.space_before = Pt(0)
                sp.paragraph_format.line_spacing_rule = WD_LINE_SPACING.EXACTLY
                sp.paragraph_format.line_spacing = Pt(2)
                cursor = b[3]
                prev_line = None
                flush_para()
                continue

            # ---- baris teks
            ln = obj
            size = ln['size']
            multi = len(ln['segments']) > 1
            center = (ln['x0'] + ln['x1']) / 2
            align = WD_ALIGN_PARAGRAPH.LEFT
            if not multi and abs(center - (left + text_w / 2)) < text_w * 0.03 and (ln['x1'] - ln['x0']) < text_w * 0.85 and ln['x0'] - left > text_w * 0.05:
                align = WD_ALIGN_PARAGRAPH.CENTER
            elif not multi and (left + text_w) - ln['x1'] < text_w * 0.02 and ln['x0'] - left > text_w * 0.25:
                align = WD_ALIGN_PARAGRAPH.RIGHT

            if layout == 'editable':
                # sambungkan ke paragraf sebelumnya bila masih satu alinea
                cont = False
                if para is not None and prev_line is not None and not multi and not prev_line.get('multi'):
                    gap = ln['top'] - prev_line['bottom']
                    same_size = abs(size - prev_line['size']) < 1.2
                    prev_full = prev_line['x1'] >= left + text_w * 0.80
                    indent_jump = (ln['x0'] - prev_line['x0']) > size * 1.5
                    same_align = align == prev_line['align'] == WD_ALIGN_PARAGRAPH.LEFT
                    cont = gap < size * 0.6 and same_size and prev_full and not indent_jump and same_align
                if cont:
                    txt = ' '.join(w['text'] for w in ln['words'])
                    last = para.runs[-1]
                    if last.text.endswith('-') and len(last.text) > 1 and last.text[-2].isalpha():
                        last.text = last.text[:-1] + txt
                    else:
                        last.text = last.text + ' ' + txt
                else:
                    para = doc.add_paragraph()
                    pf = para.paragraph_format
                    pf.alignment = align
                    pf.space_after = Pt(0)
                    pf.space_before = Pt(0 if prev_line is None else min(24, max(2, ln['top'] - prev_line['bottom'])))
                    pf.line_spacing_rule = WD_LINE_SPACING.SINGLE
                    if align == WD_ALIGN_PARAGRAPH.LEFT:
                        pf.left_indent = Pt(max(0, ln['x0'] - left)) if ln['x0'] - left > size * 1.2 else Pt(0)
                    if multi:
                        for si, seg in enumerate(ln['segments']):
                            if si:
                                para.add_run('\t')
                                pf.tab_stops.add_tab_stop(Pt(seg[0]['x0'] - left), WD_TAB_ALIGNMENT.LEFT)
                            _add_runs(para, seg, preserve_style=False)
                    else:
                        _add_runs(para, ln['words'], preserve_style=False)
                prev_line = dict(ln, align=align, multi=multi)
                continue

            # ---- preserve: satu paragraf per baris dengan jarak vertikal presisi
            para = doc.add_paragraph()
            pf = para.paragraph_format
            pf.alignment = align
            exact = max(size * 1.15, 6)
            pitch_gap = max(0.0, ln['top'] - cursor)
            pf.space_before = Pt(round(pitch_gap, 1))
            pf.space_after = Pt(0)
            pf.line_spacing_rule = WD_LINE_SPACING.EXACTLY
            pf.line_spacing = Pt(round(exact, 1))
            if align == WD_ALIGN_PARAGRAPH.LEFT:
                pf.left_indent = Pt(max(0, ln['x0'] - left))
            for si, seg in enumerate(ln['segments']):
                if si:
                    para.add_run('\t')
                    pf.tab_stops.add_tab_stop(Pt(seg[0]['x0'] - left), WD_TAB_ALIGNMENT.LEFT)
                _add_runs(para, seg, preserve_style=True)
            cursor = max(cursor, ln['top']) + exact
            prev_line = dict(ln, align=align, multi=multi)

        emit(progress=(pno + 1) / n, msg=f'Halaman {pno + 1}/{n}')

    plumber.close()
    pdf.close()
    out.parent.mkdir(parents=True, exist_ok=True)
    doc.save(out)
    return out


# ---------------------------------------------------------------------- compress
LEVELS = {
    #        sisi terpanjang maks (px), kualitas JPEG
    'low': (2600, 85),
    'medium': (1800, 70),
    'high': (1200, 55),
}


def compress(src, out, level='medium'):
    import pikepdf
    from pikepdf import Name, PdfImage

    max_side, quality = LEVELS[level]
    pdf = pikepdf.open(str(src))
    seen = set()
    objs = []
    for page in pdf.pages:
        try:
            for _, img in page.images.items():
                if img.objgen not in seen:
                    seen.add(img.objgen)
                    objs.append(img)
        except Exception:
            pass
    total = max(1, len(objs))
    for i, raw in enumerate(objs):
        try:
            if raw.get('/ImageMask'):
                continue
            w, h = int(raw.Width), int(raw.Height)
            if max(w, h) < 400:
                continue
            pil = PdfImage(raw).as_pil_image()
            if pil.mode not in ('RGB', 'L'):
                if pil.mode in ('1', 'P', 'CMYK', 'RGBA', 'LA'):
                    if pil.mode == '1':
                        continue  # citra hitam-putih (CCITT/JBIG2) sudah kecil
                    pil = pil.convert('RGB')
                else:
                    continue
            scale = min(1.0, max_side / max(w, h))
            if scale < 1.0:
                pil = pil.resize((max(1, int(w * scale)), max(1, int(h * scale))), Image.LANCZOS)
            buf = io.BytesIO()
            pil.save(buf, 'JPEG', quality=quality, optimize=True)
            data = buf.getvalue()
            try:
                old = len(raw.read_raw_bytes())
            except Exception:
                old = 1 << 60
            if len(data) >= old * 0.95:
                continue
            raw.write(data, filter=Name.DCTDecode)
            raw.Width, raw.Height = pil.width, pil.height
            raw.ColorSpace = Name.DeviceGray if pil.mode == 'L' else Name.DeviceRGB
            raw.BitsPerComponent = 8
            for k in ('/DecodeParms', '/Decode', '/Mask'):
                if k in raw:
                    del raw[k]
        except Exception:
            continue
        finally:
            emit(progress=0.9 * (i + 1) / total, msg=f'Gambar {i + 1}/{total}')
    out.parent.mkdir(parents=True, exist_ok=True)
    pdf.remove_unreferenced_resources()
    pdf.save(str(out), compress_streams=True, object_stream_mode=pikepdf.ObjectStreamMode.generate,
             recompress_flate=True)
    pdf.close()
    # jangan pernah menghasilkan file lebih besar dari aslinya
    if out.stat().st_size >= src.stat().st_size:
        import shutil
        shutil.copyfile(src, out)
    return out


# -------------------------------------------------------------------------- main
def main():
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest='cmd', required=True)
    a = sub.add_parser('pdf2images'); a.add_argument('src'); a.add_argument('outdir')
    a.add_argument('--dpi', type=int, default=180); a.add_argument('--quality', type=int, default=92)
    a.add_argument('--format', choices=['jpg', 'png'], default='jpg')
    b = sub.add_parser('pdf2docx'); b.add_argument('src'); b.add_argument('out')
    b.add_argument('--ocr', default='ind+eng')
    b.add_argument('--layout', choices=['editable', 'preserve', 'visual'], default='preserve')
    c = sub.add_parser('compress'); c.add_argument('src'); c.add_argument('out')
    c.add_argument('--level', choices=['low', 'medium', 'high'], default='medium')
    ns = ap.parse_args()
    try:
        if ns.cmd == 'pdf2images':
            res = pdf2images(Path(ns.src), Path(ns.outdir), ns.dpi, ns.quality, ns.format)
        elif ns.cmd == 'pdf2docx':
            res = pdf2docx(Path(ns.src), Path(ns.out), ns.ocr, ns.layout)
        else:
            res = compress(Path(ns.src), Path(ns.out), ns.level)
        emit(done=True, output=str(res))
    except Exception as e:
        emit(error=f'{type(e).__name__}: {e}', trace=traceback.format_exc())
        sys.exit(1)


if __name__ == '__main__':
    main()
