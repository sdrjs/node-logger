import fs from 'node:fs';
import path from 'node:path';
import { getDirname } from './getDirname.js';

let cachedRoot = null;

export function getProjectRoot() {
    if (cachedRoot) return cachedRoot;

    let currentDir = getDirname(import.meta.url);
    const systemRoot = path.parse(currentDir).root;

    while (currentDir !== systemRoot) {
        const pathToCheck = path.join(currentDir, 'package.json');

        if (fs.existsSync(pathToCheck)) {
            cachedRoot = currentDir;
            return currentDir;
        }

        currentDir = path.dirname(currentDir);
    }

    throw new Error('project root not found');
}