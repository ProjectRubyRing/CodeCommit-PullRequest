#!/usr/bin/env bash
#
# CodeCommit のプルリクエストを作成し、Terraform plan の結果をコメントとして投稿する。
#
# 使い方:
#   ./create_pr.sh <clone先フォルダ> <ブランチ名> <環境> [マージ先ブランチ]
#
#   <clone先フォルダ>  : リポジトリを clone済みのフォルダ
#   <ブランチ名>       : PR の作成元(source)ブランチ
#   <環境>             : Terraform/envs 配下の環境フォルダ (j1, j2, j3, st, pr)
#   [マージ先ブランチ] : PR のマージ先(destination)ブランチ (省略時: main)
#
# 例:
#   ./create_pr.sh ./my-repo feature/foo j1
#   ./create_pr.sh ./my-repo feature/foo pr develop
#
set -euo pipefail

# ---- 共通部品(common.sh)の読み込み -----------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

# ---- 前提コマンドの確認 ----------------------------------------------------
require_cmd git "git をインストールしてください"
require_cmd aws "AWS CLI をインストールしてください"
require_cmd terraform "Terraform をインストールしてください"

# ---- 引数チェック ----------------------------------------------------------
if [ "$#" -lt 3 ]; then
  die "使い方: $0 <clone先フォルダ> <ブランチ名> <環境(j1/j2/j3/st/pr)> [マージ先ブランチ]"
fi

REPO_DIR="$1"
SOURCE_BRANCH="$2"
ENV="$3"
DEST_BRANCH="${4:-main}"

# 環境フォルダの妥当性チェック
case "$ENV" in
  j1|j2|j3|st|pr) ;;
  *) die "環境は j1, j2, j3, st, pr のいずれかを指定してください (指定値: $ENV)" ;;
esac

cd "$REPO_DIR"

# ---- リポジトリ名を git remote から取得 ------------------------------------
# CodeCommit の remote URL 末尾がリポジトリ名
REPO_NAME="$(basename "$(git config --get remote.origin.url)")"
log_info "リポジトリ: $REPO_NAME"

# ---- Terraform plan の実行 -------------------------------------------------
PLAN_DIR="Terraform/envs/$ENV"
log_info "Terraform plan を実行します: $PLAN_DIR"

PLAN_OUTPUT="$(
  cd "$PLAN_DIR"
  terraform init -input=false -no-color >/dev/null
  terraform plan -input=false -no-color 2>&1
)"

# ---- Terraform plan の結果をコメント用に整形 -------------------------------
# CodeCommit のコメントは最大 10240 文字。マークダウンの装飾分を差し引いた
# 上限を超える場合は plan 結果の末尾を切り詰める。
MAX_LEN=10000
if [ "${#PLAN_OUTPUT}" -gt "$MAX_LEN" ]; then
  PLAN_OUTPUT="$(printf '%s' "$PLAN_OUTPUT" | head -c "$MAX_LEN")
... (以降は文字数上限のため省略しました)"
  log_warn "plan 結果が長いため末尾を切り詰めました。"
fi

# ---- プルリクエストの作成 --------------------------------------------------
PR_TITLE="[$ENV] $SOURCE_BRANCH -> $DEST_BRANCH"
log_info "プルリクエストを作成します: $PR_TITLE"

PR_JSON="$(aws codecommit create-pull-request \
  --title "$PR_TITLE" \
  --targets "repositoryName=$REPO_NAME,sourceReference=$SOURCE_BRANCH,destinationReference=$DEST_BRANCH" \
  --output json)"

PR_ID="$(echo "$PR_JSON"        | grep -o '"pullRequestId": *"[^"]*"'   | head -1 | sed 's/.*: *"\(.*\)"/\1/')"
SOURCE_COMMIT="$(echo "$PR_JSON"| grep -o '"sourceCommit": *"[^"]*"'    | head -1 | sed 's/.*: *"\(.*\)"/\1/')"
DEST_COMMIT="$(echo "$PR_JSON"  | grep -o '"destinationCommit": *"[^"]*"'| head -1 | sed 's/.*: *"\(.*\)"/\1/')"

[ -n "$PR_ID" ] || die "プルリクエストの作成に失敗しました。"
log_info "プルリクエスト作成完了: PR ID = $PR_ID"

# ---- Terraform plan の結果をコメントとして投稿 -----------------------------
COMMENT="### Terraform plan 結果 ($ENV)
\`\`\`
$PLAN_OUTPUT
\`\`\`"

aws codecommit post-comment-for-pull-request \
  --pull-request-id "$PR_ID" \
  --repository-name "$REPO_NAME" \
  --before-commit-id "$DEST_COMMIT" \
  --after-commit-id "$SOURCE_COMMIT" \
  --content "$COMMENT" \
  --output text >/dev/null

log_info "Terraform plan の結果をコメントとして投稿しました。"
