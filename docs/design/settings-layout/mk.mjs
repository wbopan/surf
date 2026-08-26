// 生成六张画板。改布局改这里再跑 `node mk.mjs`，然后重新 seed。
import { writeFileSync } from "node:fs";
import { chrome, page, CHEVRON as CH, TICK, GLASS } from "./_parts.mjs";

const pop = (t) => `<span class="popup">${t} ${CH}</span>`;
const fld = (t, w, ghost) => `<span class="field" style="width:${w}px${ghost ? ";color:#b9b9bd" : ""}">${t}</span>`;
const tdot = (c) => `<span class="dot" style="background:${c};vertical-align:1px;margin-right:6px"></span>`;
const dot = (c) => `<span class="dot" style="background:${c}"></span>`;
const row = (lab, ctl) => `<div class="lab">${lab}</div><div class="ctl">${ctl}</div>`;
/** 一行控件 + 右侧单位。单位绝不进标题——标签列是所有行共享的，长标题会顶歪整页。 */
const unit = (ctl, u) => `<div class="ctl" style="flex-direction:row;align-items:center;gap:7px">${ctl}<span class="hint">${u}</span></div>`;
const RULE = '<div class="rule"></div>';

// ── 通用：一张纯表单。整页只有一种东西——右对齐标签 + 左对齐控件。────────
writeFileSync("Main.dc.html", page(`<div class="win">
${chrome({ key: "general", title: "通用" })}
  <div class="body">
    <div class="form">
      ${row("智能体预设：", `${pop("标准模式")}<span class="hint">新开的会话用这个预设。已经在跑的保持它开始时的那个。</span>`)}
      ${row("权限：", pop("完全放开"))}
      ${RULE}
      ${row("语言：", pop("English"))}
      ${row("外观：", `<div class="seg"><span>浅色</span><span>深色</span><span class="on">跟随系统</span></div>`)}
      ${RULE}
      ${row("忙碌时 Enter：", `${pop("排队")}<span class="hint">只在忙碌时生效；⌘/Ctrl+Enter 走另一种。</span>`)}
      ${RULE}
      ${row("配置文件：", `<span class="btn">在编辑器中打开…</span><span class="hint">schema 表达不了的东西（复杂容器、未知类型）在这里改。</span>`)}
    </div>
  </div>
</div>`));

// ── 模型：主从 + 内层 tab 条 + 一个右对齐组标签收尾。────────────────────
writeFileSync("Models.dc.html", page(`<div class="win">
${chrome({ key: "models", title: "模型" })}
  <div class="body" style="gap:14px">
    <div class="split" style="min-height:212px">
      <div class="list">
        <div class="li on">${dot("#e0443e")}DeepSeek</div>
        <div class="li">${dot("#30a14e")}Kimi For Coding</div>
        <div class="li">${dot("#30a14e")}zai-coding-cn</div>
        <div class="foot"><b>+</b><b>−</b></div>
      </div>
      <div class="detail">
        <div class="strip"><span class="on">凭据</span><span>自定义设置</span></div>
        <div class="form" style="grid-template-columns:88px 1fr;row-gap:9px">
          <div class="lab">名称：</div><div class="ctl" style="padding-top:4px">DeepSeek</div>
          <div class="lab">标识：</div><div class="ctl" style="padding-top:5px"><span class="mono">deepseek-official</span></div>
          <div class="lab">状态：</div><div class="ctl" style="flex-direction:row;align-items:center;gap:6px;padding-top:4px">${dot("#e0443e")}<span>没有 key · 路由已注册（key 从别处来）</span></div>
          ${RULE}
          <div class="lab">API key：</div>
          <div class="ctl">
            <div style="display:flex;gap:7px;align-items:center">${fld("填入 API key", 216, true)}<span class="btn">保存</span></div>
            <span class="hint">存在设置文件之外，引用名 <span class="mono">deepseek-official</span>（按命名约定推出来的）。</span>
          </div>
        </div>
      </div>
    </div>
    <div style="border-top:1px solid #e2e2e4"></div>
    <div class="form" style="row-gap:8px">
      ${row("默认模型：", pop("DeepSeek"))}
      ${row("", pop("deepseek-v4-pro"))}
      ${row("思考强度：", pop("高"))}
    </div>
  </div>
</div>`));

// ── 插件 · 插件配置：主从取代手风琴，六个字段一次摊开，不再需要「更多设置」。
writeFileSync("Plugins.dc.html", page(`<div class="win">
${chrome({ key: "plugins", title: "插件" })}
  <div class="body" style="gap:14px">
    <div class="strip"><span class="on">插件配置</span><span>插件列表</span></div>
    <div class="split" style="min-height:250px">
      <div class="list">
        <div class="li on">终端</div>
        <div class="li">智能体循环</div>
        <div class="li">网页搜索</div>
        <div class="grp">其余</div>
        <div class="li">自定义 provider</div>
        <div class="li">引导状态</div>
      </div>
      <div class="detail" style="gap:11px">
        <div style="display:flex;flex-direction:column;gap:2px">
          <span style="font-size:14px;font-weight:600">终端</span>
          <span class="hint">限制智能体跑的每一条命令。<span class="mono">shell</span></span>
        </div>
        <div class="form" style="grid-template-columns:118px 1fr;row-gap:9px">
          <div class="lab">工作目录：</div><div class="ctl">${fld("跟随会话", 228, true)}</div>
          ${RULE}
          <div class="lab">命令超时：</div>${unit(fld("120000", 88), "毫秒")}
          <div class="lab">超时上限：</div>${unit(fld("600000", 88), "毫秒")}
          <div class="lab">终止宽限：</div>${unit(fld("3000", 88), "毫秒")}
          ${RULE}
          <div class="lab">输出上限：</div>${unit(fld("64000", 88), "字节")}
          <div class="lab">溢出上限：</div>${unit(fld("67108864", 88), "字节")}
        </div>
      </div>
    </div>
  </div>
</div>`));

// ── 插件 · 插件列表：带边框的表，隔行底色。取消卡片与展开。────────────
const ROWS = [
  ["include", "include", 1], ["timer", "include:timer", 1],
  ["hmr", "include:hmr", 0], ["llm", "include:llm", 1],
  ["session", "include:session", 1], ["typert-registry", "include:typert", 1],
  ["api-gateway", "include:typert-gateway", 1], ["session-title", "include:session-title", 1],
  ["agent", "include:agent", 1], ["agent-default-model", "include:agent-default-model", 1],
  ["plan-mode", "include:plan-mode", 0], ["skill", "include:skill", 1],
];
const COLS = "grid-template-columns:1fr 1.2fr 92px";
writeFileSync("PluginList.dc.html", page(`<div class="win">
${chrome({ key: "plugins", title: "插件" })}
  <div class="body" style="gap:12px">
    <div class="strip"><span>插件配置</span><span class="on">插件列表</span></div>
    <span class="search">${GLASS} 搜索插件</span>
    <div class="table" style="flex:1;min-height:0;display:flex;flex-direction:column">
      <div class="thead" style="display:grid;${COLS}"><span>名称</span><span>条目</span><span style="border-right:none">状态</span></div>
      <div style="flex:1;min-height:0;overflow:hidden">
        ${ROWS.map(([n, id, on]) => `<div class="tr" style="display:grid;${COLS}"><span>${n}</span><span class="mono">${id}</span><span>${on ? tdot("#30a14e") + "已启用" : tdot("#c3c3c6") + '<span style="color:#86868b">已停用</span>'}</span></div>`).join("\n        ")}
      </div>
    </div>
    <span class="hint">171 个插件 · 29 个已停用 · 顺序即装载顺序</span>
  </div>
</div>`));

// ── 智能体预设：主从；「设为默认」变成一个无标签复选框。─────────────────
writeFileSync("Presets.dc.html", page(`<div class="win">
${chrome({ key: "presets", title: "智能体预设" })}
  <div class="body">
    <div class="split" style="min-height:250px">
      <div class="list">
        <div class="grp">内建</div>
        <div class="li on">标准模式<span class="sub">在用</span></div>
        <div class="li">PTC 模式</div>
        <div class="li">极简模式</div>
        <div class="li">创造模式</div>
        <div class="grp">自定义</div>
        <div class="li" style="color:#9a9aa0">还没有</div>
        <div class="foot"><b>+</b><b>−</b></div>
      </div>
      <div class="detail">
        <div style="display:flex;align-items:baseline;gap:8px">
          <span style="font-size:14px;font-weight:600">标准模式</span><span class="mono">standard</span>
        </div>
        <div class="form" style="grid-template-columns:70px 1fr;row-gap:10px">
          <div class="lab">说明：</div><div class="ctl" style="padding-top:3px"><span style="line-height:1.5">功能完整的编码 Agent，支持文件编辑、Shell、文件与网页检索、Skills、计划、目标、子代理和工作流。</span></div>
          ${RULE}
          <div class="lab"></div>
          <div class="ctl" style="flex-direction:row;align-items:center;gap:7px"><span class="cb">${TICK}</span><span>新会话默认用这个预设</span></div>
          ${RULE}
          <div class="lab">位置：</div>
          <div class="ctl"><div style="display:flex;gap:8px;align-items:center"><span class="mono">…/dsh-agent-presets/presets/standard</span><span class="btn">在 Finder 中显示</span></div></div>
        </div>
      </div>
    </div>
  </div>
</div>`));

// ── 版式规则表：这套语法本身，外加每个控件在 SwiftUI 里的真名。─────────
const spec = (t, d) => `<div style="display:flex;flex-direction:column;gap:2px"><span style="font-size:12.5px;font-weight:600">${t}</span><span class="hint">${d}</span></div>`;
/** 控件清单的一行：画出来的样子 + 它在 SwiftUI 里叫什么。 */
const api = (demo, name) => `<div style="display:flex;align-items:center;gap:10px;min-height:26px"><div style="width:150px;flex:none;display:flex;align-items:center">${demo}</div><span class="mono" style="font-size:11px;color:#5b5b60">${name}</span></div>`;

writeFileSync("Anatomy.dc.html", page(`<div class="win" style="background:#fff">
  <div style="padding:22px 26px 10px;border-bottom:1px solid #e2e2e4">
    <div style="font-size:15px;font-weight:600">版式规则</div>
    <div class="hint" style="margin-top:3px">四页共用一套语法。照 macOS 偏好设置（Mimestream / 信息）的老规矩；括号里是 SwiftUI 的真名，都在 macOS 27 SDK 里核过。</div>
  </div>
  <div class="body" style="gap:15px;padding-top:16px">

    <div style="display:flex;flex-direction:column;gap:7px">
      <span class="grp" style="padding:0">网格</span>
      <div style="position:relative;border:1px dashed #c9c9cc;border-radius:6px;padding:12px 14px">
        <div class="form" style="row-gap:11px">
          ${row("标签右对齐：", pop("控件左对齐"))}
          ${RULE}
          <div class="lab">单位在控件右边：</div>${unit(fld("120000", 88), "毫秒")}
        </div>
        <div style="position:absolute;left:194px;top:0;bottom:0;width:1px;background:#0a66f5;opacity:.3"></div>
        <div style="position:absolute;left:202px;top:-8px;font-size:10px;color:#0a66f5">控件列起点</div>
      </div>
      <span class="hint"><b>顶层页面</b>的表单：标签列 170pt、列间距 10pt、行距 11pt。<b>详情栏</b>的标签列按自己那几行收窄（70–120pt）——它是另一个表单，不跟外面共享列宽。<br>同一个表单里长标题绝不进标签列（单位、量词一律甩到控件右边）：列宽是这张表所有行共享的，一行顶歪一页。</span>
    </div>

    <div style="display:grid;grid-template-columns:1fr 1fr;gap:13px 22px">
      ${spec("分隔线只跨控件列", "不是整窗横线。它分的是控件的组，不是页面。")}
      ${spec("复选框没有左标签", "文案本身就是它的标签，紧贴控件列起点。")}
      ${spec("说明只在需要处出现", "11pt 灰字，控件正下方。每行都挂说明等于都没有。")}
      ${spec("组标签也右对齐", "多个控件共用一个标签时，标签对齐第一行（照 Advanced 的 Reset:）。")}
    </div>

    <div style="border-top:1px solid #e2e2e4"></div>

    <div style="display:flex;flex-direction:column;gap:5px">
      <span class="grp" style="padding:0">原生控件清单</span>
      <div style="display:grid;grid-template-columns:1fr 1fr;gap:2px 20px">
        ${api(pop("弹出菜单"), "Picker(.menu)")}
        ${api(fld("文本框", 92), "TextField")}
        ${api(`<div class="seg"><span>分段</span><span class="on">控件</span></div>`, "Picker(.segmented)")}
        ${api(`<span class="search">${GLASS} 搜索框</span>`, ".searchable(text:)")}
        ${api(`<span style="display:inline-flex;align-items:center;gap:7px"><span class="cb">${TICK}</span>复选框</span>`, "Toggle(.checkbox)")}
        ${api(`<span class="btn">按钮</span>`, "Button")}
      </div>
      <div style="display:flex;gap:14px;align-items:flex-start;margin-top:6px">
        <div style="width:150px;flex:none;display:flex;flex-direction:column;gap:4px">
          <div class="list" style="width:150px">
            <div class="li on">主从列表</div>
            <div class="li">可增删的才带页脚</div>
            <div class="foot"><b>+</b><b>−</b></div>
          </div>
          <span class="mono" style="font-size:10.5px;color:#5b5b60;line-height:1.5">List(selection:)<br>.listStyle(.bordered(<br>&nbsp;&nbsp;alternatesRowBackgrounds:))<br>+ .safeAreaInset(edge:.bottom)</span>
        </div>
        <div style="flex:1;display:flex;flex-direction:column;gap:5px">
          <div class="strip" style="align-self:flex-start"><span class="on">内层 tab 条</span><span>第二栏</span></div>
          <span class="mono" style="font-size:10.5px;color:#5b5b60">Picker(.segmented)</span>
          <div class="table" style="margin-top:5px">
            <div class="thead" style="display:grid;grid-template-columns:1fr 76px"><span>带边框的表</span><span style="border-right:none">隔行底色</span></div>
            <div>
              <div class="tr" style="display:grid;grid-template-columns:1fr 76px"><span>一行</span><span>白</span></div>
              <div class="tr" style="display:grid;grid-template-columns:1fr 76px"><span>又一行</span><span>灰</span></div>
            </div>
          </div>
          <span class="mono" style="font-size:10.5px;color:#5b5b60;line-height:1.5">Table(of:selection:sortOrder:) + TableColumn<br>.tableStyle(.bordered(alternatesRowBackgrounds:))<br>表头点一下就排序；TableColumnCustomization 能让用户<br>自己增删列并记住</span>
        </div>
      </div>
    </div>

  </div>
</div>`));

console.log("wrote 6 artboards");
