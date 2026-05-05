#!/bin/bash

# Production Queue Monitoring Setup Script
# Run this after deploying queue monitoring changes

echo "Setting up queue monitoring in production..."

# Clear all caches
echo "1. Clearing caches..."
php artisan config:clear
php artisan cache:clear
php artisan route:clear
php artisan view:clear
php artisan event:clear

# Optimize for production
echo "2. Optimizing for production..."
php artisan config:cache
php artisan route:cache
php artisan view:cache
php artisan event:cache

# Restart queue workers (if using supervisor)
echo "3. Restarting queue workers..."
sudo supervisorctl restart queue-worker:*

# Or if using docker-compose
# docker-compose restart queue

echo "4. Verifying setup..."
php artisan queue:health-check

echo "Queue monitoring setup complete!"
echo "Check logs: tail -f storage/logs/laravel.log | grep -i 'queue'"
