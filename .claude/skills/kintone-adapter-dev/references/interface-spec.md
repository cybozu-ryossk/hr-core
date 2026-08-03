# Adapter インターフェース仕様

Adapter が実装する AdapterService の RPC・データ型・絞り込み・制約の一覧。
proto 定義は `proto/cybozu/data_connector/adapter/v1/`、完全修飾サービス名は
`cybozu.data_connector.adapter.v1.AdapterService`（Connect の HTTP パスにも使う）。

> **注意**: フィールド名・enum 値はここでは snake_case（proto 表記）で書く。TypeScript の SDK では
> camelCase（`recordIdType`・`selectOperationSupported` 等）になる。**実際の名前は必ず生成された型で確認**する。
> ドキュメントと型がズレたら型を優先（proto は世代で変わる）。

## 目次
- [RPC 一覧と必須/任意](#rpc-一覧と必須任意)
- [リクエスト/レスポンスの共通構造](#リクエストレスポンスの共通構造)
- [Context](#context)
- [各 RPC の仕様](#各-rpc-の仕様)
- [データ型: Record / Field](#データ型-record--field)
- [データ型: RecordId](#データ型-recordid)
- [データ型: FieldDefinition](#データ型-fielddefinition)
- [絞り込み: FilterCondition / MatchOperator](#絞り込み-filtercondition--matchoperator)
- [ソート: SortCondition](#ソート-sortcondition)
- [制約値](#制約値)
- [エラーの返し方](#エラーの返し方)

## RPC 一覧と必須/任意

| RPC | 必須/任意 | 呼ばれるタイミング | 概要 |
|---|---|---|---|
| GetCapability | **必須** | コネクタ登録後の接続確認時 | サポートする機能・record_id_type を返す |
| GetSchema | **必須** | フォーム設定画面表示・アプリ作成時 | フィールド定義（スキーマ）を返す |
| Select | 任意 | レコード一覧取得・詳細表示時 | 条件に合う外部レコードを返す |
| Insert | 任意 | レコード追加時 | 追加して ID を返す |
| Update | 任意 | レコード更新時 | 更新して ID を返す |
| Delete | 任意 | レコード削除時 | 削除する |
| Count | 任意 | 一覧画面の全件数表示時 | 条件に合う件数を返す |
| Search | 任意 | 検索 AI 利用時 | キーワード検索（※kintone 側が現状未実装） |
| Aggregate | 任意 | グラフの集計時 | グループ化・集計結果を返す |

- **任意の RPC を提供しないなら GetCapability で `false` を返す**。false のものは kintone から呼ばれない。
  実装せずに呼ばれると gRPC `unimplemented` エラーになる。
- filterable_fields / sortable_fields は GetCapability に項目があるが、現状の kintone は値を無視する
  （将来対応予定）。とはいえ返しておいて害はない。

## リクエスト/レスポンスの共通構造

各 RPC は「payload をラップした Request / Response」を受け渡す（proto の 1 メッセージ = 1 フィールド構造）:

- Request = `{ payload: <Xxx>RequestPayload, context: Context }`
- Response = `{ payload: <Xxx>ResponsePayload }`

TypeScript 実装ではメソッドの引数が Request、戻り値が Response（`{ payload: {...} }`）になる。例:

```ts
async getCapability(req /* GetCapabilityRequest */) {
  return { payload: { selectOperationSupported: true, /* ... */ } };
}
```

> proto 世代によっては AdapterService が単一の `Operate(OperateRequest)` になっていることがある。その場合は
> `req.payload.case`（`"selectRequestPayload"` 等の oneof）で分岐する。ペイロードの中身仕様は本書のまま使える。

## Context

各 RPC に付く kintone のリクエスト情報。コネクタ設定の「コンテキスト送信設定」で送る項目を制御できる。

| フィールド | 説明 |
|---|---|
| `operation_id` | オペレーション ID |
| `app_id` | kintone アプリ ID（特定アプリ向けでない場合は空） |
| `user.user_id` | 操作ユーザーの ID（API トークン使用時は Administrator） |
| `user.user_code` | 操作ユーザーのコード（デフォルトは「送信しない」設定） |

アクセス制御を Adapter 側で行う場合はこの user 情報で返すデータを絞る（`gotchas.md` 参照）。

## 各 RPC の仕様

### GetCapability
- リクエスト payload: 空。
- レスポンス payload:
  - `select_operation_supported` / `insert_operation_supported` / `update_operation_supported` /
    `delete_operation_supported` / `count_operation_supported` / `search_operation_supported`: boolean
  - `filterable_fields` / `sortable_fields`: repeated string（現状無視される）
  - `record_id_type`: `RECORD_ID_TYPE_UNSPECIFIED` / `RECORD_ID_TYPE_NUMBER` / `RECORD_ID_TYPE_TEXT`
  - （Aggregate のサポート可否フラグが別途ある世代もある。型で確認）

### GetSchema
- レスポンス payload: `schema` = `map<string, FieldDefinition>`（キー = フィールド名、必須）。
- **schema に含めないフィールドはアプリに配置できない。** 型ごとの定義は [FieldDefinition](#データ型-fielddefinition)。

### Select
- リクエスト payload:
  - `fields`: repeated string（取得するフィールド名。必須）
  - `filter_condition`: repeated FilterCondition（必須。`match_operator` で結合）
  - `match_operator`: `MATCH_OPERATOR_ALL`(AND) / `MATCH_OPERATOR_ANY`(OR)
  - `sort_conditions`: repeated SortCondition
  - `offset`: int（0 以上）
  - `limit`: int（1〜501）
- レスポンス payload: `records` = repeated Record。

### Count
- リクエスト payload: `filter_condition`（必須）・`match_operator`（必須）。
- レスポンス payload: `count`（int, 0 以上）。
- ※ Select の結果が limit 未満だと Agent が「全件取得済み」とみなし Count を呼ばないことがある（`gotchas.md`）。

### Insert
- リクエスト payload: `records`（repeated Record, 必須）。
- レスポンス payload: `record_ids`（repeated RecordId, 追加したレコードの ID）。
  - `ids`（repeated int）という旧フィールドが併存する世代もある（将来非推奨）。両方あるなら record_ids を使う。

### Update
- リクエスト payload: `records`（repeated Record, 必須。各 Record に対象 ID を含める）。
- レスポンス payload: `records`（repeated UpdatedRecordInfo, 1 件以上）。UpdatedRecordInfo は `record_id`（RecordId）を持つ。
  - Upsert 対応時に `operation` フィールドが増える予定。

### Delete
- リクエスト payload: `record_ids`（repeated RecordId）。旧 `ids`（repeated int）併存世代あり。
- レスポンス payload: なし。

### Search
- リクエスト payload: `fields`（必須）・`keywords`（repeated string, 必須）・
  `search_operator`（`ALL` / `ANY`）・`offset`（0 以上）・`limit`（1〜100）。
- レスポンス payload: `search_results`（repeated SearchResult, 各 `record: Record`）。
- ※ 検索 AI 機能は kintone 側が現状未実装。実装しても現時点では使われない。

### Aggregate
- リクエスト payload: `grouping_specs`（repeated）・`aggregation_specs`（repeated, 必須）・
  `filter_conditions`（必須）・`match_operator`・`sort_conditions`（repeated AggregateSortCondition）・`limit`（1〜10001）。
- レスポンス payload: `rows`（repeated AggregateRow）。
- 集計の spec（合計/平均/最大/最小/件数、グループ化キー）の正確な形は型で確認する。

## データ型: Record / Field

**Record**: `fields` = `map<string, Field>`（キー = フィールド名、値 = Field）。

**Field**（oneof）— TypeScript では `{ field: { case: <型名>, value: {...} } }`:

| oneof case | kintone フィールドタイプ | value の主なフィールド |
|---|---|---|
| `recordIdField` | レコード番号 | `fieldId`, `value`（数値 ID は bigint、文字列 ID は string） |
| `textField` | 文字列1行・複数行・ルックアップ | `fieldId`, `value`(string) |
| `numberField` | 数値 | `fieldId`, `value`（数値。型で確認: number/string/bigint のいずれか） |
| `datetimeField` | 日時 | `fieldId`, `value`（timestamp。型で確認） |
| `selectionField` | ドロップダウン | `fieldId`, `value`(string, 選択肢名) |
| `multipleSelectionField` | 複数選択 | `fieldId`, `value`（string[]、選択肢名の配列） |

具体的な組み立て例は `field-mapping.md`。

## データ型: RecordId

外部レコードの ID（oneof）。コネクタ単位で型が固定され後から変更不可。

| oneof case | 型 | 制約 |
|---|---|---|
| `valueNumber` | int（bigint） | 数値型レコード ID |
| `valueText` | string | 文字列型（正規表現 `^[a-zA-Z0-9_-]{1,100}$`、違反は `CB_VA01`） |

GetCapability の `record_id_type` で `RECORD_ID_TYPE_NUMBER` か `RECORD_ID_TYPE_TEXT` を宣言し、
Record 内の recordIdField・Insert/Update/Delete の RecordId は宣言した型に揃える。

## データ型: FieldDefinition

GetSchema で返すフィールド定義（oneof）— `{ definition: { case: <型名>, value: {...} } }`:

| oneof case | kintone フィールドタイプ | 補足 |
|---|---|---|
| `recordIdFieldDefinition` | レコード番号 | **1 つだけ必須** |
| `textFieldDefinition` | 文字列1行（既定）/ 複数行 / ルックアップ | |
| `numberFieldDefinition` | 数値 | |
| `datetimeFieldDefinition` | 日時 | |
| `selectionFieldDefinition` | ドロップダウン | 選択肢 `options` を持つ |
| `multipleSelectionFieldDefinition` | 複数選択 | 選択肢 `options` を持つ |
| `createdAtFieldDefinition` | 作成日時 | 世代により有無あり |
| `updatedAtFieldDefinition` | 更新日時 | 世代により有無あり |

- どの value にも `fieldId`（フィールド名）が要る。表示名や必須指定などの追加プロパティは型で確認。
- 選択肢系は `options`（選択肢の一覧）を定義する。kintone 側では選択肢の追加/削除/改名はできず、
  定義変更を反映するには一度フィールドを外して再配置する必要がある。

## 絞り込み: FilterCondition / MatchOperator

`Select` / `Count` / `Aggregate` のリクエストに入る絞り込み条件（oneof）。
TypeScript では `{ condition: { case: <条件名>, value: { fieldId, value } } }`。複数条件は `match_operator` で結合:
`MATCH_OPERATOR_ALL`(AND) / `MATCH_OPERATOR_ANY`(OR)。

主な条件 case（正確な集合は型で確認。世代で増減する）:
- 全件: `all_records`（絞り込みなし）
- レコード ID: `record_id_equal` / `record_id_not_equal` / `record_id_greater_than` / `record_id_less_than` /
  `record_id_in` / `record_id_contains` など
- 文字列: `text_equal` / `text_not_equal` / `text_contains` / `text_not_contains` / `text_in` /
  `text_is`（空・空でない）など
- 数値: `number_equal` / `number_not_equal` / `number_greater_than` / `number_less_than` / `number_in` など
- 日時: `datetime_equal` / `datetime_greater_than` / `datetime_less_than` / `datetime_in_range` など
- 選択: `selection_in` / `selection_not_in`
- 複数選択: `multiple_selection_in` / `multiple_selection_not_in`

実装では「case で分岐 → 外部システムのクエリ条件に変換」する。対応できない条件が来たら
無視するのではなくエラーを返すか、GetCapability の filterable_fields で事前に絞る設計を検討する。

> **and/or 混在は現状非対応**（一階層のみ）。`match_operator` は全体で 1 つ。

## ソート: SortCondition

`Select` のリクエストに入るソート条件。

| フィールド | 説明 |
|---|---|
| `field_id` | ソート対象フィールド名 |
| `order` | `SORT_ORDER_ASC`（昇順）/ `SORT_ORDER_DESC`（降順） |

> 世代により `order` が `sort_direction`（`SORT_DIRECTION_ASC` 等）という名前のこともある。型で確認する。
> Aggregate は `AggregateSortCondition`（集計列に対するソート）で別型。

## 制約値

| 項目 | 上限/範囲 |
|---|---|
| Select `limit` | 1〜501 |
| Select `offset` | 0 以上 |
| Search `limit` | 1〜100 |
| Aggregate `limit` | 1〜10001 |
| Adapter レスポンスサイズ | 4 MB（超過で `GAIA_RS01`） |
| kintone → Adapter 送信ペイロード | 4 MB（超過で `GAIA_MS02`） |
| セッションあたり同時オペレーション | 300（超過で `GAIA_CE01`） |

## エラーの返し方

- Adapter が gRPC のエラー（`ConnectError` など）を返すと、Agent がそれを `error_message`（1〜1024 文字）に
  変換して kintone に返し、kintone は `GAIA_AD03`（Adapter でエラー）等を表示する。
- ユーザーに見せたい原因は簡潔なメッセージにする。スタックトレースや内部情報を漏らさない。
- 主なユーザー向けエラーコード（原因の目安）:
  - `GAIA_AD03`: Adapter でエラー発生 / `GAIA_AU01`: Adapter が起動していない
  - `GAIA_IR05`: Adapter のレスポンスが不正 / `GAIA_RS01`: レスポンスが 4MB 超過
  - `GAIA_AG01`: Agent 側の制御外エラー（ペイロード復号失敗など）
