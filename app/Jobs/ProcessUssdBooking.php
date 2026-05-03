<?php

namespace App\Jobs;

use App\Services\SendSmsService;
use Illuminate\Bus\Queueable;
use Illuminate\Contracts\Queue\ShouldQueue;
use Illuminate\Foundation\Bus\Dispatchable;
use Illuminate\Queue\InteractsWithQueue;
use Illuminate\Queue\SerializesModels;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Facades\Hash;
use Illuminate\Support\Facades\Log;
use Illuminate\Support\Str;
use Throwable;

/**
 * Handles the heavy database transaction for USSD bookings in the background.
 * This prevents USSD gateway timeouts by allowing the USSD service to respond immediately.
 */
class ProcessUssdBooking implements ShouldQueue
{
    use Dispatchable, InteractsWithQueue, Queueable, SerializesModels;

    /**
     * The number of times the job may be attempted.
     * Use a relatively low number for USSD to avoid double bookings if not careful,
     * though advisory locks help prevent this.
     */
    public $tries = 1;

    /**
     * The number of seconds the job can run before timing out.
     */
    public $timeout = 60;

    /**
     * Create a new job instance.
     *
     * @param string $sessionId Original USSD session ID for logging/tracking.
     * @param string $phone Passenger contact phone number.
     * @param array $bookingData Contains route_id, trip_id, tenant_id, route_code, travel_date, total_fare, passenger_name.
     */
    public function __construct(
        protected string $sessionId,
        protected string $phone,
        protected array $bookingData
    ) {
        $this->onQueue('bookings');
    }

    /**
     * Execute the job.
     */
    public function handle(SendSmsService $smsService): void
    {
        Log::info('Processing USSD Booking Job', [
            'session_id' => $this->sessionId,
            'phone' => $this->phone,
            'trip_id' => $this->bookingData['trip_id'] ?? 'unknown',
        ]);

        $selectedRouteId = $this->bookingData['route_id'];
        $selectedTripId = $this->bookingData['trip_id'];
        $tenantId = $this->bookingData['tenant_id'];
        $routeCode = $this->bookingData['route_code'];
        $travelDate = $this->bookingData['travel_date'];
        $totalFare = $this->bookingData['total_fare'];
        $passengerCount = (int) ($this->bookingData['passenger_count'] ?? 1);
        $passengerName = (string) ($this->bookingData['passenger_name'] ?? 'Passenger');
        $enteredPin = (string) ($this->bookingData['payment_pin'] ?? '');

        Log::info('Processing USSD booking asynchronously', [
            'session_id' => $this->sessionId,
            'phone' => $this->phone,
            'trip_id' => $selectedTripId,
            'route_id' => $selectedRouteId,
            'tenant_id' => $tenantId,
        ]);

        $profile = DB::selectOne(
            'SELECT id, payment_pin_hash
             FROM public.profiles
             WHERE phone = ? AND (tenant_id = ? OR tenant_id IS NULL)
             ORDER BY created_at DESC
             LIMIT 1',
            [$this->phone, $tenantId]
        );

        Log::debug('Verifying payment PIN for USSD booking', ['phone' => $this->phone, 'session_id' => $this->sessionId]);
        if ($profile === null || empty($profile->payment_pin_hash)) {
            Log::error('USSD Booking Failed: No payment PIN found', ['phone' => $this->phone, 'session_id' => $this->sessionId]);
            throw new \RuntimeException('No payment PIN found for this account.');
        }

        if (! Hash::check($enteredPin, (string) $profile->payment_pin_hash)) {
            Log::error('USSD Booking Failed: Incorrect payment PIN', ['phone' => $this->phone, 'session_id' => $this->sessionId]);
            throw new \RuntimeException('Incorrect payment PIN.');
        }

        Log::info('Starting database transaction for USSD booking', ['session_id' => $this->sessionId]);

        $bookingResult = DB::transaction(function () use (
            $selectedTripId,
            $tenantId,
            $selectedRouteId,
            $passengerCount,
            $totalFare,
            $passengerName
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
                    $this->phone,
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

        // Fetch provider name, bus info, and departure location
        $tripDetails = DB::selectOne(
            'SELECT ten.name as provider_name,
                    b.registration_number as bus_reg,
                    s.stage_name as departure_location
             FROM public.trips t
             LEFT JOIN public.tenants ten ON ten.id = t.tenant_id
             LEFT JOIN public.buses b ON b.id = t.bus_id
             LEFT JOIN public.stages s ON s.id = t.boarding_stage_id
             WHERE t.id = ?',
            [$selectedTripId]
        );

        $providerName = $tripDetails->provider_name ?? 'Provider';
        $busRegistration = $tripDetails->bus_reg ?? 'N/A';
        $departureLocation = $tripDetails->departure_location ?? 'N/A';

        // Format departure time
        $departureTime = 'N/A';
        try {
            $dt = \Illuminate\Support\Carbon::parse($this->bookingData['travel_date']);
            // Get actual trip departure time from database
            $tripTime = DB::selectOne('SELECT departure_datetime FROM public.trips WHERE id = ?', [$selectedTripId]);
            if ($tripTime) {
                $departureTime = \Illuminate\Support\Carbon::parse($tripTime->departure_datetime)->format('H:i');
            }
        } catch (\Exception $e) {
            $departureTime = 'N/A';
        }

        $message = "TicketEase: Booking confirmed for {$passengerName}.\n";
        $message .= "Ticket: {$bookingResult['ticket_number']}\n";
        $message .= "Route: {$routeCode}\n";
        $message .= "Provider: {$providerName}\n";
        $message .= "Bus: {$busRegistration}\n";
        $message .= "Date: {$travelDate} at {$departureTime}\n";
        $message .= "From: {$departureLocation}\n";
        $message .= "Seat: {$bookingResult['seat_label']}\n";
        $message .= "Safe travels!";

        DB::insert(
            'INSERT INTO public.notifications (profile_id, title, message, category, metadata, tenant_id)
             VALUES (?, ?, ?, ?, ?, ?)',
            [
                (string) $profile->id,
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

        try {
            $smsService->send([$this->phone], $message)->throw();
        } catch (Throwable $smsError) {
            Log::warning('USSD booking SMS failed', [
                'session_id' => $this->sessionId,
                'phone' => $this->phone,
                'error' => $smsError->getMessage(),
            ]);
        }

        Log::info('USSD booking job completed', [
            'session_id' => $this->sessionId,
            'ticket' => $bookingResult['ticket_number'],
            'seat' => $bookingResult['seat_label'],
        ]);
    }
}
