import sys
W,H=int(sys.argv[2]),int(sys.argv[3]); fs=W*H*5//4; stride=W*5//4
d=open(sys.argv[1],'rb').read(); f=d[-fs:]
img=[[0]*W for _ in range(H)]
for y in range(H):
    row=f[y*stride:(y+1)*stride]
    for x4 in range(W//4):
        b=row[x4*5:x4*5+5]; lo=b[4]
        for k in range(4): img[y][x4*4+k]=max(0,((b[k]<<2)|((lo>>(2*k))&3))-64)
vals=sorted(v for r in img for v in r); mx=max(1,vals[int(len(vals)*0.995)])
g=lambda v: min(255,int(255*(max(0,v)/mx)**(1/2.2)))
order=sys.argv[4] if len(sys.argv)>4 else "GRBG"
pos={c:[] for c in "RGB"}
for i,c in enumerate(order): pos[c].append((i//2,i%2))
with open('frame.ppm','wb') as o:
    o.write(f"P6 {W//2} {H//2} 255\n".encode()); out=bytearray()
    for y in range(0,H-1,2):
        for x in range(0,W-1,2):
            px=lambda c: sum(img[y+dy][x+dx] for dy,dx in pos[c])/len(pos[c])
            out+=bytes((g(px("R")*20/15.8),g(px("G")),g(px("B")*20/5.8)))
    o.write(out)
