/**
 * Copies the release configuration into each module directory
 * for monorepo-style independent releases.
 *
 * Prefers the workspace root config over the bundled default.
 */
const fs = require('fs');
const path = require('path');

const KNOWN_CONFIGS = [
  '.releaserc', '.releaserc.js', '.releaserc.cjs', '.releaserc.json',
  '.releaserc.yml', '.releaserc.yaml', 'release.config.js', 'release.config.cjs',
];

// Find workspace root config, fall back to bundled
const rootConfig = KNOWN_CONFIGS.map(f => path.resolve(process.cwd(), f)).find(f => fs.existsSync(f));
const bundledConfig = path.join(__dirname, '..', '.releaserc.cjs');
const sourceConfig = rootConfig || bundledConfig;
const configName = path.basename(sourceConfig);

const modules = fs.readdirSync('.', { withFileTypes: true })
    .filter(entry => entry.isDirectory())
    .filter(entry => fs.existsSync(path.join(entry.name, 'package.json')))
    .filter(entry => !entry.name.startsWith('.') && entry.name !== 'node_modules')
    .map(entry => entry.name);

console.log(`Config source: ${sourceConfig}`);
console.log(`Modules: ${modules.join(', ')}`);

modules.forEach(mod => {
    const target = path.join(mod, configName);
    fs.copyFileSync(sourceConfig, target);
    console.log(`  -> ${mod}/${configName}`);
});
