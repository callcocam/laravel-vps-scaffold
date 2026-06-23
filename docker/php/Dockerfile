FROM php:8.4-fpm

RUN apt-get update && apt-get install -y \
    libpq-dev \
    zip \
    unzip \
    git \
    curl \
    libzip-dev \
    libpng-dev \
    libonig-dev \
    libxml2-dev \
    libjpeg62-turbo-dev \
    libwebp-dev \
    libfreetype6-dev

RUN docker-php-ext-configure gd --with-freetype --with-jpeg --with-webp \
    && docker-php-ext-install \
    pdo \
    pdo_pgsql \
    pgsql \
    pdo_mysql \
    mbstring \
    zip \
    exif \
    pcntl \
    gd

RUN pecl install redis && docker-php-ext-enable redis

RUN echo "memory_limit = 512M" > /usr/local/etc/php/conf.d/memory-limit.ini

WORKDIR /var/www