# =========================================================
# STAGE 1: Preparer (Downloads, Extracts & Cleans Moodle 5.3)
# =========================================================
FROM alpine:3.20 AS preparer

RUN apk add --no-cache curl tar findutils

WORKDIR /moodle

# Download official Moodle 5.3 LTS (stable503) archive and strip dev/test bloat
RUN curl -fSL "https://download.moodle.org/download.php/direct/stable503/moodle-latest-503.tgz" -o moodle.tgz \
  && tar -xzf moodle.tgz --strip-components=1 \
  && rm moodle.tgz \
  && find . -type d \( -name "tests" -o -name "behat" -o -name "fixtures" \) -prune -exec rm -rf {} + \
  && find . -type f \( -name "*.md" -o -name "upgrade.txt" -o -name "thirdpartylibs.xml" -o -name ".gitignore" \) -delete

# =========================================================
# STAGE 2: Maximally Compressed FastCGI (PHP-FPM 8.3) Runtime
# =========================================================
FROM php:8.3-fpm-alpine

# Install ONLY lightweight C runtime shared libraries
RUN apk add --no-cache \
  freetype \
  icu-libs \
  libjpeg-turbo \
  libpng \
  libsodium \
  libxml2 \
  libzip \
  postgresql-libs \
  zlib

# Compile extensions, strip debug symbols from .so binaries, and purge compilers
RUN apk add --no-cache --virtual .build-deps \
  $PHPIZE_DEPS \
  binutils \
  freetype-dev \
  icu-dev \
  libjpeg-turbo-dev \
  libpng-dev \
  libsodium-dev \
  libxml2-dev \
  libzip-dev \
  postgresql-dev \
  zlib-dev \
  linux-headers \
  && docker-php-ext-configure gd --with-freetype --with-jpeg \
  && docker-php-ext-install -j$(nproc) \
  exif \
  gd \
  intl \
  mysqli \
  opcache \
  pdo_pgsql \
  soap \
  sodium \
  zip \
  && strip --strip-unneeded /usr/local/lib/php/extensions/*/*.so \
  && apk del --no-network .build-deps \
  # Remove unused PHP debugger and CGI binaries to save ~30MB unpacked
  && rm -f /usr/local/bin/phpdbg /usr/local/bin/php-cgi \
  && rm -rf /tmp/* /usr/src/*

# Apply identical Moodle 5.3 PHP production configuration
RUN { \
  echo 'opcache.enable=1'; \
  echo 'opcache.enable_cli=1'; \
  echo 'opcache.memory_consumption=128'; \
  echo 'opcache.interned_strings_buffer=8'; \
  echo 'opcache.max_accelerated_files=10000'; \
  echo 'opcache.revalidate_freq=60'; \
  echo 'max_input_vars=5000'; \
  echo 'upload_max_filesize=100M'; \
  echo 'post_max_size=100M'; \
  echo 'memory_limit=256M'; \
  } > /usr/local/etc/php/conf.d/moodle-production.ini

# Tune PHP-FPM worker pool for fair benchmarking
RUN { \
  echo '[www]'; \
  echo 'pm = dynamic'; \
  echo 'pm.max_children = 20'; \
  echo 'pm.start_servers = 4'; \
  echo 'pm.min_spare_servers = 2'; \
  echo 'pm.max_spare_servers = 6'; \
  } > /usr/local/etc/php-fpm.d/zz-moodle-pool.conf

WORKDIR /var/www/html

# Copy clean Moodle 5.3 files from Stage 1
COPY --from=preparer --chown=www-data:www-data /moodle /var/www/html

# Create moodledata directory and strip apk package manager
RUN mkdir -p /var/www/moodledata \
  && chown -R www-data:www-data /var/www/moodledata \
  && rm -rf /sbin/apk /etc/apk /lib/apk /usr/share/apk /var/lib/apk /var/cache/apk/*

USER www-data

EXPOSE 9000
CMD ["php-fpm"]
