<?php

namespace App\Queue\Middleware;

use Illuminate\Support\Facades\Cache;
use Illuminate\Support\Facades\Log;

class TrackJobExecution
{
    /**
     * Process the queued job.
     *
     * @param  mixed  $job
     * @param  callable  $next
     * @return mixed
     */
    public function handle($job, $next)
    {
        $jobName = get_class($job);
        $startTime = microtime(true);

        Log::debug('Job execution tracking started', [
            'job' => $jobName,
            'started_at' => now()->toDateTimeString(),
        ]);

        try {
            $result = $next($job);

            $executionTime = round(microtime(true) - $startTime, 3);

            // Update last processed timestamp in cache
            Cache::put('queue:last_processed_at', now()->toDateTimeString(), now()->addMinutes(10));

            Log::debug('Job execution tracking completed', [
                'job' => $jobName,
                'execution_time_seconds' => $executionTime,
                'completed_at' => now()->toDateTimeString(),
            ]);

            // Log warning if job took too long (more than 30 seconds)
            if ($executionTime > 30) {
                Log::warning('Job execution took longer than expected', [
                    'job' => $jobName,
                    'execution_time_seconds' => $executionTime,
                    'threshold_seconds' => 30,
                ]);
            }

            return $result;
        } catch (\Throwable $e) {
            $executionTime = round(microtime(true) - $startTime, 3);

            Log::error('Job execution failed during tracking', [
                'job' => $jobName,
                'execution_time_seconds' => $executionTime,
                'error' => $e->getMessage(),
            ]);

            throw $e;
        }
    }
}
