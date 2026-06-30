#!/usr/bin/env bash
#
# common.sh
# =========
# 複数のシェルスクリプトから source して使う「共通部品」です。
# 主にロギング・前提コマンド確認・対話確認などの汎用ヘルパを提供します。
#
# 使い方（呼び出し側スクリプト）:
#   SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
#   # shellcheck source=common.sh
#   source "${SCRIPT_DIR}/common.sh"
#
# このファイルが提供する公開インターフェース（呼び出し側が依存してよい関数）:
#   log_info   <msg...>          : 情報ログ（stderr, 緑）
#   log_warn   <msg...>          : 警告ログ（stderr, 黄）
#   log_error  <msg...>          : エラーログ（stderr, 赤）
#   log_debug  <msg...>          : デバッグログ（DEBUG=true のときだけ stderr に出力）
#   die        <msg...>          : エラーを出して exit 1
#   require_cmd <name> [hint]    : コマンドが PATH に無ければ die
#   confirm    <prompt>          : y/N の対話確認（yes なら 0、no なら 1 を返す）
#   require_aws_auth             : 事前に AWS 認証(aws login --remote)済みか確認。
#                                  未認証なら警告して exit 1
#   require_codecommit_access <repo> [auto_assume(true/false)] [assume_role_script]
#                                : CodeCommit への操作権限を確認。権限が無い場合は
#                                  スイッチロールを促して exit 1（auto_assume=true の
#                                  ときは別チーム提供シェルを source して自動スイッチロール）
#   assume_role_with_team_script [assume_role_script]
#                                : 別チーム提供のスイッチロール用シェルを source し、
#                                  設定された認証情報を呼び出し元シェルへ引き継ぐ
#
# 環境変数:
#   DEBUG=true            : log_debug を有効化
#   NO_COLOR=1            : 色付けを無効化（出力先が非 TTY の場合も自動で無効）
#   COMMON_LOG_PREFIX     : ログ行の先頭に付けるプレフィックス（既定: 呼び出し元スクリプト名）
#   ASSUME_ROLE_SCRIPT    : スイッチロール用シェル(別チーム提供)の既定パス
#                           （--assume-role-script 等の引数指定が無い場合に使用）
#
# 注意:
#   - すべてのログは stderr に出力します（stdout はスクリプト本来の出力専用にするため）。
#   - 認証情報など秘匿値は絶対にログに出さないでください（このファイルでは出しません）。
#

# 二重 source による再定義を避けるためのガード
if [[ -n "${__COMMON_SH_LOADED:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi
__COMMON_SH_LOADED=1
COMMON_SH_VERSION="1.0.0"

# ---------------------------------------------------------------------------
# 色設定
#   - 出力先(stderr)が端末でない、または NO_COLOR が設定されている場合は無効化
# ---------------------------------------------------------------------------
if [[ -t 2 && -z "${NO_COLOR:-}" ]]; then
  __C_RESET="$(printf '\033[0m')"
  __C_RED="$(printf '\033[31m')"
  __C_GREEN="$(printf '\033[32m')"
  __C_YELLOW="$(printf '\033[33m')"
  __C_GRAY="$(printf '\033[90m')"
else
  __C_RESET=""; __C_RED=""; __C_GREEN=""; __C_YELLOW=""; __C_GRAY=""
fi

# ログ行の先頭プレフィックス（既定は呼び出し元スクリプト名）
__log_prefix() {
  local p="${COMMON_LOG_PREFIX:-$(basename "${0}")}"
  printf '[%s]' "${p}"
}

# ---------------------------------------------------------------------------
# ロギング関数（すべて stderr）
# ---------------------------------------------------------------------------
log_info() {
  printf '%s %sINFO%s  %s\n' "$(__log_prefix)" "${__C_GREEN}" "${__C_RESET}" "$*" >&2
}

log_warn() {
  printf '%s %sWARN%s  %s\n' "$(__log_prefix)" "${__C_YELLOW}" "${__C_RESET}" "$*" >&2
}

log_error() {
  printf '%s %sERROR%s %s\n' "$(__log_prefix)" "${__C_RED}" "${__C_RESET}" "$*" >&2
}

log_debug() {
  if [[ "${DEBUG:-false}" == "true" ]]; then
    printf '%s %sDEBUG%s %s\n' "$(__log_prefix)" "${__C_GRAY}" "${__C_RESET}" "$*" >&2
  fi
}

# エラーを出して終了
die() {
  log_error "$*"
  exit 1
}

# ---------------------------------------------------------------------------
# 前提コマンドの存在確認
#   require_cmd git "git をインストールしてください"
# ---------------------------------------------------------------------------
require_cmd() {
  local cmd="${1:?require_cmd: コマンド名が必要です}"
  local hint="${2:-}"
  if ! command -v "${cmd}" >/dev/null 2>&1; then
    if [[ -n "${hint}" ]]; then
      die "必要なコマンドが見つかりません: ${cmd} （${hint}）"
    else
      die "必要なコマンドが見つかりません: ${cmd}"
    fi
  fi
}

# ---------------------------------------------------------------------------
# 対話確認（y/N）
#   confirm "本当に実行しますか?" && do_something
#   - 非 TTY の場合は false を返す（呼び出し側で --yes 等を別途用意すること）
# ---------------------------------------------------------------------------
confirm() {
  local prompt="${1:-続行しますか?}"
  if [[ ! -t 0 ]]; then
    return 1
  fi
  local ans=""
  printf '%s %s [y/N]: ' "$(__log_prefix)" "${prompt}" >&2
  read -r ans || true
  case "${ans}" in
    y|Y|yes|YES) return 0 ;;
    *)           return 1 ;;
  esac
}

# ---------------------------------------------------------------------------
# AWS 認証・CodeCommit 権限まわりのヘルパ
#
# 想定する運用フロー:
#   1) 事前に `aws login --remote` で認証しておく（このシェルでは認証操作は行わない）。
#   2) 必要に応じて、別チーム提供のシェルを source してスイッチロールする。
#
# 注意:
#   - 認証情報(アクセスキー・トークン等)は絶対にログへ出力しない。
#   - スイッチロール用シェルは source で呼び出すため、関数 → 呼び出し元スクリプト
#     (common.sh を source しているスクリプト本体)の順で環境変数が引き継がれる。
# ---------------------------------------------------------------------------

# AWS のエラーメッセージから「未認証 / トークン期限切れ」を判定する正規表現。
__AWS_AUTH_ERR_RE='ExpiredToken|InvalidClientTokenId|Unable to locate credentials|Unable to locate a credential|security token|SSO session|token (has )?expired|UnrecognizedClientException|InvalidIdentityToken|NoCredentialProviders'

# AWS のエラーメッセージから「権限不足(AccessDenied 系)」を判定する正規表現。
__AWS_ACCESS_DENIED_RE='AccessDenied|AccessDeniedException|not authorized to perform|UnauthorizedOperation|is not authorized'

# ---------------------------------------------------------------------------
# 事前に AWS 認証(aws login --remote)済みかを確認する。
#   - 認証済み: 何もせず 0 を返す
#   - 未認証 / トークン期限切れ: 警告メッセージを出して exit 1
# 判定には `aws sts get-caller-identity`（読み取りのみ・副作用なし）を使用する。
# ---------------------------------------------------------------------------
require_aws_auth() {
  require_cmd aws "AWS CLI をインストールしてください"

  log_debug "AWS 認証状態を確認します (aws sts get-caller-identity)"

  local out
  if out="$(aws sts get-caller-identity --output text 2>&1)"; then
    log_info "AWS 認証OK（事前認証済み）"
    return 0
  fi

  # ここに来た時点で未認証 or トークン期限切れ。
  log_error "AWS が未認証状態です。事前に認証(aws login --remote)を行ってください。"
  log_debug "get-caller-identity のエラー内容: ${out}"
  log_error "次のコマンドで認証してから、スクリプトを再実行してください:"
  log_error "    aws login --remote"
  exit 1
}

# ---------------------------------------------------------------------------
# 別チーム提供のスイッチロール用シェルを source して実行する。
#   assume_role_with_team_script [assume_role_script_path]
#     - 第1引数でパスを指定。省略時は環境変数 ASSUME_ROLE_SCRIPT を使用。
# source で呼び出すことで、シェル内で export された AWS 認証情報(環境変数)を
# 呼び出し元スクリプトのプロセスへ引き継ぐ。
# ---------------------------------------------------------------------------
assume_role_with_team_script() {
  local script_path="${1:-${ASSUME_ROLE_SCRIPT:-}}"

  if [[ -z "${script_path}" ]]; then
    die "スイッチロール用シェルのパスが指定されていません。--assume-role-script <path> もしくは環境変数 ASSUME_ROLE_SCRIPT を設定してください。"
  fi
  if [[ ! -f "${script_path}" ]]; then
    die "スイッチロール用シェルが見つかりません: ${script_path}"
  fi

  log_info "スイッチロール用シェルを source します: ${script_path}"

  # 別チーム提供のシェル。source して認証情報(環境変数)を現在のシェルへ反映させる。
  # source 先で予期せぬ失敗があってもメッセージを出して中断できるよう戻り値を確認する。
  # shellcheck source=/dev/null
  if ! source "${script_path}"; then
    die "スイッチロール用シェルの実行に失敗しました: ${script_path}"
  fi
}

# ---------------------------------------------------------------------------
# CodeCommit への操作権限の有無を判定する内部ヘルパ。
#   _codecommit_access_ok <repository_name>
#     - 権限あり          : 0 を返す
#     - 権限なし/認証切れ  : 1 を返す
# `aws codecommit get-repository`（読み取りのみ）で判定する。
# 補足: RepositoryDoesNotExistException など「権限以外」の理由で失敗した場合は、
#       API 呼び出し自体は認可されている＝権限あり とみなす。
# ---------------------------------------------------------------------------
_codecommit_access_ok() {
  local repo="${1:?_codecommit_access_ok: リポジトリ名が必要です}"
  local out

  if out="$(aws codecommit get-repository --repository-name "${repo}" 2>&1)"; then
    return 0
  fi

  if printf '%s' "${out}" | grep -qiE "${__AWS_ACCESS_DENIED_RE}"; then
    log_debug "CodeCommit get-repository が AccessDenied: ${out}"
    return 1
  fi
  if printf '%s' "${out}" | grep -qiE "${__AWS_AUTH_ERR_RE}"; then
    log_debug "CodeCommit get-repository が認証エラー: ${out}"
    return 1
  fi

  # 権限以外の理由(リポジトリ不存在など)で失敗 → 権限はあるとみなす。
  log_debug "CodeCommit get-repository は権限以外の理由で失敗(権限ありとみなす): ${out}"
  return 0
}

# ---------------------------------------------------------------------------
# CodeCommit への操作権限を確認する。
#   require_codecommit_access <repository_name> [auto_assume(true/false)] [assume_role_script]
#
#   - 権限がある場合: 何もせず 0 を返す
#   - 権限が無い場合:
#       * auto_assume != true（既定）: スイッチロールを促して exit 1
#       * auto_assume == true        : 別チーム提供シェルを source して自動スイッチロールし、
#                                       再確認する（再確認も失敗なら exit 1）
# ---------------------------------------------------------------------------
require_codecommit_access() {
  local repo="${1:?require_codecommit_access: リポジトリ名が必要です}"
  local auto_assume="${2:-false}"
  local script_path="${3:-${ASSUME_ROLE_SCRIPT:-}}"

  require_cmd aws "AWS CLI をインストールしてください"

  if _codecommit_access_ok "${repo}"; then
    log_info "CodeCommit への操作権限を確認しました (repo: ${repo})"
    return 0
  fi

  log_warn "現在の IAM ユーザ/ロールでは CodeCommit への操作が許可されていません (repo: ${repo})。"

  if [[ "${auto_assume}" == "true" ]]; then
    log_warn "自動スイッチロールが有効です。スイッチロールを実行します。"
    assume_role_with_team_script "${script_path}"

    # スイッチロール後に再確認する。
    if _codecommit_access_ok "${repo}"; then
      log_info "スイッチロール後、CodeCommit への操作権限を確認しました (repo: ${repo})"
      return 0
    fi
    die "スイッチロールを実行しましたが、CodeCommit への操作権限を確認できませんでした (repo: ${repo})。ロールの権限設定を確認してください。"
  fi

  # 既定: 警告して終了する。
  log_error "CodeCommit を操作するには、適切なロールへスイッチロールする必要があります。"
  log_error "別チーム提供のスイッチロール用シェルを source してから、スクリプトを再実行してください:"
  log_error "    source <スイッチロール用シェルのパス>"
  log_error "または、自動スイッチロールを有効にして再実行してください: --auto-assume-role [--assume-role-script <path>]"
  exit 1
}
