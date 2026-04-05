const { execSync } = require('child_process');

const mainBranch = process.env.DEFAULT_BRANCH || 'main';

const activeBranch =
    process.env.GITHUB_REF_NAME ||
    (() => {
        try {
            return execSync('git rev-parse --abbrev-ref HEAD').toString().trim();
        } catch {
            return mainBranch;
        }
    })();

const prereleaseChannel = activeBranch.replace(/[/_]/g, '-');

const branches = [mainBranch];

if (activeBranch !== mainBranch) {
    branches.push({
        name: activeBranch,
        prerelease: prereleaseChannel
    });
}

const plugins = [
    [
        "@semantic-release/commit-analyzer",
        {
            "preset": "conventionalcommits",
            "releaseRules": [
                { "breaking": true, "release": "major" },
                { "type": "feat", "release": "minor" },
                { "type": "fix", "release": "patch" },
                { "type": "perf", "release": "patch" },
                { "type": "revert", "release": "patch" },
                { "type": "chore", "release": "patch" },
                { "type": "refactor", "release": "patch" }
            ]
        }
    ],
    [
        "@semantic-release/release-notes-generator",
        { "preset": "conventionalcommits" }
    ]
];

if (activeBranch === mainBranch) {
    plugins.push([
        "@semantic-release/git",
        {
            "assets": [],
            "message": "chore(release): ${nextRelease.version} [skip ci]\n\n${nextRelease.notes}"
        }
    ]);
}

plugins.push([
    "@semantic-release/github",
    {
        "successComment": false
    }
]);

plugins.push([
    "@semantic-release/exec",
    {
        "successCmd": "echo 'new_release_published=true' >> $GITHUB_ENV && echo 'new_release_version=${nextRelease.version}' >> $GITHUB_ENV && echo 'release_type=${nextRelease.type}' >> $GITHUB_ENV"
    }
]);

module.exports = {
    branches,
    plugins
};
