<?php

return [

    /*
    |--------------------------------------------------------------------------
    | Third Party Services
    |--------------------------------------------------------------------------
    |
    | This file is for storing the credentials for third party services such
    | as Mailgun, Postmark, AWS and more. This file provides the de facto
    | location for this type of information, allowing packages to have
    | a conventional file to locate the various service credentials.
    |
    */

    'postmark' => [
        'key' => env('POSTMARK_API_KEY'),
    ],

    'resend' => [
        'key' => env('RESEND_API_KEY'),
    ],

    'ses' => [
        'key' => env('AWS_ACCESS_KEY_ID'),
        'secret' => env('AWS_SECRET_ACCESS_KEY'),
        'region' => env('AWS_DEFAULT_REGION', 'us-east-1'),
    ],

    'slack' => [
        'notifications' => [
            'bot_user_oauth_token' => env('SLACK_BOT_USER_OAUTH_TOKEN'),
            'channel' => env('SLACK_BOT_USER_DEFAULT_CHANNEL'),
        ],
    ],

    'textbee' => [
        'api_key' => env('TEXTBEE_API_KEY'),
        'base_url' => env('TEXTBEE_BASE_URL'),
        'device_id' => env('TEXTBEE_DEVICE_ID'),
        'timeout_seconds' => env('TEXTBEE_TIMEOUT_SECONDS', 5),
        'connect_timeout_seconds' => env('TEXTBEE_CONNECT_TIMEOUT_SECONDS', 2),
        'http_retries' => env('TEXTBEE_HTTP_RETRIES', 1),
        'from_number' => '+265884244453'
    ],

];
