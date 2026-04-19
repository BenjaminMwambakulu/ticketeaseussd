<?php

namespace App\Services;

use Illuminate\Http\Request;
use Illuminate\Support\Carbon;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Facades\Log;

/**
 * Coordinates USSD menu flow, session state transitions, and DB-backed actions.
 */
class UssdService
{
    /**
     * Default cache TTL for USSD session keys in seconds.
     */
    private const DEFAULT_SESSION_TTL_SECONDS = 1200;

    /**
     * Handle an incoming USSD request and return a USSD-compliant response string.
     *
     * @param  Request  $request  Incoming HTTP request from the USSD gateway.
     * @return string Response that starts with CON (continue) or END (terminate).
     */
    public function handle(Request $request): string
    {
        $sessionId = $request->input('sessionId');
        $phoneNumber = $request->input('phoneNumber');
        $text = $request->input('text');

        Log::info('USSD Request', $request->all());

        $userInput = $text ? explode('*', $text) : [];
        $state = cache()->get("ussd_{$sessionId}_state", 'start');

        if ($state === 'start' || empty($text)) {
            $response = "CON Welcome to TicketEase!\n\n";
            $response .= "1. Book Ticket\n";
            $response .= "2. My Bookings\n";
            $response .= "3. Check Ticket\n";
            $response .= "4. Cancel Ticket\n";
            $response .= "5. Register Account\n";
            $response .= '6. Exit';

            cache()->put("ussd_{$sessionId}_state", 'menu', $this->sessionTtlSeconds());
            cache()->put("ussd_{$sessionId}_phone", $phoneNumber, $this->sessionTtlSeconds());

            return $response;
        }

        if ($state === 'menu') {
            $choice = $userInput[0] ?? '';

            if ($choice == '1') {
                return $this->startBooking($sessionId, $phoneNumber);
            }

            if ($choice == '2') {
                cache()->put("ussd_{$sessionId}_state", 'my_bookings', $this->sessionTtlSeconds());
                cache()->put("ussd_{$sessionId}_my_bookings_page", 1, $this->sessionTtlSeconds());

                return $this->showMyBookingsPage($sessionId, $phoneNumber, 1);
            }

            if ($choice == '5') {
                return $this->handleRegistration($sessionId, $phoneNumber, $userInput);
            }

            if ($choice == '6') {
                cache()->forget("ussd_{$sessionId}_state");

                return 'END Thank you for using TicketEase. Safe travels!';
            }

            return "CON Invalid option. Please try again.\n\n1. Book Ticket\n5. Register Account\n6. Exit";
        }

        return $this->continueFlow($sessionId, $phoneNumber, $userInput, $state);
    }

    /**
     * Run the multi-step registration flow (name -> national ID -> profile create/get).
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

            return 'CON Enter your National ID:';
        }

        if ($step == 3) {
            $nationalId = $this->currentInputValue($userInput);
            $fullName = cache()->get("ussd_{$sessionId}_full_name");

            try {
                DB::select('SELECT public.get_or_create_profile(?, ?, ?, NULL) as id', [
                    $fullName, $phone, $nationalId,
                ]);

                Log::info('USSD Registration Successful', [
                    'session_id' => $sessionId,
                    'phone' => $phone,
                    'full_name' => $fullName,
                    'national_id' => $nationalId,
                ]);

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
     * Initialize booking flow and present route selection options.
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
            $routes = DB::select('SELECT r.id, r.tenant_id, r.route_code, r.base_fare, t.name as tenant_name FROM public.routes r LEFT JOIN public.tenants t ON t.id = r.tenant_id ORDER BY r.id');
        } catch (\Exception $e) {
            Log::error('USSD Route Fetch Error: '.$e->getMessage());

            return 'END Sorry, routes are temporarily unavailable. Please try again later.';
        }

        if (empty($routes)) {
            return 'END No routes are available right now. Please try again later.';
        }

        $routeOptions = $this->normalizeRouteOptions($routes);

        cache()->put("ussd_{$sessionId}_route_options", $routeOptions, $this->sessionTtlSeconds());
        Log::info('Available routes', ['data' => $routeOptions]);

        $response = "CON Book Ticket\nSelect route:\n";

        foreach ($routeOptions as $index => $route) {
            $response .= ($index + 1).'. '.$route['display_label']."\n";
        }

        $response .= (count($routeOptions) + 1).'. Back to Main Menu';

        return $response;
    }

    /**
     * Handle non-menu states that are not yet implemented.
     *
     * @param  string  $sessionId  USSD session identifier.
     * @param  string|null  $phone  Caller MSISDN supplied by the gateway.
     * @param  array<int, string>  $userInput  Parsed USSD input tokens.
     * @param  string  $state  Current cached state for the session.
     * @return string Placeholder response until additional flows are implemented.
     */
    private function continueFlow($sessionId, $phone, $userInput, $state): string
    {
        if ($state === 'booking_route') {
            $routeOptions = $this->normalizeRouteOptions(cache()->get("ussd_{$sessionId}_route_options", []));

            if (empty($routeOptions)) {
                return $this->startBooking($sessionId, $phone);
            }

            $selectedValue = $userInput[count($userInput) - 1] ?? '';
            $selectedIndex = (int) $selectedValue;
            $backIndex = count($routeOptions) + 1;

            if ($selectedIndex === $backIndex) {
                cache()->put("ussd_{$sessionId}_state", 'menu', $this->sessionTtlSeconds());

                return "CON Welcome to TicketEase!\n\n1. Book Ticket\n2. My Bookings\n3. Check Ticket\n4. Cancel Ticket\n5. Register Account\n6. Exit";
            }

            if ($selectedIndex < 1 || $selectedIndex > count($routeOptions)) {
                return $this->startBooking($sessionId, $phone);
            }

            $selectedRoute = $routeOptions[$selectedIndex - 1];

            cache()->put("ussd_{$sessionId}_selected_route_id", $selectedRoute['id'], $this->sessionTtlSeconds());
            cache()->put("ussd_{$sessionId}_passenger_count", 1, $this->sessionTtlSeconds());
            cache()->put("ussd_{$sessionId}_state", 'booking_travel_date', $this->sessionTtlSeconds());

            return 'CON Selected: '.$selectedRoute['display_label']."\nSingle passenger booking only.\nEnter travel date (DD-MM-YYYY):";
        }

        if ($state === 'booking_passengers') {
            cache()->put("ussd_{$sessionId}_passenger_count", 1, $this->sessionTtlSeconds());
            cache()->put("ussd_{$sessionId}_state", 'booking_travel_date', $this->sessionTtlSeconds());

            return 'CON Single passenger booking only. Enter travel date (DD-MM-YYYY):';
        }

        if ($state === 'booking_travel_date') {
            $travelDateInput = $this->currentInputValue($userInput);

            if (! preg_match('/^\d{2}-\d{2}-\d{4}$/', $travelDateInput)) {
                return 'CON Invalid date format. Enter as DD-MM-YYYY:';
            }

            try {
                $travelDate = Carbon::createFromFormat('d-m-Y', $travelDateInput)->startOfDay();
            } catch (\Exception $e) {
                return 'CON Invalid date. Enter travel date as DD-MM-YYYY:';
            }

            if ($travelDate->lt(Carbon::today())) {
                return 'CON Travel date cannot be in the past. Enter DD-MM-YYYY:';
            }

            cache()->put("ussd_{$sessionId}_travel_date", $travelDate->toDateString(), $this->sessionTtlSeconds());

            return $this->startTripSelection($sessionId);
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
                cache()->put("ussd_{$sessionId}_state", 'booking_travel_date', $this->sessionTtlSeconds());

                return 'CON Enter travel date (DD-MM-YYYY):';
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
                $bookingResult = $this->createTripBooking($sessionId, (string) $phone);

                if ($bookingResult === null) {
                    return 'END Sorry, we could not complete your booking right now. Please try again later.';
                }

                Log::info('USSD Booking Confirmed', [
                    'session_id' => $sessionId,
                    'phone' => $phone,
                    'route_id' => cache()->get("ussd_{$sessionId}_selected_route_id"),
                    'passenger_count' => cache()->get("ussd_{$sessionId}_passenger_count"),
                    'travel_date' => cache()->get("ussd_{$sessionId}_travel_date"),
                    'seat_label' => $bookingResult['seat_label'],
                    'ticket_number' => $bookingResult['ticket_number'],
                ]);

                $this->clearBookingSessionData($sessionId);

                return "END Booking confirmed!\nSeat: {$bookingResult['seat_label']}\nTicket: {$bookingResult['ticket_number']}";
            }

            if ($confirmationChoice === '2') {
                $this->clearBookingSessionData($sessionId);

                return 'END Booking cancelled. Thank you for using TicketEase.';
            }

            return "CON Invalid option.\n"
                .$this->bookingSummary($sessionId)
                ."\n1. Confirm\n2. Cancel";
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

                return "CON Welcome to TicketEase!\n\n1. Book Ticket\n2. My Bookings\n3. Check Ticket\n4. Cancel Ticket\n5. Register Account\n6. Exit";
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

            $rowNumber = $offset + $index + 1;
            $response .= $rowNumber.'. '.$ticketNumber.' | '.$routeCode."\n";
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
     * Load available trips for the selected route and travel date, then show options.
     *
     * @param  string  $sessionId  USSD session identifier.
     * @return string Trip selection response.
     */
    private function startTripSelection(string $sessionId): string
    {
        $selectedRouteId = cache()->get("ussd_{$sessionId}_selected_route_id");
        $travelDate = cache()->get("ussd_{$sessionId}_travel_date");

        if ($selectedRouteId === null || $travelDate === null) {
            cache()->put("ussd_{$sessionId}_state", 'booking_route', $this->sessionTtlSeconds());

            return 'CON Booking session expired. Please select route again.';
        }

        try {
            $trips = DB::select(
                'SELECT t.id,
                        t.departure_datetime,
                        t.status,
                        GREATEST(COALESCE(jsonb_array_length(COALESCE(b.seat_map->\'seats\', \'[]\'::jsonb)), 0) - COALESCE(sa.assigned_seats, 0), 0) AS available_seats
                                 FROM public.trips t
                                 LEFT JOIN public.buses b ON b.id = t.bus_id
                                 LEFT JOIN (
                    SELECT trip_id, COUNT(*)::int AS assigned_seats
                    FROM public.seat_assignments
                    GROUP BY trip_id
                                 ) sa ON sa.trip_id = t.id
                                 WHERE t.route_id = ?
                   AND DATE(t.departure_datetime) = ?
                   AND t.status IN (?, ?)
                   AND GREATEST(COALESCE(jsonb_array_length(COALESCE(b.seat_map->\'seats\', \'[]\'::jsonb)), 0) - COALESCE(sa.assigned_seats, 0), 0) > 0
                                 ORDER BY t.departure_datetime',
                [$selectedRouteId, $travelDate, 'scheduled', 'active']
            );
        } catch (\Exception $e) {
            Log::error('USSD Trip Fetch Error: '.$e->getMessage());

            return 'END Sorry, trips are temporarily unavailable. Please try again later.';
        }

        $tripOptions = $this->normalizeTripOptions($trips);

        if (empty($tripOptions)) {
            cache()->put("ussd_{$sessionId}_state", 'booking_travel_date', $this->sessionTtlSeconds());

            return 'CON No trips with available seats found for that date. Enter another date (DD-MM-YYYY):';
        }

        cache()->put("ussd_{$sessionId}_trip_options", $tripOptions, $this->sessionTtlSeconds());
        cache()->put("ussd_{$sessionId}_state", 'booking_trip', $this->sessionTtlSeconds());

        $response = "CON Select trip:\n";

        foreach ($tripOptions as $index => $trip) {
            $response .= ($index + 1).'. '.$trip['display_label']."\n";
        }

        $response .= (count($tripOptions) + 1).'. Change travel date';

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
     * Resolve the selected route label from cached route options.
     *
     * @param  string  $sessionId  USSD session identifier.
     * @return string Selected route label or placeholder if not available.
     */
    private function selectedRouteLabel(string $sessionId): string
    {
        $selectedRouteId = cache()->get("ussd_{$sessionId}_selected_route_id");
        $routeOptions = $this->normalizeRouteOptions(cache()->get("ussd_{$sessionId}_route_options", []));

        foreach ($routeOptions as $route) {
            if ((string) ($route['id'] ?? '') === (string) $selectedRouteId) {
                return $route['display_label'];
            }
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
        cache()->forget("ussd_{$sessionId}_route_options");
        cache()->forget("ussd_{$sessionId}_selected_route_id");
        cache()->forget("ussd_{$sessionId}_trip_options");
        cache()->forget("ussd_{$sessionId}_selected_trip_id");
        cache()->forget("ussd_{$sessionId}_passenger_count");
        cache()->forget("ussd_{$sessionId}_travel_date");
        cache()->forget("ussd_{$sessionId}_state");
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
     * Get the most recent USSD input token from the full request payload.
     *
     * USSD gateways typically send the entire path entered so far, so the last token
     * represents the current response for step-based flows.
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
     * Persist a trip booking and return DB-generated ticket details.
     *
     * @param  string  $sessionId  USSD session identifier.
     * @param  string  $phone  Caller MSISDN to attach to passenger rows.
     * @return array{ticket_number: string, seat_label: string}|null
     */
    private function createTripBooking(string $sessionId, string $phone): ?array
    {
        $selectedRouteId = cache()->get("ussd_{$sessionId}_selected_route_id");
        $selectedTripId = cache()->get("ussd_{$sessionId}_selected_trip_id");
        $passengerCount = 1;
        $routeOptions = $this->normalizeRouteOptions(cache()->get("ussd_{$sessionId}_route_options", []));

        if ($selectedRouteId === null || $selectedTripId === null || $passengerCount < 1) {
            Log::error('USSD Booking Persist Error: missing route, trip, or passenger count', [
                'session_id' => $sessionId,
                'selected_route_id' => $selectedRouteId,
                'selected_trip_id' => $selectedTripId,
                'passenger_count' => $passengerCount,
            ]);

            return null;
        }

        $selectedRoute = null;

        foreach ($routeOptions as $routeOption) {
            if ((string) ($routeOption['id'] ?? '') === (string) $selectedRouteId) {
                $selectedRoute = $routeOption;
                break;
            }
        }

        if ($selectedRoute === null || empty($selectedRoute['tenant_id'])) {
            Log::error('USSD Booking Persist Error: selected route not found in cache', [
                'session_id' => $sessionId,
                'selected_route_id' => $selectedRouteId,
            ]);

            return null;
        }

        try {
            return DB::transaction(function () use ($sessionId, $selectedRoute, $selectedRouteId, $selectedTripId, $passengerCount, $phone) {
                $baseFare = (float) ($selectedRoute['base_fare'] ?? 0);
                $totalFare = $baseFare * $passengerCount;
                $passengerName = $this->resolvePassengerFullName($sessionId, $phone);

                $bookingResult = DB::selectOne(
                    'WITH lock_trip AS (
                        SELECT pg_advisory_xact_lock(?::bigint)
                    ),
                    new_booking AS (
                        INSERT INTO public.bookings (tenant_id, trip_id, route_id, booking_type, total_passengers, total_fare, status, is_open_ticket)
                        VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                        RETURNING id
                    ),
                    new_passenger AS (
                        INSERT INTO public.booking_passengers (booking_id, name, contact_phone)
                        SELECT nb.id, ?, ?
                        FROM new_booking nb
                        RETURNING id, ticket_number
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
                        $selectedRoute['tenant_id'],
                        $selectedTripId,
                        $selectedRouteId,
                        'ussd',
                        $passengerCount,
                        $totalFare,
                        'confirmed',
                        false,
                        $passengerName,
                        $phone,
                        $selectedTripId,
                        $selectedTripId,
                        $selectedTripId,
                    ]
                );

                if ($bookingResult === null || empty($bookingResult->seat_label)) {
                    throw new \RuntimeException('No available seats left for this trip.');
                }

                return [
                    'ticket_number' => (string) ($bookingResult->ticket_number ?? 'PENDING'),
                    'seat_label' => (string) $bookingResult->seat_label,
                ];
            });
        } catch (\Exception $e) {
            Log::error('USSD Booking Persist Error: '.$e->getMessage(), [
                'session_id' => $sessionId,
            ]);

            return null;
        }
    }

    /**
     * Resolve a passenger full name for booking passenger rows.
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
     * Resolve session cache TTL with environment override.
     */
    private function sessionTtlSeconds(): int
    {
        return max((int) env('USSD_SESSION_TTL_SECONDS', self::DEFAULT_SESSION_TTL_SECONDS), 300);
    }
}
