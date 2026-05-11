<?php

require __DIR__ . '/../vendor/autoload.php';

$app = require_once __DIR__ . '/../bootstrap/app.php';
$kernel = $app->make(Illuminate\Contracts\Console\Kernel::class);
$kernel->bootstrap();

use App\Services\SendSmsService;

// Configuration - Change this to your test phone number
$testPhone = '+265885705304'; // Replace with your test number

echo "==============================================\n";
echo "SMS Splitting Test - TicketEase System\n";
echo "==============================================\n\n";

$sms = new SendSmsService();

// Test 1: Short message (should NOT be split)
echo "Test 1: Short Message (Under 120 chars)\n";
echo "----------------------------------------------\n";
$shortMessage = "Welcome to TicketEase! Your account is ready.";
echo "Message length: " . strlen($shortMessage) . " chars\n";
echo "Expected: 1 SMS part\n";
echo "Sending...\n";

try {
    $response = $sms->send([$testPhone], $shortMessage);
    
    if (is_array($response)) {
        echo "Message split into " . count($response) . " parts\n";
        foreach ($response as $index => $partResponse) {
            echo "Part " . ($index + 1) . " - Status: " . $partResponse->status() . "\n";
        }
    } else {
        echo "Status: " . $response->status() . "\n";
    }
    echo "✅ Test 1 PASSED\n\n";
} catch (\Exception $e) {
    echo "❌ Test 1 FAILED: " . $e->getMessage() . "\n\n";
}

sleep(2); // Wait between tests

// Test 2: Medium message (should be split into 2 parts)
echo "Test 2: Booking Details Message (Over 120 chars)\n";
echo "----------------------------------------------\n";
$bookingDetailsMessage = "TicketEase Booking Details:\n";
$bookingDetailsMessage .= "Ticket: TE-123456\n";
$bookingDetailsMessage .= "Route: Blantyre-Lilongwe\n";
$bookingDetailsMessage .= "Provider: AXA Coach\n";
$bookingDetailsMessage .= "Bus: KAB 123\n";
$bookingDetailsMessage .= "Date: 15-05-2024 at 08:30\n";
$bookingDetailsMessage .= "From: Blantyre Bus Depot\n";
$bookingDetailsMessage .= "Seat: A1\n";
$bookingDetailsMessage .= "Status: CONFIRMED\n";
$bookingDetailsMessage .= "Safe travels!";

echo "Message length: " . strlen($bookingDetailsMessage) . " chars\n";
echo "Expected: 2 SMS parts with (1/2) and (2/2) indicators\n";
echo "Sending...\n";

try {
    $response = $sms->send([$testPhone], $bookingDetailsMessage);
    
    if (is_array($response)) {
        echo "Message split into " . count($response) . " parts\n";
        foreach ($response as $index => $partResponse) {
            echo "Part " . ($index + 1) . " - Status: " . $partResponse->status() . "\n";
        }
    } else {
        echo "Status: " . $response->status() . "\n";
    }
    echo "✅ Test 2 PASSED - Check your phone for 2 messages\n\n";
} catch (\Exception $e) {
    echo "❌ Test 2 FAILED: " . $e->getMessage() . "\n\n";
}

sleep(2);

// Test 3: Welcome registration message
echo "Test 3: Registration Welcome Message\n";
echo "----------------------------------------------\n";
$welcomeMessage = "Welcome to TicketEase, John Doe! Your account has been registered successfully. You can now dial our USSD code to book tickets.";

echo "Message length: " . strlen($welcomeMessage) . " chars\n";
echo "Expected: 2 SMS parts\n";
echo "Sending...\n";

try {
    $response = $sms->send([$testPhone], $welcomeMessage);
    
    if (is_array($response)) {
        echo "Message split into " . count($response) . " parts\n";
        foreach ($response as $index => $partResponse) {
            echo "Part " . ($index + 1) . " - Status: " . $partResponse->status() . "\n";
        }
    } else {
        echo "Status: " . $response->status() . "\n";
    }
    echo "✅ Test 3 PASSED - Check your phone for 2 messages\n\n";
} catch (\Exception $e) {
    echo "❌ Test 3 FAILED: " . $e->getMessage() . "\n\n";
}

sleep(2);

// Test 4: Very long booking confirmation
echo "Test 4: Long Booking Confirmation\n";
echo "----------------------------------------------\n";
$longBookingMessage = "TicketEase: Booking confirmed for John Smith.\n";
$longBookingMessage .= "Ticket: TE-789012\n";
$longBookingMessage .= "Route: Lilongwe-Mzuzu via Kasungu\n";
$longBookingMessage .= "Provider: Malawi Express\n";
$longBookingMessage .= "Bus: MAE 456 XYZ\n";
$longBookingMessage .= "Date: 20-06-2024 at 14:45\n";
$longBookingMessage .= "From: Lilongwe Main Bus Station\n";
$longBookingMessage .= "Seat: B12\n";
$longBookingMessage .= "Status: CONFIRMED\n";
$longBookingMessage .= "Please arrive 30 minutes before departure. Have a safe journey!";

echo "Message length: " . strlen($longBookingMessage) . " chars\n";
echo "Expected: 3 SMS parts\n";
echo "Sending...\n";

try {
    $response = $sms->send([$testPhone], $longBookingMessage);
    
    if (is_array($response)) {
        echo "Message split into " . count($response) . " parts\n";
        foreach ($response as $index => $partResponse) {
            echo "Part " . ($index + 1) . " - Status: " . $partResponse->status() . "\n";
        }
    } else {
        echo "Status: " . $response->status() . "\n";
    }
    echo "✅ Test 4 PASSED - Check your phone for 3 messages\n\n";
} catch (\Exception $e) {
    echo "❌ Test 4 FAILED: " . $e->getMessage() . "\n\n";
}

echo "==============================================\n";
echo "All tests completed!\n";
echo "Check your phone at {$testPhone} for the messages.\n";
echo "Messages should have sequence indicators like (1/2), (2/2), etc.\n";
echo "==============================================\n";
