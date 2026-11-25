"""Native vector architecture drawing plus a matching PNG preview."""
from pathlib import Path
from html import escape
import math
from PIL import Image, ImageDraw, ImageFont

OUT = Path(__file__).resolve().parent
W, H, S = 2240, 2330, 1
FONT = '/Library/Fonts/Arial Unicode.ttf'
im = Image.new('RGB', (W*S, H*S), '#ffffff')
dr = ImageDraw.Draw(im)
svg = [f'<svg xmlns="http://www.w3.org/2000/svg" width="{W}" height="{H}" viewBox="0 0 {W} {H}">',
       '<rect width="100%" height="100%" fill="white"/>']
C = dict(ink='#162b41', muted='#52677c', blue='#2464b5', bluefill='#eaf2ff',
         teal='#087c80', tealfill='#e8f6f4', orange='#b7671e', orangefill='#fff2e6',
         purple='#6843aa', purplefill='#f3effb', border='#c5d0df')


def rect(x, y, w, h, fill, stroke=None, radius=12, width=2):
    dr.rounded_rectangle((x*S, y*S, (x+w)*S, (y+h)*S), radius=radius*S,
                         fill=fill, outline=stroke, width=width*S if stroke else 0)
    svg.append(f'<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="{radius}" fill="{fill}"'
               + (f' stroke="{stroke}" stroke-width="{width}"' if stroke else '') + '/>')


def txt(x, y, text, size=24, color=None, align='left', maxw=None):
    color = color or C['ink']
    font = ImageFont.truetype(FONT, size*S)
    while maxw and dr.textlength(text, font=font) > maxw*S and size > 14:
        size -= 1
        font = ImageFont.truetype(FONT, size*S)
    anchor = {'left':'lm', 'center':'mm', 'right':'rm'}[align]
    dr.text((x*S, y*S), text, font=font, fill=color, anchor=anchor)
    ta = {'left':'start', 'center':'middle', 'right':'end'}[align]
    svg.append(f'<text x="{x}" y="{y}" font-size="{size}" fill="{color}" text-anchor="{ta}" '
               f'dominant-baseline="central" font-family="Arial Unicode MS,Hiragino Sans GB,sans-serif">{escape(text)}</text>')


def line(points, color=None, width=3, arrow=False, dashed=False):
    color = color or C['ink']
    if dashed:
        for a, b in zip(points, points[1:]):
            dx, dy = b[0]-a[0], b[1]-a[1]
            length = math.hypot(dx, dy)
            if not length:
                continue
            for start in range(0, int(length), 16):
                end = min(start+8, length)
                dr.line([(S*(a[0]+dx*start/length), S*(a[1]+dy*start/length)),
                         (S*(a[0]+dx*end/length), S*(a[1]+dy*end/length))], fill=color, width=width*S)
    else:
        dr.line([(x*S, y*S) for x, y in points], fill=color, width=width*S, joint='curve')
    svg.append('<polyline points="'+' '.join(f'{x},{y}' for x,y in points)+f'" fill="none" stroke="{color}" stroke-width="{width}"'
               + (' stroke-dasharray="8 8"' if dashed else '')+'/>' )
    if arrow:
        a, b = points[-2:]
        dx, dy = b[0]-a[0], b[1]-a[1]
        length = math.hypot(dx, dy)
        ux, uy = dx/length, dy/length
        tri = [b, (b[0]-13*ux+6*uy, b[1]-13*uy-6*ux), (b[0]-13*ux-6*uy, b[1]-13*uy+6*ux)]
        dr.polygon([(x*S,y*S) for x,y in tri], fill=color)
        svg.append('<polygon points="'+' '.join(f'{x},{y}' for x,y in tri)+f'" fill="{color}"/>')


def node(x, y, title, body, kind='blue', w=240, h=140, dark=False):
    stroke = C[kind]
    rect(x, y, w, h, stroke if dark else C[kind+'fill'], stroke, radius=10)
    fg = '#ffffff' if dark else C['ink']
    txt(x+w/2, y+30, title, 28, fg, 'center', w-20)
    for k, label in enumerate(body):
        txt(x+w/2, y+62+25*k, label, 21, fg if dark else C['muted'], 'center', w-20)


def memory(x, y, title, body, kind='blue', w=300, h=140):
    node(x, y, title, body, kind, w=w, h=h)
    line([(x+10,y+12),(x+10,y+h-12)], C[kind], 2)
    line([(x+w-10,y+12),(x+w-10,y+h-12)], C[kind], 2)


def lane(x, y, w, h, title, fill, ink):
    rect(x, y, w, h, fill, radius=18)
    txt(x+24, y+32, title, 26, ink)


def comb(x, y, title, body, kind='blue', w=270, h=140):
    rect(x,y,w,h,'#ffffff',C[kind],radius=4)
    txt(x+w/2,y+30,title,27,C[kind],'center',w-16)
    for i,label in enumerate(body):
        txt(x+w/2,y+62+25*i,label,20,C['muted'],'center',w-16)



def chain(y, stages, kind):
    xs = [90, 510, 930, 1350, 1770]
    for index, ((title, body), x) in enumerate(zip(stages, xs)):
        node(x, y, title, body, kind, 355, 142)
        if index:
            line([(xs[index-1]+355, y+71), (x-4, y+71)], C[kind], 3, arrow=True)

txt(64, 68, 'Allegro  |  Consecutive MMA issue and block prefetch', 44)
txt(64, 122, 'Single CTA · Three ordered command records · Two input contexts · Four cores with 64 complete dot lanes each', 26, C['muted'])

lane(52, 175, 2136, 280, 'Command admission and B source reads', C['tealfill'], C['teal'])
chain(249, [('engine', ['Register command and tracker together', 'Precheck, pin, select partition by ID']),
            ('SMEM physical array', ['32 banks × 1,824 words × 32 bits', '8 groups · 128 B/cycle per direction']),
            ('R_BREQ → grant', ['16 B atom across four adjacent banks', 'Sample at g, deliver from g+2']),
            ('Shared B loader', ['2 × 256 B, four 32-bit words per row', 'Full atoms for FP16/BF16, masks otherwise']),
            ('Four-way distribution', ['K passes through, N transposes to column order', 'Cores accept separately, last frees slot'])], 'teal')
txt(90, 421, 'An eight-column FP16/BF16 block takes sixteen 16 B reads. Adjacent commands may own the two slots. Each core checks its partition and overwrite permission.', 23, C['muted'])

lane(52, 480, 2136, 280, 'Per-core inputs  /  Reuse each operand after its own last read', C['bluefill'], C['blue'])
for x, title, body in [
        (90, 'A  /  row groups', ['2 × 1 KiB, ready by 256 B group', 'Reuse r=0…3 across column blocks']),
        (510, 'B  /  column blocks', ['8 KiB in four WS partitions', 'Overwrite each block after its final op_load']),
        (930, 'C  /  column blocks', ['2 × 1 KiB, transfer ownership across commands', 'Same-address C[j] waits for old D[j] ACK success']),
        (1350, 'scale A / B', ['2 × 128 B of scale A per core', 'Two snapshots in 4 KiB shared scale B']),
        (1770, 'R_OP  /  832 B', ['Select r, j, and their scales', 'First load in lockstep, then independent'])]:
    node(x, 554, title, body, 'blue', 355, 142)
txt(90, 726, 'The first microtile can use installed B0. Publish a WS collector only after full installation on all four cores. Read shared B source data once.', 23, C['muted'])

lane(52, 785, 2136, 280, 'Dot issue and D writeback', C['purplefill'], C['purple'])
chain(859, [('R_OP issue and refill', ['Admit first microtile by ID', '8 rows × 8 columns per core per cycle']),
            ('Native dot pipelines', ['P = 5 / 6 / 5 / 3', 'Different families can issue back to back']),
            ('R_DOT → two D slots', ['1 KiB per slot, selected by result tag', 'Release data slot on last write acceptance']),
            ('TMEM R_W', ['128 banks × 128 bits', 'Accept at w, write at w+1']),
            ('Write ACK at w+2', ['Settle the original ID and block j', 'Release dependency after all required writes succeed'])], 'purple')
txt(90, 1031, 'Wide and K32 share the input stages by default. Results retire in issue order. Trailing writes and the pin retain the original instruction ID.', 23, C['muted'])

lane(52, 1090, 2136, 280, 'Completion and synchronization', C['orangefill'], C['orange'])
chain(1164, [('Final op_load / dot', ['Last operands copied into R_OP', 'Issued microtiles retain their identities']),
            ('local_done', ['All reads, computation, writes, and ACKs', 'for this core and ID have settled']),
            ('Engine completion', ['Join four cores, loader, and snapshots', 'Return handle and publish done']),
            ('TC tracker', ['Accept one final completion per ID', "Settle this issuer's commit"]),
            ('mbarrier', ['arrival → phase', 'Wait succeeds after acquire ACK'])], 'orange')
txt(90, 1336, 'The data path hands off first issue. The tracker receives final completion. After stop, drain all three records, partial deliveries, presented requests, and write ACKs.', 23, C['muted'])

lane(52, 1395, 2136, 530, 'Steady-state N128 FP16 in-place accumulation  /  Aligned K-major, warm, uncontended. Numbers denote handshake edges.', C['bluefill'], C['blue'])
txt(92, 1486, 'Previous dots   0 … 63', 30, C['purple'])
txt(850, 1486, 'Next dots   64 … 127', 30, C['teal'])
rect(92, 1520, 754, 16, C['purple'], radius=0)
rect(846, 1520, 754, 16, C['teal'], radius=0)
txt(1650, 1528, '64 cycles between first dots', 25)
txt(92, 1594, 'Next C0    Grant 58/59 → return 61/62 → load R_OP at 63 → first dot at 64', 28)
txt(92, 1654, 'Next C1    Grant 62/63 → return 65/66 → load R_OP at 67 → first dot of block 1 at 68', 28)
txt(92, 1724, 'Previous writes    Last result enters D at 68 → writes accepted at 69/70 → final write commits at 71 → final ACK at 72', 28)
txt(92, 1784, 'Previous completion    Accept local_done at 73 → return resources and publish done at 74 → earliest tracker acceptance at 75', 28)
txt(92, 1870, 'Both commands share 128 B/cycle of SMEM. For other layouts, competing clients, late ACKs, or output stalls, use actual handshake edges.', 23, C['muted'])
lane(52, 1950, 2136, 340, 'TMA  /  One walker, with all copies sharing a peak of 128 B/cycle', C['tealfill'], C['teal'])
xs = [90, 510, 930, 1350, 1770]
for i, (title, body) in enumerate([
        ('GMEM / L2', ['128 B line · 9-bit ID', 'Hold ID and data on a stalled return']),
        ('16 × 128 B data RAM', ['Load takes a slot on return', 'Store reserves a slot before reading SMEM']),
        ('Shared SMEM / client 8', ['Eight independent 16 B group ports', 'Four 32-bit banks per group']),
        ('Tracker / 64 transaction tags', ['Track in-flight commands by ticket', 'Match actual write ACKs by original tag']),
        ('Copy completion', ['Load → mbarrier acknowledgment', 'store → bulk group full'])]):
    node(xs[i], 2020, title, body, 'teal', 355, 142)
    if i in (1, 2):
        left, right = xs[i-1]+355, xs[i]-4
        line([(left,2082),(right,2082)], C['teal'], 3, arrow=True)
        line([(right,2100),(left,2100)], C['teal'], 3, arrow=True)
for i in (3, 4):
    line([(xs[i-1]+355,2091),(xs[i]-4,2091)], C['orange'], 3, arrow=True)
line([(267,2163),(267,2192),(1527,2192),(1527,2164)], C['orange'], 3, arrow=True)
txt(90, 2224, 'Loads move right and stores move left. Release the data slot on acceptance of the final SMEM group write or the GMEM line write.', 23, C['muted'])
txt(90, 2258, 'Orange arrows show completion. Loads collect per-group SMEM write ACKs and stores collect GMEM write ACKs. Store .read may complete once all source reads finish.', 23, C['muted'])
svg.append('</svg>')
(OUT/'tensor_core_tmem_pipeline.svg').write_text('\n'.join(svg))
im.save(OUT/'tensor_core_tmem_pipeline.png')
