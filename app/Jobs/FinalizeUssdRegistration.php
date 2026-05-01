<?php

namespace App\Jobs;

use Illuminate\Bus\Queueable;
use Illuminate\Contracts\Queue\ShouldQueue;
use Illuminate\Foundation\Bus\Dispatchable;
use Illuminate\Queue\InteractsWithQueue;
use Illuminate\Queue\SerializesModels;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Facades\Hash;
use Illuminate\Support\Facades\Log;

/**
 * Handles PIN hashing and profile finalization for USSD registration in the background.
 * This prevents USSD gateway timeouts by allowing the USSD service to respond immediately
 * after profile creation, while the expensive Hash::make() operation runs asynchronously.
 */
class FinalizeUssdRegistration implements ShouldQueue
{
    use Dispatchable, InteractsWithQueue, Queueable, SerializesModels;

    /**
     * The number of times the job may be attempted.
     */
    public $tries = 2;

    /**
     * The number of seconds the job can run before timing out.
     */
    public $timeout = 30;

    /**
     * Create a new job instance.
     *
     * @param string $sessionId USSD session ID for logging.
     * @param string $phone User's phone number.
     * @param string $fullName User's full name.
     * @param string $nationalId User's national ID.
     * @param string $pin The plain-text 4-digit payment PIN to hash and store.
     */
    public function __construct(
        protected string $sessionId,
        protected string $phone,
        protected string $fullName,
        protected string $nationalId,
        protected string $pin
    ) {
        $this->onQueue('registrations');
    }

    /**
     * Execute the job.
     */
    public function handle(\App\Services\SendSmsService $smsService): void
    {
        Log::info('Finalizing USSD Registration', [
            'session_id' => $this->sessionId,
            'phone' => $this->phone,
            'full_name' => $this->fullName,
        ]);

        try {
            // Get or create the profile
            $profileResult = DB::selectOne('SELECT public.get_or_create_profile(?, ?, ?, NULL) as id', [
                $this->fullName, $this->phone, $this->nationalId,
            ]);

            if ($profileResult === null || empty($profileResult->id)) {
                Log::error('USSD Registration Failed: Could not create profile', [
                    'session_id' => $this->sessionId,
                    'phone' => $this->phone,
                ]);
                return;
            }

            // Hash the PIN and update the profile (expensive operation)
            DB::update('UPDATE public.profiles SET payment_pin_hash = ?, updated_at = NOW() WHERE id = ?', [
                Hash::make($this->pin),
                (string) $profileResult->id,
            ]);

            Log::info('USSD Registration Finalized Successfully', [
                'session_id' => $this->sessionId,
                'phone' => $this->phone,
                'full_name' => $this->fullName,
                'national_id' => $this->nationalId,
                'profile_id' => $profileResult->id,
                'db_operation' => 'get_or_create_profile + hash_pin',
                'status' => 'success'
            ]);

            // Send welcome SMS
            $message = "Welcome to TicketEase, {$this->fullName}! Your account has been registered successfully. You can now dial our USSD code to book tickets.";
            
            try {
                $smsService->send([$this->phone], $message)->throw();
            } catch (\Throwable $smsError) {
                Log::warning('USSD registration SMS failed', [
                    'session_id' => $this->sessionId,
                    'phone' => $this->phone,
                    'error' => $smsError->getMessage(),
                ]);
            }
        } catch (\Exception $e) {
            Log::error('USSD Registration Finalization Error: ' . $e->getMessage(), [
                'session_id' => $this->sessionId,
                'phone' => $this->phone,
                'exception' => $e,
            ]);
        }
    }
}
