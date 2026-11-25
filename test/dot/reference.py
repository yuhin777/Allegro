"""Generate deterministic dot transactions and exact integer reference results."""
import itertools
import random
from dataclasses import dataclass

RNG = random.Random(0xA113670)
QNAN, PINF, NINF = 0x7FFFFFFF, 0x7F800000, 0xFF800000
# exponent width, fraction width, bias, element container width
FORMATS = [(5, 10, 15, 16), (8, 7, 127, 16), (8, 23, 127, 32),
           (4, 3, 7, 8), (5, 2, 15, 8), (3, 2, 3, 8),
           (2, 3, 1, 8), (2, 1, 1, 8)]


def signed(x, width):
    return x - (1 << width) if x >> (width-1) else x


def decode(bits, dtype, negate=False):
    ew, fw, bias, _ = FORMATS[dtype]
    exp = bits >> fw & ((1 << ew) - 1)
    frac = bits & ((1 << fw) - 1)
    sign = bool((bits >> (fw + ew)) & 1) ^ negate
    if dtype in (0, 1, 2, 4) and exp == (1 << ew) - 1:
        return ('nan' if frac else 'inf', sign, 0, 0)
    if dtype == 2:
        frac >>= 13
        fw = 10
    if dtype == 3 and exp == 15 and frac == 7:
        return ('nan', sign, 0, 0)
    sig = ((1 << fw) if exp else 0) | frac
    sig <<= (10 if dtype <= 2 else 3) - fw
    exponent = max(1, exp) - bias
    if not sig:
        return ('zero', sign, 0, -126)
    if dtype >= 5 and not exp:
        shift = 4 - sig.bit_length()
        sig <<= shift
        exponent -= shift
    return ('finite', sign, sig, exponent)


def pack(integer, exponent, canonical=True):
    if integer == 0:
        return 0
    sign = (integer < 0) << 31
    mag = abs(integer)
    high = mag.bit_length() - 1
    e = high + exponent
    if e > 127:
        return sign | PINF
    if e < -149:
        return 0 if canonical else sign
    if e < -126:
        shift = -149 - exponent
        frac = mag >> shift if shift >= 0 else mag << -shift
        return sign | frac
    frac = mag >> (high-23) if high >= 23 else mag << (23-high)
    return sign | ((e+127) << 23) | (frac & 0x7fffff)


def align(terms, correction, canonical=True):
    active = [(mag, exp) for mag, exp in terms if mag]
    if not active:
        return 0
    max_exp = max(exp for _, exp in active)
    total = sum((-1 if mag < 0 else 1) * (abs(mag) >> (max_exp-exp)) for mag, exp in active)
    return pack(total, max_exp + correction, canonical)


def scale4(byte, ue4):
    if ue4:
        if byte & 127 == 0:
            return False, 0, -129
        return (byte & 127) == 127, (byte & 7) + (8 if byte & 0x78 else 0), max(1, (byte >> 3) & 15)-10
    return (False, 4, -129) if byte == 0 else (byte == 255, 8, byte-130)


@dataclass
class Vector:
    kind: int
    ta: int
    tb: int
    a: int = 0
    b: int = 0
    c: int = 0
    sa: int = 0
    sb: int = 0
    shift: int = 0
    na: bool = False
    nb: bool = False
    sat: bool = False
    ue4: bool = False
    asym: bool = False
    ncode: int = 0
    ws: bool = False

    def value(self):
        if self.kind == 3:
            total = signed(self.c, 32)
            for k in range(32):
                a = self.a >> (8*k) & 255
                b = self.b >> (8*k) & 255
                total += (signed(a, 8) if self.ta == 8 else a) * (signed(b, 8) if self.tb == 8 else b)
            if self.sat:
                total = max(-2**31, min(2**31 - 1, total))
            return total & 0xffffffff

        ce = self.c >> 23 & 255
        cs = self.c >> 31
        cmag = (self.c & 0x7fffff) + (bool(ce) << 23)
        flags = set()
        if ce == 255:
            flags.add('nan' if self.c & 0x7fffff else cs)
            cmag = 0
        adjusted = max(1, ce)-self.shift
        cmag >>= max(0, 1-adjusted)
        cexp = max(1, adjusted)-127
        csign = -1 if cs else 1
        terms = []
        if self.kind in (5, 6):
            q = (0, 1, 2, 3, 4, 6, 8, 12)
            for h in range(4):
                sigma = 0
                for k in range(16*h, 16*h+16):
                    a, b = (self.a >> (4*k)) & 15, (self.b >> (4*k)) & 15
                    neg = bool((a ^ b) & 8) ^ self.na ^ self.nb
                    sigma += (-1 if neg else 1) * q[a & 7] * q[b & 7]
                g = h if self.ue4 else h // 2
                an, am, ae = scale4((self.sa >> (8*g)) & 255, self.ue4)
                bn, bm, be = scale4((self.sb >> (8*g)) & 255, self.ue4)
                if an or bn:
                    flags.add('nan')
                terms.append((sigma * am * bm << 27, ae + be))
            terms.append((csign * cmag << 12, cexp - 6))
            result = align(terms, -29, canonical=False)
        else:
            wide = self.kind <= 1
            kmax = 8 if self.kind == 1 else (16 if wide else 32)
            scale = 0
            if self.kind == 4:
                a, b = self.sa & 255, self.sb & 255
                if 255 in (a,b):
                    flags.add('nan')
                scale = a + b - 254
            for k in range(kmax):
                ac, an, am, ae = decode(self.a >> (FORMATS[self.ta][3]*k), self.ta, self.na)
                bc, bn, bm, be = decode(self.b >> (FORMATS[self.tb][3]*k), self.tb, self.nb)
                if 'nan' in (ac,bc) or {ac,bc} == {'zero','inf'}:
                    flags.add('nan')
                elif 'inf' in (ac,bc):
                    flags.add(an ^ bn)
                terms.append(((-1 if an ^ bn else 1) * am * bm << (5 if wide else 19), ae+be))
            terms.append((csign * cmag << 2, cexp-scale))
            result = align(terms, scale-25)
        if 'nan' in flags or len(flags)>1:
            return QNAN
        if flags:
            return NINF if flags.pop() else PINF
        return result

    def emit(self):
        control = [self.kind,self.ta,self.tb,self.shift,self.na,self.nb,self.sat,self.ue4,self.asym,self.ncode,self.ws]
        print(*(int(v) for v in control), *(f'{v:x}' for v in [self.a,self.b,self.c,self.sa,self.sb,self.value()]))


def vectors():
    # Alternating pipeline lengths and independent factors/operand signs.
    yield Vector(2, 7, 7, 0x3, 0x2)
    yield Vector(3, 9, 9, asym=True)
    yield Vector(0, 0, 0, 0x4000<<16, 0x4200<<16, 0x3f800000, na=True)
    yield Vector(5, 7, 7, int('2'*64,16), int('2'*64,16), 0xbf800000, 0x7f7f, 0x7f7f)
    yield Vector(6, 7, 7, int('2'*64,16), int('2'*64,16), 0xbf800000, 0x50484038, 0x38383838, ue4=True)
    yield Vector(0, 1, 1, 0x80, 0x80)
    # Fixed raw-bit cases for both array configurations. Check the integer
    # oracle against explicit expected results before using it as the scoreboard.
    scale_one = 0x38383838
    for vector, expected in [
        (Vector(1, 2, 2, 0x7f800001, 0x3f800000), QNAN),
        (Vector(1, 2, 2, 0x3f800000, 0xff800001), QNAN),
        (Vector(1, 2, 2, 0x7f802000, 0x3f800000), QNAN),
        (Vector(1, 2, 2, PINF, 0x3f800000), PINF),
        (Vector(1, 2, 2, PINF, 0), QNAN),
        # Zero times a large finite operand leaves C and other products intact.
        (Vector(0, 1, 1, 0, 0x7f00, c=0x2b800000), 0x2b800000),
        (Vector(0, 1, 1, 0x3080, 0x7f003f80), 0x30800000),
        (Vector(1, 2, 2, 0x30800000, 0x7f0000003f800000), 0x30800000),
        (Vector(2, 4, 4, 0, 0x7b, 1), 1),
        (Vector(4, 4, 4, 0, 0x7b, 0x80000001, sa=127, sb=127), 0x80000001),
        # With +1 and -1 present, 2^-25 survives alignment; 2^-26 truncates.
        (Vector(0, 1, 1, 0x3300bf803f80, 0x3f803f803f80), 0x33000000),
        (Vector(0, 1, 1, 0x3280bf803f80, 0x3f803f803f80), 0),
        (Vector(2, 3, 7, 0x38, 1, 0xb2800000), 0x3effffff),
        (Vector(6, 7, 7, c=1, sa=scale_one, sb=scale_one, ue4=True), 1),
        (Vector(6, 7, 7, c=0x80000001, sa=scale_one, sb=scale_one, ue4=True), 0x80000001),
        # Group 0 sums to zero at huge scales. Group 2 contributes exactly one.
        (Vector(5, 7, 7, (2 << 128) | 0xa2, (2 << 128) | 0x22,
                sa=0x7ffe, sb=0x7ffe), 0x3f800000),
        # A zero scale nulls a nonzero group, leaving the smallest nonzero C.
        (Vector(6, 7, 7, 2, 2, c=1, sa=0, sb=scale_one, ue4=True), 1),
        # A negative nonzero K64 result packs to -0 at -2^-150, and to
        # the smallest negative subnormal at -2^-149. Cancellation gives +0.
        (Vector(5, 7, 7, 0xa, 2, sa=0x3434, sb=0x3434), 0x80000000),
        (Vector(5, 7, 7, 0xa, 2, sa=0x3434, sb=0x3535), 0x80000001),
        (Vector(5, 7, 7, 0xa2, 0x22, sa=0x3434, sb=0x3434), 0),
    ]:
        assert vector.value() == expected, (vector, hex(vector.value()), hex(expected))
        yield vector
    yield Vector(2, 3, 3, 0x3f, 0x3f, 0x49800000, na=True)
    for sat, ta, tb, a, b, c in itertools.product((False,True), (8,9), (8,9), (0xff,0x80), (0xff,0x7f), (0x7fffffff,0x80000000)):
        yield Vector(3, ta, tb, int(f'{a:02x}'*32,16), int(f'{b:02x}'*32,16), c, sat=sat)
    type_pairs = [[0,1], [2], list(range(3,8)), [8,9], list(range(3,8)), [7], [7]]
    for kind, types in enumerate(type_pairs):
        modes = (False,True) if kind <= 3 else (False,)
        for ta,tb,ws,ncode in itertools.product(types,types,modes,range(3)):
            for rep in range(3):
                v=Vector(kind,ta,tb,RNG.getrandbits(256),RNG.getrandbits(256),RNG.getrandbits(32),
                         RNG.getrandbits(32),RNG.getrandbits(32),ncode=ncode,ws=ws)
                if not ws and kind<=1: v.shift=RNG.randrange(16)
                if kind!=3: v.na,v.nb=bool(RNG.randrange(2)),bool(RNG.randrange(2))
                if kind==3: v.sat=bool(rep%2)
                if kind==6: v.ue4=bool(rep%2)
                yield v
    # Maximum E2M1 magnitude and scale significand exercise bit 18 of gamma
    # and both signs of the signed49 reduction. With zero groups, C alone
    # exercises the full signed37 aligned accumulator.
    for negative in (False, True):
        lanes = int('7' * 64, 16)
        yield Vector(6, 7, 7, lanes, lanes, sa=0x3f3f3f3f, sb=0x3f3f3f3f,
                     ue4=True, na=negative)
        yield Vector(6, 7, 7, c=0xbfffffff if negative else 0x3fffffff,
                     sa=0x38383838, sb=0x38383838, ue4=True)
    # A scale NaN wins even when C alone would select an infinity.
    for c in (PINF, NINF):
        yield Vector(6, 7, 7, c=c, sa=0x7f383838, sb=0x38383838, ue4=True)
    # Scale endpoints and slow subnormal alignment/both signs of underflow.
    for dtype in range(3,8):
        for sf in (0,1,127,254,255):
            yield Vector(4,dtype,dtype,0x01,0x02,1,sf,127,nb=True)
    for mode in (False,True):
        for sf in (0,1,127,128,254,255):
            yield Vector(6,7,7,0x7,0x7,0xffffffff if sf==1 else 1,sf,127,ue4=mode)
    for c in (1,0x80000001,0x007fffff,0x00800001,0x03801235,0x7f800000,0xff800000):
        for shift in (0,1,3,15):
            yield Vector(0,0,0,c=c,shift=shift)

    # Cancel the unit product with C so a bad shift or premature pair sum
    # remains visible. Move the unit product across the four exponent groups.
    for distance in (0, 25, 26, 27, 31, 32):
        for group, negative in itertools.product(range(4), (False, True)):
            lane = 4 * group
            small = ((127 - distance) << 7) | 0x7f | (negative << 15)
            a = (0x3f80 | (small << 16)) << (16 * lane)
            b = (0x3f80 | (0x3fff << 16)) << (16 * lane)
            yield Vector(0, 1, 1, a, b, c=0xbf800000)
    # Opposite BF16 products at exponent 254 cancel. The third product
    # has exponent -252, giving the maximum alignment distance of 506.
    for sign in (0, 0x8000):
        a = 0x7f00 | (0xff00 << 16) | ((0x00ff | sign) << 32)
        b = 0x7f00 | (0x7f00 << 16) | (0x00ff << 32)
        yield Vector(0, 1, 1, a, b)
    # Near-two FP16 inputs exercise the full pair and final adder widths.
    for negative in (False, True):
        lanes = int('3fff' * 16, 16)
        yield Vector(0, 0, 0, lanes, lanes, c=0xbfffffff if negative else 0x3fffffff, na=negative)

    # The bench drains before this 96-request window, then requires one issue per clock.
    for i in range(96):
        if (i < 48 and i % 2 == 0) or (i >= 48 and i % 12 == 0):
            yield Vector(2, 3, 4, a=0x38, b=0x3c, c=0x3f800000)
        else:
            yield Vector(0, 0, 1, a=0x3c00, b=0x3f80, c=0xbf800000)

    # The testbench issues these last four separately to measure exact latency.
    yield Vector(3, 8, 9, 0x1ff, 0x302, 4)
    yield Vector(0, 0, 1, 0x3c00, 0x3f80)
    yield Vector(4, 7, 6, 0x13, 0x22, sa=127, sb=127)
    yield Vector(6, 7, 7, 0x37, 0x55, sa=0x38383838, sb=0x38383838, ue4=True)


if __name__ == '__main__':
    for vector in vectors():
        vector.emit()
