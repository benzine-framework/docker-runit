FROM ubuntu:latest AS marshall

MAINTAINER Matthew Baggett <hello@gone.io>

ENV DEBIAN_FRONTEND="teletype" \
    TERM=xterm-256color \
    COMPOSER_ALLOW_SUPERUSER=1 \
    COLOUR_FAIL='\e[31m' \
    COLOUR_SUCCESS='\e[32m' \
    COLOUR_NONE='\e[39m' \
    DEFAULT_TZ='Europe/London'

CMD ["runsvdir", "-P", "/etc/service"]

WORKDIR /app

COPY ./marshall/ /

RUN chmod +x /installers/install && \
    mv /marshall_* /etc && \
    /installers/install && \
    rm -rf /installers

FROM marshall AS php-core
ARG PHP_PACKAGES
COPY php-core/install-report.sh /usr/bin/install-report
RUN apt-get -qq update && \
    apt-get -yqq install --no-install-recommends \
        python3-software-properties \
        software-properties-common \
        && \
    add-apt-repository -y ppa:ondrej/php && \
    apt-get -qq update && \
    apt-get -yqq install --no-install-recommends $PHP_PACKAGES  &&\
    apt-get remove -yqq \
        software-properties-common \
        python-apt-common \
        python3-software-properties \
        python3.5 python3.5-minimal libpython3.5-minimal \
        && \
    apt-get autoremove -yqq && \
    rm -rf \
        /usr/bin/mysqlslap \
        /usr/bin/mysqldump \
        /usr/bin/mysqlpump \
        /usr/bin/mysql_embedded \
        && \
    curl -sS https://getcomposer.org/installer | php && \
    mv composer.phar /usr/local/bin/composer && \
    composer global require -q hirak/prestissimo && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/* && \
    chmod +x /usr/bin/install-report && \
    /usr/bin/install-report

FROM php-core AS php-cli
RUN apt-get -qq update && \
    apt-get -qy upgrade && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*

# Install a funky cool repl.
RUN composer global require -q psy/psysh:@stable && \
    ln -s /root/.composer/vendor/psy/psysh/bin/psysh /usr/local/bin/repl && \
    /usr/local/bin/repl -v

COPY php+cli/psysh-config.php /root/.config/psysh/config.php

FROM php-cli AS php-cli-onbuild
# On build, add anything in with Dockerfile into /app
ONBUILD ADD ./ /app

# If composer.json/composer.lock exist, do a composer install.
ONBUILD RUN composer install; exit 0
ONBUILD RUN composer dumpautoload -o; exit 0
ONBUILD RUN /usr/bin/install-report

FROM php-core AS php-nginx
ARG PHP_VERSION
ENV PHPFPM_MAX_CHILDREN=25
COPY php+nginx /conf

RUN apt-get -qq update && \
    apt-get -yqq install --no-install-recommends \
        lsb-core \
        gnupg \
        && \
    sh -c 'echo "deb http://ppa.launchpad.net/nginx/stable/ubuntu $(lsb_release -sc) main" \
            > /etc/apt/sources.list.d/nginx-stable.list' && \
    apt-key adv --keyserver keyserver.ubuntu.com --recv-keys C300EE8C && \
    apt-get -qq update && \
    apt-get -yqq install --no-install-recommends \
        nginx \
        php$PHP_VERSION-fpm \
        && \
    apt-get remove -yqq \
        lsb-core \
        cups-common \
        software-properties-common \
        python-apt-common \
        python3-software-properties \
        python3.5 python3.5-minimal libpython3.5-minimal \
        && \
    apt-get autoremove -yqq && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/* && \
    sed -i "s/cgi.fix_pathinfo.*/cgi.fix_pathinfo=0/g" /etc/php/$PHP_VERSION/fpm/php.ini && \
    sed -i "s/upload_max_filesize.*/upload_max_filesize = 1024M/g" /etc/php/$PHP_VERSION/fpm/php.ini && \
    sed -i "s/post_max_size.*/post_max_size = 1024M/g" /etc/php/$PHP_VERSION/fpm/php.ini  && \
    sed -i "s/max_execution_time.*/max_execution_time = 0/g" /etc/php/$PHP_VERSION/fpm/php.ini && \
    sed -i "s/variables_order.*/variables_order = \"EGPCS\"/g" /etc/php/$PHP_VERSION/fpm/php.ini  && \
    sed -i "s/error_reporting.*/error_reporting = E_ALL \& \~E_DEPRECATED \& \~E_STRICT \& \~E_CORE_WARNING/g" /etc/php/$PHP_VERSION/fpm/php.ini && \
    cp /etc/php/$PHP_VERSION/fpm/php.ini /etc/php/$PHP_VERSION/cli/php.ini  && \
    if test "$PHP_VERSION" = "5.6"  ; then \
        echo "Skipping clear_env"; \
    else \
        echo "clear_env=no" >> /etc/php/$PHP_VERSION/fpm/php-fpm.conf; \
        echo "clear_env=no" >> /etc/php/$PHP_VERSION/fpm/pool.d/www.ini; \
    fi && \
    mkdir /run/php && \
    rm -fr /var/www/html && \
    ln -s /app /var/www/html && \
    mv /conf/NginxDefault /etc/nginx/sites-enabled/default && \
    mkdir /etc/service/nginx && \
    mkdir /etc/service/php-fpm && \
    mv /conf/nginx.runit /etc/service/nginx/run && \
    mv /conf/php-fpm.runit /etc/service/php-fpm/run && \
    chmod +x /etc/service/*/run && \
    rm -R /conf && \
    sed -i "s/{{PHP}}/$PHP_VERSION/g" /etc/nginx/sites-enabled/default && \
    sed -i "s/{{PHP}}/$PHP_VERSION/g" /etc/service/php-fpm/run && \
    # Enable status panel
    sed -i -e "s|;pm.status_path|pm.status_path|g" /etc/php/*/fpm/pool.d/www.conf && \
    # Using environment variables in config files works, it would seem. Neat!
    sed -i -e "s|pm.max_children = 5|pm.max_children = \${PHPFPM_MAX_CHILDREN}|g" /etc/php/*/fpm/pool.d/www.conf

# Expose ports.
EXPOSE 80

# Create a healthcheck that makes sure our httpd is up
HEALTHCHECK --interval=30s --timeout=3s \
    CMD curl -f http://localhost/ || exit 1

FROM php-nginx AS php-nginx-onbuild
# On build, add anything in with Dockerfile into /app
ONBUILD ADD ./ /app

# If composer.json/composer.lock exist, do a composer install.
ONBUILD RUN composer install; exit 0
ONBUILD RUN composer dumpautoload -o; exit 0
ONBUILD RUN /usr/bin/install-report

FROM php-core AS php-apache
RUN apt-get -qq update && \
    apt-get -yqq install --no-install-recommends \
        apache2 \
        libapache2-mod-php$PHP_VERSION \
        && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/* && \
    \
    sed -i "s/upload_max_filesize.*/upload_max_filesize = 1024M/g" /etc/php/$PHP_VERSION/apache2/php.ini && \
    sed -i "s/post_max_size.*/post_max_size = 1024M/g" /etc/php/$PHP_VERSION/apache2/php.ini && \
    sed -i "s/max_execution_time.*/max_execution_time = 0/g" /etc/php/$PHP_VERSION/apache2/php.ini && \
    sed -i "s/variables_order.*/variables_order = \"EGPCS\"/g" /etc/php/$PHP_VERSION/apache2/php.ini && \
    sed -i "s/error_reporting.*/error_reporting = E_ALL \& \~E_DEPRECATED \& \~E_STRICT \& \~E_CORE_WARNING/g" /etc/php/$PHP_VERSION/apache2/php.ini && \
    cp /etc/php/$PHP_VERSION/apache2/php.ini /etc/php/$PHP_VERSION/cli/php.ini && \
    sed -i "s/ServerSignature On/ServerSignature Off/g" /etc/apache2/conf-enabled/security.conf && \
    sed -i "s/ServerTokens OS/ServerTokens Prod/g" /etc/apache2/conf-enabled/security.conf

# Expose ports.
EXPOSE 80

# Create a healthcheck that makes sure our httpd is up
HEALTHCHECK --interval=30s --timeout=3s \
    CMD curl -f http://localhost/ || exit 1

COPY php+apache /conf
RUN rm -fr /var/www/html && \
    ln -s /app /var/www/html && \
    mv /conf/ApacheConfig.conf /etc/apache2/sites-enabled/000-default.conf && \
    mv /conf/envvars /etc/apache2/ && \
    mv /conf/apache2.conf /etc/apache2/ && \
    mkdir -p /etc/service/apache && \
    mkdir -p /etc/service/show_logs && \
    mv /conf/apache.runit /etc/service/apache/run && \
    mv /conf/show_logs.runit /etc/service/show_logs/run && \
    chmod +x /etc/service/*/run && \
    rm /conf && \
    a2enmod rewrite

FROM php-apache AS php-apache-onbuild
# On build, add anything in with Dockerfile into /app
ONBUILD ADD ./ /app

# If composer.json/composer.lock exist, do a composer install.
ONBUILD RUN composer install --ignore-platform-reqs; exit 0
ONBUILD RUN composer dumpautoload -o; exit 0
ONBUILD RUN /usr/bin/install-report

FROM marshall AS nodejs

ARG NODE_VERSION
ARG YARN_VERSION
ARG PATH="/app/node_modules/.bin:${PATH}"

RUN mkdir ~/.gnupg && \
    echo "disable-ipv6" >> ~/.gnupg/dirmngr.conf && \
    apt-get -qq update && \
    apt-get -yqq install --no-install-recommends \
        lsb-core \
        gnupg \
    && \
    \
    ARCH= && \
    dpkgArch="$(dpkg --print-architecture)" && \
    case "${dpkgArch##*-}" in \
    amd64) ARCH='x64';; \
    ppc64el) ARCH='ppc64le';; \
    s390x) ARCH='s390x';; \
    arm64) ARCH='arm64';; \
    armhf) ARCH='armv7l';; \
    i386) ARCH='x86';; \
    *) echo "unsupported architecture"; exit 1 ;; \
  esac \
  # gpg keys listed at https://github.com/nodejs/node#release-keys
  && set -ex \
  && for key in \
    94AE36675C464D64BAFA68DD7434390BDBE9B9C5 \
    FD3A5288F042B6850C66B31F09FE44734EB7990E \
    71DCFD284A79C3B38668286BC97EC7A07EDE3FC1 \
    DD8F2338BAE7501E3DD5AC78C273792F7D83545D \
    C4F0DFFF4E8C1A8236409D08E73BC641CC11F4C8 \
    B9AE9905FFD7803F25714661B63B535A4C206CA9 \
    77984A986EBC2AA786BC0F66B01FBB92821C587A \
    8FCCA13FEF1D0C2E91008E09770F7A9A5AE15600 \
    4ED778F539E3634C779C87C6D7062848A1AB005C \
    A48C2BEE680E841632CD4E44F07496B3EB3C1762 \
    B9E2F5981AA6E0CD28160D9FF13993A75599653C \
  ; do \
    gpg --batch --keyserver hkp://p80.pool.sks-keyservers.net:80 --recv-keys "$key" || \
    gpg --batch --keyserver hkp://ipv4.pool.sks-keyservers.net --recv-keys "$key" || \
    gpg --batch --keyserver hkp://pgp.mit.edu:80 --recv-keys "$key" ; \
  done \
  && curl -fsSLO --compressed "https://nodejs.org/dist/v$NODE_VERSION/node-v$NODE_VERSION-linux-$ARCH.tar.xz" \
  && curl -fsSLO --compressed "https://nodejs.org/dist/v$NODE_VERSION/SHASUMS256.txt.asc" \
  && gpg --batch --decrypt --output SHASUMS256.txt SHASUMS256.txt.asc \
  && grep " node-v$NODE_VERSION-linux-$ARCH.tar.xz\$" SHASUMS256.txt | sha256sum -c - \
  && tar -xJf "node-v$NODE_VERSION-linux-$ARCH.tar.xz" -C /usr/local --strip-components=1 --no-same-owner \
  && rm "node-v$NODE_VERSION-linux-$ARCH.tar.xz" SHASUMS256.txt.asc SHASUMS256.txt \
  && ln -s /usr/local/bin/node /usr/local/bin/nodejs \
  && set -ex \
  && for key in \
    6A010C5166006599AA17F08146C2130DFD2497F5 \
  ; do \
    gpg --batch --keyserver hkp://p80.pool.sks-keyservers.net:80 --recv-keys "$key" || \
    gpg --batch --keyserver hkp://ipv4.pool.sks-keyservers.net --recv-keys "$key" || \
    gpg --batch --keyserver hkp://pgp.mit.edu:80 --recv-keys "$key" ; \
  done \
  && curl -fsSLO --compressed "https://yarnpkg.com/downloads/$YARN_VERSION/yarn-v$YARN_VERSION.tar.gz" \
  && curl -fsSLO --compressed "https://yarnpkg.com/downloads/$YARN_VERSION/yarn-v$YARN_VERSION.tar.gz.asc" \
  && gpg --batch --verify yarn-v$YARN_VERSION.tar.gz.asc yarn-v$YARN_VERSION.tar.gz \
  && mkdir -p /opt \
  && tar -xzf yarn-v$YARN_VERSION.tar.gz -C /opt/ \
  && ln -s /opt/yarn-v$YARN_VERSION/bin/yarn /usr/local/bin/yarn \
  && ln -s /opt/yarn-v$YARN_VERSION/bin/yarnpkg /usr/local/bin/yarnpkg \
  && rm yarn-v$YARN_VERSION.tar.gz.asc yarn-v$YARN_VERSION.tar.gz \
  \
  && apt-get autoremove -y \
  && apt-get clean \
  && rm -rf \
          /var/lib/apt/lists/* \
          /tmp/* \
          /var/tmp/*

FROM nodejs AS nodejs-compiler

RUN apt-get -qq update && \
    apt-get -yqq install --no-install-recommends \
        python \
        build-essential \
        && \
    apt-get autoremove -y && \
    apt-get clean && \
    rm -rf \
        /var/lib/apt/lists/* \
        /tmp/* \
        /var/tmp/*

FROM nodejs AS nodejs-onbuild

ONBUILD ADD ./ /app

FROM nodejs-compiler AS nodejs-compiler-onbuild

ONBUILD ADD ./ /app
