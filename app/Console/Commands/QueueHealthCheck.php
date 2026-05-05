<?php

namespace App\Console\Commands;

use Illuminate\Console\Command;
use Illuminate\Support\Facades\Cache;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Facades\Log;
use Illuminate\Support\Facades\Redis;

class QueueHealthCheck extends Command
{
    /**
     * The name and signature of the console command.
     *
     * @var string
     */
    protected $signature = 'queue:health-check
                            {--max-age=300 : Maximum age in seconds before a job is considered stale}';

    /**
     * The console command description.
     *
     * @var string
     */
    protected $description = 'Check queue health and log warnings for stuck or delayed jobs';

    /**
     * Execute the console command.
     */
    public function handle(): int
    {
        $maxAge = (int) $this->option('max-age');
        $hasIssues = false;

        Log::info('Starting queue health check', ['max_age_seconds' => $maxAge]);

        // Check Redis queues for stuck jobs
        try {
            $queues = ['registrations', 'bookings'];
            
            foreach ($queues as $queue) {
                $queueKey = "queues:{$queue}";
                $delayedKey = "queues:{$queue}:delayed";
                $reservedKey = "queues:{$queue}:reserved";

                // Check reserved jobs (jobs being processed)
                $reservedJobs = Redis::zrange($reservedKey, 0, -1);
                
                if (!empty($reservedJobs)) {
                    foreach ($reservedJobs as $jobPayload) {
                        $payload = json_decode($jobPayload, true);
                        if ($payload && isset($payload['uuid'])) {
                            // Check how long the job has been reserved
                            $pushedAt = $payload['pushedAt'] ?? null;
                            if ($pushedAt) {
                                $age = time() - $pushedAt;
                                if ($age > $maxAge) {
                                    Log::warning('Queue job appears to be stuck (reserved too long)', [
                                        'queue' => $queue,
                                        'job_uuid' => $payload['uuid'],
                                        'job_name' => $payload['displayName'] ?? 'unknown',
                                        'age_seconds' => $age,
                                        'max_age_seconds' => $maxAge,
                                        'pushed_at' => date('Y-m-d H:i:s', $pushedAt),
                                    ]);
                                    $hasIssues = true;
                                }
                            }
                        }
                    }
                }

                // Check delayed jobs
                $delayedJobs = Redis::zrangebyscore($delayedKey, 0, time());
                
                if (!empty($delayedJobs)) {
                    foreach ($delayedJobs as $jobPayload) {
                        $payload = json_decode($jobPayload, true);
                        if ($payload && isset($payload['uuid'])) {
                            Log::warning('Queue job is delayed', [
                                'queue' => $queue,
                                'job_uuid' => $payload['uuid'],
                                'job_name' => $payload['displayName'] ?? 'unknown',
                                'scheduled_for' => date('Y-m-d H:i:s', (int) Redis::zscore($delayedKey, $jobPayload)),
                            ]);
                            $hasIssues = true;
                        }
                    }
                }

                // Check pending jobs count
                $pendingCount = Redis::llen($queueKey);
                if ($pendingCount > 100) {
                    Log::warning('Queue has high number of pending jobs', [
                        'queue' => $queue,
                        'pending_count' => $pendingCount,
                        'threshold' => 100,
                    ]);
                    $hasIssues = true;
                }
            }

            // Check failed jobs table
            $recentFailures = DB::table('failed_jobs')
                ->where('failed_at', '>=', now()->subMinutes(30))
                ->count();

            if ($recentFailures > 10) {
                Log::error('High number of recent job failures detected', [
                    'failure_count' => $recentFailures,
                    'time_window_minutes' => 30,
                ]);
                $hasIssues = true;
            }

            // Check last successful job processing time from cache
            $lastProcessedAt = Cache::get('queue:last_processed_at');
            if ($lastProcessedAt) {
                $secondsSinceLastJob = time() - strtotime($lastProcessedAt);
                if ($secondsSinceLastJob > $maxAge * 2) {
                    Log::warning('No jobs processed recently - queue worker may be down', [
                        'last_processed_at' => $lastProcessedAt,
                        'seconds_since_last_job' => $secondsSinceLastJob,
                        'threshold_seconds' => $maxAge * 2,
                    ]);
                    $hasIssues = true;
                }
            }

            if (!$hasIssues) {
                Log::info('Queue health check passed - no issues detected');
            } else {
                Log::warning('Queue health check completed with issues - review logs above');
            }

        } catch (\Exception $e) {
            Log::error('Queue health check failed', [
                'error' => $e->getMessage(),
                'trace' => $e->getTraceAsString(),
            ]);
            return Command::FAILURE;
        }

        return Command::SUCCESS;
    }
}
