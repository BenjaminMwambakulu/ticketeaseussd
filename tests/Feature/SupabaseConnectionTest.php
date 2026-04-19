<?php

use Illuminate\Support\Facades\DB;

it('can connect to supabase database', function () {
    $supabaseUrl = env('SUPABASE_DB_URL') ?: readEnvValue('DB_URL');

    if (! $supabaseUrl) {
        $this->markTestSkipped('Set SUPABASE_DB_URL or DB_URL in .env to run this connectivity test.');
    }

    config()->set('database.connections.supabase_ping', [
        'driver' => 'pgsql',
        'url' => $supabaseUrl,
        'charset' => 'utf8',
        'prefix' => '',
        'prefix_indexes' => true,
        'schema' => 'public',
        'sslmode' => 'prefer',
    ]);

    DB::purge('supabase_ping');

    $result = DB::connection('supabase_ping')->select('select 1 as ok');

    expect($result)->not->toBeEmpty();
    expect((int) $result[0]->ok)->toBe(1);
});

function readEnvValue(string $key): ?string
{
    $envPath = base_path('.env');

    if (! is_file($envPath)) {
        return null;
    }

    $lines = file($envPath, FILE_IGNORE_NEW_LINES | FILE_SKIP_EMPTY_LINES);

    foreach ($lines as $line) {
        $trimmed = trim($line);

        if ($trimmed === '' || str_starts_with($trimmed, '#')) {
            continue;
        }

        if (! str_starts_with($trimmed, $key.'=')) {
            continue;
        }

        $value = substr($trimmed, strlen($key) + 1);

        return trim($value, "\"'");
    }

    return null;
}
