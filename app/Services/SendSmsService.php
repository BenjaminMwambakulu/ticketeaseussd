<?php

namespace App\Services;

use Illuminate\Support\Facades\Http;

class SendSmsService {

    private const BASE_URL = 'https://api.textbee.dev/api/v1';

    private string $apiKey;
    private string $deviceId;
    private string $baseUrl;

    public function __construct()
    {
        $this->apiKey = config('services.textbee.api_key');
        $this->deviceId = config('services.textbee.device_id');
        $this->baseUrl = rtrim((string) config('services.textbee.base_url', self::BASE_URL), '/');
    }

    /**
     * Send SMS via TextBee API
     */
    public function send(array $recipients, string $message)
    {
        $response = Http::timeout((int) config('services.textbee.timeout_seconds', 15))
            ->connectTimeout((int) config('services.textbee.connect_timeout_seconds', 10))
            ->retry((int) config('services.textbee.http_retries', 1), 200)
            ->withHeaders([
                'x-api-key' => $this->apiKey,
                'Content-Type' => 'application/json',
            ])->post(
                $this->baseUrl . "/gateway/devices/{$this->deviceId}/send-sms",
                [
                    'recipients' => $recipients,
                    'message' => $message,
                ]
            );

        \Illuminate\Support\Facades\Log::info('TextBee SMS Response', [
            'status' => $response->status(),
            'body' => $response->json(),
            'recipients' => $recipients
        ]);

        return $response;
    }
}