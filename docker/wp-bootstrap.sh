#!/usr/bin/env bash
# Ruta sugerida: /docker/wp-bootstrap.sh
#
# Objetivo:
# Automatizar la configuración inicial de WordPress en Railway usando WP-CLI.
#
# Responsabilidad única:
# Instalar/activar componentes WordPress en runtime, cuando el volumen y la base
# de datos ya están disponibles.
#
# Nota:
# Este script está diseñado para ser idempotente. Puede ejecutarse varias veces
# sin reinstalar innecesariamente lo que ya existe.

set -Eeuo pipefail

WP_PATH="${WORDPRESS_PATH:-/var/www/html}"
WP_CLI="wp --path=${WP_PATH} --allow-root"

log() {
  echo "[gg-wp-bootstrap] $*"
}

is_true() {
  [[ "${1:-}" == "true" || "${1:-}" == "1" || "${1:-}" == "yes" ]]
}

wait_for_wordpress_files() {
  log "Esperando archivos base de WordPress en ${WP_PATH}..."

  for i in {1..120}; do
    if [[ -f "${WP_PATH}/wp-load.php" ]]; then
      log "Archivos WordPress detectados."
      return 0
    fi

    sleep 2
  done

  log "ERROR: WordPress no apareció en ${WP_PATH}."
  return 1
}

wait_for_database() {
  log "Esperando conexión a MariaDB..."

  local db_host="${WORDPRESS_DB_HOST%%:*}"
  local db_port="${WORDPRESS_DB_HOST##*:}"

  if [[ "${db_host}" == "${db_port}" ]]; then
    db_port="3306"
  fi

  for i in {1..120}; do
    if mysqladmin ping \
      --host="${db_host}" \
      --port="${db_port}" \
      --user="${WORDPRESS_DB_USER}" \
      --password="${WORDPRESS_DB_PASSWORD}" \
      --silent >/dev/null 2>&1; then
      log "MariaDB disponible."
      return 0
    fi

    sleep 2
  done

  log "ERROR: MariaDB no respondió a tiempo."
  return 1
}

install_wordpress_if_needed() {
  if ${WP_CLI} core is-installed >/dev/null 2>&1; then
    log "WordPress ya está instalado."
    return 0
  fi

  if ! is_true "${WP_AUTO_INSTALL:-false}"; then
    log "WordPress no está instalado. WP_AUTO_INSTALL=false; se deja el instalador web."
    return 0
  fi

  if [[ -z "${WP_SITE_URL:-}" || -z "${WP_SITE_TITLE:-}" || -z "${WP_ADMIN_USER:-}" || -z "${WP_ADMIN_PASSWORD:-}" || -z "${WP_ADMIN_EMAIL:-}" ]]; then
    log "ERROR: WP_AUTO_INSTALL=true requiere WP_SITE_URL, WP_SITE_TITLE, WP_ADMIN_USER, WP_ADMIN_PASSWORD y WP_ADMIN_EMAIL."
    return 1
  fi

  log "Instalando WordPress automáticamente..."

  ${WP_CLI} core install \
    --url="${WP_SITE_URL}" \
    --title="${WP_SITE_TITLE}" \
    --admin_user="${WP_ADMIN_USER}" \
    --admin_password="${WP_ADMIN_PASSWORD}" \
    --admin_email="${WP_ADMIN_EMAIL}" \
    --skip-email

  log "WordPress instalado."
}

install_plugin_from_wporg() {
  local slug="$1"

  if ${WP_CLI} plugin is-installed "${slug}" >/dev/null 2>&1; then
    log "Plugin ${slug} ya instalado. Actualizando..."
    ${WP_CLI} plugin update "${slug}" || true
  else
    log "Instalando plugin ${slug}..."
    ${WP_CLI} plugin install "${slug}"
  fi

  log "Activando plugin ${slug}..."
  ${WP_CLI} plugin activate "${slug}" || true
}

install_theme_from_wporg() {
  local slug="$1"
  local activate="${2:-false}"

  if ${WP_CLI} theme is-installed "${slug}" >/dev/null 2>&1; then
    log "Theme ${slug} ya instalado. Actualizando..."
    ${WP_CLI} theme update "${slug}" || true
  else
    log "Instalando theme ${slug}..."
    ${WP_CLI} theme install "${slug}"
  fi

  if is_true "${activate}"; then
    log "Activando theme ${slug}..."
    ${WP_CLI} theme activate "${slug}" || true
  fi
}

install_mcp_adapter() {
  local version="${MCP_ADAPTER_VERSION:-v0.5.0}"
  local url="${MCP_ADAPTER_ZIP_URL:-https://github.com/WordPress/mcp-adapter/releases/download/${version}/mcp-adapter.zip}"

  if ${WP_CLI} plugin is-installed "mcp-adapter" >/dev/null 2>&1; then
    log "MCP Adapter ya instalado."
    return 0
  fi

  log "Instalando MCP Adapter desde ${url}..."

  # El MCP Adapter oficial todavía se instala desde GitHub Releases.
  # Si cambia el nombre del asset, define MCP_ADAPTER_ZIP_URL manualmente.
  ${WP_CLI} plugin install "${url}" --activate

  log "MCP Adapter instalado y activo."
}

install_git_repos() {
  local type="$1"
  local repos_csv="$2"
  local target_base=""

  if [[ -z "${repos_csv}" ]]; then
    return 0
  fi

  case "${type}" in
    plugin)
      target_base="${WP_PATH}/wp-content/plugins"
      ;;
    theme)
      target_base="${WP_PATH}/wp-content/themes"
      ;;
    *)
      log "ERROR: tipo inválido para repos GitHub: ${type}"
      return 1
      ;;
  esac

  IFS=',' read -ra repos <<< "${repos_csv}"

  for repo_spec in "${repos[@]}"; do
    repo_spec="$(echo "${repo_spec}" | xargs)"

    if [[ -z "${repo_spec}" ]]; then
      continue
    fi

    local repo_url="${repo_spec}"
    local branch=""
    local repo_name=""
    local tmp_dir=""

    # Permite formato:
    # https://github.com/org/repo.git#main
    if [[ "${repo_spec}" == *"#"* ]]; then
      repo_url="${repo_spec%%#*}"
      branch="${repo_spec##*#}"
    fi

    repo_name="$(basename "${repo_url}" .git)"
    tmp_dir="/tmp/gg-${type}-${repo_name}"

    log "Instalando ${type} custom desde ${repo_url} ${branch:+branch ${branch}}..."

    rm -rf "${tmp_dir}"

    if [[ -n "${branch}" ]]; then
      git clone --depth 1 --branch "${branch}" "${repo_url}" "${tmp_dir}"
    else
      git clone --depth 1 "${repo_url}" "${tmp_dir}"
    fi

    if [[ -d "${target_base}/${repo_name}" && "${WP_FORCE_UPDATE_CUSTOM_CODE:-false}" != "true" ]]; then
      log "${type} ${repo_name} ya existe. No se reemplaza porque WP_FORCE_UPDATE_CUSTOM_CODE=false."
    else
      rm -rf "${target_base:?}/${repo_name}"
      mkdir -p "${target_base}"
      cp -R "${tmp_dir}" "${target_base}/${repo_name}"
      chown -R www-data:www-data "${target_base}/${repo_name}"
      log "${type} ${repo_name} copiado a ${target_base}/${repo_name}."
    fi

    if [[ "${type}" == "plugin" && "${WP_ACTIVATE_CUSTOM_PLUGINS:-true}" == "true" ]]; then
      ${WP_CLI} plugin activate "${repo_name}" || true
    fi

    if [[ "${type}" == "theme" && "${WP_ACTIVATE_CUSTOM_THEME:-}" == "${repo_name}" ]]; then
      ${WP_CLI} theme activate "${repo_name}" || true
    fi

    rm -rf "${tmp_dir}"
  done
}

configure_permalink_structure() {
  if [[ -n "${WP_PERMALINK_STRUCTURE:-}" ]]; then
    log "Configurando permalink structure: ${WP_PERMALINK_STRUCTURE}"
    ${WP_CLI} rewrite structure "${WP_PERMALINK_STRUCTURE}" --hard || true
    ${WP_CLI} rewrite flush --hard || true
  fi
}

main() {
  wait_for_wordpress_files
  wait_for_database

  # Espera breve para que el entrypoint oficial termine de generar wp-config.php.
  sleep 5

  install_wordpress_if_needed

  if ! ${WP_CLI} core is-installed >/dev/null 2>&1; then
    log "WordPress todavía no está instalado. Se omite instalación de plugins/themes."
    return 0
  fi

  install_plugin_from_wporg "woocommerce"
  install_theme_from_wporg "storefront" "${WP_ACTIVATE_STOREFRONT:-true}"

  install_mcp_adapter

  # Este plugin está en WordPress.org y requiere WordPress 6.9+, MCP Adapter y PHP 8.0+.
  install_plugin_from_wporg "enable-abilities-for-mcp"

  install_git_repos "plugin" "${WP_CUSTOM_PLUGIN_REPOS:-}"
  install_git_repos "theme" "${WP_CUSTOM_THEME_REPOS:-}"

  configure_permalink_structure

  log "Bootstrap finalizado."
}

main "$@"