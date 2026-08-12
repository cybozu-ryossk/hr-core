# 実装リポジトリ一覧

HRCore の要件・設計に基づく実装リポジトリの一覧。本書はハブとして実装の位置づけのみを管理し、実装コード自体は持たない。

- 最終更新: 2026-08-12

## 紐づけ方法

各実装リポジトリは、本リポジトリ（`hr-core`）を `docs/hr-core/` に git submodule として取り込み、設計仕様（`SPEC.md` / `REQUIREMENTS.md` / `POC.md` 等）を直接参照する。本リポジトリ側は各実装のコードを持たず、本書に一覧として記載するのみとする。

設計変更を実装側に取り込む場合は、実装リポジトリ側で以下を実行する。

```bash
git submodule update --remote docs/hr-core
```

## 実装一覧

| リポジトリ | 位置づけ | 対象範囲 | ステータス |
| --- | --- | --- | --- |
| [hr-core-impl](https://github.com/cybozu-ryossk/hr-core-impl)（private） | PoC実装 | kintone 外部システムのアプリ化（Agent 方式）の Adapter。`POC.md` のスコープに対応 | PoC 実装フェーズ |
| （未定） | 本番実装 | 案A/B/C の記録時間方式の判断後に着手（`POC.md` 3章、`TODO.md` B章） | 未着手 |

本番実装が PoC 実装（`hr-core-impl`）をそのまま拡張するか、別リポジトリとして新規に立ち上げるかは未確定（`POC.md` 3章5項）。判断がついた時点で本表を更新する。
