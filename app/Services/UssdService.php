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

            cache()->put("ussd_{$sessionId}_state", 'menu', 300);
            cache()->put("ussd_{$sessionId}_phone", $phoneNumber, 300);

            return $response;
        }

        if ($state === 'menu') {
            $choice = $userInput[0] ?? '';

            if ($choice == '1') {
                return $this->startBooking($sessionId, $phoneNumber);
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
            cache()->put("ussd_{$sessionId}_reg_step", 2, 300);

            return 'CON Enter your Full Name:';
        }

        if ($step == 2) {
            $fullName = $this->currentInputValue($userInput);
            cache()->put("ussd_{$sessionId}_full_name", $fullName, 300);
            cache()->put("ussd_{$sessionId}_reg_step", 3, 300);

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
        cache()->put("ussd_{$sessionId}_state", 'booking_route', 300);
        cache()->put("ussd_{$sessionId}_phone", $phone, 300);

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

        cache()->put("ussd_{$sessionId}_route_options", $routeOptions, 300);
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
                cache()->put("ussd_{$sessionId}_state", 'menu', 300);

                return "CON Welcome to TicketEase!\n\n1. Book Ticket\n2. My Bookings\n3. Check Ticket\n4. Cancel Ticket\n5. Register Account\n6. Exit";
            }

            if ($selectedIndex < 1 || $selectedIndex > count($routeOptions)) {
                return $this->startBooking($sessionId, $phone);
            }

            $selectedRoute = $routeOptions[$selectedIndex - 1];

            cache()->put("ussd_{$sessionId}_selected_route_id", $selectedRoute['id'], 300);
            cache()->put("ussd_{$sessionId}_state", 'booking_passengers', 300);

            return 'CON Selected: '.$selectedRoute['display_label']."\nEnter number of passengers:";
        }

        if ($state === 'booking_passengers') {
            $passengerCount = (int) $this->currentInputValue($userInput);

            if ($passengerCount < 1 || $passengerCount > 10) {
                return 'CON Enter number of passengers (1-10):';
            }

            cache()->put("ussd_{$sessionId}_passenger_count", $passengerCount, 300);
            cache()->put("ussd_{$sessionId}_state", 'booking_travel_date', 300);

            return 'CON Enter travel date (YYYY-MM-DD):';
        }

        if ($state === 'booking_travel_date') {
            $travelDateInput = $this->currentInputValue($userInput);

            if (! preg_match('/^\d{4}-\d{2}-\d{2}$/', $travelDateInput)) {
                return 'CON Invalid date format. Enter as YYYY-MM-DD:';
            }

            try {
                $travelDate = Carbon::createFromFormat('Y-m-d', $travelDateInput)->startOfDay();
            } catch (\Exception $e) {
                return 'CON Invalid date. Enter travel date as YYYY-MM-DD:';
            }

            if ($travelDate->lt(Carbon::today())) {
                return 'CON Travel date cannot be in the past. Enter YYYY-MM-DD:';
            }

            cache()->put("ussd_{$sessionId}_travel_date", $travelDate->toDateString(), 300);

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
                cache()->put("ussd_{$sessionId}_state", 'booking_travel_date', 300);

                return 'CON Enter travel date (YYYY-MM-DD):';
            }

            if ($selectedIndex < 1 || $selectedIndex > count($tripOptions)) {
                return $this->startTripSelection($sessionId);
            }

            $selectedTrip = $tripOptions[$selectedIndex - 1];

            cache()->put("ussd_{$sessionId}_selected_trip_id", $selectedTrip['id'], 300);
            cache()->put("ussd_{$sessionId}_state", 'booking_confirm', 300);

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
                    'ticket_number' => $bookingResult['ticket_number'],
                ]);

                $this->clearBookingSessionData($sessionId);

                return "END Booking confirmed!\nTicket: {$bookingResult['ticket_number']}";
            }

            if ($confirmationChoice === '2') {
                $this->clearBookingSessionData($sessionId);

                return 'END Booking cancelled. Thank you for using TicketEase.';
            }

            return "CON Invalid option.\n"
                .$this->bookingSummary($sessionId)
                ."\n1. Confirm\n2. Cancel";
        }

        return 'CON Feature coming soon...';
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
            cache()->put("ussd_{$sessionId}_state", 'booking_route', 300);

            return 'CON Booking session expired. Please select route again.';
        }

        try {
            $trips = DB::select(
                'SELECT id, departure_datetime, status
                 FROM public.trips
                 WHERE route_id = ?
                   AND DATE(departure_datetime) = ?
                   AND status IN (?, ?)
                 ORDER BY departure_datetime',
                [$selectedRouteId, $travelDate, 'scheduled', 'active']
            );
        } catch (\Exception $e) {
            Log::error('USSD Trip Fetch Error: '.$e->getMessage());

            return 'END Sorry, trips are temporarily unavailable. Please try again later.';
        }

        $tripOptions = $this->normalizeTripOptions($trips);

        if (empty($tripOptions)) {
            cache()->put("ussd_{$sessionId}_state", 'booking_travel_date', 300);

            return 'CON No trips found for that date. Enter another date (YYYY-MM-DD):';
        }

        cache()->put("ussd_{$sessionId}_trip_options", $tripOptions, 300);
        cache()->put("ussd_{$sessionId}_state", 'booking_trip', 300);

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
     * @return array<int, array{id: int|string, departure_datetime: string, status: string, display_label: string}>
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

            $normalizedTrips[] = [
                'id' => $trip['id'] ?? null,
                'departure_datetime' => $departureDatetime,
                'status' => (string) ($trip['status'] ?? ''),
                'display_label' => $this->tripDisplayLabel($departureDatetime, $status),
            ];
        }

        return $normalizedTrips;
    }

    /**
     * Build a short human-readable trip label for USSD menus.
     *
     * @param  string  $departureDatetime  Departure timestamp.
     * @param  string  $status  Trip status label.
     * @return string Menu label for one trip option.
     */
    private function tripDisplayLabel(string $departureDatetime, string $status): string
    {
        try {
            $departure = Carbon::parse($departureDatetime)->format('H:i');
        } catch (\Exception $e) {
            $departure = 'Unknown time';
        }

        return $departure.' ('.$status.')';
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
     * @return array{ticket_number: string}|null
     */
    private function createTripBooking(string $sessionId, string $phone): ?array
    {
        $selectedRouteId = cache()->get("ussd_{$sessionId}_selected_route_id");
        $selectedTripId = cache()->get("ussd_{$sessionId}_selected_trip_id");
        $passengerCount = (int) cache()->get("ussd_{$sessionId}_passenger_count", 0);
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

                $booking = DB::selectOne(
                    'INSERT INTO public.bookings (tenant_id, trip_id, route_id, booking_type, total_passengers, total_fare, status, is_open_ticket)
                     VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                     RETURNING id',
                    [
                        $selectedRoute['tenant_id'],
                        $selectedTripId,
                        $selectedRouteId,
                        'ussd',
                        $passengerCount,
                        $totalFare,
                        'confirmed',
                        false,
                    ]
                );

                $firstPassenger = null;

                for ($i = 1; $i <= $passengerCount; $i++) {
                    $passenger = DB::selectOne(
                        'INSERT INTO public.booking_passengers (booking_id, name, contact_phone)
                         VALUES (?, ?, ?)
                         RETURNING id, ticket_number',
                        [
                            $booking->id,
                            $passengerName,
                            $phone,
                        ]
                    );

                    if ($firstPassenger === null) {
                        $firstPassenger = $passenger;
                    }
                }

                return [
                    'ticket_number' => (string) ($firstPassenger->ticket_number ?? 'PENDING'),
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
}
