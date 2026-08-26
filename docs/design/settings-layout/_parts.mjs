// 六张画板共用的外壳与样式。画板之间运行时不共享任何东西，所以这里在生成期展开。
export const CSS = `
*{box-sizing:border-box}
body{margin:0;font:13px/1.35 -apple-system,"SF Pro Text","PingFang SC",system-ui,sans-serif;-webkit-font-smoothing:antialiased;color:#1d1d1f;background:#fff}
a{color:#0a66f5}a:hover{color:#0a4fc0}
.win{display:flex;flex-direction:column;height:100%;background:#fff}
.chrome{background:#f6f6f6;border-bottom:1px solid #d7d7d9;padding:10px 0 0}
.lights{display:flex;gap:8px;padding:0 13px}
.lights i{width:12px;height:12px;border-radius:50%;display:block}
.title{text-align:center;font-size:13px;font-weight:600;margin:-16px 0 0}
.tabs{display:flex;justify-content:center;gap:2px;padding:9px 0 7px}
.tab{display:flex;flex-direction:column;align-items:center;gap:3px;width:76px;padding:5px 0 4px;border-radius:7px;font-size:11px;color:#3c3c43}
.tab.on{background:#e3e3e5;color:#0a66f5}
.body{flex:1;min-height:0;padding:20px 26px 22px;display:flex;flex-direction:column}
.form{display:grid;grid-template-columns:170px 1fr;column-gap:10px;row-gap:11px;align-items:start}
.lab{text-align:right;font-size:13px;padding-top:4px;white-space:nowrap}
.ctl{display:flex;flex-direction:column;gap:4px;align-items:flex-start}
.hint{font-size:11px;color:#86868b;line-height:1.4}
.rule{grid-column:2;border-top:1px solid #e2e2e4;margin:4px 0 1px;height:0}
.popup{display:inline-flex;align-items:center;gap:10px;background:#eaeaec;border-radius:6px;padding:4px 8px 4px 11px;font-size:13px;box-shadow:inset 0 0 0 .5px rgba(0,0,0,.11)}
.field{background:#fff;border:1px solid #cfcfd2;border-radius:5px;padding:4px 8px;font-size:13px;color:#1d1d1f}
.btn{background:#fbfbfb;border:1px solid #cfcfd2;border-radius:6px;padding:4px 12px;font-size:13px;box-shadow:0 .5px 1px rgba(0,0,0,.06)}
.seg{display:inline-flex;background:#e6e6e8;border-radius:7px;padding:2px;gap:2px}
.seg span{padding:3px 15px;border-radius:5px;font-size:12.5px;color:#3c3c43}
.seg .on{background:#fff;color:#1d1d1f;box-shadow:0 .5px 1.5px rgba(0,0,0,.22)}
.cb{width:14px;height:14px;border-radius:3.5px;background:#0a66f5;display:inline-flex;align-items:center;justify-content:center;flex:none}
.cb.off{background:#fff;box-shadow:inset 0 0 0 1px #c4c4c7}
.mono{font-family:ui-monospace,"SF Mono",Menlo,monospace;font-size:11.5px;color:#86868b}
.dot{width:7px;height:7px;border-radius:50%;display:inline-block;flex:none}
.split{display:flex;gap:16px;flex:1;min-height:0}
.list{width:186px;display:flex;flex-direction:column;border:1px solid #d5d5d8;border-radius:6px;background:#fff;overflow:hidden;flex:none}
.li{display:flex;align-items:center;gap:8px;padding:6px 10px;font-size:13px}
.li .sub{font-size:11px;color:#86868b;margin-left:auto}
.li.on{background:#dcdcde}
.grp{font-size:10.5px;font-weight:600;color:#86868b;letter-spacing:.05em;padding:9px 10px 3px}
.foot{display:flex;border-top:1px solid #d5d5d8;background:#fafafa;height:23px;margin-top:auto}
.foot b{width:29px;display:flex;align-items:center;justify-content:center;font-weight:400;font-size:14px;color:#3c3c43;border-right:1px solid #e4e4e6}
.detail{flex:1;min-width:0;display:flex;flex-direction:column;gap:13px}
.strip{display:inline-flex;align-self:center;border:1px solid #c9c9cc;border-radius:6px;padding:1px;background:#f2f2f3}
.strip span{padding:3px 14px;font-size:12.5px;border-radius:5px;color:#3c3c43}
.strip .on{background:#fff;color:#1d1d1f;box-shadow:0 .5px 1.5px rgba(0,0,0,.20)}
.table{border:1px solid #d5d5d8;border-radius:6px;overflow:hidden;background:#fff}
.thead{background:#f3f3f4;border-bottom:1px solid #dcdcdf;font-size:11px;color:#6e6e73}
.thead span{padding:4px 10px;border-right:1px solid #e3e3e5}
.tr{font-size:12.5px;align-items:center}
.tr:nth-child(even){background:#f8f8f9}
.tr span{padding:5px 10px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;display:block}
.search{display:inline-flex;align-items:center;gap:6px;background:#eaeaec;border-radius:6px;padding:4px 9px;font-size:13px;color:#86868b;box-shadow:inset 0 0 0 .5px rgba(0,0,0,.11)}
`;

const ICON = {
  gear: '<circle cx="12" cy="12" r="3.3"/><path d="M12 2.6v2.3M12 19.1v2.3M21.4 12h-2.3M4.9 12H2.6M18.6 5.4l-1.6 1.6M7 17l-1.6 1.6M18.6 18.6L17 17M7 7L5.4 5.4"/>',
  chip: '<rect x="6.4" y="6.4" width="11.2" height="11.2" rx="2.2"/><rect x="10" y="10" width="4" height="4" rx="1"/><path d="M9.4 3.2v3.2M14.6 3.2v3.2M9.4 17.6v3.2M14.6 17.6v3.2M3.2 9.4h3.2M3.2 14.6h3.2M17.6 9.4h3.2M17.6 14.6h3.2"/>',
  plug: '<rect x="4.4" y="4.4" width="15.2" height="15.2" rx="3.4"/><path d="M4.4 10.1h2.2a1.9 1.9 0 1 1 0 3.8H4.4"/>',
  wand: '<path d="M4.6 19.4l8.8-8.8"/><path d="M12.4 4.6l.95 2.15 2.15.95-2.15.95-.95 2.15-.95-2.15-2.15-.95 2.15-.95z"/><path d="M18.4 12.6l.62 1.4 1.4.62-1.4.62-.62 1.4-.62-1.4-1.4-.62 1.4-.62z"/>',
};

function tab(key, label, active) {
  return `<div class="tab${active ? ' on' : ''}">`
    + `<svg width="22" height="22" viewBox="0 0 24 24" fill="none" stroke="${active ? '#0a66f5' : '#4a4a4f'}" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round">${ICON[key]}</svg>`
    + `<span>${label}</span></div>`;
}

/** 标题栏 + 工具栏。`which` 是当前页。 */
export function chrome(which) {
  return `<div class="chrome">
  <div class="lights"><i style="background:#ff5f57"></i><i style="background:#febc2e"></i><i style="background:#28c840"></i></div>
  <div class="title">${which.title}</div>
  <div class="tabs">
    ${tab('gear', '通用', which.key === 'general')}
    ${tab('chip', '模型', which.key === 'models')}
    ${tab('plug', '插件', which.key === 'plugins')}
    ${tab('wand', '智能体预设', which.key === 'presets')}
  </div>
</div>`;
}

export const CHEVRON = '<svg width="10" height="14" viewBox="0 0 10 14" fill="none" stroke="#6e6e73" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><path d="M2.2 6L5 3.2 7.8 6M2.2 8L5 10.8 7.8 8"/></svg>';
export const TICK = '<svg width="9" height="9" viewBox="0 0 10 10" fill="none" stroke="#fff" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round"><path d="M1.6 5.2l2.2 2.2L8.4 2.8"/></svg>';
export const GLASS = '<svg width="12" height="12" viewBox="0 0 14 14" fill="none" stroke="#86868b" stroke-width="1.4" stroke-linecap="round"><circle cx="6.2" cy="6.2" r="4"/><path d="M9.2 9.2l3 3"/></svg>';

/** 包一个完整的 .dc.html。静态画板不需要 data-dc-script。 */
export function page(bodyHtml) {
  return `<!doctype html>
<html>
<head>
  <meta charset="utf-8">
  <script src="./support.js"></script>
</head>
<body>
<x-dc>
<helmet>
  <style>${CSS}</style>
</helmet>
${bodyHtml}
</x-dc>
</body>
</html>
`;
}
