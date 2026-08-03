---
name: kintone-adapter-dev
description: >
  kintone「外部システムのアプリ化（Agent 方式 / data-connector）」の Adapter を TypeScript で開発するスキル。
  外部システム（REST API・DB・SaaS 等）のデータを kintone アプリのレコードとして扱えるようにする Adapter
  ── Connect RPC（HTTP/2）で動く gRPC サーバ ── を新規プロジェクトとしてゼロから作り、9 つの RPC
  （GetCapability / GetSchema / Select / Insert / Update / Delete / Count / Search / Aggregate）を実装し、
  curl でスモーク確認するまでを支援する。次のいずれかが話題に出たら必ず使う:
  「外部システムのアプリ化」「Agent 方式」「data-connector」「Adapter を作る/実装する」「AdapterService」
  「GetCapability / GetSchema / Select などの RPC 実装」「外部システムを kintone に繋ぐコネクタ」
  「@buf/cybozu_kintone-data-connector」「connectrpc で kintone のアダプタ」。
  kintone のアプリ・レコードを REST API で操作する話（kintone-api / kintone-mcp）や、通常の kintone アプリ作成
  （kintone-app-creator）とは別物 ── こちらは「外部システム側に立てる変換サーバ」を作るスキルである点に注意。
---

# kintone 外部システムアプリ化 Adapter 開発（TypeScript）

外部システムのデータを kintone アプリのレコードとして扱えるようにする **Adapter** を TypeScript で作る。
Adapter は Agent 方式（data-connector）の構成要素で、**Connect RPC（HTTP/2）の gRPC サーバ**として動作し、
Agent からのリクエストを外部システムへの操作に変換する。サイボウズはインターフェース（proto）だけを定義し、
Adapter 本体はパートナー・顧客が実装する ── その実装を担うのがこのスキル。

```
kintone ──► Proxy ──► Agent ──► [ Adapter ] ──► 外部システム
                                   ↑ここを作る
```

Adapter は Agent と同じ顧客プライベートネットワーク上に置く。Agent は Adapter に対して gRPC クライアントとして振る舞う。

## まず全体像をつかむ（最初に必ず読む）

1. `references/interface-spec.md` — 9 つの RPC・データ型（Record / Field / RecordId / FieldDefinition）・
   絞り込み条件・ソート・各種制約の一覧。**実装前に必ず目を通す。**
2. `references/field-mapping.md` — 外部システムのデータモデルを kintone フィールド型へ対応づける方法と、
   GetSchema / Record を組み立てる際の oneof の正確な形。
3. `references/gotchas.md` — 実運用で踏みやすい落とし穴（count が呼ばれない・一覧非表示フィールドは
   交換されない・アクセス権が無い 等）。設計判断に効くので序盤に読む。

## 重要原則: 生成された SDK の型を「正」とする

proto（インターフェース）は世代で変わる。フィールド名・enum 値・サービスの形（後述）は
ドキュメントと実物がズレることがある。**必ず `npm install` 後に実際に入った型定義を確認してから実装する**:

```bash
# 生成物の場所とエクスポートを確認する
ls node_modules/@buf/cybozu_kintone-data-connector.bufbuild_es/cybozu/data_connector/adapter/v1/
# サービス定義・メッセージ・enum の正確な名前を確認する（.d.ts を読む）
```

ドキュメントの記述と型がズレていたら **型を優先**する。このスキルの reference は「地図」であって「正本」ではない。

### サービスの形は 2 通りありうる（実装前に確認）

ほとんどの資料は AdapterService が **9 個の独立した RPC メソッド**（`GetCapability` / `Select` …）を持つ前提。
一方で「単一の `Operate` RPC が oneof のペイロードを受ける」形になっている proto 世代もある。
`adapter_pb`（または `_connect` / `_pb`）の型を見て、**メソッドが 9 個あるのか、`Operate` 1 個なのか**を先に確定する。

- **9 メソッド型**（本スキルの主線）: `router.service(AdapterService, impl)` で各メソッドを実装。
- **単一 Operate 型**: `Operate` の中で `request.payload.case` により分岐する。中身のペイロード仕様は同じなので、
  `references/interface-spec.md` の各ペイロード定義はそのまま使える。分岐の骨組みだけ変える。

## ワークフロー

### STEP 1: 対象と Capability を決める

実装に入る前に次を確定させる。仕様・要件に関わるので曖昧なら**ユーザーに確認**する:

- **接続先の外部システム**は何か（REST API / SQL DB / SaaS / インメモリのサンプル 等）。
- **サポートする操作**はどれか。GetCapability / GetSchema は必須。Select / Insert / Update / Delete / Count /
  Search / Aggregate は任意で、**提供しない RPC は GetCapability で `false` を返す**。
  false を返した RPC は kintone から呼ばれない。実装せずに呼ばれると `unimplemented` エラーになる。
  （※ Search AI は現状 kintone 側が未実装なので、実装しても使われない）
- **レコード ID の型**（数値 / 文字列）。GetCapability の `record_id_type` で返す。
  **コネクタ単位で固定され後から変更できない**ので最初に決める。文字列 ID は `^[a-zA-Z0-9_-]{1,100}$`。
- **フィールド定義**（外部データ → kintone フィールド型）。`references/field-mapping.md` に沿って設計する。

### STEP 2: プロジェクトを scaffold する

設定ファイル（package.json / tsconfig / .npmrc）と最小の起動スケルトンは同梱スクリプトで生成する:

```bash
node <skill-dir>/scripts/scaffold.mjs <project-dir> [--name <pkg-name>] [--port 8082]
cd <project-dir>
pnpm install          # BSR SDK + Connect を取得（.npmrc で @buf レジストリを設定済み）
```

生成される主なもの:
- `package.json` — `@connectrpc/connect` / `@connectrpc/connect-node` / `@bufbuild/protobuf` と
  BSR の SDK `@buf/cybozu_kintone-data-connector.bufbuild_es`、`build` / `dev` / `typecheck` / `smoke` スクリプト。
- `.npmrc` — `@buf:registry=https://buf.build/gen/npm/v1/`（BSR から `@buf/...` を取得するために必須）。
- `tsconfig.json` / `src/index.ts`（HTTP/2 サーバ起動）/ `src/service.ts`（実装スケルトン）/ `src/data.ts`（サンプルデータ）。

**install が通ったら STEP の「重要原則」に従い、`node_modules/@buf/...` の型で AdapterService と各メッセージの
正確な形を確認する。** scaffold のスケルトンはこの確認を前提に import 行へコメントを残してある。

BSR の `@buf/...` が取得できない場合（認証・ネットワーク）は `references/verification.md` の
「proto をローカル生成するフォールバック」を参照する。

### STEP 3: GetCapability と GetSchema を実装する（必須）

- **GetCapability**: サポートする操作の boolean と `record_id_type` を返す。詳細は `references/interface-spec.md`。
- **GetSchema**: `map<string, FieldDefinition>` を返す。**ここに含めないフィールドはアプリに配置できない。**
  型ごとの oneof の形は `references/field-mapping.md`。

### STEP 4: データ操作の RPC を実装する

`references/interface-spec.md` と `references/field-mapping.md` を見ながら、サポートすると宣言した RPC を実装する:

- **Select** — `fields`（取得列）・`filter_condition` + `match_operator`（AND/OR）・`sort_conditions`・
  `offset`・`limit`(1〜501) を外部システムのクエリに変換し、`Record[]` を返す。
- **Count** — 同じ絞り込みで件数を返す。
- **Insert / Update / Delete** — 追加・更新・削除。返す ID の形（RecordId）に注意。
- **Search / Aggregate** — 必要なら実装（`interface-spec.md` に仕様）。

Record と Field の値は oneof で表現する（`{ field: { case: "textField", value: {...} } }` の形）。
正確な形は必ず `references/field-mapping.md` と実際の型で確認する。

### STEP 5: curl でスモーク確認する

Connect RPC は JSON over HTTP でも叩けるので、Agent や Proxy を立てなくても Adapter 単体を確認できる:

```bash
pnpm dev            # または pnpm build && node ./dist/index.js
# 別ターミナルで全 RPC を一括スモーク
node <skill-dir>/scripts/smoke.mjs --port 8082
```

`smoke.mjs` は GetCapability / GetSchema / Select(all) / Count を順に叩いて結果を表示する。
個別に叩く curl の例と、Agent/Proxy を使う E2E 確認は `references/verification.md` を参照。

## このスキルが「作らない」もの・混同しないもの

- **通常の kintone アプリ作成**（フォーム・フィールド設定）は `kintone-app-creator`。
- **kintone のレコード/設定を REST API や MCP で操作**するのは `kintone-api` / kintone-mcp。
- このスキルは「**外部システム側に立てる変換サーバ（Adapter）**」を作るものであり、上記とは対象が異なる。

## 顧客データの扱い

- 顧客名・顧客データはコード・成果物にハードコードしない。サンプルは仮名・ダミーで作る。
- アクセス制御は kintone 標準のアクセス権では効かない（`references/gotchas.md`）。要件にあれば
  Context のユーザー情報を使って Adapter 側でフィルタする設計にする。
