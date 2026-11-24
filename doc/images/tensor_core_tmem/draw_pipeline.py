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

txt(64, 68, 'Allegro  |  跨 MMA 连续发射与分块预取', 44)
txt(64, 122, '单 CTA · 三个有序命令记录 · 两个输入上下文 · 四核各 64 路完整 dot', 26, C['muted'])

lane(52, 175, 2136, 280, '命令与 B 源读取', C['tealfill'], C['teal'])
chain(249, [('engine', ['cmd 与 tracker 同沿登记', '按 id 预检、pin、选择分区']),
            ('SMEM 物理阵列', ['32 bank × 1,824 × 32 bit', '8 组 · 每方向共 128 B/拍']),
            ('R_BREQ → grant', ['16 B atom 选四个相邻 bank', 'g 同沿采样，g+2 最早交付']),
            ('共享 B loader', ['2 × 256 B，每行 4 × 32 bit', '半精度整 atom / 其他 masked']),
            ('四目的分发', ['K 直通 / N 转置后共享列序', '四核独立握手，末目的释放槽'])], 'teal')
txt(90, 421, 'FP16/BF16 八列块读 16 笔 16 B atom。两个槽可分属相邻命令，分发时检查每核的分区选择和覆盖保护。', 23, C['muted'])

lane(52, 480, 2136, 280, '每核输入  /  三种操作数以各自最后读取沿回收', C['bluefill'], C['blue'])
for x, title, body in [
        (90, 'A  /  行组', ['2 × 1 KiB，按 256 B 组就绪', 'r=0…3 在各列块重用']),
        (510, 'B  /  列块', ['8 KiB，四个 WS 分区', '末次 op_load 后可逐块覆盖']),
        (930, 'C  /  列块', ['2 × 1 KiB，跨指令换主', '同址 C[j] 等老 D[j] 成功 ACK']),
        (1350, 'scale A / B', ['本核 2 × 128 B scale A', '共享 4 KiB 内取两份快照']),
        (1770, 'R_OP  /  832 B', ['取本次 r、j 与对应 scale', '首片四核同沿，之后独立推进'])]:
    node(x, 554, title, body, 'blue', 355, 142)
txt(90, 726, 'B0 已装好就可供本条首片使用。四核整份安装成功才发布 WS collector。核间共享的 B 源数据只读一份。', 23, C['muted'])

lane(52, 785, 2136, 280, '发射与 D 写回', C['purplefill'], C['purple'])
chain(859, [('R_OP 送旧装新', ['首片按 id 准入', '8 行 × 8 列 / 核 / 拍']),
            ('原生 dot 流水', ['P = 5 / 6 / 5 / 3', '不同族可相邻发射']),
            ('R_DOT → D 双槽', ['每槽 1 KiB；由结果 tag 选槽', '最后写接受后归还数据槽']),
            ('TMEM R_W', ['128 bank × 128 bit', 'w 接受，w+1 实际写入']),
            ('w+2 真实 ACK', ['只结算原 id / j', '全部必要写成功才开放依赖'])], 'purple')
txt(90, 1031, '各族独立接收，队首族按发射序交付；旧指令的写尾与 pin 继续按原 id 结算。', 23, C['muted'])

lane(52, 1090, 2136, 280, '完成与同步', C['orangefill'], C['orange'])
chain(1164, [('末 op_load / dot', ['最后操作数已复制进 R_OP', '已发微块仍保留身份']),
            ('local_done', ['本核本 id 的读、算术、写', '及真实 ACK 责任已结清']),
            ('engine 收尾', ['汇合四核及 loader / 快照', '归还 handle，发布 done']),
            ('TC tracker', ['按 id 接受一次最终完成', '结算本 issuer 的 commit']),
            ('mbarrier', ['arrival → phase', 'wait 按实际 acquire 唤醒'])], 'orange')
txt(90, 1336, '首片交接在数据通路，最终完成在 tracker。stop 后继续排空三个命令记录、部分分发、已展示请求及写 ACK。', 23, C['muted'])

lane(52, 1395, 2136, 530, '稳态 N128 FP16 同址累加  /  对齐 K-major、已预热、无竞争，以下为握手沿', C['bluefill'], C['blue'])
txt(92, 1486, '前条 dot   0 … 63', 30, C['purple'])
txt(850, 1486, '后条 dot   64 … 127', 30, C['teal'])
rect(92, 1520, 754, 16, C['purple'], radius=0)
rect(846, 1520, 754, 16, C['teal'], radius=0)
txt(1650, 1528, '首发间隔 64 拍', 25)
txt(92, 1594, '后条 C0    58 / 59 grant → 61 / 62 返回 → 63 装 R_OP → 64 首 dot', 28)
txt(92, 1654, '后条 C1    62 / 63 grant → 65 / 66 返回 → 67 装 R_OP → 68 块 1 首 dot', 28)
txt(92, 1724, '前条写尾    68 末片入 D → 69 / 70 接受写 → 71 末写提交 → 72 末 ACK', 28)
txt(92, 1784, '前条完成    73 接受 local_done → 74 资源交还并发布 done → 75 tracker 最早接受', 28)
txt(92, 1870, '两条指令的数据共用 128 B/拍 SMEM；一般布局、其他客户端、迟到 ACK 与输出反压按真实边沿计时。', 23, C['muted'])
lane(52, 1950, 2136, 340, 'TMA  /  单 walker，各 copy 共用后端峰值 128 B/拍', C['tealfill'], C['teal'])
xs = [90, 510, 930, 1350, 1770]
for i, (title, body) in enumerate([
        ('GMEM / L2', ['128 B 行 · 9-bit ID', '返回受阻时保持 ID 与数据']),
        ('16 × 128 B 数据 RAM', ['load 收到返回时分槽', 'store 读 SMEM 前预留槽']),
        ('共享 SMEM / client 8', ['八组各 16 B · 独立握手', '每组四个 32-bit bank']),
        ('tracker / 64 个事务 tag', ['在途命令按 ticket 结算', '真实写 ACK 按原 tag 结算']),
        ('copy 完成', ['load → mbarrier 确认', 'store → bulk group full'])]):
    node(xs[i], 2020, title, body, 'teal', 355, 142)
    if i in (1, 2):
        left, right = xs[i-1]+355, xs[i]-4
        line([(left,2082),(right,2082)], C['teal'], 3, arrow=True)
        line([(right,2100),(left,2100)], C['teal'], 3, arrow=True)
for i in (3, 4):
    line([(xs[i-1]+355,2091),(xs[i]-4,2091)], C['orange'], 3, arrow=True)
line([(267,2163),(267,2192),(1527,2192),(1527,2164)], C['orange'], 3, arrow=True)
txt(90, 2224, '数据向右 load、向左 store。最后一组 SMEM 写或整行 GMEM 写被接受即释放数据槽。', 23, C['muted'])
txt(90, 2258, '橙线为完成通路：load 收各组 SMEM 写 ACK，store 收 GMEM 写 ACK。store 的 .read 在全部源读完成后即可放行。', 23, C['muted'])
svg.append('</svg>')
(OUT/'tensor_core_tmem_pipeline.svg').write_text('\n'.join(svg))
im.save(OUT/'tensor_core_tmem_pipeline.png')
