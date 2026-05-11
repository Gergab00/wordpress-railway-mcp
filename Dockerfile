# Ruta sugerida: /Dockerfile
#
# Objetivo:
# Construir una imagen WordPress personalizada para Railway con:
# - Apache + PHP 8.3
# - WP-CLI
# - herramientas mínimas para bootstrap
# - configuración PHP para uploads
# - scripts de inicialización reproducibles
#
# Responsabilidad única:
# Este archivo solo define la imagen base y sus dependencias de sistema.
# No instala plugins activos en la base de datos porque eso debe hacerse
# en runtime, cuando WordPress ya tenga acceso a MariaDB.

FROM wordpress:php8.3-apache

# Evita prompts interactivos durante la instalación de paquetes.
ENV DEBIAN_FRONTEND=noninteractive

# Define el path estándar del sitio WordPress dentro de la imagen oficial.
ENV WORDPRESS_PATH=/var/www/html

# Instala herramientas necesarias para:
# - curl: descargar WP-CLI y assets remotos.
# - git: clonar plugins/themes desde GitHub.
# - unzip: instalar plugins/themes ZIP.
# - mariadb-client: validar conexión contra MariaDB.
# - less/default-mysql-client pueden ayudar en debugging, pero aquí evitamos exceso.
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        curl \
        git \
        unzip \
        mariadb-client \
        ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Instala WP-CLI globalmente.
# WP-CLI es necesario para instalar/activar plugins, themes y ejecutar comandos
# administrativos en WordPress desde el contenedor.
RUN curl -fsSL https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar -o /usr/local/bin/wp \
    && chmod +x /usr/local/bin/wp \
    && wp --info --allow-root

# Copia configuración PHP para permitir uploads razonables en WordPress/WooCommerce.
COPY config/php/uploads.ini /usr/local/etc/php/conf.d/uploads.ini
COPY config/wp-bootstrap.env /usr/local/etc/gg-wp-bootstrap.env

# Copia scripts propios.
COPY docker/entrypoint.sh /usr/local/bin/gg-entrypoint.sh
COPY docker/wp-bootstrap.sh /usr/local/bin/gg-wp-bootstrap.sh

# Da permisos de ejecución a los scripts.
RUN chmod +x /usr/local/bin/gg-entrypoint.sh /usr/local/bin/gg-wp-bootstrap.sh

# Usa un entrypoint wrapper que conserva el comportamiento original de WordPress,
# pero agrega bootstrap automatizado vía WP-CLI.
ENTRYPOINT ["gg-entrypoint.sh"]

# Comando estándar de la imagen oficial WordPress Apache.
CMD ["apache2-foreground"]
