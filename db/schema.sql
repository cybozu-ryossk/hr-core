-- HRCore スキーマ（PoC）
--
-- 設計の根拠は docs/SPEC.md を参照（このファイルがスキーマの単一ソース）。要点のみ再掲する。
--   - 有効期間は daterange、半開区間 [) で統一。無期限は upper を NULL
--   - 期間の重複は EXCLUDE USING gist で DB 側が保証する
--   - 未来日データは通常行として格納し、参照側が基準日で判定する（反映バッチ不要）
--   - 組織階層は隣接リストで格納し、kintone 公開時に5列へ展開する
--   - HRCore は公開情報の骨格のみを持つ（非公開の個人情報・兼務工数・マネジメント役割は kintone 側）

CREATE EXTENSION IF NOT EXISTS btree_gist;  -- EXCLUDE で = と && を併用するため必須


-- ============================================================
-- マスタ
-- ============================================================

-- 会社（グループ会社を含む）
-- standard_weekly_hours は FTE 換算の分母。会社ごとに所定が異なりうるため会社側に持つ
-- （例: 40.0 = 8時間 × 週5日を 1.0 FTE とする）
CREATE TABLE company (
  company_code         text      PRIMARY KEY,
  company_name         text      NOT NULL,
  company_name_en      text,
  standard_weekly_hours numeric(4,1),
  valid_period         daterange NOT NULL
);

-- 拠点
CREATE TABLE location (
  location_code    text      PRIMARY KEY,
  location_name    text      NOT NULL,
  location_name_en text,
  valid_period     daterange NOT NULL
);

-- 組織階層区分（会社 → 本部 → 副本部 → 部 → 副部 → チーム）
-- 時系列を持たない固定マスタ。ENUM ではなくテーブルにしているのは段の追加・並べ替えに耐えるため
--
-- layer_order 0 の「会社」は役員の役職を設置するための器（docs/SPEC.md 3.7）。
-- is_countable = false にして階層別の人員集計から除外する。
-- これがないと「本部レベルの人員数」を数えたときに会社相当組織が混入する
CREATE TABLE org_layer (
  layer_code   text     PRIMARY KEY,
  layer_name   text     NOT NULL,
  layer_order  smallint NOT NULL UNIQUE,
  is_countable boolean  NOT NULL DEFAULT true   -- 階層別集計の対象にするか
);

INSERT INTO org_layer (layer_code, layer_name, layer_order, is_countable) VALUES
  ('company',    '会社',   0, false),   -- 役員設置用。階層集計から除外する
  ('honbu',      '本部',   1, true),
  ('fuku_honbu', '副本部', 2, true),
  ('bu',         '部',     3, true),
  ('fuku_bu',    '副部',   4, true),
  ('team',       'チーム', 5, true);

-- 在籍状況の区分
-- is_active = true が「在籍人員として数える状態」。集計側が状態名を列挙せずフラグで絞れるようにする
--
-- 現行の7区分（入社前/在籍/休職/退職/在職(外部)/休職(外部)/退職(外部)）は
-- 「内部・外部」×「在籍・休職・退職」＋「入社前」の掛け算を1次元に押し込んだもの。
-- HRCore では2軸に分解する（docs/SPEC.md 3.8）
--   内部/外部 → employment_type.is_employee
--   入社前     → employment.valid_period の下限が未来日であることから導出（行を作らない）
CREATE TABLE employment_status_type (
  status_code text    PRIMARY KEY,
  status_name text    NOT NULL,
  is_active   boolean NOT NULL
);

INSERT INTO employment_status_type (status_code, status_name, is_active) VALUES
  ('active',   '在籍', true),
  ('leave',    '休職', false),
  ('retired',  '退職', false);

-- 社員区分。is_employee = false は雇用契約のない外部人材（業務委託・派遣 等）
-- 人員集計・人的資本開示の分母から外すために使う。
-- 「社員数」は is_employee かつ is_active、「稼働人員数」は is_active（外部人材を含む）
--
-- 値は「社員名簿(公開)」の社員区分フィールドの選択肢に合わせた実際の18種類
-- （kintone スペースID:5 / アプリID:34 で確認、2026-08-04。当初の仮置き4値は大きく外れていた）。
-- is_employee の判定:
--   役員系（代表取締役社長・社外取締役・監査役）… 委任契約のため false（会社法上明確）
--   執行役員 … 一律 false で確定（人事・労務確認、2026-08-04）。使用人兼務型（雇用契約あり）の
--             ケースは実在するが少数で、人員集計の分母への影響は小さいと判断し
--             個人単位の厳密な判定（employment 側へのフラグ移動）は採らない
--   出向契約・出向契約（官民交流）… 雇用元は出向先企業と想定して false（要確認、docs/TODO.md B章）
--   ラボユース・ラボユース（研究生）… 契約形態が未確認のため false（要確認、docs/TODO.md B章）
CREATE TABLE employment_type (
  type_code   text    PRIMARY KEY,
  type_name   text    NOT NULL,
  is_employee boolean NOT NULL
);

INSERT INTO employment_type (type_code, type_name, is_employee) VALUES
  ('exec_president',            '代表取締役社長',             false),
  ('outside_director',          '社外取締役',                 false),
  ('auditor',                   '監査役',                     false),
  ('executive_officer',         '執行役員',                   false),
  ('advisor',                   '顧問',                       false),
  ('permanent',                 '無期雇用またはそれに準ずる', true),
  ('permanent_challenged',      '無期雇用（チャレンジド）',   true),
  ('fixed_term_contract',       '有期雇用（契約社員）',       true),
  ('fixed_term_parttime',       '有期雇用（アルバイト）',     true),
  ('intern',                    'インターン',                 true),
  ('labo_use',                  'ラボユース',                 false),
  ('labo_use_researcher',       'ラボユース（研究生）',       false),
  ('dispatched',                '派遣契約',                   false),
  ('outsourced',                '業務委託契約',               false),
  ('eor',                       'EORサービス契約',            false),
  ('secondment',                '出向契約',                   false),
  ('secondment_public_private', '出向契約（官民交流）',       false),
  ('partner_staff',             '協力会社社員',               false);

-- 役職階層（役職のランク）。grade_order が小さいほど組織上の上位
--
-- 1〜5 は org_layer の 1〜5 と数字が対応するが、1:1 には**ならない**。
-- 副本部長・副部長は「副本部／副部という組織の長」ではなく「本部／部の No.2」であり、
-- 本部に本部長と副本部長が並ぶ。したがって
--   設置組織の layer_order = grade_order
-- という制約は張れない（docs/SPEC.md 3.7）。
-- grade_order 0 の役員は組織階層に属さず、会社相当組織（layer_code = 'company'）に設置する
CREATE TABLE position_grade (
  grade_code  text     PRIMARY KEY,
  grade_name  text     NOT NULL,
  grade_order smallint NOT NULL UNIQUE
);

INSERT INTO position_grade (grade_code, grade_name, grade_order) VALUES
  ('exec',           '役員',           0),
  ('honbu_cho',      '本部長',         1),
  ('fuku_honbu_cho', '副本部長',       2),
  ('bu_cho',         '部長',           3),
  ('fuku_bu_cho',    '副部長',         4),
  ('team_leader',    'チームリーダー', 5);


-- ============================================================
-- 人
-- ============================================================

-- 個人。転籍をまたいで不変の識別子
-- 個人属性は公開度で3テーブルに分ける（詳細は docs/SPEC.md 3.5）
--   person              … 識別子と雇用に紐づく属性。全ロールが参照する
--   person_name         … 氏名（公開。組織図・社員名簿に出る）
--   person_demographics … 性別・生年月日（非公開。人的資本開示の指標算出に使う）
-- 1:1 の分割は正規化のためではなく、GRANT でアクセス境界を引くための垂直分割
CREATE TABLE person (
  person_id       bigserial   PRIMARY KEY,
  group_joined_on date,        -- グループ通算入社日。転籍で employment が切れても勤続年数を保てる
  created_at      timestamptz NOT NULL DEFAULT now()
);

-- 氏名（公開）。改姓は上書き更新で履歴を持たない
-- 過去断面を旧姓で再現する要件が出た場合は valid_period を足してバージョン化する
CREATE TABLE person_name (
  person_id      bigint PRIMARY KEY REFERENCES person,
  full_name      text   NOT NULL,
  full_name_kana text
);

-- 性別・生年月日（非公開）
-- 人的資本開示（女性管理職比率・男性育児休業取得率・年齢構成）の経年算出に使う
-- 履歴は持たない（上書き更新）
CREATE TABLE person_demographics (
  person_id  bigint PRIMARY KEY REFERENCES person,
  gender     text,   -- 「男」/「女」の2値（kintone アプリID:35 で確認、2026-08-04）。マスタ化しない
  birth_date date
);

-- 雇用（会社 × 期間）
-- 在籍出向はなく会社跨ぎは転籍のみ → 同時に1社。転籍は前雇用の終了 + 新雇用の開始で表現する
-- 雇用契約のない外部人材（業務委託・派遣）も本テーブルで扱う。現行も同じ名簿で管理しており、
-- 配属・職能・WG を同じモデルで扱えるため。区別は employment_type.is_employee で行う
-- 入社前の人は valid_period の下限が未来日の行として存在する（employment_status の行は作らない）
-- employee_no は会社ごとに新規発番される（人事・労務確認、2026-08-04）。
-- person_id は転籍をまたいで不変だが、employee_no は転籍のたびに切り替わる
CREATE TABLE employment (
  person_id               bigint    NOT NULL REFERENCES person,
  company_code            text      NOT NULL REFERENCES company,
  employee_no             text      NOT NULL,
  account_name            text,     -- 情報システム連携キー（SSO / kintone ログイン名）
  employment_type         text      REFERENCES employment_type(type_code),  -- 社員区分
  hire_category           text,     -- 入社区分（新卒・中途・再雇用・転籍）
  work_style              text,
  location_code           text      REFERENCES location,  -- 通勤拠点
  residence_location_code text      REFERENCES location,  -- 届出拠点（通勤拠点とは別軸）
  valid_period            daterange NOT NULL,
  EXCLUDE USING gist (person_id WITH =, valid_period WITH &&)
);

CREATE INDEX idx_employment_person ON employment USING gist (person_id, valid_period);
CREATE INDEX idx_employment_company ON employment (company_code);

-- 在籍状況（在籍・休職・退職）
-- assignment とは独立して切れる。休職しても配属は切らない運用のため、
-- 「在籍かつ配属」を数えるときは assignment と本テーブルを JOIN する必要がある
--
-- 産休・育休・私傷病・介護は休職の「状態」としては分けない（人事・労務確認、2026-08-04）。
-- いずれも is_active = false で共通のため employment_status_type には追加しない。
-- 男性育児休業取得率（reason = 育児休業）等の開示指標を表記ゆれなく集計できるよう、
-- reason の値は CHECK 制約または小さな参照テーブルで統制する（現時点は未実装、docs/SPEC.md 3.3）
CREATE TABLE employment_status (
  person_id    bigint    NOT NULL REFERENCES person,
  status_code  text      NOT NULL REFERENCES employment_status_type,
  event_type   text,     -- 入社・復職・休職・退職（この状態に入った契機）
  reason       text,     -- 事由（自己都合・会社都合・育児休業・介護休業・転籍 等）
  valid_period daterange NOT NULL,
  EXCLUDE USING gist (person_id WITH =, valid_period WITH &&)  -- 同時に1状態
);

CREATE INDEX idx_employment_status_person ON employment_status USING gist (person_id, valid_period);

-- 労働条件（所定労働時間・週の勤務日数・固定残業・労働時間管理・給与体系）
-- employment に列として持たない理由: 労働条件が変わっても雇用契約は継続するため。
-- employment に持つと労働条件の変更ごとに雇用の期間を切ることになり、
-- 「いつからその会社に在籍しているか」が読めなくなる（employment_status と同じ理屈）
-- 現行では5項目とも「社員名簿(公開)」アプリにあり、公開情報として扱われている
-- worktime_mgmt_type / pay_type は text のままとし、マスタテーブル化しない
-- （値の増減が少なく、org_layer 等と違って参照制約が必要なほど頻繁に変わらないため）。
-- 値の妥当性は入力側（API 層）でバリデーションする。
-- 現行値（kintone アプリID:34 で確認、2026-08-04）:
--   worktime_mgmt_type: 管理監督者（月給）/ 通常の労働時間制（月給・時給・日給）/
--                        裁量労働制（月給）/ フレックスタイム制（月給）の6種
--   pay_type:           月給 / 年俸 / 日給 / 時給 の4種
CREATE TABLE employment_condition (
  person_id            bigint    NOT NULL REFERENCES person,
  scheduled_hours      numeric(4,2),   -- 所定労働時間数（1日あたり）
  work_days_per_week   numeric(3,1),   -- 週の勤務日数
  fixed_overtime_hours numeric(4,1),   -- 固定残業時間数（みなし残業）
  worktime_mgmt_type   text,           -- 労働時間管理
  pay_type             text,           -- 給与体系。賃金の分類のみで金額は持たない
  valid_period         daterange NOT NULL,
  EXCLUDE USING gist (person_id WITH =, valid_period WITH &&)  -- 同時に1条件
);

CREATE INDEX idx_employment_condition_person
  ON employment_condition USING gist (person_id, valid_period);


-- ============================================================
-- 組織
-- ============================================================

-- 組織
-- 各会社には layer_code = 'company' の会社相当組織を1つ置き、役員の役職の設置先とする
-- （例: CB-ROOT / サイボウズ株式会社）。本部はその配下に入るため、ツリーの深さは
-- 会社を含めて最大6になる。階層別集計では org_layer.is_countable = false で除外する
CREATE TABLE org_unit (
  org_code     text      NOT NULL,
  org_name     text      NOT NULL,
  org_name_en  text,
  company_code text      NOT NULL REFERENCES company,
  layer_code   text      NOT NULL REFERENCES org_layer,
  valid_period daterange NOT NULL,
  EXCLUDE USING gist (org_code WITH =, valid_period WITH &&)
);

CREATE INDEX idx_org_unit_code ON org_unit USING gist (org_code, valid_period);

-- 組織階層。parent_org_code IS NULL がルート
-- グループ会社の組織がサイボウズのツリー内に存在するため、会社を跨ぐ単一ツリー＋独立ルートの
-- フォレスト構造になる
CREATE TABLE org_hierarchy (
  org_code        text      NOT NULL,
  parent_org_code text,
  valid_period    daterange NOT NULL,
  EXCLUDE USING gist (org_code WITH =, valid_period WITH &&)  -- 親は同時に1つ
);

CREATE INDEX idx_org_hierarchy_parent ON org_hierarchy (parent_org_code);

-- 組織コードの外部システム対応表（org_external_code）は削除した。
-- kintone スペースID:5 のアプリを確認した結果（2026-08-04）、bozuman システム組織コードは
-- 「タグ一覧」＝職能側（job_function.external_code）にのみ紐づいており、「組織一覧」には
-- 外部コード用のフィールドが存在しないため、組織側の対応表は不要と判定した


-- 親の階層区分が子より上位であることを保証する
-- 段の飛ばし（歯抜け: 副本部なしで本部の直下に部）は許容し、layer_order の単調増加のみ要求する
CREATE FUNCTION check_org_layer_order() RETURNS trigger AS $$
DECLARE
  parent_order smallint;
  child_order  smallint;
BEGIN
  IF NEW.parent_org_code IS NULL THEN
    RETURN NEW;   -- ルートは検査不要
  END IF;

  SELECT l.layer_order INTO child_order
    FROM org_unit o JOIN org_layer l USING (layer_code)
   WHERE o.org_code = NEW.org_code
     AND o.valid_period && NEW.valid_period;

  SELECT l.layer_order INTO parent_order
    FROM org_unit o JOIN org_layer l USING (layer_code)
   WHERE o.org_code = NEW.parent_org_code
     AND o.valid_period && NEW.valid_period;

  IF parent_order IS NULL OR child_order IS NULL THEN
    RAISE EXCEPTION '組織(% / %)が指定期間に存在しません', NEW.org_code, NEW.parent_org_code;
  END IF;

  IF parent_order >= child_order THEN
    RAISE EXCEPTION '親組織(%)の階層区分が子組織(%)以下です', NEW.parent_org_code, NEW.org_code;
  END IF;

  RETURN NEW;
END $$ LANGUAGE plpgsql;

CREATE CONSTRAINT TRIGGER trg_org_layer_order
  AFTER INSERT OR UPDATE ON org_hierarchy
  DEFERRABLE INITIALLY DEFERRED
  FOR EACH ROW EXECUTE FUNCTION check_org_layer_order();


-- ============================================================
-- 役職・配属
-- ============================================================

-- 役職。役員は会社相当組織（layer_code = 'company'）に設置する
-- 同一組織に grade の違う役職が並ぶ（本部に本部長と副本部長）ため、
-- 設置組織の階層区分と grade_code を 1:1 で検証する制約は張らない（docs/SPEC.md 3.7）
CREATE TABLE position (
  position_id      bigserial PRIMARY KEY,
  org_code         text      NOT NULL,
  position_name    text      NOT NULL,
  position_name_en text,
  grade_code       text      REFERENCES position_grade,  -- 役職階層
  valid_period     daterange NOT NULL
);

CREATE TABLE position_holder (
  person_id    bigint    NOT NULL REFERENCES person,
  position_id  bigint    NOT NULL REFERENCES position,
  valid_period daterange NOT NULL,
  EXCLUDE USING gist (person_id WITH =, position_id WITH =, valid_period WITH &&)
);

-- 配属（案A: valid time のみ）
-- 兼務工数は kintone 側で管理するため持たない。主務/兼務の区分だけを保持して結合を素直にする
-- 休職中も配属は切らない。在籍状況は employment_status 側で表現する
-- event_type は配属の切れ目の理由。在籍イベント（入社・復職・休職・退職）は
-- employment_status 側が正であり、こちらは異動系を記録する
CREATE TABLE assignment (
  person_id    bigint    NOT NULL REFERENCES person,
  org_code     text      NOT NULL,
  is_primary   boolean   NOT NULL DEFAULT false,
  event_type   text,     -- 異動・組織再編・入社時初回配属 等
  reason       text,     -- 異動理由
  valid_period daterange NOT NULL,
  EXCLUDE USING gist (person_id WITH =, org_code WITH =, valid_period WITH &&)
);

CREATE INDEX idx_assignment_person ON assignment USING gist (person_id, valid_period);
CREATE INDEX idx_assignment_org ON assignment USING gist (org_code, valid_period);


-- 配属（案B: バイテンポラル）。案A と並行実装して更新経路の実装可否を検証する
CREATE TABLE assignment_bt (
  person_id       bigint    NOT NULL REFERENCES person,
  org_code        text      NOT NULL,
  is_primary      boolean   NOT NULL DEFAULT false,
  valid_period    daterange NOT NULL,   -- いつからいつまでその配属か
  recorded_period tstzrange NOT NULL,   -- いつからいつまでそう認識していたか
  EXCLUDE USING gist (person_id WITH =, org_code WITH =,
                      valid_period WITH &&, recorded_period WITH &&)
);

-- 業務側・kintone 側にはこのビューのみ公開する（生テーブルの直参照を禁止）
-- recorded_period の条件を書き忘れると重複行が静かに返るため、ビュー経由を運用規律とする
CREATE VIEW assignment_bt_current AS
  SELECT * FROM assignment_bt WHERE recorded_period @> now();

-- 案B の更新。UPDATE せず、既存行の recorded_period を閉じて新行を INSERT する（append-only）
-- ロジックを DB 側に閉じ込めることで、呼び出し側（内製 API / 将来の Workato）は関数コール1回で済む
CREATE FUNCTION assignment_upsert(
  p_person_id  bigint,
  p_org_code   text,
  p_is_primary boolean,
  p_valid      daterange
) RETURNS void AS $$
BEGIN
  UPDATE assignment_bt
     SET recorded_period = tstzrange(lower(recorded_period), now())
   WHERE person_id = p_person_id
     AND org_code  = p_org_code
     AND valid_period && p_valid
     AND recorded_period @> now();

  INSERT INTO assignment_bt (person_id, org_code, is_primary, valid_period, recorded_period)
  VALUES (p_person_id, p_org_code, p_is_primary, p_valid, tstzrange(now(), NULL));
END $$ LANGUAGE plpgsql;


-- ============================================================
-- 横断的な所属（組織階層の外）
-- ============================================================
-- org_unit / org_hierarchy は「親は同時に1つ」「layer_order の単調増加」を前提とするため、
-- 階層に属さない横断的な所属はこちらで表現する。
-- ワーキンググループ（活動体）と職能（個人の役割分類）は、構造は似ているが
-- ライフサイクルと意味が違うため分けている（docs/SPEC.md 3.6）

CREATE TABLE working_group (
  wg_code      text      NOT NULL,
  wg_name      text      NOT NULL,
  wg_name_en   text,
  sub_category text,     -- ワーキンググループ名（サブ分類）
  valid_period daterange NOT NULL,
  EXCLUDE USING gist (wg_code WITH =, valid_period WITH &&)
);

CREATE TABLE working_group_member (
  person_id    bigint    NOT NULL REFERENCES person,
  wg_code      text      NOT NULL,   -- 論理参照（working_group は期間で複数行を持つため FK 不可）
  role         text      NOT NULL,   -- 'manager'（管理担当者） / 'member'
  valid_period daterange NOT NULL,
  EXCLUDE USING gist (person_id WITH =, wg_code WITH =, valid_period WITH &&)
);

CREATE INDEX idx_wg_member_wg ON working_group_member USING gist (wg_code, valid_period);


-- 職能（現行の「タグ一覧」アプリに相当）
-- 開発組織のメンバーを職能（フロントエンドエンジニア・バックエンドエンジニア・QA・PD マネジメント等）で
-- 横断管理する。「kintone 開発組織の人員」と「全製品のフロントエンドエンジニア」という
-- マトリクスの横軸にあたり、組織ツリーには紐づかない
-- external_code は bozuman システム上の組織コード。bozuman 側では職能が組織として扱われている
-- 複数システムへの対応が必要になった時点で system_name を持つ別テーブルへ切り出す
CREATE TABLE job_function (
  fn_code       text      NOT NULL,
  fn_name       text      NOT NULL,
  fn_name_en    text,
  external_code text,     -- bozuman システム組織コード
  valid_period  daterange NOT NULL,
  EXCLUDE USING gist (fn_code WITH =, valid_period WITH &&)
);

-- 職能の割当。1人が複数の職能を持てる（フロントエンド兼 QA 等）
-- role で職能ごとのマネジメントライン（職能マネージャー）を表現する
CREATE TABLE person_job_function (
  person_id    bigint    NOT NULL REFERENCES person,
  fn_code      text      NOT NULL,   -- 論理参照（job_function は期間で複数行を持つため FK 不可）
  role         text      NOT NULL,   -- 'manager'（職能マネージャー） / 'member'
  valid_period daterange NOT NULL,
  EXCLUDE USING gist (person_id WITH =, fn_code WITH =, valid_period WITH &&)
);

CREATE INDEX idx_person_job_function_fn
  ON person_job_function USING gist (fn_code, valid_period);


-- ============================================================
-- 監査
-- ============================================================

-- 案A の監査用。案B を採る場合は本体が履歴を兼ねるため不要になる
-- changed_by の受け渡し方式は未決（docs/POC.md 3章-3）。PoC では固定値を入れる
CREATE TABLE change_log (
  id         bigserial   PRIMARY KEY,
  table_name text        NOT NULL,
  operation  text        NOT NULL,
  changed_at timestamptz NOT NULL DEFAULT now(),
  changed_by text,
  before_row jsonb,
  after_row  jsonb
);


-- ============================================================
-- kintone 公開用ビュー・関数
-- ============================================================

-- 基準日のフルパスを5列に展開する
-- 列位置は depth ではなく layer_order で決める。これにより歯抜けが NULL のまま残り、
-- 現行 kintone の見え方（EP事業本部 / NULL / EP事業部 ...）と一致する
-- 会社相当組織（layer_order = 0）は level1〜level5 のどこにも入らないため、
-- 会社をツリーに追加しても現行の見え方は変わらない。ただし depth は会社を含めて +1 になる
CREATE FUNCTION org_full_path(p_asof date)
RETURNS TABLE (
  org_code text, org_name text, layer_code text, depth int,
  level1 text, level2 text, level3 text, level4 text, level5 text
) AS $$
WITH RECURSIVE up AS (
  -- 起点: 基準日に存在する各組織
  SELECT h.org_code AS target, h.org_code AS node, h.parent_org_code, 1 AS depth
    FROM org_hierarchy h
   WHERE h.valid_period @> p_asof
  UNION ALL
  -- 親を辿る
  SELECT up.target, h.org_code, h.parent_org_code, up.depth + 1
    FROM up
    JOIN org_hierarchy h ON h.org_code = up.parent_org_code
                        AND h.valid_period @> p_asof
)
SELECT
  t.org_code, t.org_name, t.layer_code,
  max(up.depth)::int AS depth,
  max(u.org_name) FILTER (WHERE l.layer_order = 1) AS level1,
  max(u.org_name) FILTER (WHERE l.layer_order = 2) AS level2,
  max(u.org_name) FILTER (WHERE l.layer_order = 3) AS level3,
  max(u.org_name) FILTER (WHERE l.layer_order = 4) AS level4,
  max(u.org_name) FILTER (WHERE l.layer_order = 5) AS level5
FROM up
JOIN org_unit  t ON t.org_code = up.target AND t.valid_period @> p_asof
JOIN org_unit  u ON u.org_code = up.node   AND u.valid_period @> p_asof
JOIN org_layer l ON l.layer_code = u.layer_code
GROUP BY t.org_code, t.org_name, t.layer_code;
$$ LANGUAGE sql STABLE;

CREATE VIEW org_path_current AS SELECT * FROM org_full_path(CURRENT_DATE);

-- 社員の現在断面。外部システムのアプリ化では range 型を扱えないため date 2列に展開する
-- 在籍状況を含めることで、利用側が status の JOIN を忘れて休職者を混ぜる事故を防ぐ
CREATE VIEW employee_current AS
SELECT
  e.person_id,
  n.full_name,
  n.full_name_kana,
  e.employee_no,
  e.account_name,
  c.company_code,
  c.company_name,
  e.employment_type,
  et.type_name AS employment_type_name,
  et.is_employee,
  e.hire_category,
  e.work_style,
  l.location_code,
  l.location_name,
  rl.location_code AS residence_location_code,
  rl.location_name AS residence_location_name,
  p.group_joined_on,
  s.status_code,
  st.status_name,
  st.is_active,
  lower(e.valid_period) AS valid_start,
  upper(e.valid_period) AS valid_end
FROM employment e
JOIN person       p ON p.person_id = e.person_id
LEFT JOIN person_name n ON n.person_id = e.person_id
JOIN company      c ON c.company_code = e.company_code AND c.valid_period @> CURRENT_DATE
LEFT JOIN employment_type et ON et.type_code = e.employment_type
LEFT JOIN location l  ON l.location_code  = e.location_code           AND l.valid_period  @> CURRENT_DATE
LEFT JOIN location rl ON rl.location_code = e.residence_location_code AND rl.valid_period @> CURRENT_DATE
LEFT JOIN employment_status s ON s.person_id = e.person_id AND s.valid_period @> CURRENT_DATE
LEFT JOIN employment_status_type st ON st.status_code = s.status_code
WHERE e.valid_period @> CURRENT_DATE;

-- 入社前の人（現行の在籍状況「入社前」に相当）
-- status として持たず、雇用開始日が未来日であることから導出する
-- 情報システム本部の機材準備・アカウント発行に使う
CREATE VIEW employee_pending AS
SELECT
  e.person_id,
  n.full_name,
  n.full_name_kana,
  e.employee_no,
  e.account_name,
  e.company_code,
  e.employment_type,
  e.hire_category,
  lower(e.valid_period) AS hire_date
FROM employment e
LEFT JOIN person_name n ON n.person_id = e.person_id
WHERE lower(e.valid_period) > CURRENT_DATE;

-- 配属の現在断面（案A）
-- is_active を出して、利用側が「在籍者のみ」に絞れるようにする（休職者は配属を切らないため）
CREATE VIEW assignment_current AS
SELECT
  a.person_id,
  a.org_code,
  o.org_name,
  o.layer_code,
  a.is_primary,
  st.is_active,
  lower(a.valid_period) AS valid_start,
  upper(a.valid_period) AS valid_end
FROM assignment a
JOIN org_unit o ON o.org_code = a.org_code AND o.valid_period @> CURRENT_DATE
LEFT JOIN employment_status s ON s.person_id = a.person_id AND s.valid_period @> CURRENT_DATE
LEFT JOIN employment_status_type st ON st.status_code = s.status_code
WHERE a.valid_period @> CURRENT_DATE;

-- 労働条件の現在断面。FTE を DB 側で計算して出す
-- 分母（standard_weekly_hours）を利用側に選ばせると集計がばらつくため、ここで確定させる
-- ⚠ 兼務者の FTE をこのまま配属で集計すると二重計上になる。
--    兼務工数は kintone 側にあるため、HRCore 単体で正しく出せるのは主務ベースの FTE のみ
CREATE VIEW employment_condition_current AS
SELECT
  c.person_id,
  c.scheduled_hours,
  c.work_days_per_week,
  c.fixed_overtime_hours,
  c.worktime_mgmt_type,
  c.pay_type,
  round(c.scheduled_hours * c.work_days_per_week
        / nullif(co.standard_weekly_hours, 0), 3) AS fte,
  lower(c.valid_period) AS valid_start,
  upper(c.valid_period) AS valid_end
FROM employment_condition c
JOIN employment e  ON e.person_id = c.person_id      AND e.valid_period  @> CURRENT_DATE
JOIN company    co ON co.company_code = e.company_code AND co.valid_period @> CURRENT_DATE
WHERE c.valid_period @> CURRENT_DATE;

-- ワーキンググループの現在断面
CREATE VIEW working_group_member_current AS
SELECT
  m.person_id,
  m.wg_code,
  w.wg_name,
  w.sub_category,
  m.role,
  lower(m.valid_period) AS valid_start,
  upper(m.valid_period) AS valid_end
FROM working_group_member m
JOIN working_group w ON w.wg_code = m.wg_code AND w.valid_period @> CURRENT_DATE
WHERE m.valid_period @> CURRENT_DATE;

-- 職能の現在断面。マトリクスの横軸での集計に使う
-- is_active を出して、在籍者のみに絞れるようにする（休職者は職能を持ったまま残る）
CREATE VIEW person_job_function_current AS
SELECT
  f.person_id,
  f.fn_code,
  j.fn_name,
  j.fn_name_en,
  j.external_code,
  f.role,
  st.is_active,
  lower(f.valid_period) AS valid_start,
  upper(f.valid_period) AS valid_end
FROM person_job_function f
JOIN job_function j ON j.fn_code = f.fn_code AND j.valid_period @> CURRENT_DATE
LEFT JOIN employment_status s      ON s.person_id = f.person_id AND s.valid_period @> CURRENT_DATE
LEFT JOIN employment_status_type st ON st.status_code = s.status_code
WHERE f.valid_period @> CURRENT_DATE;


-- ============================================================
-- ロールとアクセス制御
-- ============================================================
-- 非公開の個人属性（person_demographics）をテーブル単位で分離する。
-- ビューは定義者の権限で動く（security_invoker = false がデフォルト）ため、
-- 公開ビューに GRANT すれば、下のテーブルへの権限がなくても氏名などは参照できる。
--
-- 行レベルの制御（RLS）は不要。「自分のレコードだけ見せる」要件は kintone 側の
-- アクセス権で担保する（docs/REQUIREMENTS.md 1章）。
--
-- ロール名・粒度は PoC 用の暫定。本番は社内クラウド基盤側の運用に合わせる

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'hrcore_hr') THEN
    CREATE ROLE hrcore_hr;        -- 人事・労務。全テーブルの参照・更新
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'hrcore_analyst') THEN
    CREATE ROLE hrcore_analyst;   -- 分析・BI・AI エージェント。非公開属性を除く参照
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'hrcore_kintone') THEN
    CREATE ROLE hrcore_kintone;   -- Agent 経由の kintone。公開ビューのみ参照
  END IF;
END $$;

-- 人事・労務: 全テーブル
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO hrcore_hr;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO hrcore_hr;

-- 分析: 全テーブル・全ビューを参照可にしたうえで、非公開属性だけを剥がす
-- （REVOKE の順序が重要。GRANT ... ALL TABLES はビューも含む）
GRANT SELECT ON ALL TABLES IN SCHEMA public TO hrcore_analyst;
REVOKE ALL ON person_demographics FROM hrcore_analyst;

-- kintone（Agent 経由）: 公開ビューのみ
GRANT SELECT ON
  org_path_current,
  employee_current,
  employee_pending,
  assignment_current,
  employment_condition_current,
  working_group_member_current,
  person_job_function_current,
  assignment_bt_current
TO hrcore_kintone;
