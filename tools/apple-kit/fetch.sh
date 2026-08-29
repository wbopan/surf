#!/usr/bin/env bash
# 匿名下载 Apple 官方 macOS 27 UI Kit（Sketch 版）并建符号索引。
# 数据落 $APPLE_KIT_DIR（默认 <仓库根>/.scratch/apple-design/，已 gitignore，不入库）。
#
# 原理（2026-08 实测）：developer.apple.com/design/resources 上 macOS 27 的
# "Download for Sketch" 是一个 sketch.com 公开云文档（publicAccessLevel=VIEW），
# 其 GraphQL 接口 graphql.sketch.cloud 无需登录就能拿到带 token 的下载地址。
# Figma 版（community file 1651309434229735362）没有等价的匿名下载；`.fig` 是
# 私有二进制不可解析——`.sketch` 是 zip 包 JSON，这正是选 Sketch 版的原因。
#
# 用法：tools/apple-kit/fetch.sh [--force]   # 已有数据时秒过，--force 重新下载
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
DIR="${APPLE_KIT_DIR:-$ROOT/.scratch/apple-design}"
# macOS 27 UI Kit 的分享 id。Apple 出新版时到设计资源页抓新的 sketch.com/s/<id> 链接换掉它。
SHORT_ID="57153a31-3379-4737-8ac6-dbfd6525f052"
mkdir -p "$DIR"
if [ ! -f "$DIR/macos27/document.json" ] || [ "${1:-}" = "--force" ]; then
  echo "取下载地址…" >&2
  URL=$(curl -s -A Mozilla/5.0 -H 'content-type: application/json' https://graphql.sketch.cloud/api \
    --data "{\"query\":\"{ share(shortId:\\\"$SHORT_ID\\\"){ version{ document{ url } } } }\"}" \
    | python3 -c 'import sys,json;print(json.load(sys.stdin)["data"]["share"]["version"]["document"]["url"])')
  echo "下载（约 110MB）…" >&2
  curl -L -A Mozilla/5.0 "$URL" -o "$DIR/macos27.sketch"
  rm -rf "$DIR/macos27"
  unzip -q "$DIR/macos27.sketch" -d "$DIR/macos27"
fi
python3 - "$DIR" <<'EOF'
import json,glob,os,sys
d=sys.argv[1]; idx=[]
for pf in glob.glob(f'{d}/macos27/pages/*.json'):
    pg=json.load(open(pf))
    for L in pg.get('layers',[]):
        if L.get('_class')=='symbolMaster':
            fr=L['frame']
            idx.append({'name':L['name'],'page':pg['name'],'w':fr['width'],'h':fr['height'],
                        'id':L['symbolID'],'file':os.path.basename(pf)})
idx.sort(key=lambda x:(x['page'],x['name']))
json.dump(idx,open(f'{d}/symbols-index.json','w'),ensure_ascii=False,indent=0)
with open(f'{d}/symbols-index.tsv','w') as f:
    for s in idx:
        f.write(f"{s['page']}\t{s['name']}\t{s['w']:g}x{s['h']:g}\t{s['id']}\t{s['file']}\n")
print(f"索引就绪：{len(idx)} 个 symbol → {d}/symbols-index.tsv")
EOF
