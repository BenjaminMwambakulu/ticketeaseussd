<?php

namespace App\Services;

use App\Jobs\FinalizeUssdRegistration;
use App\Jobs\ProcessUssdBooking;
use Illuminate\Http\Request;
use Illuminate\Support\Carbon;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Facades\Hash;
use Illuminate\Support\Facades\Log;
use Illuminate\Support\Str;

/**
 * Coordinates USSD menu flow, session state transitions, and DB-backed actions.
 */
class UssdService
{
    private SendSmsService $smsService;

    /**
     * Default cache TTL for USSD session keys in seconds.
     */
    private const DEFAULT_SESSION_TTL_SECONDS = 1200;

    public function __construct(SendSmsService $smsService)
    {
        $this->smsService = $smsService;
    }

    /**
     * Handle an incoming USSD request and return a USSD-compliant response string.
     *
     * @param  Request  $request  Incoming HTTP request from the USSD gateway.
     * @return string Response that starts with CON (continue) or END (terminate).
     */
    public function handle(Request $request): string
    {
        $startTime = microtime(true);
        $sessionId = $request->input('sessionId');
        $phoneNumber = $request->input('phoneNumber');
        $text = $request->input('text');

        $userInput = $text ? explode('*', $text) : [];
        $state = cache()->get("ussd_{$sessionId}_state", 'start');

        if ($state === 'start' || empty($text)) {
            $response = "CON Welcome to TicketEase!\n\n";
            $response .= "1. Book Ticket\n";
            $response .= "2. My Bookings\n";
            $response .= "3. Register Account\n";
            $response .= '4. Exit';

            cache()->put("ussd_{$sessionId}_state", 'menu', $this->sessionTtlSeconds());
            cache()->put("ussd_{$sessionId}_phone", $phoneNumber, $this->sessionTtlSeconds());

            $this->logPerformance($sessionId, 'start_menu', $startTime, ['status' => 'success']);
            return $response;
        }

        if ($state === 'menu') {
            $choice = $this->currentInputValue($userInput);

            if ($choice == '1') {
                $profileCacheKey = "ussd_profile_{$phoneNumber}";
                $profileData = cache()->remember($profileCacheKey, 300, function() use ($phoneNumber) {
                    $result = DB::selectOne(
                        'SELECT id, payment_pin_hash FROM public.profiles WHERE phone = ? LIMIT 1',
                        [$phoneNumber]
                    );
                    return $result !== null ? (array) $result : null;
                });
                $profile = $profileData !== null ? (object) $profileData : null;

                if ($profile === null || empty($profile->payment_pin_hash)) {
                    return "END You must register an account and set a payment PIN before booking.\n\nDial again and select option 3 to register.";
                }

                $response = $this->startBooking($sessionId, $phoneNumber);
                $this->logPerformance($sessionId, 'menu_booking', $startTime, ['status' => 'success']);
                return $response;
            }

            if ($choice == '2') {
                cache()->put("ussd_{$sessionId}_state", 'my_bookings', $this->sessionTtlSeconds());
                cache()->put("ussd_{$sessionId}_my_bookings_page", 1, $this->sessionTtlSeconds());

                $response = $this->showMyBookingsPage($sessionId, $phoneNumber, 1);
                $this->logPerformance($sessionId, 'menu_my_bookings', $startTime, ['status' => 'success']);
                return $response;
            }

            if ($choice == '3') {
                cache()->put("ussd_{$sessionId}_state", 'registration', $this->sessionTtlSeconds());
                cache()->put("ussd_{$sessionId}_reg_step", 1, $this->sessionTtlSeconds());
                $response = $this->handleRegistration($sessionId, $phoneNumber, $userInput);
                $this->logPerformance($sessionId, 'menu_registration', $startTime, ['status' => 'success']);
                return $response;
            }

            if ($choice == '4') {
                cache()->forget("ussd_{$sessionId}_state");

                $this->logPerformance($sessionId, 'menu_exit', $startTime, ['status' => 'success']);
                return 'END Thank you for using TicketEase. Safe travels!';
            }

            $response = "CON Invalid option. Please try again.\n\n1. Book Ticket\n2. My Bookings\n3. Register Account\n4. Exit";
            $this->logPerformance($sessionId, 'menu_invalid', $startTime, ['status' => 'error', 'reason' => 'invalid_choice']);
            return $response;
        }

        if ($state === 'registration') {
            $response = $this->handleRegistration($sessionId, $phoneNumber, $userInput);
            $this->logPerformance($sessionId, 'menu_registration', $startTime, ['status' => 'success']);
            return $response;
        }

        $response = $this->continueFlow($sessionId, $phoneNumber, $userInput, $state);
        $this->logPerformance($sessionId, "flow_{$state}", $startTime, ['status' => 'success']);
        return $response;
    }
    private function logPerformance(string $sessionId, string $step, float $startTime, array $context = []): void
    {
        $duration = round((microtime(true) - $startTime) * 1000, 2);
        $contextString = !empty($context) ? ' ' . json_encode($context) : '';
        Log::info("USSD Performance [{$sessionId}] [{$step}]: {$duration}ms{$contextString}");
    }

    /**
     * Run the multi-step registration flow (name -> profile create/get).
     *
     * @param  string  $sessionId  USSD session identifier.
     * @param  string|null  $phone  Caller MSISDN supplied by the gateway.
     * @param  array<int, string>  $userInput  Parsed USSD input tokens.
     * @return string USSD response for the current registration step.
     */
    private function handleRegistration($sessionId, $phone, $userInput): string
    {
        $step = cache()->get("ussd_{$sessionId}_reg_step", 1);

        if ($step == 1) {
            cache()->put("ussd_{$sessionId}_reg_step", 2, $this->sessionTtlSeconds());

            return 'CON Enter your Full Name:';
        }

        if ($step == 2) {
            $fullName = $this->currentInputValue($userInput);
            cache()->put("ussd_{$sessionId}_full_name", $fullName, $this->sessionTtlSeconds());
            cache()->put("ussd_{$sessionId}_reg_step", 3, $this->sessionTtlSeconds());

            return 'CON Set a 4-digit payment PIN:';
        }

        if ($step == 3) {
            $pin = $this->currentInputValue($userInput);

            if (! preg_match('/^\d{4}$/', $pin)) {
                return 'CON Invalid PIN. Enter a 4-digit payment PIN:';
            }

            $fullName = cache()->get("ussd_{$sessionId}_full_name");

            try {
                // Queue the expensive PIN hashing and profile update to run asynchronously
                FinalizeUssdRegistration::dispatch(
                    $sessionId,
                    $phone,
                    $fullName,
                    $pin
                );

                Log::info('USSD Registration Queued for Finalization', [
                    'session_id' => $sessionId,
                    'phone' => $phone,
                    'full_name' => $fullName,
                    'status' => 'queued'
                ]);

                cache()->forget("ussd_{$sessionId}_state");
                cache()->forget("ussd_{$sessionId}_reg_step");
                cache()->forget("ussd_{$sessionId}_full_name");

                return "END Registration successful!\nYour account is now active.\nDial again to book tickets.";
            } catch (\Exception $e) {
                Log::error('USSD Registration Error: '.$e->getMessage());

                return 'END Sorry, registration failed. Please try again later.';
            }
        }

        return 'END Error in registration.';
    }

    /**
     * Initialize booking flow and present unique route options.
     *
     * @param  string  $sessionId  USSD session identifier.
     * @param  string|null  $phone  Caller MSISDN supplied by the gateway.
     * @return string USSD route selection menu.
     */
    private function startBooking($sessionId, $phone): string
    {
        cache()->put("ussd_{$sessionId}_state", 'booking_route', $this->sessionTtlSeconds());
        cache()->put("ussd_{$sessionId}_phone", $phone, $this->sessionTtlSeconds());

        try {
            $uniqueRoutes = cache()->remember(
                'ussd_unique_routes',
                $this->sessionTtlSeconds(),
                function () {
                    $results = DB::select('SELECT DISTINCT r.route_code FROM public.routes r ORDER BY r.route_code');
                    return array_map(function ($row) {
                        return is_object($row) ? (string) $row->route_code : (string) $row['route_code'];
                    }, $results);
                }
            );
            
            Log::info("USSD DB Fetch [{$sessionId}] [routes]: found " . count($uniqueRoutes) . " unique routes", [
                'routes' => $uniqueRoutes,
                'source' => cache()->has('ussd_unique_routes') ? 'cache' : 'database'
            ]);
        } catch (\Exception $e) {
            Log::error('USSD Route Fetch Error: '.$e->getMessage());

            return 'END Sorry, routes are temporarily unavailable. Please try again later.';
        }

        if (empty($uniqueRoutes)) {
            return 'END No routes are available right now. Please try again later.';
        }

        // Ensure we have a clean array of strings
        $routeCodes = [];

        foreach ($uniqueRoutes as $route) {
            $routeCode = $this->extractRouteCode($route);

            if ($routeCode !== null && $routeCode !== '') {
                $routeCodes[] = $routeCode;
            }
        }

        cache()->put("ussd_{$sessionId}_route_codes", $routeCodes, $this->sessionTtlSeconds());

        $response = "CON Book Ticket\nSelect route:\n";

        foreach ($routeCodes as $index => $routeCode) {
            $response .= ($index + 1).'. '.$routeCode."\n";
        }

        $response .= (count($routeCodes) + 1).'. Back to Main Menu';

        return $response;
    }

    /**
     * Handle non-menu states including the new booking flow.
     *
     * @param  string  $sessionId  USSD session identifier.
     * @param  string|null  $phone  Caller MSISDN supplied by the gateway.
     * @param  array<int, string>  $userInput  Parsed USSD input tokens.
     * @param  string  $state  Current cached state for the session.
     * @return string Response for the current booking step.
     */
    private function continueFlow($sessionId, $phone, $userInput, $state): string
    {
        if ($state === 'booking_route') {
            $routeCodes = cache()->get("ussd_{$sessionId}_route_codes", []);

            if (empty($routeCodes)) {
                return $this->startBooking($sessionId, $phone);
            }

            $selectedValue = $userInput[count($userInput) - 1] ?? '';
            $selectedIndex = (int) $selectedValue;
            $backIndex = count($routeCodes) + 1;

            if ($selectedIndex === $backIndex) {
                cache()->put("ussd_{$sessionId}_state", 'menu', $this->sessionTtlSeconds());

                return "CON Welcome to TicketEase!\n\n1. Book Ticket\n2. My Bookings\n3. Register Account\n4. Exit";
            }

            if ($selectedIndex < 1 || $selectedIndex > count($routeCodes)) {
                return $this->startBooking($sessionId, $phone);
            }

            $selectedRouteCode = $routeCodes[$selectedIndex - 1];
            cache()->put("ussd_{$sessionId}_selected_route_code", $selectedRouteCode, $this->sessionTtlSeconds());
            cache()->put("ussd_{$sessionId}_state", 'booking_travel_date', $this->sessionTtlSeconds());

            return 'CON Selected: '.$selectedRouteCode."\nEnter travel date (DD-MM):";
        }

        if ($state === 'booking_travel_date') {
            $travelDateInput = $this->currentInputValue($userInput);

            if (! preg_match('/^\d{2}-\d{2}$/', $travelDateInput)) {
                return 'CON Invalid date format. Enter as DD-MM:';
            }

            try {
                $travelDate = Carbon::createFromFormat('d-m', $travelDateInput)->year(Carbon::now()->year)->startOfDay();
            } catch (\Exception $e) {
                return 'CON Invalid date. Enter travel date as DD-MM:';
            }

            if ($travelDate->lt(Carbon::today())) {
                return 'CON Travel date cannot be in the past. Enter DD-MM:';
            }

            cache()->put("ussd_{$sessionId}_travel_date", $travelDate->toDateString(), $this->sessionTtlSeconds());

            return $this->showProvidersForRouteAndDate($sessionId);
        }

        if ($state === 'booking_provider') {
            return $this->handleProviderSelection($sessionId, $phone, $userInput);
        }

        if ($state === 'booking_trip') {
            $tripOptions = $this->normalizeTripOptions(cache()->get("ussd_{$sessionId}_trip_options", []));

            if (empty($tripOptions)) {
                return $this->startTripSelection($sessionId);
            }

            $selectedValue = $this->currentInputValue($userInput);
            $selectedIndex = (int) $selectedValue;
            $backIndex = count($tripOptions) + 1;

            if ($selectedIndex === $backIndex) {
                cache()->forget("ussd_{$sessionId}_provider_options");
                cache()->forget("ussd_{$sessionId}_selected_tenant_id");
                cache()->forget("ussd_{$sessionId}_trip_options");
                cache()->put("ussd_{$sessionId}_state", 'booking_provider', $this->sessionTtlSeconds());

                return $this->showProvidersForRouteAndDate($sessionId);
            }

            if ($selectedIndex < 1 || $selectedIndex > count($tripOptions)) {
                return $this->startTripSelection($sessionId);
            }

            $selectedTrip = $tripOptions[$selectedIndex - 1];

            cache()->put("ussd_{$sessionId}_selected_trip_id", $selectedTrip['id'], $this->sessionTtlSeconds());
            cache()->put("ussd_{$sessionId}_state", 'booking_confirm', $this->sessionTtlSeconds());

            return "CON Confirm Booking\n"
                .$this->bookingSummary($sessionId)
                ."\n1. Confirm\n2. Cancel";
        }

        if ($state === 'booking_confirm') {
            $confirmationChoice = $this->currentInputValue($userInput);

            if ($confirmationChoice === '1') {
                cache()->put("ussd_{$sessionId}_state", 'booking_payment_pin', $this->sessionTtlSeconds());

                return 'CON Enter your 4-digit payment PIN to confirm payment:';
            }

            if ($confirmationChoice === '2') {
                $this->clearBookingSessionData($sessionId);

                return 'END Booking cancelled. Thank you for using TicketEase.';
            }

            return "CON Invalid option.\n"
                .$this->bookingSummary($sessionId)
                ."\n1. Confirm\n2. Cancel";
        }

        if ($state === 'booking_payment_pin') {
            $enteredPin = $this->currentInputValue($userInput);

            if (! preg_match('/^\d{4}$/', $enteredPin)) {
                return 'CON Invalid PIN format. Enter your 4-digit payment PIN:';
            }

            try {
                $this->queueBookingConfirmation($sessionId, (string) $phone, $enteredPin);
                $this->clearBookingSessionData($sessionId);

                return 'END Booking request received. You will receive an SMS confirmation shortly.';
            } catch (\Throwable $e) {
                Log::error('USSD Direct Booking Failed', [
                    'session_id' => $sessionId,
                    'phone' => $phone,
                    'error' => $e->getMessage(),
                ]);

                return 'END Sorry, booking could not be queued right now. Please try again.';
            }
        }

        if ($state === 'my_bookings') {
            $choice = $this->currentInputValue($userInput);

            if ($choice === '1') {
                $nextPage = ((int) cache()->get("ussd_{$sessionId}_my_bookings_page", 1)) + 1;
                cache()->put("ussd_{$sessionId}_my_bookings_page", $nextPage, $this->sessionTtlSeconds());

                return $this->showMyBookingsPage($sessionId, $phone, $nextPage);
            }

            if ($choice === '2') {
                cache()->forget("ussd_{$sessionId}_my_bookings_page");
                cache()->put("ussd_{$sessionId}_state", 'menu', $this->sessionTtlSeconds());

                return "CON Welcome to TicketEase!\n\n1. Book Ticket\n2. My Bookings\n3. Register Account\n4. Exit";
            }

            return 'CON Invalid option.\n1. More\n2. Main Menu';
        }

        return 'CON Feature coming soon...';
    }

    /**
     * Show recent bookings for the caller phone number.
     *
     * @param  string|null  $phone  Caller MSISDN supplied by the gateway.
     * @return string Booking list response.
     */
    private function showMyBookingsPage(string $sessionId, ?string $phone, int $page): string
    {
        if (empty($phone)) {
            return 'END Unable to identify your phone number. Please try again.';
        }

        $pageSize = 3;
        $offset = max($page - 1, 0) * $pageSize;

        try {
            $bookings = DB::select(
                'SELECT bp.ticket_number,
                        b.status,
                        r.route_code,
                        t.departure_datetime,
                        sa.seat_label,
                        b.created_at
                 FROM public.booking_passengers bp
                 JOIN public.bookings b ON b.id = bp.booking_id
                 LEFT JOIN public.routes r ON r.id = b.route_id
                 LEFT JOIN public.trips t ON t.id = b.trip_id
                 LEFT JOIN public.seat_assignments sa ON sa.booking_passenger_id = bp.id
                 WHERE bp.contact_phone = ?
                 ORDER BY b.created_at DESC
                 LIMIT ? OFFSET ?',
                [$phone, $pageSize + 1, $offset]
            );

            Log::info("USSD DB Fetch [{$sessionId}] [my_bookings]: found " . count($bookings) . " bookings for {$phone}", [
                'count' => count($bookings),
                'page' => $page
            ]);
        } catch (\Exception $e) {
            Log::error('USSD My Bookings Error: '.$e->getMessage(), ['phone' => $phone]);

            return 'END Sorry, we could not fetch your bookings right now. Please try again later.';
        }

        if (empty($bookings)) {
            cache()->forget("ussd_{$sessionId}_my_bookings_page");
            cache()->put("ussd_{$sessionId}_state", 'menu', $this->sessionTtlSeconds());

            return 'END No bookings found for your number yet.';
        }

        $hasMore = count($bookings) > $pageSize;
        $visibleBookings = array_slice($bookings, 0, $pageSize);

        $response = "CON My Bookings\n";

        foreach ($visibleBookings as $index => $booking) {
            $travelDate = 'N/A';

            if (! empty($booking->departure_datetime)) {
                try {
                    $travelDate = Carbon::parse($booking->departure_datetime)->format('d-m-Y H:i');
                } catch (\Exception $e) {
                    $travelDate = 'N/A';
                }
            }

            $ticketNumber = (string) ($booking->ticket_number ?? 'N/A');
            $routeCode = (string) ($booking->route_code ?? 'Unknown Route');
            $seatLabel = (string) ($booking->seat_label ?? 'Unassigned');
            $status = strtoupper((string) ($booking->status ?? 'unknown'));

            $response .= '- '.$ticketNumber.' | '.$routeCode."\n";
            $response .= '   '.$travelDate.' | Seat: '.$seatLabel.' | '.$status."\n";
        }

        if ($hasMore) {
            $response .= "1. More\n2. Main Menu";
        } else {
            $response .= '2. Main Menu';
        }

        return rtrim($response);
    }

    /**
     * Show available providers (tenants) for the selected route and date.
     * Only shows providers that have trips with available seats on that date.
     *
     * @param  string  $sessionId  USSD session identifier.
     * @return string Provider selection menu.
     */
    private function showProvidersForRouteAndDate(string $sessionId): string
    {
        $selectedRouteCode = cache()->get("ussd_{$sessionId}_selected_route_code");
        $travelDate = cache()->get("ussd_{$sessionId}_travel_date");

        if (!$selectedRouteCode || !$travelDate) {
            cache()->put("ussd_{$sessionId}_state", 'booking_route', $this->sessionTtlSeconds());
            return 'CON Session expired. Please select route again.';
        }

        try {
            // Cache provider query with date-based key to reduce database load
            $cacheKey = "ussd_providers_{$selectedRouteCode}_{$travelDate}";
            $providers = cache()->remember($cacheKey, 300, function () use ($selectedRouteCode, $travelDate) {
                // Simplified query: just get providers with trip counts for the date
                $results = DB::select(
                    'SELECT t.id as tenant_id, 
                           t.name as tenant_name, 
                           r.id as route_id,
                           r.base_fare,
                           COUNT(trip.id) as trip_count
                    FROM public.routes r
                    JOIN public.tenants t ON t.id = r.tenant_id
                    JOIN public.trips trip ON trip.route_id = r.id 
                       AND immutable_date(trip.departure_datetime) = ?::date
                       AND trip.status = ANY(ARRAY[\'scheduled\',\'active\'])
                    WHERE r.route_code = ? 
                      AND t.is_active = true
                    GROUP BY t.id, t.name, r.id, r.base_fare
                    ORDER BY t.name',
                    [$travelDate, $selectedRouteCode]
                );

                // Convert stdClass objects to arrays to avoid "incomplete object" issues on serialization/unserialization
                return array_map(fn($item) => (array) $item, $results);
            });

            Log::info("USSD DB Fetch [{$sessionId}] [providers]: found " . count($providers) . " providers for {$selectedRouteCode} on {$travelDate}", [
                'route' => $selectedRouteCode,
                'date' => $travelDate,
                'count' => count($providers)
            ]);
        } catch (\Exception $e) {
            Log::error('USSD Provider Fetch Error: '.$e->getMessage());

            return 'END Sorry, providers are temporarily unavailable. Please try again later.';
        }

        if (empty($providers)) {
            cache()->forget("ussd_{$sessionId}_travel_date");
            cache()->put("ussd_{$sessionId}_state", 'booking_travel_date', $this->sessionTtlSeconds());

            return 'CON No providers with available trips found for '.$selectedRouteCode.' on '.$travelDate.". Enter another date (DD-MM):";
        }

        $providerOptions = [];
        foreach ($providers as $provider) {
            // Robustly handle either object or array
            $p = (array) $provider;
            $providerOptions[] = [
                'tenant_id' => (string) ($p['tenant_id'] ?? ''),
                'tenant_name' => (string) ($p['tenant_name'] ?? ''),
                'route_id' => (int) ($p['route_id'] ?? 0),
                'base_fare' => (float) ($p['base_fare'] ?? 0),
                'trip_count' => (int) ($p['trip_count'] ?? 0),
            ];
        }

        cache()->put("ussd_{$sessionId}_provider_options", $providerOptions, $this->sessionTtlSeconds());
        cache()->put("ussd_{$sessionId}_state", 'booking_provider', $this->sessionTtlSeconds());

        $response = "CON Providers for {$selectedRouteCode} on {$travelDate}:\n";

        foreach ($providerOptions as $index => $provider) {
            $fareFormatted = number_format($provider['base_fare'], 0);
            $tripsInfo = $provider['trip_count'].' trip'.($provider['trip_count'] > 1 ? 's' : '');
            $response .= ($index + 1).'. '.$provider['tenant_name']." (MK {$fareFormatted}, {$tripsInfo})\n";
        }

        $response .= (count($providerOptions) + 1).'. Change date';

        return $response;
    }

    /**
     * Handle provider selection and show available trips.
     *
     * @param  string  $sessionId  USSD session identifier.
     * @param  string|null  $phone  Caller MSISDN.
     * @param  array<int, string>  $userInput  Parsed USSD input tokens.
     * @return string Trip selection menu.
     */
    private function handleProviderSelection(string $sessionId, ?string $phone, array $userInput): string
    {
        $providerOptions = cache()->get("ussd_{$sessionId}_provider_options", []);

        if (empty($providerOptions)) {
            return $this->showProvidersForRouteAndDate($sessionId);
        }

        $selectedValue = $this->currentInputValue($userInput);
        $selectedIndex = (int) $selectedValue;
        $backIndex = count($providerOptions) + 1;

        if ($selectedIndex === $backIndex) {
            cache()->forget("ussd_{$sessionId}_provider_options");
            cache()->forget("ussd_{$sessionId}_travel_date");
            cache()->put("ussd_{$sessionId}_state", 'booking_travel_date', $this->sessionTtlSeconds());

            return 'CON Enter travel date (DD-MM):';
        }

        if ($selectedIndex < 1 || $selectedIndex > count($providerOptions)) {
            return $this->showProvidersForRouteAndDate($sessionId);
        }

        $selectedProvider = $providerOptions[$selectedIndex - 1];

        cache()->put("ussd_{$sessionId}_selected_route_id", $selectedProvider['route_id'], $this->sessionTtlSeconds());
        cache()->put("ussd_{$sessionId}_selected_tenant_id", $selectedProvider['tenant_id'], $this->sessionTtlSeconds());
        cache()->put("ussd_{$sessionId}_base_fare", $selectedProvider['base_fare'], $this->sessionTtlSeconds());
        cache()->put("ussd_{$sessionId}_passenger_count", 1, $this->sessionTtlSeconds());

        return $this->startTripSelection($sessionId);
    }

    /**
     * Load available trips for the selected route, date, and provider, then show options.
     *
     * @param  string  $sessionId  USSD session identifier.
     * @return string Trip selection response.
     */
    private function startTripSelection(string $sessionId): string
    {
        $selectedRouteId = cache()->get("ussd_{$sessionId}_selected_route_id");
        $selectedTenantId = cache()->get("ussd_{$sessionId}_selected_tenant_id");
        $travelDate = cache()->get("ussd_{$sessionId}_travel_date");

        if ($selectedRouteId === null || $travelDate === null || $selectedTenantId === null) {
            cache()->put("ussd_{$sessionId}_state", 'booking_route', $this->sessionTtlSeconds());

            return 'CON Booking session expired. Please select route again.';
        }

        $tripCacheKey = "ussd_trip_options_route_{$selectedRouteId}_tenant_{$selectedTenantId}_date_{$travelDate}";

        try {
            $tripOptions = cache()->remember(
                $tripCacheKey,
                300, // Cache for 5 minutes for better performance
                function () use ($selectedRouteId, $selectedTenantId, $travelDate) {
                    // Simplified query: get trips without complex seat calculations
                    $trips = DB::select(
                        'SELECT t.id,
                               t.departure_datetime,
                               t.status,
                               COALESCE(jsonb_array_length(b.seat_map->\'seats\'), 0) 
                                   - COALESCE(sa_counts.assigned, 0) as available_seats
                        FROM public.trips t
                        JOIN public.buses b ON b.id = t.bus_id
                        LEFT JOIN (
                            SELECT trip_id, COUNT(*) as assigned
                            FROM public.seat_assignments
                            WHERE trip_id = ANY(
                                SELECT id FROM public.trips 
                                WHERE route_id = ? 
                                  AND tenant_id = ?
                                  AND immutable_date(departure_datetime) = ?::date
                            )
                            GROUP BY trip_id
                        ) sa_counts ON sa_counts.trip_id = t.id
                        WHERE t.route_id = ?
                          AND t.tenant_id = ?
                          AND immutable_date(t.departure_datetime) = ?::date
                          AND t.status = ANY(ARRAY[\'scheduled\',\'active\'])
                        ORDER BY t.departure_datetime
                        LIMIT 20',
                        [$selectedRouteId, $selectedTenantId, $travelDate, $selectedRouteId, $selectedTenantId, $travelDate]
                    );

                    return $this->normalizeTripOptions($trips);
                }
            );

            Log::info("USSD DB Fetch [{$sessionId}] [trips]: found " . count($tripOptions) . " trips", [
                'route_id' => $selectedRouteId,
                'tenant_id' => $selectedTenantId,
                'date' => $travelDate,
                'count' => count($tripOptions)
            ]);
        } catch (\Exception $e) {
            $tripOptions = $this->normalizeTripOptions(cache()->get($tripCacheKey, []));

            if (! empty($tripOptions)) {
                Log::warning('USSD Trip Fetch Error, serving cached trips', [
                    'error' => $e->getMessage(),
                    'route_id' => $selectedRouteId,
                    'tenant_id' => $selectedTenantId,
                    'travel_date' => $travelDate,
                ]);
            } else {
                Log::error('USSD Trip Fetch Error: '.$e->getMessage());

                return 'END Sorry, trips are temporarily unavailable. Please try again later.';
            }
        }

        $tripOptions = $this->normalizeTripOptions($tripOptions);

        if (empty($tripOptions)) {
            cache()->forget("ussd_{$sessionId}_provider_options");
            cache()->forget("ussd_{$sessionId}_selected_tenant_id");
            cache()->put("ussd_{$sessionId}_state", 'booking_provider', $this->sessionTtlSeconds());

            return 'CON No trips with available seats found for this provider on that date. Please select another provider:';
        }

        cache()->put("ussd_{$sessionId}_trip_options", $tripOptions, $this->sessionTtlSeconds());
        cache()->put("ussd_{$sessionId}_state", 'booking_trip', $this->sessionTtlSeconds());

        $selectedProvider = null;
        foreach (cache()->get("ussd_{$sessionId}_provider_options", []) as $provider) {
            if ($provider['tenant_id'] === $selectedTenantId) {
                $selectedProvider = $provider;
                break;
            }
        }

        $providerName = $selectedProvider ? $selectedProvider['tenant_name'] : 'Selected Provider';

        $response = "CON Select trip for {$providerName}:\n";

        foreach ($tripOptions as $index => $trip) {
            $response .= ($index + 1).'. '.$trip['display_label']."\n";
        }

        $response .= (count($tripOptions) + 1).'. Change provider';

        return $response;
    }

    /**
     * Build a short booking summary for the confirmation screen.
     *
     * @param  string  $sessionId  USSD session identifier.
     * @return string Multi-line booking summary.
     */
    private function bookingSummary(string $sessionId): string
    {
        $routeLabel = $this->selectedRouteLabel($sessionId);
        $tripLabel = $this->selectedTripLabel($sessionId);
        $passengerCount = (string) cache()->get("ussd_{$sessionId}_passenger_count", 'N/A');
        $travelDate = (string) cache()->get("ussd_{$sessionId}_travel_date", 'N/A');

        return "Route: {$routeLabel}\nTrip: {$tripLabel}\nPassengers: {$passengerCount}\nDate: {$travelDate}";
    }

    /**
     * Resolve the selected route label from cached route code.
     *
     * @param  string  $sessionId  USSD session identifier.
     * @return string Selected route label or placeholder if not available.
     */
    private function selectedRouteLabel(string $sessionId): string
    {
        $selectedRouteCode = cache()->get("ussd_{$sessionId}_selected_route_code");
        
        if ($selectedRouteCode && $selectedRouteCode !== '') {
            return (string) $selectedRouteCode;
        }

        return 'Unknown Route';
    }

    /**
     * Resolve the selected trip label from cached trip options.
     *
     * @param  string  $sessionId  USSD session identifier.
     * @return string Selected trip label or placeholder if not available.
     */
    private function selectedTripLabel(string $sessionId): string
    {
        $selectedTripId = cache()->get("ussd_{$sessionId}_selected_trip_id");
        $tripOptions = $this->normalizeTripOptions(cache()->get("ussd_{$sessionId}_trip_options", []));

        foreach ($tripOptions as $trip) {
            if ((string) ($trip['id'] ?? '') === (string) $selectedTripId) {
                return $trip['display_label'];
            }
        }

        return 'Unknown Trip';
    }

    /**
     * Clear booking-specific session cache keys after confirm or cancel.
     *
     * @param  string  $sessionId  USSD session identifier.
     */
    private function clearBookingSessionData(string $sessionId): void
    {
        cache()->forget("ussd_{$sessionId}_route_codes");
        cache()->forget("ussd_{$sessionId}_selected_route_code");
        cache()->forget("ussd_{$sessionId}_provider_options");
        cache()->forget("ussd_{$sessionId}_selected_route_id");
        cache()->forget("ussd_{$sessionId}_selected_tenant_id");
        cache()->forget("ussd_{$sessionId}_base_fare");
        cache()->forget("ussd_{$sessionId}_trip_options");
        cache()->forget("ussd_{$sessionId}_selected_trip_id");
        cache()->forget("ussd_{$sessionId}_passenger_count");
        cache()->forget("ussd_{$sessionId}_travel_date");
        cache()->forget("ussd_{$sessionId}_state");
    }

    /**
     * Queue the booking work so the USSD response can return immediately.
     */
    private function queueBookingConfirmation(string $sessionId, string $phone, string $enteredPin): void
    {
        $selectedRouteId = cache()->get("ussd_{$sessionId}_selected_route_id");
        $selectedTripId = cache()->get("ussd_{$sessionId}_selected_trip_id");
        $travelDate = cache()->get("ussd_{$sessionId}_travel_date");
        $passengerCount = (int) cache()->get("ussd_{$sessionId}_passenger_count", 1);
        $tenantId = cache()->get("ussd_{$sessionId}_selected_tenant_id");
        $baseFare = (float) cache()->get("ussd_{$sessionId}_base_fare", 0);
        $selectedRouteCode = cache()->get("ussd_{$sessionId}_selected_route_code", '');

        if ($selectedRouteId === null || $selectedTripId === null || $travelDate === null || $tenantId === null) {
            throw new \RuntimeException('Booking session expired. Please start again.');
        }

        $bookingData = [
            'route_id' => $selectedRouteId,
            'trip_id' => $selectedTripId,
            'tenant_id' => (string) $tenantId,
            'route_code' => (string) $selectedRouteCode,
            'travel_date' => (string) $travelDate,
            'total_fare' => $baseFare * $passengerCount,
            'passenger_count' => $passengerCount,
            'passenger_name' => $this->resolvePassengerFullName($sessionId, $phone),
            'payment_pin' => $enteredPin,
        ];

        $queueConnection = (string) config('queue.default', 'sync');
        $queueConnections = (array) config('queue.connections', []);

        if (! array_key_exists($queueConnection, $queueConnections)) {
            Log::warning('USSD booking queue connection is unavailable; processing immediately', [
                'session_id' => $sessionId,
                'queue_connection' => $queueConnection,
            ]);

            $this->processBookingImmediately($sessionId, $phone, $bookingData);

            return;
        }

        ProcessUssdBooking::dispatch(
            sessionId: $sessionId,
            phone: $phone,
            bookingData: $bookingData
        );
    }

    /**
     * Extract a route code from a cached route payload without assuming a concrete object type.
     *
     * @param  mixed  $route  Cached route payload.
     */
    private function extractRouteCode(mixed $route): ?string
    {
        if (is_string($route) || is_numeric($route)) {
            return trim((string) $route);
        }

        if (is_array($route)) {
            $routeCode = $route['route_code'] ?? null;

            return $routeCode === null ? null : trim((string) $routeCode);
        }

        if (is_object($route)) {
            $routeArray = (array) $route;

            foreach ($routeArray as $key => $value) {
                if (str_ends_with((string) $key, 'route_code')) {
                    return trim((string) $value);
                }
            }
        }

        return null;
    }

    /**
     * Convert route records into plain arrays so cached session data stays serializable.
     *
     * @param  array<int, mixed>  $routes  Raw DB rows or cached route records.
     * @return array<int, array{id: int|string, tenant_id: string|null, route_code: string, base_fare: mixed, tenant_name: string, display_label: string}>
     */
    private function normalizeRouteOptions(array $routes): array
    {
        $normalizedRoutes = [];

        foreach ($routes as $route) {
            if (is_object($route)) {
                $route = (array) $route;
            }

            if (isset($route['stdClass']) && is_object($route['stdClass'])) {
                $route = (array) $route['stdClass'];
            }

            if (! is_array($route)) {
                continue;
            }

            $routeCode = (string) ($route['route_code'] ?? '');
            $tenantName = (string) ($route['tenant_name'] ?? 'Unknown Tenant');

            $normalizedRoutes[] = [
                'id' => $route['id'] ?? null,
                'tenant_id' => $route['tenant_id'] ?? null,
                'route_code' => $routeCode,
                'base_fare' => $route['base_fare'] ?? null,
                'tenant_name' => $tenantName,
                'display_label' => $routeCode.' ('.$tenantName.')',
            ];
        }

        return $normalizedRoutes;
    }

    /**
     * Convert trip records into plain arrays for safe cache storage.
     *
     * @param  array<int, mixed>  $trips  Raw DB rows or cached trip records.
     * @return array<int, array{id: int|string, departure_datetime: string, status: string, available_seats: int, display_label: string}>
     */
    private function normalizeTripOptions(array $trips): array
    {
        $normalizedTrips = [];

        foreach ($trips as $trip) {
            if (is_object($trip)) {
                $trip = (array) $trip;
            }

            if (! is_array($trip)) {
                continue;
            }

            $departureDatetime = (string) ($trip['departure_datetime'] ?? '');
            $status = strtoupper((string) ($trip['status'] ?? ''));
            $availableSeats = (int) ($trip['available_seats'] ?? 0);

            $normalizedTrips[] = [
                'id' => $trip['id'] ?? null,
                'departure_datetime' => $departureDatetime,
                'status' => (string) ($trip['status'] ?? ''),
                'available_seats' => $availableSeats,
                'display_label' => $this->tripDisplayLabel($departureDatetime, $status, $availableSeats),
            ];
        }

        return $normalizedTrips;
    }

    /**
     * Build a short human-readable trip label for USSD menus.
     *
     * @param  string  $departureDatetime  Departure timestamp.
     * @param  string  $status  Trip status label.
     * @param  int  $availableSeats  Computed available seat count.
     * @return string Menu label for one trip option.
     */
    private function tripDisplayLabel(string $departureDatetime, string $status, int $availableSeats): string
    {
        try {
            $departure = Carbon::parse($departureDatetime)->format('H:i');
        } catch (\Exception $e) {
            $departure = 'Unknown time';
        }

        return $departure.' ('.$status.') - Seats: '.$availableSeats;
    }

    /**
     * Resolve a passenger full name for booking passenger rows.
     * Checks cache first (for new registrations) then existing profiles.
     *
     * @param  string  $sessionId  USSD session identifier.
     * @param  string  $phone  Caller MSISDN.
     * @return string Best-effort full name.
     */
    private function resolvePassengerFullName(string $sessionId, string $phone): string
    {
        $cachedName = trim((string) cache()->get("ussd_{$sessionId}_full_name", ''));

        if ($cachedName !== '') {
            return $cachedName;
        }

        $profile = DB::selectOne('SELECT full_name FROM public.profiles WHERE phone = ? ORDER BY created_at DESC LIMIT 1', [$phone]);

        if ($profile !== null && ! empty($profile->full_name)) {
            return (string) $profile->full_name;
        }

        return 'Passenger';
    }

    /**
     * Process booking instantly without dispatching a queue job.
     *
     * @param  string  $sessionId  USSD session identifier.
     * @param  string  $phone  Caller MSISDN.
     * @param  array{route_id:mixed,trip_id:mixed,tenant_id:string,route_code:string,travel_date:string,total_fare:float|int|string,passenger_count:int,passenger_name:string}  $bookingData
     * @return array{ticket_number:string,seat_label:string}
     */
    private function processBookingImmediately(string $sessionId, string $phone, array $bookingData): array
    {
        Log::info('Processing USSD Booking Directly', [
            'session_id' => $sessionId,
            'phone' => $phone,
            'trip_id' => $bookingData['trip_id'] ?? 'unknown',
        ]);

        $selectedTripId = $bookingData['trip_id'];
        $tenantId = $bookingData['tenant_id'];
        $selectedRouteId = $bookingData['route_id'];
        $passengerCount = (int) ($bookingData['passenger_count'] ?? 1);
        $totalFare = (float) ($bookingData['total_fare'] ?? 0);
        $passengerName = (string) ($bookingData['passenger_name'] ?? 'Passenger');

        $bookingResult = DB::transaction(function () use (
            $selectedTripId,
            $tenantId,
            $selectedRouteId,
            $passengerCount,
            $totalFare,
            $passengerName,
            $phone
        ) {
            $transactionReference = 'USSD-'.strtoupper(substr(str_replace('-', '', (string) Str::uuid()), 0, 12));

            $result = DB::selectOne(
                'WITH lock_trip AS (
                    SELECT pg_advisory_xact_lock(?::bigint)
                ),
                new_booking AS (
                    INSERT INTO public.bookings (tenant_id, trip_id, route_id, booking_type, total_passengers, total_fare, status, is_open_ticket)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?::boolean)
                    RETURNING id
                ),
                new_passenger AS (
                    INSERT INTO public.booking_passengers (booking_id, name, contact_phone)
                    SELECT nb.id, ?, ?
                    FROM new_booking nb
                    RETURNING id, ticket_number
                ),
                new_payment AS (
                    INSERT INTO public.payments (booking_id, amount, payment_method, status, transaction_reference, paid_at)
                    SELECT nb.id, ?, ?, ?, ?, NOW()
                    FROM new_booking nb
                    RETURNING id
                ),
                available_seat AS (
                    SELECT s.seat_label
                    FROM (
                        SELECT jsonb_array_elements_text(COALESCE(b.seat_map->\'seats\', \'[]\'::jsonb)) AS seat_label
                        FROM public.trips t
                        JOIN public.buses b ON b.id = t.bus_id
                        WHERE t.id = ?
                    ) s
                    WHERE NOT EXISTS (
                        SELECT 1
                        FROM public.seat_assignments sa
                        WHERE sa.trip_id = ?
                          AND sa.seat_label = s.seat_label
                    )
                    ORDER BY s.seat_label
                    LIMIT 1
                ),
                new_assignment AS (
                    INSERT INTO public.seat_assignments (trip_id, booking_passenger_id, seat_label)
                    SELECT ?, np.id, a.seat_label
                    FROM new_passenger np
                    JOIN available_seat a ON true
                    RETURNING seat_label
                )
                SELECT np.ticket_number, na.seat_label
                FROM new_passenger np
                JOIN new_assignment na ON true
                LIMIT 1',
                [
                    $selectedTripId,
                    $tenantId,
                    $selectedTripId,
                    $selectedRouteId,
                    'ussd',
                    $passengerCount,
                    $totalFare,
                    'confirmed',
                    false,
                    $passengerName,
                    $phone,
                    $totalFare,
                    'mobile_money',
                    'completed',
                    $transactionReference,
                    $selectedTripId,
                    $selectedTripId,
                    $selectedTripId,
                ]
            );

            if ($result === null || empty($result->seat_label)) {
                throw new \RuntimeException("No available seats left for trip ID: {$selectedTripId}");
            }

            return [
                'ticket_number' => (string) ($result->ticket_number ?? 'PENDING'),
                'seat_label' => (string) $result->seat_label,
            ];
        });

        Log::info('USSD Direct Booking Successful', [
            'session_id' => $sessionId,
            'ticket' => $bookingResult['ticket_number'],
            'seat' => $bookingResult['seat_label'],
        ]);

        $this->recordBookingNotification(
            $phone,
            $bookingData['tenant_id'],
            $bookingData['route_code'],
            $bookingData['travel_date'],
            $bookingData['passenger_name'],
            $bookingResult
        );

        return $bookingResult;
    }

    /**
     * Persist booking confirmation notification payload and send SMS.
     *
     * @param  array{ticket_number:string,seat_label:string}  $bookingResult
     */
    private function recordBookingNotification(
        string $phone,
        string $tenantId,
        string $routeCode,
        string $travelDate,
        string $passengerName,
        array $bookingResult
    ): void {
        $profileId = $this->resolveNotificationProfileId($phone, $passengerName, $tenantId);

        $message = "TicketEase: Booking confirmed for {$passengerName} on {$travelDate}. Ticket: {$bookingResult['ticket_number']}. Seat: {$bookingResult['seat_label']}. Route: {$routeCode}. Safe travels!";

        try {
            DB::insert(
                'INSERT INTO public.notifications (profile_id, title, message, category, metadata, tenant_id)
                 VALUES (?, ?, ?, ?, ?, ?)',
                [
                    $profileId,
                    'Booking Confirmed',
                    $message,
                    'booking',
                    json_encode([
                        'ticket_number' => $bookingResult['ticket_number'],
                        'seat_label' => $bookingResult['seat_label'],
                        'route_code' => $routeCode,
                        'travel_date' => $travelDate,
                    ]),
                    $tenantId,
                ]
            );

            Log::info('USSD Direct Booking Notification Recorded', ['phone' => $phone, 'message' => $message]);
        } catch (\Throwable $e) {
            Log::error('Failed to record USSD booking notification', ['error' => $e->getMessage()]);
        }

        // Send SMS confirmation
        try {
            $this->smsService->send([$phone], $message);
            Log::info('USSD Direct Booking SMS Sent', ['phone' => $phone]);
        } catch (\Throwable $e) {
            Log::error('Failed to send USSD booking confirmation SMS', [
                'phone' => $phone,
                'error' => $e->getMessage(),
            ]);
        }
    }

    /**
     * Resolve or create profile id for notifications.
     */
    private function resolveNotificationProfileId(string $phone, string $fullName, string $tenantId): ?string
    {
        try {
            $profile = DB::selectOne(
                'SELECT id FROM public.profiles WHERE phone = ? AND (tenant_id = ? OR tenant_id IS NULL) ORDER BY created_at DESC LIMIT 1',
                [$phone, $tenantId]
            );

            if ($profile !== null && ! empty($profile->id)) {
                return (string) $profile->id;
            }

            $result = DB::selectOne('SELECT public.get_or_create_profile(?, ?, ?, ?) AS id', [
                $fullName,
                $phone,
                null,
                $tenantId,
            ]);

            return $result !== null && ! empty($result->id) ? (string) $result->id : null;
        } catch (\Throwable $e) {
            return null;
        }
    }

    /**
     * Validate payment PIN entered in USSD against the profile PIN hash.
     */
    private function verifyPaymentPin(string $phone, string $tenantId, string $enteredPin): ?bool
    {
        $profile = DB::selectOne(
            'SELECT payment_pin_hash
             FROM public.profiles
             WHERE phone = ? AND (tenant_id = ? OR tenant_id IS NULL)
             ORDER BY created_at DESC
             LIMIT 1',
            [$phone, $tenantId]
        );

        if ($profile === null || empty($profile->payment_pin_hash)) {
            return null;
        }

        return Hash::check($enteredPin, (string) $profile->payment_pin_hash);
    }

    /**
     * Get the most recent USSD input token from the full request payload.
     *
     * @param  array<int, string>  $userInput  Parsed USSD input tokens.
     * @return string Latest non-empty token, or an empty string if none exists.
     */
    private function currentInputValue(array $userInput): string
    {
        $currentValue = '';

        foreach (array_reverse($userInput) as $value) {
            if ($value !== '') {
                $currentValue = $value;
                break;
            }
        }

        return $currentValue;
    }

    /**
     * Resolve session cache TTL with environment override.
     */
    private function sessionTtlSeconds(): int
    {
        return max((int) env('USSD_SESSION_TTL_SECONDS', self::DEFAULT_SESSION_TTL_SECONDS), 300);
    }
}
