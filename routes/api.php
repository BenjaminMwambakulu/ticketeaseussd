<?php

use Illuminate\Http\Request;
use Illuminate\Support\Facades\Route;

Route::get('/user', function (Request $request) {
    return $request->user();
})->middleware('auth:sanctum');

Route::post('/sms/send-trip-update', [\App\Http\Controllers\SmsController::class, 'sendTripUpdate']);

