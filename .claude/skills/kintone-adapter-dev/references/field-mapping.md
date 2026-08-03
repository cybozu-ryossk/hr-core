# フィールドマッピングと組み立て

外部システムのデータモデルを kintone フィールドへ対応づけ、GetSchema / Record / FilterCondition を
TypeScript で組み立てるときの実践ガイド。**oneof の正確な形は必ず生成された型で確認**すること。
ここに載せる形は「よくある形」であって、proto 世代でズレることがある。

## 1. 外部データ型 → kintone フィールド型の対応

| 外部システムの値 | kintone フィールド | FieldDefinition の case | Field の case |
|---|---|---|---|
| 一意な ID（連番） | レコード番号（数値 ID） | `recordIdFieldDefinition` | `recordIdField` |
| 一意な ID（文字列） | レコード番号（文字列 ID） | `recordIdFieldDefinition` | `recordIdField` |
| 文字列 / テキスト | 文字列1行・複数行 | `textFieldDefinition` | `textField` |
| 数値・金額・数量 | 数値 | `numberFieldDefinition` | `numberField` |
| 日付・日時 | 日時 | `datetimeFieldDefinition` | `datetimeField` |
| 区分（単一） | ドロップダウン | `selectionFieldDefinition` | `selectionField` |
| タグ（複数） | 複数選択 | `multipleSelectionFieldDefinition` | `multipleSelectionField` |
| 作成日時 / 更新日時 | 作成日時 / 更新日時 | `createdAtFieldDefinition` / `updatedAtFieldDefinition` | （読み取り主体） |

### 使えない・注意が必要な型（Agent 方式）
- 添付ファイル・ユーザー選択・組織選択・チェックボックス・ラジオ・リンク・計算・リッチエディタは **使えない**。
  外部側にこれらの概念があっても、文字列・数値・選択で表現する。
- ルックアップは kintone 側では `textField` として扱う（値はリンクにならずプレーンテキスト）。
- 真偽値は「ドロップダウン（はい/いいえ）」や「複数選択」で表す。

## 2. GetSchema の組み立て

`schema` は `map<string, FieldDefinition>`。キーがフィールド名（= kintone のフィールドコード/名の初期値）。
**recordIdFieldDefinition を必ず 1 つ**含める。ここに無いフィールドはアプリに配置できない。

```ts
async getSchema(_req) {
  return {
    payload: {
      schema: {
        id:    { definition: { case: "recordIdFieldDefinition", value: { fieldId: "id" } } },
        name:  { definition: { case: "textFieldDefinition",     value: { fieldId: "name" } } },
        price: { definition: { case: "numberFieldDefinition",   value: { fieldId: "price" } } },
        due:   { definition: { case: "datetimeFieldDefinition", value: { fieldId: "due" } } },
        status:{ definition: { case: "selectionFieldDefinition", value: {
                   fieldId: "status",
                   options: [ { label: "未着手" }, { label: "対応中" }, { label: "完了" } ], // 形は型で確認
                 } } },
        tags:  { definition: { case: "multipleSelectionFieldDefinition", value: {
                   fieldId: "tags",
                   options: [ { label: "急ぎ" }, { label: "重要" } ],
                 } } },
      },
    },
  };
}
```

> `options` の要素の形（`label` か `name` か、`value` を持つか）は世代差がある。**型で確認**。

## 3. Record / Field の組み立て（Select・Search のレスポンス）

Record は `fields: map<string, Field>`。各 Field は oneof。数値 ID の場合 recordIdField の value は bigint。

```ts
function toRecord(row) {
  return {
    fields: {
      id:    { field: { case: "recordIdField", value: { fieldId: "id", value: BigInt(row.id) } } },
      name:  { field: { case: "textField",     value: { fieldId: "name",  value: row.name } } },
      price: { field: { case: "numberField",   value: { fieldId: "price", value: row.price } } }, // 型で確認
      due:   { field: { case: "datetimeField", value: { fieldId: "due",   value: toTimestamp(row.due) } } },
      status:{ field: { case: "selectionField", value: { fieldId: "status", value: row.status } } },
      tags:  { field: { case: "multipleSelectionField", value: { fieldId: "tags", value: row.tags } } },
    },
  };
}
```

注意点:
- **Select の `fields` に含まれる列だけ**返せばよい（全列返しても害は少ないが、無駄が減る）。
- kintone の一覧に表示設定されていないフィールドは、返しても kintone 側で受け取られない（`gotchas.md`）。
- 数値・日時の value の具体型（number / string / bigint / Timestamp メッセージ）は世代差が大きい。
  **必ず型で確認**し、変換ヘルパ（`toTimestamp` 等）を用意する。

### 文字列レコード ID の場合
`record_id_type` を `RECORD_ID_TYPE_TEXT` にし、recordIdField / RecordId は文字列を使う:

```ts
id: { field: { case: "recordIdField", value: { fieldId: "id", value: row.uuid } } } // string
// Insert/Update/Delete の RecordId
{ id: { case: "valueText", value: row.uuid } } // 形は型で確認（valueText / value_text）
```

## 4. FilterCondition → 外部クエリへの変換

Select / Count で来る `filter_condition[]` を `match_operator`(ALL=AND / ANY=OR) で結合して外部クエリにする。
oneof の case で分岐する。SQL・REST クエリ・配列 filter いずれにも同じ考え方で落とせる。

```ts
function toPredicate(cond) {
  const c = cond.condition;
  switch (c.case) {
    case "allRecords":       return () => true;
    case "textEqual":        return (r) => r[c.value.fieldId] === c.value.value;
    case "textContains":     return (r) => String(r[c.value.fieldId] ?? "").includes(c.value.value);
    case "numberGreaterThan":return (r) => r[c.value.fieldId] > c.value.value;
    case "numberLessThan":   return (r) => r[c.value.fieldId] < c.value.value;
    case "selectionIn":      return (r) => c.value.values.includes(r[c.value.fieldId]);
    // ... interface-spec.md の条件一覧を網羅する。未対応 case はエラーを返す
    default: throw new Error(`unsupported filter: ${c.case}`);
  }
}

function applyFilter(rows, conditions, matchOperator) {
  const preds = conditions.map(toPredicate);
  const isAll = matchOperator === "MATCH_OPERATOR_ALL"; // enum の実体は型で確認
  return rows.filter((r) => isAll ? preds.every((p) => p(r)) : preds.some((p) => p(r)));
}
```

- SQL バックエンドなら case を WHERE 句フラグメント + プレースホルダに変換し、`match_operator` で AND/OR 連結する。
  **必ずパラメータ化**して SQL インジェクションを防ぐ。
- REST バックエンドなら外部 API のクエリパラメータに変換する。外部 API が表現できない条件は、
  取得後にメモリ上で `applyFilter` して補完する（件数・ページングの整合に注意）。

## 5. ソート・ページング

- `sort_conditions[]` を順に適用。`order`（`SORT_ORDER_ASC`/`DESC`、名前は型で確認）で昇降を決める。
- `offset` / `limit`(1〜501) を適用。外部 API 側でページングできるなら委譲し、できないなら取得後にスライスする。
- Count は「フィルタ適用後の総件数」を返す（offset/limit を適用する前の件数）。

## 6. Insert / Update / Delete のレスポンス

- Insert: 追加したレコードの `record_ids`（RecordId[]）を、リクエストの records と同順で返す。
- Update: `records`（UpdatedRecordInfo[]、各 `record_id`）を返す。**1 件以上**必須。
- Delete: レスポンス無し。存在しない ID の扱い（エラーにするか黙って成功にするか）は要件で決める
  （kintone 標準は存在しない ID でもエラーにしない挙動）。
