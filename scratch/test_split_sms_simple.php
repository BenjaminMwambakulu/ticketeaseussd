<?php

require __DIR__ . '/../vendor/autoload.php';

$app = require_once __DIR__ . '/../bootstrap/app.php';
$kernel = $app->make(Illuminate\Contracts\Console\Kernel::class);
$kernel->bootstrap();

use App\Services\SendSmsService;

// Change this to your test phone number
$testPhone = '+265884244453';

echo "Testing SMS Splitting - Sending split message...\n\n";

$sms = new SendSmsService();

// This message is 195 chars and will be split into 2 parts
$message = "TicketEase Booking Details:\n";
$message .= "Ticket: TE-123456\n";
$message .= "Route: Blantyre-Lilongwe\n";
$message .= "Provider: AXA Coach\n";
$message .= "Bus: KAB 123\n";
$message .= "Date: 15-05-2024 at 08:30\n";
$message .= "From: Blantyre Bus Depot\n";
$message .= "Seat: A1\n";
$message .= "Status: CONFIRMED\n";
$message .= "Safe travels!";

echo "Message length: " . strlen($message) . " characters\n";
echo "Expected: Will be split into 2 SMS parts\n";
echo "Sending to: {$testPhone}\n\n";

try {
    $response = $sms->send([$testPhone], $message);
    
    echo "✅ SMS Sent Successfully!\n";
    
    // Handle both single response and array of responses
    if (is_array($response)) {
        echo "Message was split into " . count($response) . " parts\n";
        foreach ($response as $index => $partResponse) {
            echo "Part " . ($index + 1) . " - Status: " . $partResponse->status() . "\n";
        }
        echo "\nCheck your phone - you should receive " . count($response) . " messages with sequence indicators.\n";
    } else {
        echo "Status Code: " . $response->status() . "\n";
        echo "Response Body: " . $response->body() . "\n";
        echo "\nCheck your phone for the message.\n";
    }
} catch (\Exception $e) {
    echo "❌ Failed to send SMS\n";
    echo "Error: " . $e->getMessage() . "\n";
}
