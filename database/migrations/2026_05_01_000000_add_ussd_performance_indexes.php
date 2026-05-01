<?php

use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\Schema;
use Illuminate\Support\Facades\DB;

return new class extends Migration
{
    /**
     * Run the migrations.
     * Adds optimized indexes to boost USSD query performance.
     */
    public function up(): void
    {
        // Index for route code lookups
        DB::statement('CREATE INDEX IF NOT EXISTS idx_routes_route_code ON public.routes(route_code) WHERE route_code IS NOT NULL');

        // Index for trip queries - use departure_datetime directly (PostgreSQL is smart about date comparisons)
        DB::statement('CREATE INDEX IF NOT EXISTS idx_trips_route_status_departure ON public.trips(route_id, status, departure_datetime)');

        // Index for tenant lookups
        DB::statement('CREATE INDEX IF NOT EXISTS idx_tenants_active ON public.tenants(is_active) WHERE is_active = true');

        // Index for seat assignments lookup (used in availability checks)
        DB::statement('CREATE INDEX IF NOT EXISTS idx_seat_assignments_trip ON public.seat_assignments(trip_id)');

        // Index for route-tenant relationships
        DB::statement('CREATE INDEX IF NOT EXISTS idx_routes_tenant ON public.routes(tenant_id)');

        // Index for profile phone lookups (used in registration/booking)
        DB::statement('CREATE INDEX IF NOT EXISTS idx_profiles_phone ON public.profiles(phone)');
    }

    /**
     * Reverse the migrations.
     */
    public function down(): void
    {
        DB::statement('DROP INDEX IF EXISTS idx_routes_route_code');
        DB::statement('DROP INDEX IF EXISTS idx_trips_route_date_status');
        DB::statement('DROP INDEX IF EXISTS idx_tenants_active');
        DB::statement('DROP INDEX IF EXISTS idx_seat_assignments_trip');
        DB::statement('DROP INDEX IF EXISTS idx_routes_tenant');
        DB::statement('DROP INDEX IF EXISTS idx_profiles_phone');
    }
};
