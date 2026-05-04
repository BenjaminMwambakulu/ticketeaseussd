<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Laravel Log Viewer</title>
    <style>
        * {
            margin: 0;
            padding: 0;
            box-sizing: border-box;
        }

        body {
            font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, Oxygen, Ubuntu, Cantarell, sans-serif;
            background: #f5f5f5;
            color: #333;
            line-height: 1.6;
        }

        .container {
            max-width: 1400px;
            margin: 0 auto;
            padding: 20px;
        }

        header {
            background: white;
            padding: 20px;
            border-radius: 8px;
            box-shadow: 0 2px 4px rgba(0,0,0,0.1);
            margin-bottom: 20px;
        }

        h1 {
            color: #ff2d20;
            margin-bottom: 10px;
        }

        .controls {
            display: flex;
            gap: 10px;
            align-items: center;
            flex-wrap: wrap;
            margin-top: 15px;
        }

        select, button, input {
            padding: 8px 12px;
            border: 1px solid #ddd;
            border-radius: 4px;
            font-size: 14px;
        }

        button {
            background: #ff2d20;
            color: white;
            border: none;
            cursor: pointer;
            transition: background 0.3s;
        }

        button:hover {
            background: #e0271b;
        }

        button.secondary {
            background: #6c757d;
        }

        button.secondary:hover {
            background: #5a6268;
        }

        .stats {
            background: white;
            padding: 15px;
            border-radius: 8px;
            box-shadow: 0 2px 4px rgba(0,0,0,0.1);
            margin-bottom: 20px;
            display: flex;
            gap: 20px;
            flex-wrap: wrap;
        }

        .stat-item {
            display: flex;
            flex-direction: column;
        }

        .stat-label {
            font-size: 12px;
            color: #666;
            text-transform: uppercase;
        }

        .stat-value {
            font-size: 24px;
            font-weight: bold;
            color: #333;
        }

        .log-entry {
            background: white;
            padding: 15px;
            margin-bottom: 10px;
            border-radius: 8px;
            box-shadow: 0 2px 4px rgba(0,0,0,0.1);
            border-left: 4px solid #ddd;
        }

        .log-entry.ERROR {
            border-left-color: #dc3545;
            background: #fff5f5;
        }

        .log-entry.WARNING {
            border-left-color: #ffc107;
            background: #fffbf0;
        }

        .log-entry.INFO {
            border-left-color: #17a2b8;
            background: #f0f9ff;
        }

        .log-entry.DEBUG {
            border-left-color: #6c757d;
            background: #f8f9fa;
        }

        .log-header {
            display: flex;
            justify-content: space-between;
            align-items: center;
            margin-bottom: 10px;
            flex-wrap: wrap;
            gap: 10px;
        }

        .log-timestamp {
            font-size: 12px;
            color: #666;
            font-family: 'Courier New', monospace;
        }

        .log-level {
            padding: 4px 8px;
            border-radius: 4px;
            font-size: 12px;
            font-weight: bold;
            text-transform: uppercase;
        }

        .log-level.ERROR {
            background: #dc3545;
            color: white;
        }

        .log-level.WARNING {
            background: #ffc107;
            color: #333;
        }

        .log-level.INFO {
            background: #17a2b8;
            color: white;
        }

        .log-level.DEBUG {
            background: #6c757d;
            color: white;
        }

        .log-message {
            font-family: 'Courier New', monospace;
            font-size: 13px;
            word-wrap: break-word;
            white-space: pre-wrap;
            color: #333;
        }

        .toggle-stack {
            margin-top: 10px;
            padding: 5px 10px;
            background: #e9ecef;
            border: none;
            border-radius: 4px;
            cursor: pointer;
            font-size: 12px;
            color: #495057;
        }

        .toggle-stack:hover {
            background: #dee2e6;
        }

        .stack-trace {
            display: none;
            margin-top: 10px;
            padding: 10px;
            background: #f8f9fa;
            border-radius: 4px;
            font-family: 'Courier New', monospace;
            font-size: 11px;
            overflow-x: auto;
            white-space: pre-wrap;
            color: #495057;
        }

        .stack-trace.show {
            display: block;
        }

        .pagination {
            display: flex;
            justify-content: center;
            gap: 5px;
            margin-top: 20px;
            flex-wrap: wrap;
        }

        .pagination a, .pagination span {
            padding: 8px 12px;
            border: 1px solid #ddd;
            border-radius: 4px;
            text-decoration: none;
            color: #333;
        }

        .pagination a:hover {
            background: #f0f0f0;
        }

        .pagination .active {
            background: #ff2d20;
            color: white;
            border-color: #ff2d20;
        }

        .alert {
            padding: 15px;
            border-radius: 8px;
            margin-bottom: 20px;
        }

        .alert-success {
            background: #d4edda;
            color: #155724;
            border: 1px solid #c3e6cb;
        }

        .alert-error {
            background: #f8d7da;
            color: #721c24;
            border: 1px solid #f5c6cb;
        }

        .empty-state {
            text-align: center;
            padding: 60px 20px;
            background: white;
            border-radius: 8px;
            box-shadow: 0 2px 4px rgba(0,0,0,0.1);
        }

        .empty-state h3 {
            color: #666;
            margin-bottom: 10px;
        }

        .filter-controls {
            margin-bottom: 15px;
        }

        .filter-btn {
            padding: 6px 12px;
            margin-right: 5px;
            border: 1px solid #ddd;
            background: white;
            border-radius: 4px;
            cursor: pointer;
            font-size: 13px;
        }

        .filter-btn.active {
            background: #ff2d20;
            color: white;
            border-color: #ff2d20;
        }

        @media (max-width: 768px) {
            .container {
                padding: 10px;
            }

            .controls {
                flex-direction: column;
                align-items: stretch;
            }

            .stats {
                flex-direction: column;
            }
        }
    </style>
</head>
<body>
    <div class="container">
        <header>
            <h1>📋 Laravel Log Viewer</h1>
            <p>TicketEase USSD Application Logs</p>
            
            <div class="controls">
                <form method="GET" action="{{ route('logs.index') }}" style="display: inline;">
                    <select name="file" onchange="this.form.submit()">
                        @foreach($logFiles as $file)
                            <option value="{{ $file }}" {{ $currentFile == $file ? 'selected' : '' }}>
                                {{ $file }}
                            </option>
                        @endforeach
                    </select>
                </form>

                <a href="{{ route('logs.download', ['file' => $currentFile]) }}">
                    <button type="button">⬇️ Download</button>
                </a>

                <form method="POST" action="{{ route('logs.clear') }}" style="display: inline;" 
                      onsubmit="return confirm('Are you sure you want to clear this log file?')">
                    @csrf
                    <input type="hidden" name="file" value="{{ $currentFile }}">
                    <button type="submit" class="secondary">🗑️ Clear Log</button>
                </form>

                <a href="{{ route('logs.index') }}">
                    <button type="button" class="secondary">🔄 Refresh</button>
                </a>
            </div>
        </header>

        @if(session('success'))
            <div class="alert alert-success">
                {{ session('success') }}
            </div>
        @endif

        @if(session('error'))
            <div class="alert alert-error">
                {{ session('error') }}
            </div>
        @endif

        @if($error)
            <div class="alert alert-error">
                {{ $error }}
            </div>
        @endif

        <div class="stats">
            <div class="stat-item">
                <span class="stat-label">Total Entries</span>
                <span class="stat-value">{{ number_format($totalLogs) }}</span>
            </div>
            <div class="stat-item">
                <span class="stat-label">Current Page</span>
                <span class="stat-value">{{ $currentPage }} / {{ $totalPages }}</span>
            </div>
            <div class="stat-item">
                <span class="stat-label">Per Page</span>
                <span class="stat-value">{{ $perPage }}</span>
            </div>
            <div class="stat-item">
                <span class="stat-label">Log File</span>
                <span class="stat-value" style="font-size: 16px;">{{ $currentFile }}</span>
            </div>
        </div>

        <div class="filter-controls">
            <button class="filter-btn active" onclick="filterLogs('all')">All</button>
            <button class="filter-btn" onclick="filterLogs('ERROR')">Errors</button>
            <button class="filter-btn" onclick="filterLogs('WARNING')">Warnings</button>
            <button class="filter-btn" onclick="filterLogs('INFO')">Info</button>
            <button class="filter-btn" onclick="filterLogs('DEBUG')">Debug</button>
        </div>

        @if(empty($logs))
            <div class="empty-state">
                <h3>No log entries found</h3>
                <p>The log file is empty or could not be read.</p>
            </div>
        @else
            @foreach($logs as $log)
                <div class="log-entry {{ $log['level'] }}" data-level="{{ $log['level'] }}">
                    <div class="log-header">
                        <span class="log-timestamp">{{ $log['timestamp'] }}</span>
                        <span class="log-level {{ $log['level'] }}">{{ $log['level'] }}</span>
                    </div>
                    <div class="log-message">{{ $log['message'] }}</div>
                    
                    @if($log['has_stack_trace'])
                        <button class="toggle-stack" onclick="toggleStackTrace(this)">
                            Show Stack Trace ▼
                        </button>
                        <div class="stack-trace">{{ $log['raw'] }}</div>
                    @endif
                </div>
            @endforeach

            @if($totalPages > 1)
                <div class="pagination">
                    @if($currentPage > 1)
                        <a href="{{ route('logs.index', ['page' => $currentPage - 1, 'file' => $currentFile]) }}">← Previous</a>
                    @endif

                    @for($i = 1; $i <= $totalPages; $i++)
                        @if($i == $currentPage)
                            <span class="active">{{ $i }}</span>
                        @elseif($i == 1 || $i == $totalPages || abs($i - $currentPage) <= 2)
                            <a href="{{ route('logs.index', ['page' => $i, 'file' => $currentFile]) }}">{{ $i }}</a>
                        @elseif(abs($i - $currentPage) == 3)
                            <span>...</span>
                        @endif
                    @endfor

                    @if($currentPage < $totalPages)
                        <a href="{{ route('logs.index', ['page' => $currentPage + 1, 'file' => $currentFile]) }}">Next →</a>
                    @endif
                </div>
            @endif
        @endif
    </div>

    <script>
        function toggleStackTrace(button) {
            const stackTrace = button.nextElementSibling;
            stackTrace.classList.toggle('show');
            button.textContent = stackTrace.classList.contains('show') 
                ? 'Hide Stack Trace ▲' 
                : 'Show Stack Trace ▼';
        }

        function filterLogs(level) {
            const entries = document.querySelectorAll('.log-entry');
            const buttons = document.querySelectorAll('.filter-btn');
            
            // Update active button
            buttons.forEach(btn => btn.classList.remove('active'));
            event.target.classList.add('active');
            
            // Filter entries
            entries.forEach(entry => {
                if (level === 'all' || entry.dataset.level === level) {
                    entry.style.display = 'block';
                } else {
                    entry.style.display = 'none';
                }
            });
        }

        // Auto-refresh every 30 seconds (optional)
        // setTimeout(() => window.location.reload(), 30000);
    </script>
</body>
</html>
