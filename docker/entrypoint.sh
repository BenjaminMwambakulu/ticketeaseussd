#!/bin/bash

# Exit on error
set -e

echo "Starting Laravel application..."

# Clear and cache configurations
php artisan config:clear
php artisan cache:clear
php artisan route:clear
php artisan view:clear

# Optimize for production (optional, comment out in development)
php artisan config:cache
php artisan route:cache
php artisan view:cache

echo "Starting supervisor..."
exec /usr/bin/supervisord -n -c /etc/supervisor/conf.d/supervisord.conf
