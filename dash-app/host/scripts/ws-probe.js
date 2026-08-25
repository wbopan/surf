// WS 事件流协议探针：连接 mux + host，打印前几帧的 method，验证帧格式
const ws = require("/Users/wenbopan/Library/Application Support/io.wenbo.dsharness/harness/versions/0.1.1-rc.2/node_modules/ws");

const port = process.argv[2];
const out = [];
function probe(name, path, n) {
  return new Promise((resolve) => {
    const sock = new ws(`ws://127.0.0.1:${port}${path}`);
    const seen = [];
    const timer = setTimeout(() => { sock.close(); resolve(seen); }, 4000);
    sock.on("message", (data) => {
      try {
        const obj = JSON.parse(data.toString());
        seen.push(obj.method || obj.type);
        out.push(`${name}: ${obj.method} ${JSON.stringify(obj.payload || {}).slice(0, 140)}`);
        if (seen.length >= n) { clearTimeout(timer); sock.close(); resolve(seen); }
      } catch {}
    });
    sock.on("error", (e) => { clearTimeout(timer); out.push(`${name}: ERROR ${e.message}`); resolve(seen); });
    sock.on("close", () => resolve(seen));
  });
}

(async () => {
  const mux = await probe("MUX", "/api/events.mux", 3);
  const host = await probe("HOST", "/api/events.host", 3);
  console.log(out.join("\n"));
  console.log(`SUMMARY mux=${mux.join(",")} host=${host.join(",")}`);
})();
