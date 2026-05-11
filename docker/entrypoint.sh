#!/usr/bin/env bash
# Ruta sugerida: /docker/entrypoint.sh
#
# Objetivo:
# Envolver el entrypoint oficial de WordPress para Railway.
#
# Responsabilidad única:
# Preparar Apache, lanzar bootstrap WP-CLI en segundo plano y delegar
# el arranque real al entrypoint oficial de WordPress.

set -Eeuo pipefail

# Corrige warnings de Apache cuando no existe ServerName.
if ! grep -q "ServerName localhost" /etc/apache2/apache2.conf; then
  echo "ServerName localhost" >> /etc/apache2/apache2.conf
fi

# Railway puede presentar conflictos Apache MPM en imágenes derivadas.
# Forzamos prefork, que es el MPM más compatible con mod_php.
a2dismod mpm_event >/dev/null 2>&1 || true
a2dismod mpm_worker >/dev/null 2>&1 || true
a2enmod mpm_prefork >/dev/null 2>&1 || true

# Si el contenedor va a iniciar Apache, ejecutamos bootstrap en segundo plano.
# Se hace en segundo plano porque el entrypoint oficial termina haciendo exec
# del proceso principal y no regresa el control.
if [[ "${1:-}" == "apache2-foreground" ]]; then
  /usr/local/bin/gg-wp-bootstrap.sh &
fi

# Delega al entrypoint oficial de la imagen WordPress.
exec docker-entrypoint.sh "$@"