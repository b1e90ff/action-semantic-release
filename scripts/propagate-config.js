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

const MODULE_MARKERS = (process.env.INPUT_MODULE_MARKERS || '')
    .split(',')
    .map(m => m.trim())
    .filter(Boolean);

if (MODULE_MARKERS.length === 0) {
    console.error('INPUT_MODULE_MARKERS is empty, so no module can be discovered');
    process.exit(1);
}

const modules = fs.readdirSync('.', { withFileTypes: true })
    .filter(entry => entry.isDirectory())
    .filter(entry => MODULE_MARKERS.some(m => fs.existsSync(path.join(entry.name, m))))
    .filter(entry => !entry.name.startsWith('.') && entry.name !== 'node_modules')
    .map(entry => entry.name);

console.log(`Config source: ${sourceConfig}`);
console.log(`Modules: ${modules.join(', ')}`);

modules.forEach(mod => {
    const target = path.join(mod, configName);
    fs.copyFileSync(sourceConfig, target);
    console.log(`  -> ${mod}/${configName}`);
});
