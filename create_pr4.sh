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
#       01-workload/env/<環境>/   <- *.tfplan の出力先(plan のルート)
#       02-apprelease/env/<環境>/ <- *.tfplan の出力先(plan のルート)
#       03-dbrelease/env/<環境>/  <- *.tfplan の出力先(plan のルート)
#
#   上記 3 スタックそれぞれの env/<環境> 配下に、事前に出力済みの *.tfplan ファイル
#   を読み込み、terraform show で人間可読なテキストへ変換した結果を、スタックごとに
#   PR のコメントとして投稿する。
#
#   ※ tfplan が terraform show で解析できないフォーマット/サポートエラー
#     (unsupported state file format / could not be parsed as json 等)の場合は、
#     .tfplan をそのままテキストファイルとして読み込む(フォーマットエラーである旨は
#     警告メッセージとして出力する)。テキスト形式の plan を .tfplan 拡張子で保存
#     しているケースを想定。
#
#   ※ tfplan ファイルが見つからないスタックはスキップする。
#
# オプション:
#   -n, --dry-run      : tfplan の読み込みは行うが、PR の作成・コメント投稿は行わない
#                        (副作用のある操作をスキップして内容を確認する)
#
# 例:
#   ./create_pr.sh ./my-repo feature/foo j1
#   ./create_pr.sh ./my-repo feature/foo pr develop
#   ./create_pr.sh --dry-run ./my-repo feature/foo j1
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
POSITIONAL=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    -n|--dry-run) DRY_RUN=true; shift ;;
    --)           shift; while [ "$#" -gt 0 ]; do POSITIONAL+=("$1"); shift; done ;;
    -*)           die "不明なオプション: $1" ;;
    *)            POSITIONAL+=("$1"); shift ;;
  esac
done
set -- "${POSITIONAL[@]}"

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

# ---- 対象スタック一覧 ------------------------------------------------------
# ブランチ直下の terraform/stacks 配下にある各スタックの env/<環境> に、
# 事前に出力済みの *.tfplan が存在することを前提とする。
STACKS=(
  "01-workload"
  "02-apprelease"
  "03-dbrelease"
)
STACKS_BASE="$REPO_DIR/terraform/stacks"

# ---- 各スタックの tfplan を読み込み ----------------------------------------
# CodeCommit のコメントは最大 10240 文字。マークダウンの装飾分を差し引いた
# 上限を超える場合は plan 結果の末尾を切り詰める。
MAX_LEN=10000

# terraform show のフォーマット/サポートエラーを判定するための正規表現。
# これらに合致した場合は .tfplan をテキストファイルとして読み込む。
FORMAT_ERR_RE='unsupported state file format|could not be parsed|failed to read the given file|state or plan file'

# スタック名と整形済み plan 結果を対応付けて保持する(同一 index)。
STACK_NAMES=()
STACK_OUTPUTS=()

for STACK in "${STACKS[@]}"; do
  PLAN_DIR="$STACKS_BASE/$STACK/env/$ENV"

  if [ ! -d "$PLAN_DIR" ]; then
    log_warn "[$STACK] env ディレクトリが存在しないためスキップします: $PLAN_DIR"
    continue
  fi

  # 環境フォルダ直下の *.tfplan を探す(事前に出力済みの想定)。
  shopt -s nullglob
  PLAN_FILES=( "$PLAN_DIR"/*.tfplan )
  shopt -u nullglob

  if [ "${#PLAN_FILES[@]}" -eq 0 ]; then
    log_warn "[$STACK] tfplan ファイルが見つかりません。事前に tfplan を出力してください: $PLAN_DIR"
    continue
  fi

  PLAN_FILE="${PLAN_FILES[0]}"
  if [ "${#PLAN_FILES[@]}" -gt 1 ]; then
    log_warn "[$STACK] tfplan ファイルが複数見つかりました。最初のファイルを使用します: $PLAN_FILE"
  fi

  PLAN_BASENAME="$(basename "$PLAN_FILE")"
  log_info "[$STACK] tfplan を読み込みます: $PLAN_FILE"

  # まず terraform show でバイナリ plan を人間可読テキストへ変換する。
  # set -e 下ではコマンド置換の代入失敗で即終了するため、if 条件で失敗を捕捉する。
  # エラーメッセージ判定のため 2>&1 で stderr も SHOW_OUTPUT に取り込む。
  if SHOW_OUTPUT="$(
        cd "$PLAN_DIR"
        terraform show -no-color "$PLAN_BASENAME" 2>&1
      )"; then
    # 正常に解析できた場合はその出力を使用する。
    PLAN_OUTPUT="$SHOW_OUTPUT"

  elif grep -qiE "$FORMAT_ERR_RE" <<<"$SHOW_OUTPUT"; then
    # terraform show がフォーマット/サポートエラーで失敗した場合。
    # .tfplan がバイナリ plan ではなくテキスト形式の plan 出力である可能性があるため、
    # ファイルをそのままテキストとして読み込む。フォーマットエラーである旨を警告出力する。
    log_warn "[$STACK] tfplan のフォーマットエラーを検出しました(terraform show で解析不可)。テキストファイルとして読み込みます: $PLAN_FILE"
    log_warn "[$STACK] terraform show のエラー内容: $SHOW_OUTPUT"
    PLAN_OUTPUT="$(cat "$PLAN_FILE")"

  else
    # フォーマットエラー以外の失敗(例: provider スキーマ未取得 等)。
    # テキストとして読み込むとバイナリが混入する恐れがあるためスキップする。
    log_warn "[$STACK] terraform show に失敗したためスキップします: $SHOW_OUTPUT"
    continue
  fi

  # 上限を超える場合は末尾を切り詰める(show 出力 / テキスト読み込みの双方に適用)。
  if [ "${#PLAN_OUTPUT}" -gt "$MAX_LEN" ]; then
    PLAN_OUTPUT="${PLAN_OUTPUT:0:$MAX_LEN}
... (以降は文字数上限のため省略しました)"
    log_warn "[$STACK] plan 結果が長いため末尾を切り詰めました。"
  fi

  STACK_NAMES+=("$STACK")
  STACK_OUTPUTS+=("$PLAN_OUTPUT")
done

# ---- 読み込み対象が 1 つも無い場合はエラー ---------------------------------
# 全スタックで env ディレクトリ未存在 / tfplan 未検出 / show 失敗 によりスキップ
# された場合は中断する。
if [ "${#STACK_NAMES[@]}" -eq 0 ]; then
  die "読み込み可能な tfplan が 1 つも見つかりませんでした (環境: $ENV)"
fi

# ---- dry-run の場合はここで終了 --------------------------------------------
# tfplan の読み込みまでは実行済み。PR 作成・コメント投稿(副作用)は行わない。
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

# grep ... | head -1 は pipefail 下で SIGPIPE になり得るため grep -m1 を使用。
PR_ID="$(echo "$PR_JSON"        | grep -o -m1 '"pullRequestId": *"[^"]*"'    | sed 's/.*: *"\(.*\)"/\1/')"
SOURCE_COMMIT="$(echo "$PR_JSON"| grep -o -m1 '"sourceCommit": *"[^"]*"'     | sed 's/.*: *"\(.*\)"/\1/')"
DEST_COMMIT="$(echo "$PR_JSON"  | grep -o -m1 '"destinationCommit": *"[^"]*"'| sed 's/.*: *"\(.*\)"/\1/')"

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