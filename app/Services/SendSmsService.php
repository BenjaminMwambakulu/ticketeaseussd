<?php

namespace App\Services;

use Illuminate\Support\Facades\Http;
use Illuminate\Support\Facades\Log;

class SendSmsService
{
    private const BASE_URL = 'https://api.httpsms.com/v1';

    private string $apiKey;
    private string $baseUrl;

    public function __construct()
    {
        $this->apiKey  = config('services.textbee.api_key');
        $this->baseUrl = rtrim((string) config('services.textbee.base_url', self::BASE_URL), '/');
    }

    public function send(array $recipients, string $message)
    {
        $responses = [];

        foreach ($recipients as $to) {
            $response = Http::timeout(15)
                ->connectTimeout(10)
                ->retry(2, 300)
                ->withHeaders([
                    'x-api-key'     => $this->apiKey,
                    'Content-Type'  => 'application/json',
                    'Accept'        => 'application/json',
                ])
                ->post("{$this->baseUrl}/messages/send", [
                    'content' => $message,
                    'from'    => config('services.textbee.from_number'), // ← Very important
                    'to'      => $to,
                ]);

            Log::info('httpSMS Send Response', [
                'status'    => $response->status(),
                'body'      => $response->json(),
                'to'        => $to,
                'full_url'  => "{$this->baseUrl}/messages/send",   // For debugging
            ]);

            $responses[] = $response;
        }

        return count($responses) === 1 ? $responses[0] : $responses;
    }
}