<?php

namespace App\Providers;

use Illuminate\Queue\Events\JobExceptionOccurred;
use Illuminate\Queue\Events\JobFailed;
use Illuminate\Queue\Events\JobProcessed;
use Illuminate\Queue\Events\JobProcessing;
use Illuminate\Support\Facades\Event;
use Illuminate\Support\Facades\Log;
use Illuminate\Support\ServiceProvider;

class AppServiceProvider extends ServiceProvider
{
    /**
     * Register any application services.
     */
    public function register(): void
    {
        //
    }

    /**
     * Bootstrap any application services.
     */
    public function boot(): void
    {
        // Monitor queue job events for logging and timeout detection
        Event::listen(function (JobProcessing $event) {
            Log::info('Queue job started processing', [
                'job_id' => $event->job->getJobId(),
                'job_name' => $event->job->resolveName(),
                'queue' => $event->job->getQueue(),
                'attempts' => $event->job->attempts(),
                'timestamp' => now()->toDateTimeString(),
            ]);
        });

        Event::listen(function (JobProcessed $event) {
            Log::info('Queue job processed successfully', [
                'job_id' => $event->job->getJobId(),
                'job_name' => $event->job->resolveName(),
                'queue' => $event->job->getQueue(),
                'attempts' => $event->job->attempts(),
                'timestamp' => now()->toDateTimeString(),
            ]);
        });

        Event::listen(function (JobFailed $event) {
            Log::error('Queue job failed', [
                'job_id' => $event->job->getJobId(),
                'job_name' => $event->job->resolveName(),
                'queue' => $event->job->getQueue(),
                'attempts' => $event->job->attempts(),
                'exception' => $event->exception->getMessage(),
                'timestamp' => now()->toDateTimeString(),
            ]);
        });

        Event::listen(function (JobExceptionOccurred $event) {
            Log::warning('Queue job encountered an exception', [
                'job_id' => $event->job->getJobId(),
                'job_name' => $event->job->resolveName(),
                'queue' => $event->job->getQueue(),
                'attempts' => $event->job->attempts(),
                'exception' => $event->exception->getMessage(),
                'will_retry' => $event->job->attempts() < $event->job->maxTries(),
                'timestamp' => now()->toDateTimeString(),
            ]);
        });
    }
}
