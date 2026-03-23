import 'dotenv/config';
import { logger } from '../lib/logger.js';

logger.addCustomLog('chat', { toConsole: true });