<?php

require __DIR__ . '/../vendor/autoload.php';

$app = require_once __DIR__ . '/../bootstrap/app.php';
$kernel = $app->make(Illuminate\Contracts\Console\Kernel::class);
$kernel->bootstrap();

use App\Services\SendSmsService;

$sms = new SendSmsService();
$response = $sms->send(['+265986026135'], 'Test SMS from TicketEase System Debugger');

echo "Status: " . $response->status() . "\n";
echo "Body: " . $response->body() . "\n";
