# LINE グループ ⇄ メール

📖 **[English version / 英語版 README](README.md)**

LINE グループとメールを双方向につなぐブリッジです。AWS 上に Terraform で構築します。

- **送信方向（アウトバウンド）** — パブリックな Function URL の背後にある Lambda が
  [LINE Messaging API](https://developers.line.biz/ja/docs/messaging-api/) の
  Webhook を受け取り、署名を検証し、グループに誰かが投稿するたびに（Amazon SES
  経由で）あなたにメールを送ります。
- **受信方向（インバウンド、任意）** — あなたが秘密のアドレスにメールを送ると、SES
  がそのメールを認証し、Lambda が本文をグループに投稿します。

```
送信:  LINE グループ ──webhook──▶ Function URL ▶ Lambda（検証+解析）▶ SES ▶ あなたの受信箱
受信:  あなたのメール ──▶ SES (MX) ▶ S3 + Lambda（認証+解析）▶ LINE push ▶ グループ
```

このガイドは単体で完結します。LINE チャネルも AWS 設定もない状態から、動作する
システムまでを順に説明します。外部コンソールで行う手順については、古くなりやすい
スクリーンショットを複製するのではなく、その公式ドキュメントへのリンクを示します。

---

## リポジトリ構成

| ファイル | 役割 |
|------|---------|
| `main.tf` | 送信側: IAM、SES の送信者/受信者、Lambda、ロググループ、Function URL |
| `inbound.tf` | 受信側: SES 受信ルール、S3、Lambda、IAM（メール → グループ投稿） |
| `variables.tf` | 入力変数 |
| `src/lambda_fn.py` | Webhook ハンドラ（署名検証、解析、メール送信） |
| `src/inbound_fn.py` | 受信ハンドラ（認証、本文解析、グループへ push） |
| `terraform.tfvars.example` | 値のテンプレート。`terraform.tfvars` にコピーして使う |
| `.gitignore` | state・tfvars・ビルド成果物を git から除外 |

> **秘密情報は git に入れないこと。** Terraform の state（`*.tfstate`）と
> `terraform.tfvars` にはチャネルシークレットやトークンが平文で入るため、gitignore
> しています。コミットされるのは `terraform.tfvars.example` だけです。フォークや
> 公開をする場合も、この状態を維持してください。

---

## 前提条件

始める前に、以下がすべて必要です。

- Messaging API チャネルを作成するための **LINE アカウント**（個人アカウントで可）。
- IAM・Lambda・SES・S3・CloudWatch を管理できる権限を持つ **AWS アカウント**。
  root ユーザーではなく IAM ユーザー/ロールの利用を推奨します。
- DNS レコード（TXT/CNAME/MX）を追加できる、**あなたが所有するドメイン**。これは
  必須です。`@gmail.com` / `@yahoo.com` のアドレスを送信元にすることはできません
  （[理由](#自分のドメインが必要な理由)）。安価なドメインで構いません。
- **[Terraform CLI](https://developer.hashicorp.com/terraform/install)** 1.9 以上
  （本プロジェクトは変数間バリデーションを使用）。
- **[AWS CLI](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html)**
  （認証情報を `aws configure` で設定済み）。検証コマンドや Terraform の認証に使います。

**リージョンについて:** 受信機能を使う場合は、**SES のメール受信（email
receiving）** に対応した AWS リージョンにデプロイしてください。対応していない
リージョンもあります。対応状況は
[SES email-receiving エンドポイント一覧](https://docs.aws.amazon.com/general/latest/gr/ses.html)
で確認できます。送信機能はどの SES リージョンでも動作します。

---

## パート A — LINE チャネルの作成と認証情報の取得

ここで 3 つを取得します。**チャネルシークレット**、**チャネルアクセストークン**、
そして（後で）**グループ ID** です。

### A1. Messaging API チャネルを作成する

1. [LINE Developers コンソール](https://developers.line.biz/console/) にログインします。
2. **プロバイダー**を作成します（名前は任意。プロジェクト名や会社名など）。
3. そのプロバイダーの下に **Messaging API チャネル**を作成します。これにより LINE
   公式アカウントも同時に作成されます。
   詳細な手順:
   [Messaging API を始めよう](https://developers.line.biz/ja/docs/messaging-api/getting-started/)。

### A2. チャネルシークレットをコピーする

チャネル → **チャネル基本設定**タブ → **チャネルシークレット**。これを
`line_channel_secret` に設定します。Webhook が本当に LINE から来たものかを検証する
ために使われます（リクエストボディの HMAC-SHA256）。

### A3. チャネルアクセストークン（長期）を発行する

チャネル → **Messaging API**タブ → **チャネルアクセストークン（長期）** →
**発行**。これを `line_channel_access_token` にコピーします。
参考:
[チャネルアクセストークン](https://developers.line.biz/ja/docs/basics/channel-access-token/)。

このトークンにより、Bot は送信者の表示名を取得でき、（受信機能では）メッセージを
push できます。単純な通知だけなら任意ですが推奨で、受信機能では**必須**です。

### A4. 応答設定を行う

LINE 公式アカウントは既定で自動応答（チャット）モードになっており、これは
**Webhook を無効化します**。次のように修正してください。

- **Messaging API**タブ（または連携先の
  [LINE Official Account Manager](https://manager.line.biz/) → **設定 → 応答設定**）で:
  - **応答モード / チャット**: **Bot** にする（チャットにしない）。
  - **Webhook**: **有効**にする。
  - **自動応答メッセージ**・**あいさつメッセージ**: **オフ**にする（Bot を静かに
    保つため）。
  - **Bot のグループトーク参加を許可**: **オン**にする（そうしないとグループで何も
    受信しません）。

実際の **Webhook URL** は、Terraform が URL を出力した後、
[パート C](#c4-webhook-を接続する) で設定します。

---

## パート B — AWS の準備

1. **認証情報。** 前提条件に挙げたサービスを管理できる IAM ユーザー/ロールで AWS CLI
   を設定します（`aws configure`）。`aws sts get-caller-identity` で確認します。
2. **リージョンを 1 つ選ぶ**（例: `ap-northeast-1`）。すべて同じリージョンで統一します。
3. **SES は最初「サンドボックス」にあります。** 新規アカウントは*検証済み*の
   アドレスにしか、かつ低いレートでしか送信できません。ここでは自分の受信箱に送る
   だけなので問題ありません。後で任意の宛先に送りたい場合は
   [本番アクセス](https://docs.aws.amazon.com/ses/latest/dg/request-production-access.html)
   を申請してください。**受信**側はサンドボックスの制限を**受けません**。

### 自分のドメインが必要な理由

メールプロバイダー（Gmail、Yahoo など）は自ドメインに対して厳格な **DMARC**
ポリシーを公開しています。`From:` が `you@gmail.com` なのに実際には
`amazonses.com` が送信・DKIM 署名しているメールを送ると、DMARC が失敗し、メールは
拒否されます（`554 5.7.9 ... DMARC`）。*あなたが所有する*ドメインを SES の **Easy
DKIM** で検証すると、SES があなたのドメインとして署名するため DMARC が整合し、メール
が配信されます。したがって通知の**送信元**は、あなたのドメインのアドレス（例:
`notify@example.com`）である必要があります。

---

## パート C — 送信通知をデプロイする

### C1. 値を設定する

```bash
git clone <this-repo> && cd <this-repo>
cp terraform.tfvars.example terraform.tfvars
```

`terraform.tfvars` を編集します。

```hcl
aws_region          = "ap-northeast-1"          # あなたのリージョン
line_channel_secret = "…"                        # A2 で取得
ses_sender_domain   = "example.com"              # あなたが所有するドメイン
ses_sender_email    = "notify@example.com"       # そのドメインの任意のアドレス
ses_recipient_email = "you@example.com"          # 通知の宛先（任意の受信箱）

line_channel_access_token = "…"                  # A3 で取得（推奨）
```

`terraform.tfvars` は gitignore 済みです。あるいは `TF_VAR_<name>` 環境変数で値を
渡せば、ファイルに一切残さずに済みます。

### C2. デプロイする

```bash
terraform init
terraform apply
```

最後に Terraform が `webhook_url` と、追加すべき DNS レコードを出力します。

### C3. 送信ドメインと受信者を検証する

DNS レコードを出力し、DNS プロバイダーに追加します。

```bash
terraform output ses_domain_verification_txt   # TXT レコード 1 件
terraform output ses_dkim_cname_records        # CNAME レコード 3 件
```

ヒント: 多くの DNS エディタはドメインを自動補完するため、**ホスト**部分だけを入力
します（例: `_amazonses`、`<token>._domainkey`）。Cloudflare の場合、CNAME は
**DNS only**（プロキシしない）に設定します。数分〜数時間で SES がドメインを
**Verified** にします。

```bash
aws ses get-identity-verification-attributes --identities example.com
```

**受信者:** サンドボックスでは受信者も検証が必要です。`terraform apply` がワン
クリックの確認メールを送るので、そのリンクをクリックしてください。

### C4. Webhook を接続する

[LINE Developers コンソール](https://developers.line.biz/console/) → あなたの
チャネル → **Messaging API**タブで:

1. **Webhook URL** を `webhook_url` の出力値に設定します
   （`terraform output -raw webhook_url`）。
2. **検証**をクリックします。成功するはずです。
3. **Webhook の利用**がオンであることを確認します（および
   [A4](#a4-応答設定を行う) の応答設定）。

### C5. Bot をグループに追加して確認する

1. 公式アカウントを友だち追加し（ID/QR コードは **Messaging API**タブまたは
   Official Account Manager にあります）、LINE グループに招待します。
2. グループにメッセージを投稿します。数秒以内にメールが届くはずです。新しいドメイン
   からの最初のメールは**迷惑メール**に入ることがあります。その場合は「迷惑メール
   ではない」を選んでください。

---

## パート D — 任意: 受信（メール → グループ）

メールを送ることでグループに投稿できるようにします。メールの**本文**が LINE の
メッセージになります。

**セキュリティの仕組み。** 次の 3 つすべてを満たした場合のみ投稿されます。
1. SES の **DMARC 判定が PASS**（かつスパム/ウイルス判定が失敗でない）— `From` を
   詐称できません。
2. `From` アドレスが **`allowed_senders`** に含まれている。
3. **秘密のアドレス**（`inbound_local_part@inbound_subdomain`）宛てに送られている。

なお、送信は普段の受信箱（Gmail/Yahoo など）から行います。これらのプロバイダーの
実メールは DMARC を通過し、それがここで使う判定材料になります。（これは送信側の
*送信元*が自分のドメインでなければならないのと逆です。）

### D1. グループ ID を取得する

グループ ID はどのコンソールにも表示されず、Webhook イベントにのみ現れます。最も
簡単な方法: 送信機能を動かし（パート C）、Bot をグループに入れた状態でメッセージを
投稿すると、**通知メール**（および CloudWatch ログ）に `GroupID` が含まれます。その
値をコピーします。

### D2. 設定してデプロイする

`terraform.tfvars` に追記します。

```hcl
# 受信専用の、あなたが所有するドメインのサブドメイン（通常のメール/MX に影響を与え
# ません）。ses_sender_domain と一致している必要はありません。
inbound_subdomain  = "post.example.com"
inbound_local_part = "line-<random>"     # 秘密。アドレス = <this>@<subdomain>
allowed_senders    = ["you@example.com"] # 投稿を許可する From アドレス
line_group_id      = "Cxxxxxxxx…"        # D1 で取得
# line_channel_access_token が設定されている必要があります（パート A3）。
```

推測されにくい `inbound_local_part` を選んでください（例:
`line-$(python -c 'import secrets;print(secrets.token_hex(5))')`）。その後:

```bash
terraform apply
```

### D3. 受信用 DNS レコードを追加する

```bash
terraform output inbound_mx_record           # MX  -> inbound-smtp.<region>.amazonaws.com
terraform output inbound_verification_txt     # 所有を証明する TXT
terraform output -raw inbound_email_address   # 送信先の秘密アドレス
```

サブドメインの **MX**（優先度 10）と **TXT** を追加します。SES がそのサブドメインを
**Verified** にするまで待ちます（`aws ses get-identity-verification-attributes
--identities post.example.com`）。

> SES の受信ルールセットは、アカウント/リージョンごとに **1 つ**しかアクティブに
> できません。既に 1 つある場合は、2 つ目をアクティブ化するのではなく、それを利用
> してください（`inbound.tf` 参照）。

### D4. テストする

許可されたアカウントから、秘密のアドレスにメールを送ります。本文が数秒以内に
グループに現れます（署名や引用返信は除去され、約 4900 文字で上限）。何も投稿され
ない場合は `aws logs tail /aws/lambda/<function_name>-inbound --since 15m` を確認
してください。メッセージが拒否された理由（判定、送信者、空の本文）が正確にログに
出ます。

---

## 設定リファレンス

| 変数 | 必須 | 既定値 | 備考 |
|----------|----------|---------|-------|
| `aws_region` | はい | — | ソースに残さないため既定値なし。tfvars か `TF_VAR_aws_region` で設定。 |
| `line_channel_secret` | はい | — | 機密。基本設定タブ（A2）。 |
| `ses_sender_domain` | はい | — | あなたが所有し DKIM 検証したドメイン。gmail/yahoo 不可。 |
| `ses_sender_email` | はい | — | 送信元アドレス。`ses_sender_domain` のアドレスであること。 |
| `ses_recipient_email` | はい | — | 通知の宛先（任意の受信箱）。 |
| `line_channel_access_token` | 任意* | `""` | 送信者の表示名を付加。*受信機能では必須。* |
| `function_name` | 任意 | `line-notifier` | Lambda 名、および受信側リソースの接頭辞。 |
| `log_retention_days` | 任意 | `14` | CloudWatch ログの保持日数。 |
| `inbound_subdomain` | 受信 | — | MX を SES に向けるサブドメイン（例: `post.example.com`）。 |
| `inbound_local_part` | 受信 | — | 機密。トリガーアドレスの秘密のローカル部。 |
| `allowed_senders` | 受信 | — | 投稿を許可する `From` アドレスのリスト（DMARC 通過必須）。 |
| `line_group_id` | 受信 | — | 機密。受信メールの投稿先グループ。 |
| `inbound_retention_days` | 任意 | `7` | 受信した生メールを S3 に保持する日数。 |

「受信」= 受信機能を有効にする場合のみ必須。

---

## 注意点・制約

- グループのメッセージ**すべて**でメールが飛びます。にぎやかなグループでは、
  `src/lambda_fn.py` にフィルタ（例: キーワード）を追加してください。
- Function URL は `authorization_type = NONE` を使用します。真正性は関数内での
  `X-Line-Signature` ヘッダの HMAC-SHA256 検証で担保されます。
- 表示名は送信者の**グローバルな** LINE 名で、グループごとのニックネームではありま
  せん（LINE の API はグループニックネームを公開していません）。テキスト以外の
  メッセージは `[<type> message]` と表示されます。
- **プロバイダーのバージョン:** AWS プロバイダー **6.28 以上**が必要です。2025 年
  10 月以降、パブリックな Function URL には `lambda:InvokeFunctionUrl` と
  `lambda:InvokeFunction` の両方の許可が必要で、6.28 以上は両方を自動追加します
  （古いバージョンでは 403 になります）。
- **コスト。** AWS 側はごくわずかです（Lambda + SES は無料枠内/付近）。受信の投稿は
  LINE の **push** メッセージで、**受信者ごと**に課金されます。N 人のグループへの
  1 投稿は、[LINE のプラン](https://developers.line.biz/ja/docs/messaging-api/pricing/)
  の枠に対して N メッセージとしてカウントされます。

---

## トラブルシューティング

**メッセージを投稿してもメールが届かない。** 上から順に確認します。まずリージョンを
設定します: `export AWS_REGION=<your-region>`（`<function_name>` の既定は
`line-notifier`）。

1. **そもそも関数は呼ばれているか？**
   ```bash
   aws logs tail /aws/lambda/line-notifier --since 15m --format short
   ```
   - *ログイベントなし* → LINE が関数に到達していません。手順 2 へ。
   - *`Invalid LINE signature`* → `line_channel_secret` が呼び出し元チャネルと一致
     していません。修正して再 apply。
   - *`Email sent. Message ID: …`* → パイプラインは動作しています。迷惑メールと、
     SES アドレスが検証済みか（手順 4）を確認。

2. **パブリックエンドポイントに到達できるか？**
   ```bash
   curl -s -w '\n%{http_code}\n' -X POST "$(terraform output -raw webhook_url)" \
     -H 'Content-Type: application/json' -d '{"events":[]}'
   ```
   - **400 Bad Request** → エンドポイントは正常（関数が動き、署名なしリクエストを
     拒否）。問題は LINE 側 — 手順 3 へ。
   - **403 `{"Message":"Forbidden…"}`** → AWS がコード到達前にブロック。AWS
     プロバイダー **6.28 以上**を確認して再 apply するか、不足している許可を手動で
     追加:
     ```bash
     aws lambda add-permission --function-name line-notifier \
       --statement-id FunctionURLInvokeAllowPublicAccess \
       --action lambda:InvokeFunction --principal '*' --invoked-via-function-url
     ```

3. **LINE 側チェックリスト**（Developers コンソール + Official Account Manager）:
   - Webhook URL が `terraform output -raw webhook_url` と一致し、**Webhook の
     利用**がオン。
   - **検証**ボタンが成功する。
   - **Bot のグループトーク参加を許可**がオンで、Bot が実際にグループにいる。
   - **応答モード**が **Bot**（チャットではない。チャットは Webhook を無効化）。

4. **SES / 配信:** 送信**ドメイン**と受信者が検証済みか確認:
   ```bash
   aws ses get-identity-verification-attributes --identities example.com you@example.com
   ```
   `554 5.7.9 ... DMARC` のバウンスは、`From` が DKIM 検証していないドメイン（例:
   gmail/yahoo アドレス）であることを意味します —
   [パート C3](#c3-送信ドメインと受信者を検証する) を参照。

**受信: メールは送ったのに投稿されない。**
`aws logs tail /aws/lambda/line-notifier-inbound --since 15m` を確認します。
`Rejected … verdicts` = DMARC/スパム/ウイルス判定に失敗、`sender … not
allowlisted` = `allowed_senders` に追加が必要、何も出ない = サブドメインが未検証、
または MX が未設定/誤り。

---

## 削除（Tear down）

```bash
terraform destroy
```

注意: パブリックな Function URL 用に追加されたリソースベースポリシーの許可は、URL を
削除しても SES によって自動削除されません。害はありませんが、必要なら手動で削除でき
ます。
