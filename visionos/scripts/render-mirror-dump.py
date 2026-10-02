#!/usr/bin/env python3
# Renders a scene-mirror dump (TPVR_TEST_MIRROR_DUMP=<frame>, copied out of the app's
# Documents/mirror-dump) from the game camera with a small software rasterizer, as the game would
# draw that data: textures, mul/add colour, cut-outs, blends, back-face culling as RealityKit does
# it. If this looks right and the window doesn't, the fault is on the RealityKit side (materials,
# placement, clipping); if this looks wrong too, it's in the capture (aurora's mirror.cpp).
#
#   visionos/scripts/render-mirror-dump.py <dump folder> <out.png> [cull|nocull]   (needs numpy, Pillow)
import sys, glob, re, numpy as np
from PIL import Image
d=sys.argv[1]; out=sys.argv[2]; cull=sys.argv[3]=="cull"
W,H=608,448
v=np.fromfile(d+"/vertices.bin",dtype=np.uint8).reshape(-1,36)
pos=v[:,0:12].copy().view(np.float32).reshape(-1,3).astype(np.float64)
uv=v[:,12:20].copy().view(np.float32).reshape(-1,2).astype(np.float64)
mul=v[:,20:28].copy().view(np.float16).reshape(-1,4).astype(np.float64)
add=v[:,28:36].copy().view(np.float16).reshape(-1,4).astype(np.float64)
idx=np.fromfile(d+"/indices.bin",dtype=np.uint32).reshape(-1,3)
parts=[l.split() for l in open(d+"/parts.txt")]
tex={}
for f in glob.glob(d+"/tex-*.rgba"):
    m=re.search(r"tex-(\d+)-(\d+)x(\d+)",f); i,w,h=map(int,m.groups())
    tex[i]=np.fromfile(f,dtype=np.uint8).reshape(h,w,4).astype(np.float64)/255
tx,ty=[float(x) for x in open(d+"/camera.txt").read().split()[:2]]
z=-pos[:,2]
sx=(pos[:,0]/np.maximum(z,1e-3)/tx*0.5+0.5)*W
sy=(0.5-pos[:,1]/np.maximum(z,1e-3)/ty*0.5)*H
img=np.zeros((H,W,3)); zb=np.full((H,W),np.inf)
for p in parts:
    first,count,texid,kind,flags=int(p[0]),int(p[1]),int(p[2]),int(p[3]),int(p[4])
    weights=[float(x) for x in p[6:11]]
    T=tex.get(texid)
    for a,b,c in idx[first//3:(first+count)//3]:
        if min(z[a],z[b],z[c])<1: continue
        ax,ay,bx,by,cx,cy=sx[a],sy[a],sx[b],sy[b],sx[c],sy[c]
        area=(bx-ax)*(cy-ay)-(cx-ax)*(by-ay)   # screen y down: ccw-as-seen => negative
        if area==0: continue
        if cull and (flags&1) and area>0: continue   # RealityKit culls clockwise-as-seen (back)
        if cull and (flags&2) and area<0: continue
        x0,x1=int(max(0,np.floor(min(ax,bx,cx)))),int(min(W-1,np.ceil(max(ax,bx,cx))))
        y0,y1=int(max(0,np.floor(min(ay,by,cy)))),int(min(H-1,np.ceil(max(ay,by,cy))))
        if x0>x1 or y0>y1: continue
        X,Y=np.meshgrid(np.arange(x0,x1+1)+0.5,np.arange(y0,y1+1)+0.5)
        w0=((bx-X)*(cy-Y)-(cx-X)*(by-Y))/area; w1=((cx-X)*(ay-Y)-(ax-X)*(cy-Y))/area; w2=1-w0-w1
        inside=(w0>=0)&(w1>=0)&(w2>=0)
        if not inside.any(): continue
        iz=w0/z[a]+w1/z[b]+w2/z[c]; depth=1/iz
        pw=np.stack([w0/z[a],w1/z[b],w2/z[c]],-1)/iz[...,None]
        u=pw@uv[[a,b,c]]; m=pw@mul[[a,b,c]]; ad=pw@add[[a,b,c]]
        if T is not None:
            h,w=T.shape[:2]
            s=T[(np.floor(u[...,1]*h).astype(int))%h,(np.floor(u[...,0]*w).astype(int))%w]
        else: s=np.ones(u.shape[:-1]+(4,))
        col=np.clip(s[...,:3]*m[...,:3]+ad[...,:3],0,1); al=np.clip(s[...,3]*m[...,3]+ad[...,3],0,1)
        if kind==1: inside&=al>=float(p[5])
        sub=zb[y0:y1+1,x0:x1+1]; ok=inside&(depth<sub)
        if kind==2:
            cb,ca,ob,oa,ol=weights
            luma=col@np.array([0.2126,0.7152,0.0722])
            op=np.clip(ob+oa*al+ol*luma,0,1)[...,None]; cc=col*(cb+ca*al)[...,None]
            region=img[y0:y1+1,x0:x1+1]; region[ok]=(cc+region*(1-op))[ok]
        else:
            img[y0:y1+1,x0:x1+1][ok]=col[ok]; sub[ok]=depth[ok]
Image.fromarray((img*255).astype(np.uint8)).save(out)
