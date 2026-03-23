/**
 * Environment variables:
 * - LOG_PATH    – directory for log files (default: 'logs')
 * - LOG_SIZE    – max size per log file in bytes (default: 5 * 1024 * 1024)
 *                Supports expressions with '*', e.g. '10 * 1024 * 1024' is 10 MB
 * - LOG_FILES   – max number of backup files (default: 5)
 * - LOG_DEBUG   – enable debug logs if 'true' or '1' (default: false)
 */

import fs from 'node:fs';
import path from 'node:path';
import { inspect } from 'node:util';
import { getProjectRoot } from '../utils/getProjectRoot.js';

function safeStringify({ message, context, ...props }) {
    const data = { ...props, message };
    if (context && typeof context === 'object' && Object.keys(context).length) {
        data.context = context;
    }

    try {
        return JSON.stringify(data);
    } catch (err) {
        console.error(err);

        data.message = `[Serialization error]: ${err.message}`;
        if ('context' in data) {
            data.context = inspect(context, { depth: null, compact: true });
        }

        return JSON.stringify(data);
    }
}

function parseNumber(str) {
    if (typeof str !== 'string' || isNaN(parseInt(str, 10))) return null;

    if (!str.match(/\*/)) {
        return parseInt(str, 10);
    }

    return str.split('*').reduce((acc, cur) => acc * parseInt(cur, 10));
}

const projectPath = getProjectRoot();
const logsPath = process.env.LOG_PATH || 'logs';

const logsDir = path.join(projectPath, logsPath);

const relativePath = path.relative(projectPath, logsDir);
if (relativePath.startsWith('..') || path.isAbsolute(relativePath)) {
    throw new Error(`Path traversal: ${logsPath} attempts to escape project root`);
}

try {
    fs.mkdirSync(logsDir, { recursive: true });
} catch (err) {
    console.error('Failed to create logs directory:', err);
}

const MONTHS = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
const RESERVED_NAMES = ['app', 'error', 'warn', 'info', 'debug', 'access'];

export class Logger {
    #streams = {};

    #maxSize = parseNumber(process.env.LOG_SIZE) ?? 5 * 1024 * 1024;
    #maxFiles = parseNumber(process.env.LOG_FILES) ?? 5;
    #debugLogEnabled = process.env.LOG_DEBUG === 'true' || process.env.LOG_DEBUG === '1';

    /**
     * Maximum size (in bytes) of a single log file before rotation.
     * @returns {number}
     */
    get maxSize() { return this.#maxSize; }

    /**
     * Maximum number of rotated backup files to keep.
     * @returns {number}
     */
    get maxFiles() { return this.#maxFiles; }

    /**
     * Indicates whether debug-level messages are written to log files.
     * @returns {boolean}
     */
    get debugLogEnabled() { return this.#debugLogEnabled; }

    constructor() {
        this.#initStreams();
    }

    #initStreams() {
        this.#streams.error = {};
        this.#streams.app = {};
        this.#streams.access = {};

        if (this.#debugLogEnabled) {
            this.#streams.debug = {};
        }

        for (const name in this.#streams) {
            this.#initStream(name);
        }
    }

    #initCustomStream(name, options) {
        const { toConsole } = options;

        if (RESERVED_NAMES.includes(name)) {
            console.error(`Log name "${name}" is reserved. Custom stream not created.`);
            return;
        }

        if (name in this) {
            console.error(`Log name "${name}" is already using. Custom stream not created.`);
            return;
        }

        this[name] = function (message, context = {}) {
            this.#log(name, message, context, { customStream: true, toConsole: Boolean(toConsole) });
        }

        this.#initStream(name);
    }

    #initStream(name) {
        this.#streams[name] = {
            path: path.join(logsDir, `${name}.log`),
            queue: [],
            fileLogEnabled: true,
            queueProcessingPromise: null,
        };

        this.#createStream(name, true);
    }

    async #createStream(name, init) {
        const streamObj = this.#streams[name];
        streamObj.size = 0;

        if (init) {
            try {
                const stats = await fs.promises.stat(streamObj.path);
                streamObj.size = stats.size;
            } catch (err) {
                if (err.code !== 'ENOENT') {
                    console.error(err);
                }
            }
        }

        streamObj.stream = fs.createWriteStream(streamObj.path, { flags: 'a' });
        streamObj.stream.on('error', console.error);

        try {
            await new Promise((resolve, reject) => {
                const onResolve = () => {
                    streamObj.stream.removeListener('error', onError);
                    resolve();
                };
                const onError = err => {
                    streamObj.stream.removeListener('open', onResolve);
                    reject(err);
                };

                streamObj.stream.once('open', onResolve);
                streamObj.stream.once('error', onError);
            });

            this.#flushQueue(name);
        } catch (err) {
            await this.#destroyStream(name);
        }
    }

    #flushQueue(basename) {
        const streamObj = this.#streams[basename];
        if (streamObj.queue.length > 0) {
            this.#processLogQueue(basename);
        }
    }

    async #closeStream(name) {
        const streamObj = this.#streams[name];
        if (!streamObj.stream || !streamObj.stream.writable) return;

        streamObj.stream.end();
        await new Promise(resolve => streamObj.stream.once('close', resolve));
        streamObj.stream.removeListener('error', console.error);
    }

    async #destroyStream(name) {
        const streamObj = this.#streams[name];

        streamObj.fileLogEnabled = false;
        streamObj.queue.length = 0;

        if (!streamObj.stream || streamObj.stream.destroyed) return;

        streamObj.stream.destroy();
        await new Promise(resolve => streamObj.stream.once('close', resolve));
        streamObj.stream.removeListener('error', console.error);
    }

    /**
     * Ensures all pending writes to files are completed, then closes all log streams.
     * @returns {Promise<void>}
     */
    async close() {
        const queuePromises = [];

        for (const name in this.#streams) {
            queuePromises.push(this.#streams[name].queueProcessingPromise);
        }

        await Promise.all(queuePromises);

        const closePromises = [];

        for (const name in this.#streams) {
            closePromises.push(this.#closeStream(name));
        }

        await Promise.all(closePromises);
    }

    #log(level, message, context, options = {}) {
        const { enabledBasenames, disabledBasenames } = this.#getBasenames(level, options);

        if (disabledBasenames.length > 0) {
            console.warn(`${disabledBasenames.join(', ')} file log disabled`);
        }

        const date = new Date();

        if (!options.customStream || options.toConsole) {
            this.#writeToConsole(date, level, message, context);
        }

        if (enabledBasenames.length === 0) return;

        const timestamp = date.toISOString();

        const data = safeStringify({
            timestamp,
            level,
            pid: process.pid,
            message,
            context
        }) + '\n';

        for (const basename of enabledBasenames) {
            this.#streams[basename].queue.push(data);
            this.#processLogQueue(basename);
        }
    }

    #getBasenames(level, options) {
        const basenames = [];

        if (options.customStream) {
            basenames.push(level);
        } else {
            switch (level) {
                case 'access':
                    basenames.push('access');
                    break;

                case 'debug':
                    if (this.#debugLogEnabled) {
                        basenames.push('debug');
                    }
                    break;

                case 'info':
                case 'warn':
                    basenames.push('app');
                    break;

                case 'error':
                    basenames.push('error', 'app');
                    break;
            }
        }

        const enabledBasenames = [];
        const disabledBasenames = [];

        for (const name of basenames) {
            if (this.#streams[name].fileLogEnabled) {
                enabledBasenames.push(name);
            } else {
                disabledBasenames.push(name);
            }
        }

        return { enabledBasenames, disabledBasenames };
    }

    #writeToConsole(date, level, message, context) {
        const month = MONTHS[date.getMonth()];
        const day = date.getDate();
        const hours = date.getHours();
        const minutes = date.getMinutes();
        const seconds = date.getSeconds();
        const milliseconds = String(date.getMilliseconds()).padStart(3, '0');

        const time = `${hours}:${minutes}:${seconds}.${milliseconds}`.replace(/\b\d\b/g, '0$&');
        const dateFormatted = `${day} ${month} ${time}`;

        const formattedLevel = `[${level.toUpperCase()}]`.padEnd(8, ' ');

        const colors = {
            error: '\x1b[31m', // red
            warn: '\x1b[33m',  // yellow
            info: '\x1b[32m',  // green
            debug: '\x1b[34m', // blue
            access: '\x1b[35m' // purple
        };

        const messageColor = '\x1b[36m'; // cyan

        const color = colors[level] ?? '';
        const resetColor = '\x1b[0m';

        const coloredLevel = `${color}${formattedLevel}${resetColor}`;
        const coloredMessage = `${messageColor}${message}${resetColor}`;

        const hasContextProps = context && typeof context === 'object' && Object.keys(context).length;
        const contextStr = hasContextProps ? ' ' + inspect(context, {
            colors: true,
            depth: null,
            compact: true
        }) : '';

        console.log(`${dateFormatted} ${coloredLevel} ${coloredMessage}${contextStr}`);
    }

    async #processLogQueue(basename) {
        const streamObj = this.#streams[basename];
        if (!streamObj.stream?.writable || streamObj.queueProcessingPromise) return;

        streamObj.queueProcessingPromise = new Promise(async resolve => {
            while (streamObj.queue.length > 0 && streamObj.fileLogEnabled) {
                const data = streamObj.queue.shift();

                await new Promise(resolve => {
                    streamObj.stream.write(data, async (err) => {
                        if (err) {
                            console.error(err);

                            if (err.code === 'ENOSPC' || err.code === 'EACCES') {
                                await this.#destroyStream(basename);
                            }
                        } else {
                            streamObj.size += Buffer.byteLength(data);
                        }

                        resolve();
                    });
                });

                if (streamObj.size > this.#maxSize && this.#maxFiles > 0) {
                    await this.#rotateFiles(basename);
                    if (!streamObj.fileLogEnabled) return;

                    await this.#closeStream(basename);
                    await this.#createStream(basename);
                };
            }

            resolve();
        });

        await streamObj.queueProcessingPromise;
        streamObj.queueProcessingPromise = null;
    }

    async #rotateFiles(basename) {
        if (this.#maxFiles <= 0) return;

        const file = this.#streams[basename].path;

        for (let i = this.#maxFiles - 1; i > 0; i--) {
            const renameFrom = `${file}.${i}`;

            try {
                await fs.promises.rename(renameFrom, `${file}.${i + 1}`);
            } catch (err) {
                if (err.code !== 'ENOENT') {
                    console.error(err);
                }
            }
        }

        try {
            await fs.promises.rename(file, `${file}.1`);
        } catch (err) {
            console.error(err);

            if (err.code === 'ENOSPC' || err.code === 'EACCES') {
                await this.#destroyStream(basename);
            }
        }
    }

    /**
     * Logs an `access`-level message.
     * @param {string} message - The log message.
     * @param {Object} [context] - Additional structured metadata.
     */
    access(message, context = {}) {
        this.#log('access', message, context);
    }

    /**
     * Logs a `debug`-level message. Writes to file only if `debugLogEnabled` is true.
     * @param {string} message - The log message.
     * @param {Object} [context] - Additional structured metadata.
     */
    debug(message, context = {}) {
        this.#log('debug', message, context);
    }

    /**
     * Logs an `info`-level message.
     * @param {string} message - The log message.
     * @param {Object} [context] - Additional structured metadata.
     */
    info(message, context = {}) {
        this.#log('info', message, context);
    }

    /**
     * Logs a `warn`-level message.
     * @param {string} message - The log message.
     * @param {Object} [context] - Additional structured metadata.
     */
    warn(message, context = {}) {
        this.#log('warn', message, context);
    }

    /**
     * Logs an `error`-level message. Writes to both the app and error log files.
     * @param {string} message - The log message.
     * @param {Object} [context] - Additional structured metadata.
     */
    error(message, context = {}) {
        this.#log('error', message, context);
    }

    /**
     * Adds a custom log level with its own log file and optional console output.
     * @param {string} name - The name of the custom log level (e.g., 'chat').
     *   A method `logger.<name>(message, context)` will be added, and logs will be written to `<name>.log`.
     * @param {Object} [options] - Configuration options.
     * @param {boolean} [options.toConsole=false] - Whether to output messages of this level to the console.
     */
    addCustomLog(name, options = {}) {
        this.#initCustomStream(name, options);
    }
}

export const logger = new Logger();