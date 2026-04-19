<?php

namespace App\Http\Controllers;

use App\Services\UssdService;
use Illuminate\Http\Request;

class UssdController extends Controller
{
    public function handle(Request $request, UssdService $ussdService)
    {
        $response = $ussdService->handle($request);

        return response($response, 200)
            ->header('Content-Type', 'text/plain');
    }
}
