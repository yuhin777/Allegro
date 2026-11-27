"""Emit independent B request tokens, masks and assembled blocks for the RTL replay."""

MODES={0:(16,0),1:(128,0x60),2:(128,0x70),4:(64,0x30),6:(32,0x10)}
WIDTH=(16,16,32,8,8,6,6,4,8,8)


def memory(addr):
    return ((addr*0x9d + (addr>>3)*0x57 + (addr>>9)*0x37 + 0xab) ^ (addr>>12)) & 255


def address(d,r,z,t):
    start=(d & 0x3fff)*16
    lbo=((d>>16)&0x3fff)*16
    sbo=((d>>32)&0x3fff)*16
    mode=d>>61
    w,x=MODES[mode]
    if t and mode==0:
        offset=r%16 + r//16*sbo + z%8*16 + z//8*lbo
    elif t:
        h=4 if mode==1 else 8
        offset=r%w + r//w*lbo + z%h*w + z//h*sbo
    else:
        offset=r%8*w + r//8*sbo + (z%16+z//16*lbo if mode==0 else z)
    pos=start+offset
    return pos ^ ((pos>>(2 if mode==1 else 3))&x)


def source(d,t,dtype,kind,row,k,bit):
    width=WIDTH[dtype]
    e=row if t else k
    physical=128*(e//16)+width*(e%16)+bit if width<8 and kind<5 else width*e+bit
    byte=address(d,physical//8,k,True) if t else address(d,row,physical//8,False)
    return byte,physical%8


def block_vectors(d,t,dtype,kind,j):
    data=0
    requests=[{} for _ in range(16)]
    width=WIDTH[dtype]
    container=max(width,8) if kind<5 else 4
    for c in range(8):
        for k in range(256//container):
            p=2*(k%8)+k//8 if kind==0 and t else 2*c+(k*container)//128
            for b in range(width):
                addr,bit=source(d,t,dtype,kind,8*j+c,k,b)
                atom=addr & -16
                requests[p][atom]=requests[p].get(atom,0)|(1<<(addr%16))
                data |= ((memory(addr)>>bit)&1)<<(256*c+k*container+b)
    return data,requests


def cases():
    # Includes panel subblocks with nonzero phase, collapsed strides, and
    # duplicate source addresses in different pieces.
    yield 0,0,False,0,0,128,256,0
    yield 0,1,True,0,1,256,128,0
    for dt in (0,1):
        for trans in (False,True):
            for code,mode in enumerate((2,4,6)):
                yield 0,dt,trans,mode,code,256,1024,160
    for mode in (0,1,2,4,6):
        yield 1,2,False,mode,0,128,1024,160
    yield 1,2,True,1,1,512,512,160
    for dt in range(3,10):
        kind=3 if dt>=8 else 2
        for mode in (0,2,4,6):
            yield kind,dt,False,mode,0,128,512,160
            if WIDTH[dt]==8:
                yield kind,dt,True,mode,0,512,1024,160
    for mode in (0,2,4,6):
        for stride in (0,16,48,80,112,192):
            yield 3,9,True,mode,0,stride,stride,160
    yield 3,9,True,0,0,0,0,0
    yield 4,6,False,6,1,128,512,160
    yield 5,7,False,2,0,128,512,160
    yield 6,7,False,4,2,128,1024,160


def main():
    all_cases=list(cases())
    print(len(all_cases))
    for i,(kind,dt,t,mode,n,lbo,sbo,start) in enumerate(all_cases):
        desc=(mode<<61)|((1 if mode and start else 0)<<49)|(1<<46)|((sbo//16)<<32)|((lbo//16)<<16)|(start//16)
        print(kind,dt,int(t),n,f'{desc:x}')
        for j in range(8<<n):
            data,req=block_vectors(desc,t,dt,kind,j)
            print(f'{data:x}')
            for pairs in req:
                print(len(pairs),*(f'{addr:x} {mask:x}' for addr,mask in sorted(pairs.items())))


if __name__=='__main__':
    main()
