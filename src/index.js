import './config/index.js';
import { logger } from './lib/logger.js';

async function shutdown() {
    await logger.close();

    process.exit();
}

process.on('SIGINT', shutdown);
process.on('SIGTERM', shutdown);


/* usage samples */
logger.debug('Cache refreshing...');

setTimeout(() => {
    logger.error('Database connection failed', { error: new Error('Connection timeout') });
}, 500);

setTimeout(() => {
    logger.warn('High memory usage', { usage: '85%' });
}, 1000);

setTimeout(() => {
    logger.chat('New message', { from: 'Alice' });
}, 1500);

setTimeout(() => {
    logger.info('User logged in', { userId: 123 });
}, 2000);

setTimeout(() => {
    logger.access('GET /api/data 200 12ms');
}, 2500);