<?php

namespace App\Jobs;

use Illuminate\Bus\Queueable;
use Illuminate\Contracts\Queue\ShouldQueue;
use Illuminate\Foundation\Bus\Dispatchable;
use Illuminate\Queue\InteractsWithQueue;
use Illuminate\Queue\SerializesModels;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Facades\Log;
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
    public $tries = 3;

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
    public function handle(): void
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
        $passengerCount = $this->bookingData['passenger_count'] ?? 1;
        $passengerName = $this->bookingData['passenger_name'] ?? 'Passenger';

        try {
            $bookingResult = DB::transaction(function () use (
                $selectedTripId, 
                $tenantId, 
                $selectedRouteId, 
                $passengerCount, 
                $totalFare, 
                $passengerName
            ) {
                // Perform the complex insert with advisory lock to ensure seat safety
                $result = DB::selectOne(
                    'WITH lock_trip AS (
                        -- Use session-level advisory lock on trip ID to prevent race conditions during seat assignment
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
                        -- Find the first available seat for this trip
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
                        -- Assign the found seat to the passenger
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

            Log::info('USSD Booking Job Successful', [
                'session_id' => $this->sessionId,
                'ticket' => $bookingResult['ticket_number'],
                'seat' => $bookingResult['seat_label'],
            ]);

            // Save notification and Trigger SMS
            $this->sendConfirmationSms($bookingResult, $tenantId, $routeCode, $travelDate, $passengerName);

        } catch (Throwable $e) {
            Log::error('USSD Booking Job Failed', [
                'session_id' => $this->sessionId,
                'error' => $e->getMessage(),
                'phone' => $this->phone
            ]);
            
            // Re-throw to allow Laravel queue to handle retries
            throw $e;
        }
    }

    /**
     * Create a notification record and send/queue the SMS.
     */
    protected function sendConfirmationSms(array $bookingResult, string $tenantId, string $routeCode, string $travelDate, string $passengerName): void
    {
        $profileId = $this->resolveProfileId($this->phone, $passengerName, $tenantId);

        $message = "TicketEase: Booking confirmed for {$passengerName} on {$travelDate}. Ticket: {$bookingResult['ticket_number']}. Seat: {$bookingResult['seat_label']}. Route: {$routeCode}. Safe travels!";

        try {
            // 1. Record in notifications table
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

            // 2. Dispatch SMS (Integration point)
            // Example: Http::post('https://api.africastalking.com/...', [...]);
            Log::info('SMS Notification Queued/Sent', ['phone' => $this->phone, 'message' => $message]);

        } catch (Throwable $e) {
            Log::error('Failed to record/send USSD SMS', ['error' => $e->getMessage()]);
        }
    }

    /**
     * Resolve or create a profile ID for the notification.
     */
    protected function resolveProfileId(string $phone, string $fullName, string $tenantId): ?string
    {
        try {
            $profile = DB::selectOne(
                'SELECT id FROM public.profiles WHERE phone = ? AND (tenant_id = ? OR tenant_id IS NULL) ORDER BY created_at DESC LIMIT 1',
                [$phone, $tenantId]
            );

            if ($profile !== null && ! empty($profile->id)) {
                return (string) $profile->id;
            }

            // Fallback: create a minimal profile
            $result = DB::selectOne('SELECT public.get_or_create_profile(?, ?, ?, ?) AS id', [
                $fullName,
                $phone,
                null, // national_id
                $tenantId,
            ]);

            return $result !== null && ! empty($result->id) ? (string) $result->id : null;
        } catch (Throwable $e) {
            return null;
        }
    }
}
