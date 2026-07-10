#!/usr/bin/env bash
#
# create_pr_helper.sh
# ===================
# プロジェクト直下の create_pr*.sh を「ラッピング」して、毎回コンソールで
# 指定するパラメータ数を極力減らすためのヘルパーです。
#
#   - よく使う値（clone先フォルダ・環境・マージ先・スイッチロール用シェル等）を
#     このファイル上部の「既定値」セクションに固定しておけば、実行時はブランチ名
#     だけ渡せば済むようになります（既定値は環境変数でも上書き可）。
#   - 「どうしても外から指定が必要なパラメータ」は引数チェックを行い、
#     不足時は usage を表示して終了します。
#   - 元スクリプトは "source せず子プロセスで実行" します。これにより
#     common.sh 内の source によるスイッチロール制御が元スクリプト側プロセスで
#     完結し、ヘルパーを別ディレクトリに置いても正常に動作します。
#
# 配置:
#   <project>/
#     common.sh
#     create_pr.sh, create_pr2.sh ... create_pr5.sh
#     helpers/
#       create_pr_helper.sh   <- このファイル（別ディレクトリでOK）
#
# 使い方:
#   ./helpers/create_pr_helper.sh [ヘルパーオプション] <ブランチ名>
#
#   最小構成（既定値を埋めておけば）:
#     ./helpers/create_pr_helper.sh feature/foo
#
#   都度上書きしたい場合:
#     ./helpers/create_pr_helper.sh -e pr -d develop -r ./other-repo feature/foo
#     ./helpers/create_pr_helper.sh --target create_pr5.sh feature/foo   # 環境なしスクリプト
#     ./helpers/create_pr_helper.sh --dry-run feature/foo
#
set -euo pipefail

# ===========================================================================
# ▼▼▼ 既定値セクション（ここを自由に編集して指定パラメータを減らす）▼▼▼
#   すべて「環境変数が設定されていればそれを優先、無ければ既定値」の形。
#   よく使う値を右辺に固定しておくと、実行時の入力が減ります。
# ===========================================================================

# 呼び出す元スクリプト名（create_pr.sh / create_pr2.sh / ... / create_pr5.sh）
: "${TARGET_SCRIPT_NAME:=create_pr.sh}"

# 元スクリプト群が置かれているディレクトリ。
#   既定はこのヘルパーの一つ上（= プロジェクトルート）。
#   別配置なら環境変数 PR_SCRIPTS_DIR で上書き可。
HELPER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
: "${PR_SCRIPTS_DIR:=$(cd "${HELPER_DIR}/.." && pwd)}"

# clone先フォルダ（毎回同じならここに固定。空なら実行時に必須指定）
: "${DEF_REPO_DIR:=}"

# 環境（j1/j2/j3/st/pr）。環境を取らないスクリプト(create_pr5.sh)では未使用
: "${DEF_ENV:=j1}"

# マージ先(destination)ブランチ
: "${DEF_DEST_BRANCH:=main}"

# 別チーム提供のスイッチロール用シェルのパス（空なら --assume-role-script は付けない）
: "${DEF_ASSUME_ROLE_SCRIPT:=}"

# 既定で自動スイッチロール(--auto-assume-role)を有効にするか（true/false）
: "${DEF_AUTO_ASSUME_ROLE:=true}"

# 既定で dry-run にするか（true/false）
: "${DEF_DRY_RUN:=false}"

# 対象スクリプトが「環境(env)引数」を取るか（create_pr5.sh は取らない）。
#   空文字なら TARGET_SCRIPT_NAME から自動判定する。
: "${TARGET_HAS_ENV:=}"

# ===========================================================================
# ▲▲▲ 既定値セクションここまで ▲▲▲
# ===========================================================================

TARGET_SCRIPT="${PR_SCRIPTS_DIR%/}/${TARGET_SCRIPT_NAME}"

# ---- ログ用に common.sh を利用（あれば）。無くても動くようフォールバック ----
if [[ -f "${PR_SCRIPTS_DIR%/}/common.sh" ]]; then
  # shellcheck source=../common.sh
  source "${PR_SCRIPTS_DIR%/}/common.sh"
else
  log_info()  { printf '[helper] INFO  %s\n' "$*" >&2; }
  log_warn()  { printf '[helper] WARN  %s\n' "$*" >&2; }
  log_error() { printf '[helper] ERROR %s\n' "$*" >&2; }
  die()       { log_error "$*"; exit 1; }
fi

# 環境(env)引数の要否を自動判定する。
#   TARGET_HAS_ENV を明示指定していれば尊重し、未指定なら TARGET_SCRIPT_NAME から判定。
#   （--target はオプション解析で後から変わり得るため、判定は関数化して随時呼ぶ）
TARGET_HAS_ENV_EXPLICIT=false
[[ -n "${TARGET_HAS_ENV}" ]] && TARGET_HAS_ENV_EXPLICIT=true
detect_has_env() {
  if [[ "${TARGET_HAS_ENV_EXPLICIT}" == "true" ]]; then
    return 0
  fi
  case "${TARGET_SCRIPT_NAME}" in
    create_pr5.sh) TARGET_HAS_ENV=false ;;
    *)             TARGET_HAS_ENV=true  ;;
  esac
}
detect_has_env

# ---- usage -----------------------------------------------------------------
usage() {
  cat >&2 <<USAGE
使い方:
  $(basename "$0") [ヘルパーオプション] <ブランチ名>

必須:
  <ブランチ名>                PR の作成元(source)ブランチ
$(if [[ "${DEF_REPO_DIR}" == "" ]]; then echo "  -r, --repo <dir>            clone先フォルダ（既定値未設定のため必須）"; fi)

ヘルパーオプション（未指定なら既定値を使用）:
  -r, --repo <dir>            clone先フォルダ           (既定: ${DEF_REPO_DIR:-<未設定>})
$(if [[ "${TARGET_HAS_ENV}" == "true" ]]; then echo "  -e, --env <env>             環境 j1/j2/j3/st/pr        (既定: ${DEF_ENV})"; fi)
  -d, --dest <branch>         マージ先ブランチ          (既定: ${DEF_DEST_BRANCH})
  -t, --target <script>       呼び出す元スクリプト名    (既定: ${TARGET_SCRIPT_NAME})
      --assume-role-script <p> スイッチロール用シェル   (既定: ${DEF_ASSUME_ROLE_SCRIPT:-<未設定>})
      --auto-assume-role      自動スイッチロールを有効化 (既定: ${DEF_AUTO_ASSUME_ROLE})
      --no-auto-assume-role   自動スイッチロールを無効化
  -n, --dry-run               dry-run で実行            (既定: ${DEF_DRY_RUN})
      --no-dry-run            dry-run を無効化
  -h, --help                  この使い方を表示

例:
  $(basename "$0") feature/foo
  $(basename "$0") -e pr -d develop feature/foo
  $(basename "$0") --target create_pr5.sh feature/foo
  $(basename "$0") --dry-run feature/foo

対象元スクリプト: ${TARGET_SCRIPT}
USAGE
}

# ---- ヘルパーオプション解析 ------------------------------------------------
REPO_DIR="${DEF_REPO_DIR}"
ENV_VAL="${DEF_ENV}"
DEST_BRANCH="${DEF_DEST_BRANCH}"
ASSUME_ROLE_SCRIPT_VAL="${DEF_ASSUME_ROLE_SCRIPT}"
AUTO_ASSUME_ROLE="${DEF_AUTO_ASSUME_ROLE}"
DRY_RUN="${DEF_DRY_RUN}"
SOURCE_BRANCH=""

POSITIONAL=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    -r|--repo)              REPO_DIR="${2:?--repo にはパスを指定してください}"; shift 2 ;;
    --repo=*)               REPO_DIR="${1#*=}"; shift ;;
    -e|--env)               ENV_VAL="${2:?--env には環境を指定してください}"; shift 2 ;;
    --env=*)                ENV_VAL="${1#*=}"; shift ;;
    -d|--dest)              DEST_BRANCH="${2:?--dest にはブランチ名を指定してください}"; shift 2 ;;
    --dest=*)               DEST_BRANCH="${1#*=}"; shift ;;
    -t|--target)            TARGET_SCRIPT_NAME="${2:?--target にはスクリプト名を指定してください}"; TARGET_SCRIPT="${PR_SCRIPTS_DIR%/}/${TARGET_SCRIPT_NAME}"; shift 2 ;;
    --target=*)             TARGET_SCRIPT_NAME="${1#*=}"; TARGET_SCRIPT="${PR_SCRIPTS_DIR%/}/${TARGET_SCRIPT_NAME}"; shift ;;
    --assume-role-script)   ASSUME_ROLE_SCRIPT_VAL="${2:?--assume-role-script にはパスを指定してください}"; shift 2 ;;
    --assume-role-script=*) ASSUME_ROLE_SCRIPT_VAL="${1#*=}"; shift ;;
    --auto-assume-role)     AUTO_ASSUME_ROLE=true; shift ;;
    --no-auto-assume-role)  AUTO_ASSUME_ROLE=false; shift ;;
    -n|--dry-run)           DRY_RUN=true; shift ;;
    --no-dry-run)           DRY_RUN=false; shift ;;
    -h|--help)              detect_has_env; usage; exit 0 ;;
    --)                     shift; while [ "$#" -gt 0 ]; do POSITIONAL+=("$1"); shift; done ;;
    -*)                     usage; die "不明なオプション: $1" ;;
    *)                      POSITIONAL+=("$1"); shift ;;
  esac
done

# --target で対象が変わり得るため、環境引数の要否を最終確定する
detect_has_env

# 位置引数からブランチ名を取得（最初の1つだけ）
if [ "${#POSITIONAL[@]}" -ge 1 ]; then
  SOURCE_BRANCH="${POSITIONAL[0]}"
fi
if [ "${#POSITIONAL[@]}" -ge 2 ]; then
  usage
  die "位置引数が多すぎます。ブランチ名は1つだけ指定してください（それ以外はオプションで指定）: ${POSITIONAL[*]}"
fi

# ---- 必須パラメータのチェック ----------------------------------------------
if [ -z "${SOURCE_BRANCH}" ]; then
  usage
  die "ブランチ名(<ブランチ名>)が指定されていません。"
fi
if [ -z "${REPO_DIR}" ]; then
  usage
  die "clone先フォルダが指定されていません。-r/--repo で指定するか、DEF_REPO_DIR を設定してください。"
fi
if [ "${TARGET_HAS_ENV}" = "true" ] && [ -z "${ENV_VAL}" ]; then
  usage
  die "環境(env)が指定されていません。-e/--env で指定するか、DEF_ENV を設定してください。"
fi
if [ ! -f "${TARGET_SCRIPT}" ]; then
  die "呼び出す元スクリプトが見つかりません: ${TARGET_SCRIPT}（PR_SCRIPTS_DIR / --target を確認してください）"
fi

# ---- 元スクリプトへ渡す引数を組み立て --------------------------------------
# オプション類（元スクリプトの解釈に合わせる）
ARGS=()
[ "${DRY_RUN}" = "true" ]          && ARGS+=("--dry-run")
[ "${AUTO_ASSUME_ROLE}" = "true" ] && ARGS+=("--auto-assume-role")
[ -n "${ASSUME_ROLE_SCRIPT_VAL}" ] && ARGS+=("--assume-role-script" "${ASSUME_ROLE_SCRIPT_VAL}")

# 以降の位置引数を "--" で明示的に区切る（ブランチ名等が "-" 始まりでも安全に）
ARGS+=("--" "${REPO_DIR}" "${SOURCE_BRANCH}")
[ "${TARGET_HAS_ENV}" = "true" ] && ARGS+=("${ENV_VAL}")
ARGS+=("${DEST_BRANCH}")

log_info "元スクリプトを実行します: ${TARGET_SCRIPT_NAME}"
log_info "  repo=${REPO_DIR} branch=${SOURCE_BRANCH}$( [ "${TARGET_HAS_ENV}" = "true" ] && printf ' env=%s' "${ENV_VAL}" ) dest=${DEST_BRANCH}"
log_info "  dry_run=${DRY_RUN} auto_assume_role=${AUTO_ASSUME_ROLE} assume_role_script=${ASSUME_ROLE_SCRIPT_VAL:-<未設定>}"

# ---- 実行 ------------------------------------------------------------------
# 重要: source ではなく "子プロセスで実行" する。
#   - 元スクリプトは自身の ${BASH_SOURCE[0]} から SCRIPT_DIR を求めて
#     common.sh を source するため、ヘルパーの場所や CWD に依存しない。
#   - common.sh のスイッチロール(assume_role_with_team_script)は
#     元スクリプトのプロセス内で source されるので、以降の aws 実行にも
#     認証情報が正しく引き継がれる。
# exec でプロセスを置き換え、終了コードもそのまま呼び出し元へ返す。
exec bash "${TARGET_SCRIPT}" "${ARGS[@]}"
