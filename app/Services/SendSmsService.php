<?php

namespace App\Services;

use Illuminate\Support\Facades\Http;

class SendSmsService {

    private const BASE_URL = 'https://api.textbee.dev/api/v1';

    private string $apiKey;
    private string $deviceId;

    public function __construct()
    {
        $this->apiKey = config('services.textbee.api_key');
        $this->deviceId = config('services.textbee.device_id');
    }

    /**
     * Send SMS via TextBee API
     */
    public function send(array $recipients, string $message)
    {
        return Http::withHeaders([
            'x-api-key' => $this->apiKey,
            'Content-Type' => 'application/json',
        ])->post(
            self::BASE_URL . "/gateway/devices/{$this->deviceId}/send-sms",
            [
                'recipients' => $recipients,
                'message' => $message,
            ]
        );
    }
}