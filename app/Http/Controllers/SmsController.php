<?php

namespace App\Http\Controllers;

use App\Services\SendSmsService;
use Illuminate\Http\Request;
use Illuminate\Support\Facades\Log;

class SmsController extends Controller
{
    public function sendTripUpdate(Request $request, SendSmsService $smsService)
    {
        $request->validate([
            'recipients' => 'required|array',
            'recipients.*' => 'required|string',
            'message' => 'required|string',
        ]);

        $recipients = collect($request->input('recipients'))->map(function ($phone) {
            // Remove any non-numeric characters
            $phone = preg_replace('/[^0-9]/', '', $phone);

            // If starts with 0, replace with 265
            if (str_starts_with($phone, '0')) {
                return '265' . substr($phone, 1);
            }

            // If it's already 9 digits (Malawi local without 0), prepend 265
            if (strlen($phone) === 9) {
                return '265' . $phone;
            }

            return $phone;
        })->toArray();

        $message = $request->input('message');


        try {
            Log::info('Sending Trip Update SMS', [
                'recipient_count' => count($recipients),
                'message' => $message
            ]);

            $response = $smsService->send($recipients, $message);

            if ($response->successful()) {
                return response()->json([
                    'success' => true,
                    'message' => 'SMS sent successfully',
                    'data' => $response->json()
                ]);
            }

            Log::error('Failed to send SMS via TextBee', [
                'status' => $response->status(),
                'body' => $response->body()
            ]);

            return response()->json([
                'success' => false,
                'message' => 'Failed to send SMS',
                'error' => $response->json()
            ], 500);

        } catch (\Exception $e) {
            Log::error('Exception during SMS sending', [
                'error' => $e->getMessage()
            ]);

            return response()->json([
                'success' => false,
                'message' => 'An error occurred while sending SMS',
                'error' => $e->getMessage()
            ], 500);
        }
    }
}
