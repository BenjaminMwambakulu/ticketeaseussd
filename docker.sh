#!/bin/bash

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${GREEN}TicketEase USSD Docker Helper${NC}"
echo "================================"
echo ""

case "$1" in
    start)
        echo -e "${YELLOW}Starting all services...${NC}"
        docker-compose up -d --build
        echo -e "${GREEN}Services started!${NC}"
        echo "Access your application at: http://localhost"
        ;;
    
    stop)
        echo -e "${YELLOW}Stopping all services...${NC}"
        docker-compose down
        echo -e "${GREEN}Services stopped!${NC}"
        ;;
    
    restart)
        echo -e "${YELLOW}Restarting all services...${NC}"
        docker-compose down
        docker-compose up -d --build
        echo -e "${GREEN}Services restarted!${NC}"
        ;;
    
    logs)
        if [ -z "$2" ]; then
            echo -e "${YELLOW}Showing logs for all services...${NC}"
            docker-compose logs -f
        else
            echo -e "${YELLOW}Showing logs for $2...${NC}"
            docker-compose logs -f "$2"
        fi
        ;;
    
    status)
        echo -e "${YELLOW}Service status:${NC}"
        docker-compose ps
        ;;
    
    shell)
        SERVICE=${2:-app}
        echo -e "${YELLOW}Opening shell in $SERVICE container...${NC}"
        docker-compose exec "$SERVICE" bash
        ;;
    
    seed)
        echo -e "${YELLOW}Seeding database...${NC}"
        docker-compose exec app php artisan db:seed
        ;;
    
    queue-restart)
        echo -e "${YELLOW}Restarting queue worker...${NC}"
        docker-compose restart queue
        echo -e "${GREEN}Queue worker restarted!${NC}"
        ;;
    
    cache-clear)
        echo -e "${YELLOW}Clearing all caches...${NC}"
        docker-compose exec app php artisan cache:clear
        docker-compose exec app php artisan config:clear
        docker-compose exec app php artisan route:clear
        docker-compose exec app php artisan view:clear
        echo -e "${GREEN}Caches cleared!${NC}"
        ;;
    
    optimize)
        echo -e "${YELLOW}Optimizing for production...${NC}"
        docker-compose exec app php artisan config:cache
        docker-compose exec app php artisan route:cache
        docker-compose exec app php artisan view:cache
        echo -e "${GREEN}Application optimized!${NC}"
        ;;
    
    *)
        echo "Usage: ./docker.sh {start|stop|restart|logs|status|shell|seed|queue-restart|cache-clear|optimize}"
        echo ""
        echo "Commands:"
        echo "  start          - Build and start all services"
        echo "  stop           - Stop all services"
        echo "  restart        - Restart all services"
        echo "  logs [service] - View logs (optionally for specific service)"
        echo "  status         - Show service status"
        echo "  shell [service]- Open bash shell in container (default: app)"
        echo "  seed           - Seed the database"
        echo "  queue-restart  - Restart queue worker"
        echo "  cache-clear    - Clear all caches"
        echo "  optimize       - Optimize for production"
        exit 1
        ;;
esac
