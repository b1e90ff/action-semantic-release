/**
 * Copies the shared release configuration into each module directory
 * for monorepo-style independent releases.
 */
const fs = require('fs');
const path = require('path');

const sharedConfig = path.join(__dirname, '..', '.releaserc.js');

const modules = fs.readdirSync('.', { withFileTypes: true })
    .filter(entry => entry.isDirectory())
    .filter(entry => fs.existsSync(path.join(entry.name, 'package.json')))
    .filter(entry => !entry.name.startsWith('.') && entry.name !== 'node_modules')
    .map(entry => entry.name);

console.log(`Modules detected: ${modules.join(', ')}`);

modules.forEach(mod => {
    const target = path.join(mod, '.releaserc.js');
    fs.copyFileSync(sharedConfig, target);
    console.log(`  -> ${mod}/.releaserc.js`);
});

console.log('Configuration propagated.');
