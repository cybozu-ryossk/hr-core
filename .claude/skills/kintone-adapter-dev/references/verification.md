# 動作確認

Adapter は Connect RPC のサーバなので、Agent や Proxy を立てなくても **JSON over HTTP** で単体確認できる。
まずこの curl スモークで単体品質を担保し、必要なら Agent/Proxy を使った E2E に進む。

## 1. curl スモーク（proxy/agent 不要・最速）

Adapter を起動しておく:

```bash
pnpm dev            # tsx でホットリロード起動（既定 localhost:8082）
# または
pnpm build && node ./dist/index.js
```

Connect は HTTP/2 で `POST /<完全修飾サービス名>/<メソッド>` に JSON ボディを送れば叩ける。
完全修飾サービス名は `cybozu.data_connector.adapter.v1.AdapterService`（実際の値は proto/型で確認）。

```bash
BASE=http://localhost:8082/cybozu.data_connector.adapter.v1.AdapterService

# GetCapability
curl -s --http2-prior-knowledge -H 'Content-Type: application/json' \
  --data '{}' $BASE/GetCapability | jq .

# GetSchema
curl -s --http2-prior-knowledge -H 'Content-Type: application/json' \
  --data '{}' $BASE/GetSchema | jq .

# Select（全件・id 昇順・先頭 10 件）
curl -s --http2-prior-knowledge -H 'Content-Type: application/json' --data '{
  "payload": {
    "fields": ["id","name"],
    "filterCondition": [ { "allRecords": {} } ],
    "matchOperator": "MATCH_OPERATOR_ALL",
    "sortConditions": [ { "fieldId": "id", "order": "SORT_ORDER_ASC" } ],
    "offset": 0, "limit": 10
  }
}' $BASE/Select | jq .

# Count（全件）
curl -s --http2-prior-knowledge -H 'Content-Type: application/json' --data '{
  "payload": { "filterCondition": [ { "allRecords": {} } ], "matchOperator": "MATCH_OPERATOR_ALL" }
}' $BASE/Count | jq .
```

> リクエストが `{ "payload": {...} }` でラップされるか、直接ペイロードかは Request メッセージの形による。
> 単一 `Operate` 型なら `POST .../Operate` に `{ "selectRequestPayload": {...} }` の oneof を送る。
> **うまく叩けないときはまず生成された型と proto を確認**する。

## 2. 同梱スモークスクリプト

`scripts/smoke.mjs` が上記の GetCapability / GetSchema / Select(all) / Count を順に叩いて結果と
簡単な合否（HTTP 200 か・payload があるか）を表示する:

```bash
node <skill-dir>/scripts/smoke.mjs --port 8082
# サービス名やホストを変える場合
node <skill-dir>/scripts/smoke.mjs --port 8082 --service cybozu.data_connector.adapter.v1.AdapterService
```

scaffold したプロジェクトでは `pnpm smoke` でも呼べる。

## 3. proto をローカル生成するフォールバック（BSR が使えないとき）

`@buf/cybozu_kintone-data-connector.bufbuild_es` が認証・ネットワークで取得できない場合は、
data-connector リポジトリの proto から自前生成する:

```bash
# data-connector リポジトリを取得（proto を含める）
git clone git@github.com:kintone-private/data-connector.git
# adapter の proto を自プロジェクトに vendor して buf generate する
#   proto/cybozu/data_connector/adapter/v1/*.proto を対象に
#   @bufbuild/protoc-gen-es（protobuf-es v2）で生成する
```

`buf.gen.yaml` の例（生成先や plugin バージョンはプロジェクトに合わせる）:

```yaml
version: v2
plugins:
  - local: protoc-gen-es
    out: src/gen
    opt: target=ts
```

生成後は import 先を `@buf/...` から `./gen/...` に差し替える。以降の実装・スモークは同じ。

## 4. Agent/Proxy を使った E2E（任意・data-connector リポジトリが必要）

kintone 相当の経路まで通すなら data-connector リポジトリの Go バイナリ（proxy / agent / connctl）を使う。
手順は data-connector リポジトリの `ai-guide/local-verification.md` と、リポジトリ同梱の
`/run-agent-and-adapter` スキルが詳しい。要点だけ:

1. `make` で proxy/agent/connctl をビルド。
2. `./build/proxy --development_mode`（鍵ファイル不要）で Proxy 起動。
3. Adapter 起動（このスキルで作ったもの）。
4. `openssl` で RSA 鍵ペアを作り、`connctl register` でコネクタ登録＆トークン発行。
5. `agent.json`（token / addr / private_key_path / adapter_addr / adapter_plaintext）を作り `./build/agent` 起動。
6. `connctl invoke <connector_id> '{"getCapabilityRequestPayload":{}}' ...` で確認。

生成ファイル（鍵・設定）は作業用ディレクトリ（例 `.claude-work/`）にまとめ、リポジトリを汚さない。
