#!/usr/bin/env node
// kintone 外部システムアプリ化 Adapter（TypeScript / Connect RPC）の新規プロジェクトを scaffold する。
// 設定ファイル（package.json / .npmrc / tsconfig.json）と最小の起動スケルトンを生成する。
// 生成後: cd <dir> && pnpm install してから src/service.ts を実装する。
//
// 使い方:
//   node scaffold.mjs <project-dir> [--name <pkg-name>] [--port <n>] [--force]
//
// 注意: 実装本体（各 RPC のロジック）は生成しない。SKILL.md / references に沿って実装する。
//       AdapterService の import 先と各メッセージの形は install 後に node_modules/@buf/... の型で必ず確認する。

import { mkdirSync, writeFileSync, existsSync } from "node:fs";
import { join, resolve, basename } from "node:path";

const args = process.argv.slice(2);
const positional = [];
const opts = { name: null, port: 8082, force: false };
for (let i = 0; i < args.length; i++) {
  const a = args[i];
  if (a === "--name") opts.name = args[++i];
  else if (a === "--port") opts.port = Number(args[++i]);
  else if (a === "--force") opts.force = true;
  else if (a.startsWith("--")) { console.error(`unknown option: ${a}`); process.exit(1); }
  else positional.push(a);
}

const targetDir = positional[0];
if (!targetDir) {
  console.error("usage: node scaffold.mjs <project-dir> [--name <pkg-name>] [--port <n>] [--force]");
  process.exit(1);
}
const dir = resolve(targetDir);
const pkgName = opts.name || basename(dir);
const port = Number.isFinite(opts.port) ? opts.port : 8082;

mkdirSync(join(dir, "src"), { recursive: true });

const files = {
  "package.json": JSON.stringify({
    name: pkgName,
    version: "0.1.0",
    private: true,
    type: "module",
    scripts: {
      dev: "tsx watch ./src/index.ts",
      build: "tsc",
      start: "node ./dist/index.js",
      typecheck: "tsc --noEmit",
      smoke: `node ./scripts/smoke.mjs --port ${port}`
    },
    dependencies: {
      "@connectrpc/connect": "^2.0.2",
      "@connectrpc/connect-node": "^2.0.2",
      "@bufbuild/protobuf": "^2.3.0",
      // BSR で公開されている Adapter SDK。install には .npmrc の @buf レジストリ設定が必要。
      // 取得できない場合は references/verification.md の proto ローカル生成フォールバックを使う。
      "@buf/cybozu_kintone-data-connector.bufbuild_es": "latest"
    },
    devDependencies: {
      "typescript": "^5.8.3",
      "tsx": "^4.19.0",
      "@types/node": "^22.0.0"
    }
  }, null, 2) + "\n",

  ".npmrc":
`# BSR（Buf Schema Registry）から @buf/... の生成 SDK を取得するための設定。
@buf:registry=https://buf.build/gen/npm/v1/
`,

  "tsconfig.json": JSON.stringify({
    compilerOptions: {
      target: "es2022",
      module: "node16",
      moduleResolution: "node16",
      lib: ["es2023"],
      strict: true,
      esModuleInterop: true,
      skipLibCheck: true,
      sourceMap: true,
      outDir: "dist",
      rootDir: "src"
    },
    include: ["src"],
    exclude: ["node_modules", "dist"]
  }, null, 2) + "\n",

  ".gitignore":
`node_modules/
dist/
.claude-work/
*.pem
`,

  "src/data.ts":
`// 動作確認用のインメモリ・サンプルデータ。実運用では外部システムへの問い合わせに置き換える。
// フィールド構成は接続先に合わせて変更する（ここはあくまで雛形）。
export type Row = {
  id: number;
  name: string;
  // TODO: 接続先のフィールドを追加する
};

export const rows: Row[] = [
  { id: 1, name: "サンプルA" },
  { id: 2, name: "サンプルB" },
  { id: 3, name: "サンプルC" },
];
`,

  "src/service.ts":
`// AdapterService の実装スケルトン。
// !!! 実装前に必ず node_modules/@buf/cybozu_kintone-data-connector.bufbuild_es の型を確認すること !!!
//   - AdapterService の import 先（例: adapter_pb.js）
//   - 9 メソッド型か、単一 Operate 型か
//   - 各メッセージ（Request/Response/Record/Field/FieldDefinition/FilterCondition）の正確な形と enum 名
// 仕様は SKILL.md / references/interface-spec.md / references/field-mapping.md を参照。
//
// import { AdapterService } from "@buf/cybozu_kintone-data-connector.bufbuild_es/cybozu/data_connector/adapter/v1/adapter_pb.js";
// import type { ServiceImpl } from "@connectrpc/connect";

import { rows } from "./data.js";

// TODO: 実際の AdapterService 型に合わせて型注釈を付ける（ServiceImpl<typeof AdapterService> 等）。
export const adapterService = {
  async getCapability(_req: unknown) {
    // TODO: サポートする操作と record_id_type を返す。提供しない RPC は false。
    return {
      payload: {
        selectOperationSupported: true,
        insertOperationSupported: false,
        updateOperationSupported: false,
        deleteOperationSupported: false,
        countOperationSupported: true,
        searchOperationSupported: false,
        recordIdType: "RECORD_ID_TYPE_NUMBER", // enum の実体は型で確認
      },
    };
  },

  async getSchema(_req: unknown) {
    // TODO: map<string, FieldDefinition> を返す。recordIdFieldDefinition を必ず含める。
    return {
      payload: {
        schema: {
          id:   { definition: { case: "recordIdFieldDefinition", value: { fieldId: "id" } } },
          name: { definition: { case: "textFieldDefinition",     value: { fieldId: "name" } } },
        },
      },
    };
  },

  async select(_req: unknown) {
    // TODO: fields / filterCondition + matchOperator / sortConditions / offset / limit を適用する。
    const records = rows.map((r) => ({
      fields: {
        id:   { field: { case: "recordIdField", value: { fieldId: "id", value: BigInt(r.id) } } },
        name: { field: { case: "textField",     value: { fieldId: "name", value: r.name } } },
      },
    }));
    return { payload: { records } };
  },

  async count(_req: unknown) {
    // TODO: filterCondition を適用した件数を返す。
    return { payload: { count: rows.length } };
  },

  // TODO: サポートすると宣言した RPC（insert/update/delete/search/aggregate）を実装する。
};
`,

  "src/index.ts":
`// HTTP/2 で Connect RPC サーバを起動する。
// !!! AdapterService の import 先とルーティングは install 後に型で確認して調整すること !!!
import * as http2 from "node:http2";
import { connectNodeAdapter } from "@connectrpc/connect-node";
// import { AdapterService } from "@buf/cybozu_kintone-data-connector.bufbuild_es/cybozu/data_connector/adapter/v1/adapter_pb.js";
import { adapterService } from "./service.js";

const argv = process.argv.slice(2);
const portIdx = argv.indexOf("--port");
const PORT = portIdx >= 0 ? Number(argv[portIdx + 1]) : ${port};

const server = http2.createServer(
  connectNodeAdapter({
    routes: (router) => {
      // TODO: router.service(AdapterService, adapterService);
      // AdapterService を import して有効化する。
      void router;
      void adapterService;
    },
  }),
);

server.listen(PORT, "localhost", () => {
  console.log(\`adapter listening on localhost:\${PORT}\`);
});
`,

  "README.md":
`# ${pkgName}

kintone 外部システムアプリ化（Agent 方式）の Adapter。Connect RPC（HTTP/2）の gRPC サーバ。

## セットアップ
\`\`\`bash
pnpm install       # .npmrc の @buf レジストリ設定で BSR SDK を取得
pnpm dev           # localhost:${port} で起動
\`\`\`

## 実装の進め方
1. \`node_modules/@buf/cybozu_kintone-data-connector.bufbuild_es\` の型で AdapterService と各メッセージの形を確認。
2. \`src/service.ts\` の各 RPC を実装（GetCapability / GetSchema は必須。提供しない RPC は GetCapability で false）。
3. \`src/index.ts\` で \`router.service(AdapterService, adapterService)\` を有効化。
4. \`pnpm smoke\` または curl で動作確認（詳細はスキルの references/verification.md）。
`,
};

let created = 0, skipped = 0;
for (const [rel, content] of Object.entries(files)) {
  const p = join(dir, rel);
  if (existsSync(p) && !opts.force) { console.log(`skip (exists): ${rel}`); skipped++; continue; }
  writeFileSync(p, content);
  console.log(`create: ${rel}`);
  created++;
}

console.log(`\ndone. created=${created} skipped=${skipped}`);
console.log(`next:\n  cd ${targetDir}\n  pnpm install\n  # node_modules/@buf/... の型を確認してから src/service.ts と src/index.ts を実装`);
console.log(`  # スモーク: node <skill-dir>/scripts/smoke.mjs --port ${port}`);
