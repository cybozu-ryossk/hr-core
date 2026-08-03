#!/usr/bin/env node
// Adapter 単体のスモークテスト。Connect RPC を JSON over HTTP/2 で叩いて GetCapability / GetSchema /
// Select(all) / Count の応答を確認する。proxy/agent 不要。外部依存なし（Node 標準の http2 のみ）。
//
// 使い方:
//   node smoke.mjs [--port 8082] [--host localhost] [--service <完全修飾サービス名>]
//
// メモ: Request が { payload: {...} } でラップされるか直かは proto 世代による。うまく通らないときは
//       --raw で payload ラップを外す、または生成された型/proto を確認する。

import * as http2 from "node:http2";

const argv = process.argv.slice(2);
const getOpt = (name, def) => {
  const i = argv.indexOf(name);
  return i >= 0 ? argv[i + 1] : def;
};
const has = (name) => argv.includes(name);

const HOST = getOpt("--host", "localhost");
const PORT = Number(getOpt("--port", "8082"));
const SERVICE = getOpt("--service", "cybozu.data_connector.adapter.v1.AdapterService");
const RAW = has("--raw"); // payload ラップを外して送る

function wrap(payload) {
  return RAW ? payload : { payload };
}

function call(method, body) {
  return new Promise((resolve) => {
    const client = http2.connect(`http://${HOST}:${PORT}`);
    client.on("error", (err) => resolve({ method, ok: false, error: String(err) }));
    const data = JSON.stringify(body);
    const req = client.request({
      ":method": "POST",
      ":path": `/${SERVICE}/${method}`,
      "content-type": "application/json",
      "content-length": Buffer.byteLength(data),
    });
    let chunks = "";
    req.setEncoding("utf8");
    req.on("response", (headers) => { req.status = headers[":status"]; });
    req.on("data", (c) => (chunks += c));
    req.on("end", () => {
      client.close();
      let parsed;
      try { parsed = JSON.parse(chunks); } catch { parsed = chunks; }
      resolve({ method, ok: req.status === 200, status: req.status, body: parsed });
    });
    req.on("error", (err) => { client.close(); resolve({ method, ok: false, error: String(err) }); });
    req.write(data);
    req.end();
  });
}

const cases = [
  ["GetCapability", wrap({})],
  ["GetSchema", wrap({})],
  ["Select", wrap({
    fields: ["id", "name"],
    filterCondition: [{ allRecords: {} }],
    matchOperator: "MATCH_OPERATOR_ALL",
    sortConditions: [{ fieldId: "id", order: "SORT_ORDER_ASC" }],
    offset: 0,
    limit: 10,
  })],
  ["Count", wrap({
    filterCondition: [{ allRecords: {} }],
    matchOperator: "MATCH_OPERATOR_ALL",
  })],
];

console.log(`smoke: http://${HOST}:${PORT}  service=${SERVICE}  raw=${RAW}\n`);

let pass = 0;
for (const [method, body] of cases) {
  const r = await call(method, body);
  const mark = r.ok ? "PASS" : "FAIL";
  if (r.ok) pass++;
  const detail = r.ok
    ? JSON.stringify(r.body).slice(0, 300)
    : (r.error || `status=${r.status} ${JSON.stringify(r.body).slice(0, 300)}`);
  console.log(`[${mark}] ${method}\n       ${detail}\n`);
}

console.log(`result: ${pass}/${cases.length} passed`);
process.exit(pass === cases.length ? 0 : 1);
