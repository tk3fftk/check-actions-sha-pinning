# check-actions-sha-pinning

[English](README.md) | **日本語**

GitHub Actions のワークフローファイルおよびコンポジットアクションファイルで参照されている全アクションが SHA ピンニングされているかを、推移的依存関係を含めて再帰的にチェックする Bash スクリプトです。

## 特徴

- 40文字の完全なコミットSHAハッシュにピン留めされていないアクションを検出
- コンポジットアクションの内部依存関係も再帰的に検査し、SHAピンニングを検証
- `sha256:` ダイジェストにピン留めされていない Docker 参照を検出
- 取得した `action.yml` ファイルのキャッシュおよび訪問済みアクションの重複排除により API 呼び出しを最小化
- ターミナルでのカラー出力（パイプやリダイレクト時は自動的に無効化）
- 最大再帰深度の設定が可能

## 前提条件

- **Bash 3.2 以上**（macOS およびほとんどの Linux ディストリビューションにプリインストール済み）

以下の CLI ツールがインストールされ、`PATH` 上で利用可能である必要があります:

| ツール | 説明 |
|--------|------|
| [`gh`](https://cli.github.com/) | GitHub CLI（GitHub API 経由でリモートのアクションファイルを取得するために使用） |
| [`yq`](https://github.com/mikefarah/yq) | YAML プロセッサ（ワークフローおよびアクションファイルの解析に使用） |
| `base64` | Base64 デコーダ（macOS および Linux では通常プリインストール済み） |

また、`gh` で認証済みである必要があります（`gh auth login`）。

## クイックスタート（ワンライナー）

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/tk3fftk/check-actions-sha-pinning/main/check-actions-sha-pinning.sh)
```

より安全に実行するには、`main` の代わりに信頼できるコミット SHA を指定してください:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/tk3fftk/check-actions-sha-pinning/<COMMIT_SHA>/check-actions-sha-pinning.sh)
```

## 使い方

```
check-actions-sha-pinning.sh [オプション] [ディレクトリ]
```

### 引数

| 引数 | 説明 |
|------|------|
| `ディレクトリ` | スキャン対象のリポジトリルート（デフォルト: git リポジトリルートまたはカレントディレクトリ） |

### オプション

| オプション | 説明 |
|------------|------|
| `-d, --max-depth N` | 推移的依存関係チェックの最大再帰深度（デフォルト: `5`） |
| `--no-color` | カラー出力を無効化 |
| `-h, --help` | ヘルプメッセージを表示 |

### 実行例

```bash
# カレントリポジトリをスキャン
./check-actions-sha-pinning.sh

# 特定のリポジトリディレクトリをより深い再帰でスキャン
./check-actions-sha-pinning.sh -d 10 /path/to/repo

# パイプ向け出力（カラーは自動的に無効化）
./check-actions-sha-pinning.sh | tee report.txt
```

## スキャン対象

- `.github/workflows/*.yml` / `.github/workflows/*.yaml` — ワークフローファイル（再利用可能ワークフローの `uses` およびステップレベルの `uses`）
- `.github/actions/*/action.yml` / `.github/actions/*/action.yaml` — ローカルコンポジットアクションファイル

ローカルアクション（`./` または `.github/` プレフィックス付き）は同一リポジトリ内に存在するため、チェック対象から除外されます。

## 出力

各アクション参照は以下のいずれかのステータスで報告されます:

| ステータス | 意味 |
|------------|------|
| `[PASS]` | アクションが SHA ピンニングされている（またはサブ依存関係のない非コンポジットアクション） |
| `[FAIL]` | アクションが SHA ピンニングされていない、または推移的依存関係がピンニングされていない |
| `[WARN]` | アクションを取得できなかった（プライベートリポジトリ / 未検出）、または最大再帰深度に到達 |

推移的依存関係はインデント表示され、依存関係ツリーが視覚的に確認できます。

最後にサマリーが出力され、合格・不合格・警告の各件数と、ピンニングされていない依存関係チェーンの一覧が表示されます。

## 終了コード

| コード | 意味 |
|--------|------|
| `0` | チェックした全アクションが正しく SHA ピンニングされている |
| `1` | 1つ以上のアクションが SHA ピンニングされていない |
