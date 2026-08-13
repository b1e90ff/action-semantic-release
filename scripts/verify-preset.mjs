import { createRequire } from "node:module";
import { join } from "node:path";
import { pathToFileURL } from "node:url";

const [toolsDir] = process.argv.slice(2);

if (!toolsDir) {
  console.log("::error::verify-preset.mjs needs the install directory");
  process.exit(1);
}

const PRESET = "conventional-changelog-conventionalcommits";

function fail(message) {
  console.log(`::error::${message}`);
  process.exit(1);
}

const requireFromTools = createRequire(pathToFileURL(join(toolsDir, "index.js")));

let generatorPath;
try {
  generatorPath = requireFromTools.resolve("@semantic-release/release-notes-generator");
} catch {
  fail(`@semantic-release/release-notes-generator is not installed in ${toolsDir}`);
}

// release-notes-generator resolves the preset from its own location and otherwise
// falls back to the released project's node_modules, where any version may sit.
const requireFromGenerator = createRequire(generatorPath);

let presetPath;
try {
  presetPath = requireFromGenerator.resolve(PRESET);
} catch {
  fail(`${PRESET} is not resolvable from the generator, so the notes would come from the project's own copy`);
}

const createPreset = (await import(pathToFileURL(presetPath))).default;
const preset = await createPreset({});

// A preset older than 8 answers with parserOpts/writerOpts, which generator 14
// ignores; the notes then lose every section without any error.
if (!preset?.writer) {
  fail(`${presetPath} does not expose writer options that this generator understands`);
}

console.log(`Preset resolved next to the generator: ${presetPath}`);
