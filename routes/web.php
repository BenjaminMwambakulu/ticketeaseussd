<?php

use App\Http\Controllers\LogViewerController;
use App\Http\Controllers\UssdController;
use Illuminate\Support\Facades\Route;

Route::get('/', function () {
    return view('welcome');
});

Route::post('/ussd', [UssdController::class, 'handle']);

// Log Viewer Routes
Route::prefix('logs')->name('logs.')->group(function () {
    Route::get('/', [LogViewerController::class, 'index'])->name('index');
    Route::post('/clear', [LogViewerController::class, 'clear'])->name('clear');
    Route::get('/download', [LogViewerController::class, 'download'])->name('download');
});