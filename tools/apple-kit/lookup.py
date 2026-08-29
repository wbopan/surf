#!/usr/bin/env python3
"""查 Apple 官方 macOS 27 UI Kit（Sketch 版）里的控件数值。数据先跑 fetch.sh 取。
  lookup.py list <substr>          按名字模糊列 symbol（页/名/尺寸）
  lookup.py show <substr> [n]      展开第 n 个命中 symbol 的层树：frame / 圆角 / 填充 / 阴影 / 字体
  lookup.py colors [substr]        颜色变量（System Colors / Labels / Fills …）
  lookup.py text [substr]          文字样式（字号/字重/行高）
数据目录：$APPLE_KIT_DIR，缺省 <仓库根>/.scratch/apple-design/。命名规律见同目录 README.md。"""
import json,glob,sys,os,functools,signal
signal.signal(signal.SIGPIPE,signal.SIG_DFL)
DATA=os.environ.get('APPLE_KIT_DIR') or os.path.join(
    os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))),'.scratch','apple-design')
ROOT=os.path.join(DATA,'macos27')
if not os.path.isfile(os.path.join(ROOT,'document.json')):
    sys.exit(f"套件数据不在 {DATA}/。先跑 tools/apple-kit/fetch.sh（约 110MB，匿名下载）。")
IDX=json.load(open(os.path.join(DATA,'symbols-index.json')))
DOC=json.load(open(f'{ROOT}/document.json'))
def rgba(c): return f"rgba({round(c['red']*255)},{round(c['green']*255)},{round(c['blue']*255)},{round(c['alpha'],3)})"
SW={s['do_objectID']:s for s in DOC['sharedSwatches']['objects']}
STY={s['do_objectID']:s for s in DOC['layerStyles']['objects']}
TXT={s['do_objectID']:s for s in DOC['layerTextStyles']['objects']}
SYMNAME={s['id']:s['name'] for s in IDX}
@functools.lru_cache(None)
def page(f): return json.load(open(f'{ROOT}/pages/{f}'))
def find(sub): sub=sub.lower(); return [s for s in IDX if sub in s['name'].lower()]
def desc_style(st):
    out=[]
    for f in st.get('fills',[]) or []:
        if f.get('isEnabled'):
            c=f.get('color'); sw=f.get('colorVariable') or {}
            out.append('fill='+(rgba(c) if c else '?')+(f" <{SW[sw['identifier']]['name']}>" if sw.get('identifier') in SW else ''))
    for b in st.get('borders',[]) or []:
        if b.get('isEnabled'): out.append(f"border={rgba(b['color'])} w={b.get('thickness')}")
    for s in st.get('shadows',[]) or []:
        if s.get('isEnabled'): out.append(f"shadow=({s['offsetX']},{s['offsetY']},blur {s['blurRadius']}) {rgba(s['color'])}")
    if st.get('blur',{}).get('isEnabled'): out.append(f"blur={st['blur'].get('radius')}")
    return ' '.join(out)
def walk(L,d=0,ox=0,oy=0):
    fr=L['frame']; x,y=ox+fr['x'],oy+fr['y']
    bits=[f"{'  '*d}{L['_class']:<14} {L['name'][:48]:<48} x={x:g} y={y:g} {fr['width']:g}x{fr['height']:g}"]
    if L['_class']=='rectangle' and L.get('points'):
        r={p.get('cornerRadius',0) for p in L['points']}
        if r-{0}: bits.append(f"radius={sorted(r)}")
    if L['_class']=='symbolInstance': bits.append('→ '+SYMNAME.get(L.get('symbolID'),'?'))
    st=L.get('style') or {}
    sid=(L.get('sharedStyleID'))
    if sid in STY: bits.append(f"<{STY[sid]['name']}>")
    ds=desc_style(st)
    if ds: bits.append(ds)
    if L['_class']=='text':
        a=st.get('textStyle',{}).get('encodedAttributes',{}); f=a.get('MSAttributedStringFontAttribute',{}).get('attributes',{})
        col=a.get('MSAttributedStringColorAttribute')
        bits.append(f"font={f.get('name')} {f.get('size')}"+(f" color={rgba(col)}" if col else '')+(f" <{TXT[sid]['name']}>" if sid in TXT else '')+f" text={L.get('attributedString',{}).get('string','')[:30]!r}")
    print(' | '.join(bits))
    for c in L.get('layers',[]) or []: walk(c,d+1,x,y)
cmd=sys.argv[1] if len(sys.argv)>1 else 'list'; arg=sys.argv[2] if len(sys.argv)>2 else ''
if cmd=='list':
    for s in find(arg): print(f"{s['w']:>6g}x{s['h']:<6g} {s['page']} / {s['name']}")
elif cmd=='show':
    hits=find(arg); n=int(sys.argv[3]) if len(sys.argv)>3 else 0
    if not hits: sys.exit('no match')
    s=hits[n]; print(f"### {s['page']} / {s['name']}  ({len(hits)} hits, showing #{n})")
    for L in page(s['file'])['layers']:
        if L.get('_class')=='symbolMaster' and L['symbolID']==s['id']: walk(L)
elif cmd=='colors':
    for s in DOC['sharedSwatches']['objects']:
        if arg.lower() in s['name'].lower(): print(f"{s['name']:<50} {rgba(s['value'])}")
elif cmd=='text':
    for t in DOC['layerTextStyles']['objects']:
        if arg.lower() in t['name'].lower():
            a=t['value']['textStyle']['encodedAttributes']; f=a.get('MSAttributedStringFontAttribute',{}).get('attributes',{}); p=a.get('paragraphStyle',{})
            print(f"{t['name']:<40} {f.get('name')} {f.get('size')}pt  lineHeight={p.get('maximumLineHeight')} kern={a.get('kerning')}")
else:
    sys.exit(__doc__)
