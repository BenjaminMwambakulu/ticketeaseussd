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

    /**
     * Send SMS message(s) to recipients.
     * Automatically splits messages exceeding 160 characters into multiple parts.
     *
     * @param array $recipients Array of phone numbers
     * @param string $message The message content
     * @return mixed Single response or array of responses
     */
    public function send(array $recipients, string $message)
    {
        $responses = [];
        $originalLength = strlen($message);

        foreach ($recipients as $to) {
            // Split message if it exceeds 160 characters
            $messageParts = $this->splitMessage($message);

            if (count($messageParts) > 1) {
                Log::info('SMS Message Split', [
                    'to' => $to,
                    'original_length' => $originalLength,
                    'total_parts' => count($messageParts),
                    'parts_lengths' => array_map('strlen', $messageParts),
                ]);
            }

            foreach ($messageParts as $part) {
                $response = Http::timeout(15)
                    ->connectTimeout(10)
                    ->retry(2, 300)
                    ->withHeaders([
                        'x-api-key'     => $this->apiKey,
                        'Content-Type'  => 'application/json',
                        'Accept'        => 'application/json',
                    ])
                    ->post("{$this->baseUrl}/messages/send", [
                        'content' => $part,
                        'from'    => config('services.textbee.from_number'),
                        'to'      => $to,
                    ]);

                Log::info('httpSMS Send Response', [
                    'status'    => $response->status(),
                    'body'      => $response->json(),
                    'to'        => $to,
                    'full_url'  => "{$this->baseUrl}/messages/send",
                    'part_length' => strlen($part),
                    'total_parts' => count($messageParts),
                ]);

                $responses[] = $response;
            }
        }

        return count($responses) === 1 ? $responses[0] : $responses;
    }

    /**
     * Split a message into parts if it exceeds 160 characters.
     * Each part will be prefixed with a sequence indicator if there are multiple parts.
     * Uses 120 character limit per part for maximum delivery reliability.
     *
     * @param string $message The original message
     * @return array Array of message parts
     */
    private function splitMessage(string $message): array
    {
        $maxLength = 120; // Reduced for maximum reliability

        if (strlen($message) <= $maxLength) {
            return [$message];
        }

        // Split by newlines first to preserve formatting
        $lines = explode("\n", $message);
        $parts = [];
        $currentPart = '';

        foreach ($lines as $line) {
            // If adding this line would exceed the limit
            if (strlen($currentPart . ($currentPart ? "\n" : '') . $line) > $maxLength) {
                // Save current part if not empty
                if (!empty($currentPart)) {
                    $parts[] = $currentPart;
                    $currentPart = '';
                }

                // If single line exceeds limit, split it by words
                if (strlen($line) > $maxLength) {
                    $words = explode(' ', $line);
                    foreach ($words as $word) {
                        if (strlen($currentPart . ($currentPart ? ' ' : '') . $word) > $maxLength) {
                            if (!empty($currentPart)) {
                                $parts[] = $currentPart;
                            }
                            $currentPart = $word;
                        } else {
                            $currentPart .= ($currentPart ? ' ' : '') . $word;
                        }
                    }
                } else {
                    $currentPart = $line;
                }
            } else {
                $currentPart .= ($currentPart ? "\n" : '') . $line;
            }
        }

        // Add the last part
        if (!empty($currentPart)) {
            $parts[] = $currentPart;
        }

        // If we have multiple parts, add sequence indicators
        if (count($parts) > 1) {
            $totalParts = count($parts);
            $numberedParts = [];
            foreach ($parts as $index => $part) {
                $partNumber = $index + 1;
                $numberedParts[] = "({$partNumber}/{$totalParts}) {$part}";
            }
            return $numberedParts;
        }

        return $parts;
    }
}