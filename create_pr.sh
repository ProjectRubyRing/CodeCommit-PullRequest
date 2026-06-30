#!/usr/bin/env bash
#
# CodeCommit のプルリクエストを作成し、Terraform plan の結果をコメントとして投稿する。
#
# 使い方:
#   ./create_pr.sh [オプション] <clone先フォルダ> <ブランチ名> <環境> [マージ先ブランチ]
#
#   <clone先フォルダ>  : リポジトリを clone済みのフォルダ
#   <ブランチ名>       : PR の作成元(source)ブランチ
#   <環境>             : 各スタックの env 配下の環境フォルダ (j1, j2, j3, st, pr)
#   [マージ先ブランチ] : PR のマージ先(destination)ブランチ (省略時: main)
#
# ディレクトリ構成 (ブランチ直下):
#   terraform/
#     stacks/
#       01-workload/env/<環境>/   <- terraform plan のルートディレクトリ
#       02-apprelease/env/<環境>/ <- terraform plan のルートディレクトリ
#       03-dbrelease/env/<環境>/  <- terraform plan のルートディレクトリ
#
#   上記 3 スタックそれぞれで terraform plan を実行し、結果をスタックごとに
#   PR のコメントとして投稿する。
#
# オプション:
#   -n, --dry-run      : terraform plan は実行するが、PR の作成・コメント投稿は
#                        行わない(副作用のある操作をスキップして内容を確認する)
#
#   --auto-assume-role        : CodeCommit 権限が無い場合に終了せず、別チーム提供の
#                               シェルを source して自動でスイッチロールする
#                               (既定: 警告して終了)
#   --assume-role-script <p>  : 自動スイッチロール時に source するシェルのパス
#                               (環境変数 ASSUME_ROLE_SCRIPT でも指定可)
#
# 事前条件:
#   - 事前に `aws login --remote` で認証しておくこと(未認証なら警告して終了する)。
#
# 例:
#   ./create_pr.sh ./my-repo feature/foo j1
#   ./create_pr.sh ./my-repo feature/foo pr develop
#   ./create_pr.sh --dry-run ./my-repo feature/foo j1
#   ./create_pr.sh --auto-assume-role --assume-role-script /opt/team/assume_role.sh ./my-repo feature/foo j1
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

# ---- オプション解析 --------------------------------------------------------
DRY_RUN=false
AUTO_ASSUME_ROLE=false
ASSUME_ROLE_SCRIPT_OPT=""
POSITIONAL=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    -n|--dry-run)           DRY_RUN=true; shift ;;
    --auto-assume-role)     AUTO_ASSUME_ROLE=true; shift ;;
    --assume-role-script)   ASSUME_ROLE_SCRIPT_OPT="${2:?--assume-role-script にはパスを指定してください}"; shift 2 ;;
    --assume-role-script=*) ASSUME_ROLE_SCRIPT_OPT="${1#*=}"; shift ;;
    --)           shift; while [ "$#" -gt 0 ]; do POSITIONAL+=("$1"); shift; done ;;
    -*)           die "不明なオプション: $1" ;;
    *)            POSITIONAL+=("$1"); shift ;;
  esac
done
set -- "${POSITIONAL[@]}"

# ---- 事前認証(aws login --remote)の確認 ------------------------------------
# 未認証なら警告して終了する。
require_aws_auth

# ---- 引数チェック ----------------------------------------------------------
if [ "$#" -lt 3 ]; then
  die "使い方: $0 [--dry-run] <clone先フォルダ> <ブランチ名> <環境(j1/j2/j3/st/pr)> [マージ先ブランチ]"
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

# clone先フォルダの絶対パスを基準にする(以降の cd の影響を受けないように)
REPO_DIR="$(pwd)"

# ---- リポジトリ名を git remote から取得 ------------------------------------
# CodeCommit の remote URL 末尾がリポジトリ名
REPO_NAME="$(basename "$(git config --get remote.origin.url)")"
log_info "リポジトリ: $REPO_NAME"

# ---- CodeCommit への操作権限の確認 -----------------------------------------
# 権限が無い場合、既定では警告して終了する。--auto-assume-role 指定時は
# 別チーム提供のシェルを source して自動でスイッチロールする。
require_codecommit_access "$REPO_NAME" "$AUTO_ASSUME_ROLE" "$ASSUME_ROLE_SCRIPT_OPT"

# ---- terraform plan を実行するスタック一覧 ---------------------------------
# ブランチ直下の terraform/stacks 配下にある各スタックの env/<環境> が
# terraform plan のルートディレクトリ。
STACKS=(
  "01-workload"
  "02-apprelease"
  "03-dbrelease"
)
STACKS_BASE="$REPO_DIR/terraform/stacks"

# ---- 各スタックで Terraform plan を実行 ------------------------------------
# CodeCommit のコメントは最大 10240 文字。マークダウンの装飾分を差し引いた
# 上限を超える場合は plan 結果の末尾を切り詰める。
MAX_LEN=10000

# スタック名と整形済み plan 結果を対応付けて保持する(同一 index)。
STACK_NAMES=()
STACK_OUTPUTS=()

for STACK in "${STACKS[@]}"; do
  PLAN_DIR="$STACKS_BASE/$STACK/env/$ENV"

  if [ ! -d "$PLAN_DIR" ]; then
    log_warn "[$STACK] plan 対象のディレクトリが存在しないためスキップします: $PLAN_DIR"
    continue
  fi

  log_info "Terraform plan を実行します: $PLAN_DIR"

  PLAN_OUTPUT="$(
    cd "$PLAN_DIR"
    terraform init -input=false -no-color >/dev/null
    terraform plan -input=false -no-color 2>&1
  )"

  if [ "${#PLAN_OUTPUT}" -gt "$MAX_LEN" ]; then
    PLAN_OUTPUT="$(printf '%s' "$PLAN_OUTPUT" | head -c "$MAX_LEN")
... (以降は文字数上限のため省略しました)"
    log_warn "[$STACK] plan 結果が長いため末尾を切り詰めました。"
  fi

  STACK_NAMES+=("$STACK")
  STACK_OUTPUTS+=("$PLAN_OUTPUT")
done

# ---- plan 対象が 1 つも無い場合はエラー ------------------------------------
# 全スタックでディレクトリが存在せずスキップされた場合は処理を中断する。
if [ "${#STACK_NAMES[@]}" -eq 0 ]; then
  die "plan 対象のディレクトリが 1 つも見つかりませんでした (環境: $ENV)"
fi

# ---- dry-run の場合はここで終了 --------------------------------------------
# terraform plan までは実行済み。PR 作成・コメント投稿(副作用)は行わない。
PR_TITLE="[$ENV] $SOURCE_BRANCH -> $DEST_BRANCH"
if [ "$DRY_RUN" = "true" ]; then
  log_warn "dry-run モードのため、PR の作成とコメント投稿はスキップします。"
  log_info "作成される予定の PR: $PR_TITLE (repo: $REPO_NAME)"
  for i in "${!STACK_NAMES[@]}"; do
    log_info "----- 投稿される予定の plan 結果 (${STACK_NAMES[$i]}) -----"
    printf '%s\n' "${STACK_OUTPUTS[$i]}" >&2
  done
  exit 0
fi

# ---- プルリクエストの作成 --------------------------------------------------
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

# ---- Terraform plan の結果をスタックごとにコメントとして投稿 ---------------
for i in "${!STACK_NAMES[@]}"; do
  STACK="${STACK_NAMES[$i]}"
  PLAN_OUTPUT="${STACK_OUTPUTS[$i]}"

  COMMENT="### Terraform plan 結果 ($ENV / $STACK)
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

  log_info "[$STACK] Terraform plan の結果をコメントとして投稿しました。"
done
