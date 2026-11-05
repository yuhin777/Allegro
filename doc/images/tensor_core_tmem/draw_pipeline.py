"""Native vector architecture drawing plus a matching PNG preview."""
from pathlib import Path
from html import escape
import math
from PIL import Image, ImageDraw, ImageFont

OUT = Path(__file__).resolve().parent
W, H, S = 3200, 2820, 2
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



# Colored boxes are registers; white boxes are combinational logic.
txt(70,55,'Tensor Core + TMEM：全 MMA 类型 / 布局与发射期限',43)
txt(70,110,'方案解析推导 | cta_group::1 | 四核 8×8 完整 dot | 参考描述符 + 逐帧服务证书',27,C['muted'])
node(70,160,'R_CMD / R_COLLECTOR',['唯一命令 / owner / epoch / allocation pin','A / WS b0..b3 fill / use / lastuse / discard 身份'],w=950,h=135)
node(1060,160,'R_SCHED / R_FILL',['行列分区，j / r / P / U；fire 推进','B/C/D generation、分片 filled / consumed / sent'],kind='purple',w=950,h=135)
node(2050,160,'R_RTAG / R_BTAG / R_ARB',['每 bank 三项读身份：在途 + Q + 外部返回','写 ACK 已占 + R_W 在途 ≤ 2；期限 / 轮询状态'],w=1080,h=135)

lane(60,340,1820,490,'TMEM：128 bank × 128 word × 128 bit = 256 KiB；bank=lane / word=column//4','#f4f8fe',C['blue'])
lane(60,870,1820,490,'SMEM：32 bank × 456 word × 128 bit = 228 KiB；全部客户端共用 XOR bank 映射','#f1f9f7',C['teal'])
lane(60,1750,1820,560,'TMEM 写：每分区 512 B/cycle；grant → 实际写入 +1 → ACK 退休 +2','#fff8ef',C['orange'])
rect(1930,340,1200,1970,'#f7f4fc',radius=18)
txt(1955,375,'Tensor Core i ×4；容量按每核计算',28,C['purple'])

comb(85,440,'组合地址 / 仲裁',['按 bank 合并 / 保证期限','同 word 写优先于新读','空闲 bank 服务其他客户端'],w=290,h=160)
memory(425,440,'TMEM M0 读端',['128 bank，1R1W','每32-bank分区读512 B/cycle'],w=305,h=160)
memory(785,440,'SRAM_Q @ g+1',['宏内读输出，512 B/分区','支持按 bank read-enable 保持','仅已预留读可以发出'],w=285,h=160)
node(1120,425,'R_RESP @ g+2',['512 B / 分区；逐 bank valid'],w=350,h=110)
node(1120,580,'R_BACKUP',['512 B；接住不可撤销返回'],w=350,h=110)
comb(1530,480,'组合分片路由',['g+3 写 TC buffer','g+4 最早载入 R_OP'],w=300,h=150)
for a,b in [(375,412),(730,772),(1070,1107)]:
    line([(a,520),(b,520)],C['blue'],arrow=True)
line([(1090,520),(1090,635),(1107,635)],C['blue'],arrow=True)
line([(1470,480),(1517,480)],C['blue'],arrow=True)
line([(1470,635),(1500,635),(1500,575),(1517,575)],C['blue'],arrow=True)
node(85,705,'R_RTAG[bank][0..2] / delivered mask',['总读预留 ≤ 3 / bank = SRAM_Q + main + backup；同拍交付可归还 credit','ready 突降先停止新 grant，已发 SRAM 返回仍必须捕获'],w=1745,h=100)

node(1970,425,'A 驻留：1 KiB',['原始/压缩 A，最多32行×32 B','跨 N 复用；ashift 保留原位模式'],kind='purple',w=530,h=135)
node(2540,425,'E / S_A / S_B 快照',['256 / 128 / 折合1024 B','S_B 四物理partition共4 KiB','组合读，先完成必要覆盖保护'],kind='purple',w=550,h=135)
node(1970,650,'C0：1 KiB',['32×8；非WS M64有效512 B','FP16低16bit精确提升'],kind='purple',w=530,h=120)
node(2540,650,'C1：1 KiB',['分片预取 / consumed mask','最后一次 op_fire 后释放'],kind='purple',w=550,h=120)
line([(1830,555),(1900,555),(1900,405),(2815,405)],C['blue'])
for x in (2235,2815):line([(x,405),(x,422)],C['blue'],arrow=True)
line([(1900,555),(1900,625),(2815,625)],C['blue'])
for x in (2235,2815):line([(x,625),(x,647)],C['blue'],arrow=True)

node(85,970,'R_BREQ',['源路由寄存 1 拍','atom / dst / block tag'],kind='teal',w=275,h=140)
memory(410,970,'SMEM M1 读端',['共享512 B/cycle','相同源一次读取并广播'],kind='teal',w=310,h=140)
memory(770,970,'B_SRAM_Q',['共享512 B宏内输出','bank grant +1；可保持'],kind='teal',w=300,h=140)
node(1120,930,'R_BRESP',['共享512 B，grant +2'],kind='teal',w=350,h=110)
node(1120,1095,'R_BBACK',['共享512 B；逐目的保持'],kind='teal',w=350,h=110)
comb(1530,995,'分片 gather / 广播',['grant +3 写B槽','每核目的容器 ≤256 B/cycle','快目的交付一次，慢目的保持'],kind='teal',w=300,h=165)
for a,b in [(360,397),(720,757),(1070,1107)]:line([(a,1040),(b,1040)],C['teal'],arrow=True)
line([(1090,1040),(1090,1150),(1107,1150)],C['teal'],arrow=True)
line([(1470,985),(1500,985),(1500,1030),(1517,1030)],C['teal'],arrow=True)
line([(1470,1150),(1517,1150)],C['teal'],arrow=True)
node(85,1240,'R_BTAG[bank][0..2] / delivered mask',['每bank在途与未交付 ≤3；槽在返回时按generation分配','source byte与目的容器分别计费；不隐含第三个B tile槽'],kind='teal',w=1745,h=100)

node(1970,895,'B0：512 B + scale 32 B',['八列完整B；按U=4/2复用','dense256 / sparse512 B上界'],kind='teal',w=530,h=130)
node(2540,895,'B1：512 B + scale 32 B',['预取下一块，逐分片写入','最后一次 op_fire 后释放'],kind='teal',w=550,h=130)
line([(1830,1075),(1900,1075),(1900,865),(2815,865)],C['teal'])
for x in (2235,2815):line([(x,865),(x,892)],C['teal'],arrow=True)
line([(2815,560),(3105,560),(3105,840),(2815,840),(2815,892)],C['purple'],2,True)
txt(2600,810,'S_B 快照 → 每槽最多8列×4 B',21,C['purple'],'center')

comb(2010,1125,'读取 / 解包 / C提升 / 控制适配',['A256 + B512 + C256 + E64 + S_A32 + S_B32','保留原始驻留；命令字段引用 R_CMD'],kind='purple',w=1040,h=115)
for x,y in ((2235,560),(2815,560),(2235,770),(2815,770)):
    line([(x,y),(3120,y),(3120,1182),(3063,1182)],C['purple'],arrow=True)
for x in (2235,2815):line([(x,1025),(x,1080),(2530,1080),(2530,1122)],C['teal'],arrow=True)
node(2010,1280,'R_OP：1152 B / valid / 微块tag',['操作数准备寄存级：op_fire → 下一拍 dot_fire','弹性保持；最后op_fire后可释放旧B/C'],kind='purple',w=1040,h=115)
line([(2530,1240),(2530,1277)],C['purple'],arrow=True)
comb(2020,1420,'组合：逐行稀疏选择 / scale / 8×8广播',['TF32 1:2；普通2:4；FP4成对4:8；scale沿原逻辑K'],kind='purple',w=1020,h=100)
line([(2530,1395),(2530,1417)],C['purple'],arrow=True)
node(2010,1560,'64 路完整 dot / 选择一种算术阵列',['F16/BF16/TF32 L=5；低精度/MX L=6；FP4 L=5；INT8 L=4','各阵列 II=1；内部寄存器省略，未增加TC部分和','原生末级 R_DOT 保持最终 FP32/S32 与76bit状态'],kind='purple',w=1040,h=155,dark=True)
line([(2530,1520),(2530,1557)],C['purple'],arrow=True)
node(2010,1760,'R_FMT0：≤608 B',['76bit最终状态 / valid / tag','FP16规范化与舍入准备'],kind='purple',w=480,h=125)
node(2570,1760,'R_FMT1：≤256 B',['最终FP16编码 / valid / tag','64路编码，Lfmt=2、II=1'],kind='purple',w=480,h=125)
line([(2530,1715),(2530,1735),(2250,1735),(2250,1757)],C['purple'],arrow=True)
line([(2490,1820),(2557,1820)],C['purple'],arrow=True)
line([(3050,1638),(3110,1638),(3110,1925),(2530,1925)],C['purple'],2,True)
txt(3090,1740,'旁路',19,C['purple'],'right')
node(1970,1980,'D0：1 KiB',['4个结果；非WS M64为2个','FP16低两byte写mask'],kind='purple',w=530,h=125)
node(2540,1980,'D1：1 KiB',['收下一块 / 排上一块','owner / received / sent'],kind='purple',w=550,h=125)
line([(2810,1885),(2810,1925),(2235,1925),(2235,1977)],C['purple'],arrow=True)
line([(2530,1925),(2815,1925),(2815,1977)],C['purple'],arrow=True)
txt(2530,2155,'R_DOT / R_FMT1 → 再1拍写D；目标generation忙则反压全部弹性级',22,C['purple'],'center',1100)
txt(2530,2230,'TC 6208 B；旁路快照1408 B；R_OP与算术/接口分别计容',23,C['purple'],'center',1100)

comb(1530,1870,'写仲裁 / ACK credit',['最后payload接受后释放D','C/D每块V=2或3个word','ACK阻塞限制新写'],kind='orange',w=300,h=170)
node(1100,1870,'R_W：512 B / 分区',['唯一写payload / byte mask','bank-word / block / generation'],kind='orange',w=370,h=170)
memory(620,1870,'TMEM M0 写端',['与上方M0为同一SRAM','接受后+1实际写入并生成ACK','bank每拍最多1R+1W'],kind='orange',w=410,h=170)
node(85,1870,'R_ACK[0] / R_ACK[1]',['每分区两项身份帧','只记录已实际写入','再1拍退休；可保持'],kind='orange',w=465,h=170)
line([(2235,2105),(2235,2180),(1900,2180),(1900,1955),(1843,1955)],C['orange'],arrow=True)
line([(2815,2105),(2815,2180),(2235,2180)],C['orange'])
for a,b in [(1530,1483),(1100,1043),(620,563)]:line([(a,1955),(b,1955)],C['orange'],arrow=True)
node(85,2130,'R_ACK_OWNER / R_WR_ARB / R_SENT',['接受、实际写入、ACK入队、ACK退休分别记账；旧ACK不访问复用槽','同word读写冲突先完成已获准写；SRAM写mask保持未写byte'],kind='orange',w=1745,h=130)

node(85,2375,'R_DONE / R_COLLECTOR / R_SIDE_EFFECT',['按实际分片与ACK退休计数；读、算术、provider、ashift与错误排空共同收敛','全部写确认后才发complete并解除allocation pin；collector身份按实际lastuse释放'],kind='orange',w=1745,h=140)
line([(315,2040),(315,2320),(570,2320),(570,2372)],C['orange'],arrow=True)
node(1970,2375,'软件完成 / 结果读回',['MMA → commit → mbarrier wait → TMEM ld','线程调度 / 软件同步另计；数值与宏时序待验收'],w=1120,h=140)
line([(1830,2445),(1957,2445)],C['orange'],arrow=True)
txt(70,2585,'参考保证布局：Bbase 4 KiB对齐；K-major、无swizzle、LBO128；dense SBO256 / sparse SBO512；A/E/scale先驻留。',24,C['muted'])
txt(70,2640,'逐帧证书：P=U连续；P>U每块间等待P−U拍；g→Q +1→RESP +2→TC +3→R_OP +4→最早dot +5。',24,C['muted'])
txt(70,2695,'图例：彩色框为寄存器/存储；白框为组合逻辑；宏内Q已单列。外部接口1.75 KiB/核，宏内读输出折合640 B/核。',24,C['muted'])
txt(70,2750,'F=T_snap+P+5；W=(J−1)P+U；T_done=F+W+Ldot+Lfmt+V+2；D列对齐V=2，其他V=3。方案推导。',24,C['muted'])
svg.append('</svg>')
(OUT/'tensor_core_tmem_pipeline.svg').write_text('\n'.join(svg))
im.save(OUT/'tensor_core_tmem_pipeline.png')
print(OUT/'tensor_core_tmem_pipeline.png')
print(OUT/'tensor_core_tmem_pipeline.svg')
