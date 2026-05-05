<?php

require __DIR__ . '/../vendor/autoload.php';

$app = require_once __DIR__ . '/../bootstrap/app.php';
$app->make(\Illuminate\Contracts\Console\Kernel::class)->bootstrap();

use App\Services\SendSmsService;

// Create a reflection to access the private splitMessage method
$smsService = new SendSmsService();
$reflection = new ReflectionClass($smsService);
$method = $reflection->getMethod('splitMessage');
$method->setAccessible(true);

echo "Testing SMS Message Splitting\n";
echo str_repeat("=", 80) . "\n\n";

// Test 1: Short message (under 160 chars)
$shortMessage = "Welcome to TicketEase! Your account has been registered successfully.";
$result = $method->invoke($smsService, $shortMessage);
echo "Test 1: Short Message (" . strlen($shortMessage) . " chars)\n";
echo "Parts: " . count($result) . "\n";
echo "Content: " . $result[0] . "\n\n";

// Test 2: Medium message (around 160 chars)
$mediumMessage = "TicketEase: Booking confirmed for John Doe on 2024-05-15. Ticket: TE-123456. Seat: A1. Route: BLZ-LMW. Safe travels!";
$result = $method->invoke($smsService, $mediumMessage);
echo "Test 2: Medium Message (" . strlen($mediumMessage) . " chars)\n";
echo "Parts: " . count($result) . "\n";
foreach ($result as $i => $part) {
    echo "Part " . ($i + 1) . " (" . strlen($part) . " chars): " . $part . "\n";
}
echo "\n";

// Test 3: Long message (over 160 chars - booking details)
$longMessage = "TicketEase Booking Details:\n";
$longMessage .= "Ticket: TE-123456\n";
$longMessage .= "Route: Blantyre-Lilongwe\n";
$longMessage .= "Provider: AXA Coach\n";
$longMessage .= "Bus: KAB 123\n";
$longMessage .= "Date: 15-05-2024 at 08:30\n";
$longMessage .= "From: Blantyre Bus Depot\n";
$longMessage .= "Seat: A1\n";
$longMessage .= "Status: CONFIRMED\n";
$longMessage .= "Safe travels!";

$result = $method->invoke($smsService, $longMessage);
echo "Test 3: Long Message (" . strlen($longMessage) . " chars)\n";
echo "Parts: " . count($result) . "\n";
foreach ($result as $i => $part) {
    echo "Part " . ($i + 1) . " (" . strlen($part) . " chars):\n" . $part . "\n\n";
}

// Test 4: Very long message (over 320 chars)
$veryLongMessage = "TicketEase: Booking confirmed for John Smith.\n";
$veryLongMessage .= "Ticket: TE-789012\n";
$veryLongMessage .= "Route: Lilongwe-Mzuzu via Kasungu\n";
$veryLongMessage .= "Provider: Malawi Express\n";
$veryLongMessage .= "Bus: MAE 456 XYZ\n";
$veryLongMessage .= "Date: 20-06-2024 at 14:45\n";
$veryLongMessage .= "From: Lilongwe Main Bus Station\n";
$veryLongMessage .= "Seat: B12\n";
$veryLongMessage .= "Status: CONFIRMED\n";
$veryLongMessage .= "Please arrive 30 minutes before departure. Have a safe journey!";

$result = $method->invoke($smsService, $veryLongMessage);
echo "Test 4: Very Long Message (" . strlen($veryLongMessage) . " chars)\n";
echo "Parts: " . count($result) . "\n";
foreach ($result as $i => $part) {
    echo "Part " . ($i + 1) . " (" . strlen($part) . " chars):\n" . $part . "\n\n";
}

echo "\nAll tests completed!\n";
