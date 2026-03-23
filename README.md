# Node.js custom logger with file rotation and archiving

This project provides a logger for Node.js applications.
It can be configured via environment variables and includes a PowerShell script to archive rotated logs **by date**.

## Features

- Multiple log methods (`access`, `debug`, `info`, `warn`, `error`)
- Custom log methods with separate log files
- Log rotation by size
- Structured logging with JSON to files and colored console output
- Environment variable configuration
- PowerShell script to archive rotated logs based on timestamps extracted from JSON lines

## Log files

> **Note:** The logger uses environment variables (e.g., `LOG_PATH`, `LOG_DEBUG`). Setting `LOG_FILES=0` disables log rotation entirely.

| Level / method     | Log file(s) written to | Notes |
|--------------------|------------------------|-------|
| `logger.access()`  | `access.log`           | |
| `logger.info()`    | `app.log`              | |
| `logger.warn()`    | `app.log`              | |
| `logger.debug()`   | `debug.log`            | only if `LOG_DEBUG` is enabled |
| `logger.error()`   | `error.log` and `app.log` | duplicates to `app.log` |
| `logger.<custom>()`| `<custom>.log`         | e.g., `chat.log` for `logger.addCustomLog('chat', ...)` |

## Logger usage

> **Note:** If you use a `.env` file, load it before importing the logger (e.g., with `import 'dotenv/config'`).

```js
import { logger } from './src/lib/logger.js';

logger.info('User logged in', { userId: 123 });
logger.error('Database connection failed', { error: err });
logger.debug('Processing request', { url: req.url });

logger.addCustomLog('chat', { toConsole: true });
logger.chat('New message', { from: 'Alice', to: 'Bob' });
```

To ensure all pending writes are flushed before the process exits, call `await logger.close()`:

```js
async function shutdown() {
    await logger.close();

    process.exit(0);
}

process.on('SIGINT', shutdown);
process.on('SIGTERM', shutdown);
```

## PowerShell archive script

This script is written for **PowerShell** (built‑in on Windows) and also works on **Linux/macOS** with [PowerShell Core](https://github.com/PowerShell/PowerShell) installed.

- Reads `LOG_PATH` from `.env` (or uses `logs`).
- Finds all files matching `*.log.*` (with a digit) in the log directory.
- For each line that is valid JSON, extracts the date from `obj.timestamp`.
- Appends the line to an archive file inside a subfolder named after the log type, with the filename `<date>.log` (e.g., `logs_archive/app/2026-03-24.log`).
- After successful processing, the original rotated file is deleted. If any errors occurred, the file is moved to a `_corrupted` subfolder inside the archive directory.
- The script uses a lock file (`archive.lock`) to prevent concurrent runs. If the lock file is older than the value of the environment variable `LOG_ARCHIVE_LOCK_TIMEOUT`, it is considered stale and removed.
- The script logs its own activity to `logs_archive/archive_script.log`. This log file is also rotated based on `LOG_SIZE` and `LOG_FILES`.