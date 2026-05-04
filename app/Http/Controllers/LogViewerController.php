<?php

namespace App\Http\Controllers;

use Illuminate\Http\Request;
use Illuminate\Support\Facades\File;

class LogViewerController extends Controller
{
    /**
     * Display the log viewer
     */
    public function index(Request $request)
    {
        // Get all log files first
        $logFiles = [];
        if (File::exists(storage_path('logs'))) {
            $files = File::files(storage_path('logs'));
            $logFiles = array_map(function ($file) {
                return $file->getFilename();
            }, $files);
            
            // Filter to only .log files
            $logFiles = array_values(array_filter($logFiles, function ($file) {
                return str_ends_with($file, '.log');
            }));
        }

        $selectedFile = $request->input('file', 'laravel.log');
        $logPath = storage_path('logs/' . $selectedFile);

        if (!File::exists($logPath)) {
            // If selected file doesn't exist, try laravel.log
            if (File::exists(storage_path('logs/laravel.log'))) {
                $selectedFile = 'laravel.log';
                $logPath = storage_path('logs/laravel.log');
            } else {
                // No log files exist
                return view('log-viewer', [
                    'logs' => [],
                    'allLogs' => [],
                    'totalLogs' => 0,
                    'currentPage' => 1,
                    'totalPages' => 0,
                    'perPage' => 50,
                    'logFiles' => $logFiles,
                    'currentFile' => $selectedFile,
                    'error' => 'No log files found in storage/logs/'
                ]);
            }
        }

        // Read and parse logs
        $logs = $this->parseLogFile($logPath);
        
        // Pagination
        $perPage = 50;
        $currentPage = $request->input('page', 1);
        $totalLogs = count($logs);
        $totalPages = max(1, ceil($totalLogs / $perPage));
        $offset = ($currentPage - 1) * $perPage;
        $paginatedLogs = array_slice($logs, $offset, $perPage);

        return view('log-viewer', [
            'logs' => $paginatedLogs,
            'allLogs' => $logs,
            'totalLogs' => $totalLogs,
            'currentPage' => $currentPage,
            'totalPages' => $totalPages,
            'perPage' => $perPage,
            'logFiles' => $logFiles,
            'currentFile' => $selectedFile,
            'error' => null
        ]);
    }

    /**
     * Clear the log file
     */
    public function clear(Request $request)
    {
        $file = $request->input('file', 'laravel.log');
        $logPath = storage_path('logs/' . $file);
        
        if (File::exists($logPath)) {
            File::put($logPath, '');
            return redirect()->route('logs.index', ['file' => $file])
                ->with('success', 'Log file cleared successfully');
        }
        
        return redirect()->route('logs.index')
            ->with('error', 'Log file not found');
    }

    /**
     * Download the log file
     */
    public function download(Request $request)
    {
        $file = $request->input('file', 'laravel.log');
        $logPath = storage_path('logs/' . $file);
        
        if (File::exists($logPath)) {
            return response()->download($logPath);
        }
        
        return redirect()->route('logs.index')
            ->with('error', 'Log file not found');
    }

    /**
     * Parse log file into structured data
     */
    private function parseLogFile(string $path): array
    {
        $content = File::get($path);
        
        if (empty($content)) {
            return [];
        }

        // Split by timestamp pattern
        $pattern = '/\[(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})\] (\w+)\./';
        preg_match_all($pattern, $content, $matches, PREG_OFFSET_CAPTURE);

        $logs = [];
        $matchCount = count($matches[0]);

        for ($i = 0; $i < $matchCount; $i++) {
            $timestamp = $matches[1][$i][0];
            $level = $matches[2][$i][0];
            $startOffset = $matches[0][$i][1];
            
            // Get end offset (start of next log entry or end of file)
            $endOffset = ($i + 1 < $matchCount) 
                ? $matches[0][$i + 1][1] 
                : strlen($content);
            
            // Extract the full log message
            $fullMessage = substr($content, $startOffset, $endOffset - $startOffset);
            
            // Extract just the message part (after the level)
            $messageStart = strpos($fullMessage, $level . '.') + strlen($level) + 2;
            $message = trim(substr($fullMessage, $messageStart));
            
            // Remove stack traces for cleaner display (keep them in raw)
            $cleanMessage = $message;
            if (strpos($message, '{"exception"') !== false) {
                // Extract just the exception message
                preg_match('/\[object\] \((.*?)\) at/', $message, $exceptionMatch);
                if (!empty($exceptionMatch)) {
                    $cleanMessage = $exceptionMatch[1];
                }
            }

            $logs[] = [
                'timestamp' => $timestamp,
                'level' => strtoupper($level),
                'message' => $cleanMessage,
                'raw' => $message,
                'has_stack_trace' => strpos($message, '[stacktrace]') !== false || strpos($message, '{"exception"') !== false
            ];
        }

        // Reverse to show newest first
        return array_reverse($logs);
    }
}
