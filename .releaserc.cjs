const { execSync } = require('child_process');
const fs = require('fs');
const path = require('path');

const mainBranch = process.env.DEFAULT_BRANCH || 'main';
const activeBranch =
    process.env.GITHUB_REF_NAME ||
    (() => { try { return execSync('git rev-parse --abbrev-ref HEAD').toString().trim(); } catch { return mainBranch; } })();

const branches = [mainBranch];
if (activeBranch !== mainBranch) {
    branches.push({ name: activeBranch, prerelease: activeBranch.replace(/[/_]/g, '-') });
}

const BUILTIN_PLUGINS = [
    "@semantic-release/commit-analyzer", "@semantic-release/release-notes-generator",
    "@semantic-release/exec", "@semantic-release/git", "@semantic-release/github",
];

function findProjectConfig() {
    // Look in cwd first (single-repo runs and modules that ship their own override),
    // then fall back to the original checkout root for monorepo per-module runs
    // where cwd is the module subdirectory.
    const candidates = [path.join(process.cwd(), '.releaserc-config.json')];
    if (process.env.GITHUB_WORKSPACE) {
        candidates.push(path.join(process.env.GITHUB_WORKSPACE, '.releaserc-config.json'));
    }
    return candidates.find(p => fs.existsSync(p)) || null;
}

function loadProjectPlugins() {
    const configPath = findProjectConfig();
    if (!configPath) return [];
    try {
        const config = require(configPath);
        return Array.isArray(config) ? config : [];
    } catch (e) {
        console.error(`Could not load ${configPath}:`, e.message);
        return [];
    }
}

const projectPlugins = loadProjectPlugins();

function getOverrides(name) {
    const found = projectPlugins.find(p => (Array.isArray(p) ? p[0] : p) === name);
    return found ? (Array.isArray(found) ? found[1] : {}) : null;
}

const extraPlugins = projectPlugins.filter(p => !BUILTIN_PLUGINS.includes(Array.isArray(p) ? p[0] : p));

const execOverrides = getOverrides("@semantic-release/exec") || {};
const gitOverrides = getOverrides("@semantic-release/git") || {};
const githubOverrides = getOverrides("@semantic-release/github") || {};

const plugins = [
    ...extraPlugins,
    ["@semantic-release/commit-analyzer", {
        preset: "conventionalcommits",
        releaseRules: [
            { breaking: true, release: "major" },
            { type: "feat", release: "minor" },
            { type: "fix", release: "patch" },
            { type: "perf", release: "patch" },
            { type: "revert", release: "patch" },
            { type: "chore", release: "patch" },
            { type: "refactor", release: "patch" },
        ]
    }],
    ["@semantic-release/release-notes-generator", { preset: "conventionalcommits" }],
    ["@semantic-release/exec", {
        successCmd: "echo 'new_release_published=true' >> $GITHUB_ENV && echo 'new_release_version=${nextRelease.version}' >> $GITHUB_ENV && echo 'release_type=${nextRelease.type}' >> $GITHUB_ENV",
        ...execOverrides,
    }],
];

if (activeBranch === mainBranch) {
    plugins.push(["@semantic-release/git", {
        assets: [...(gitOverrides.assets || [])],
        message: gitOverrides.message || "chore(release): ${nextRelease.version} [skip ci]\n\n${nextRelease.notes}",
    }]);
}

plugins.push(["@semantic-release/github", { successComment: false, ...githubOverrides }]);

module.exports = { branches, plugins };
