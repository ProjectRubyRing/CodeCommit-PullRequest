#!/usr/bin/env bash
#
# CodeCommit のプルリクエストを作成する。
#
# 使い方:
#   ./create_pr.sh [オプション] <clone先フォルダ> <ブランチ名> [マージ先ブランチ]
#
#   <clone先フォルダ>  : リポジトリを clone済みのフォルダ
#   <ブランチ名>       : PR の作成元(source)ブランチ
#   [マージ先ブランチ] : PR のマージ先(destination)ブランチ (省略時: main)
#
# オプション:
#   -n, --dry-run      : PR の作成は行わず、作成される予定の PR の内容のみ表示する
#
# 例:
#   ./create_pr.sh ./my-repo feature/foo
#   ./create_pr.sh ./my-repo feature/foo develop
#   ./create_pr.sh --dry-run ./my-repo feature/foo
#
set -euo pipefail

# ---- 共通部品(common.sh)の読み込み -----------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

# ---- 前提コマンドの確認 ----------------------------------------------------
require_cmd git "git をインストールしてください"
require_cmd aws "AWS CLI をインストールしてください"

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
if [ "$#" -lt 2 ]; then
  die "使い方: $0 [--dry-run] <clone先フォルダ> <ブランチ名> [マージ先ブランチ]"
fi

REPO_DIR="$1"
SOURCE_BRANCH="$2"
DEST_BRANCH="${3:-main}"

cd "$REPO_DIR"

# clone先フォルダの絶対パスを基準にする
REPO_DIR="$(pwd)"

# ---- リポジトリ名を git remote から取得 ------------------------------------
# CodeCommit の remote URL 末尾がリポジトリ名
REPO_NAME="$(basename "$(git config --get remote.origin.url)")"
log_info "リポジトリ: $REPO_NAME"

# ---- dry-run の場合はここで終了 --------------------------------------------
PR_TITLE="$SOURCE_BRANCH -> $DEST_BRANCH"
if [ "$DRY_RUN" = "true" ]; then
  log_warn "dry-run モードのため、PR の作成はスキップします。"
  log_info "作成される予定の PR: $PR_TITLE (repo: $REPO_NAME)"
  exit 0
fi

# ---- プルリクエストの作成 --------------------------------------------------
log_info "プルリクエストを作成します: $PR_TITLE"

PR_JSON="$(aws codecommit create-pull-request \
  --title "$PR_TITLE" \
  --targets "repositoryName=$REPO_NAME,sourceReference=$SOURCE_BRANCH,destinationReference=$DEST_BRANCH" \
  --output json)"

# grep ... | head -1 は pipefail 下で SIGPIPE になり得るため grep -m1 を使用。
PR_ID="$(echo "$PR_JSON" | grep -o -m1 '"pullRequestId": *"[^"]*"' | sed 's/.*: *"\(.*\)"/\1/')"

[ -n "$PR_ID" ] || die "プルリクエストの作成に失敗しました。"
log_info "プルリクエスト作成完了: PR ID = $PR_ID"