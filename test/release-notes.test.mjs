import assert from 'node:assert/strict';
import { createRequire } from 'node:module';
import test from 'node:test';
import { generateNotes } from '@semantic-release/release-notes-generator';

const require = createRequire(import.meta.url);
const { plugins } = require('../.releaserc.cjs');

const notesEntry = plugins.find(
    (plugin) => Array.isArray(plugin) && plugin[0] === '@semantic-release/release-notes-generator',
);
assert.ok(notesEntry, '@semantic-release/release-notes-generator is not configured');

const notesOptions = notesEntry[1];

// A revert needs the commit it reverts to show up at all.
const types = (notesOptions.presetConfig?.types ?? []).filter(
    (entry) => entry.section && !entry.hidden && entry.type !== 'revert',
);

const commits = types.map((entry, index) => ({
    hash: String(index + 1).repeat(40),
    message: `${entry.type}: subject of ${entry.type}`,
}));

async function notesFor(commitList) {
    return generateNotes(notesOptions, {
        cwd: process.cwd(),
        options: { repositoryUrl: 'https://github.com/eventfrog/example' },
        lastRelease: { gitTag: 'v1.0.0', version: '1.0.0' },
        nextRelease: { gitTag: 'v1.0.1', version: '1.0.1', type: 'patch' },
        commits: commitList,
        logger: { log() {}, error() {} },
    });
}

test('the configured types are covered by fixtures', () => {
    assert.ok(types.length > 0, 'presetConfig declares no visible sections');
});

test('every configured type renders its section', async () => {
    const notes = await notesFor(commits);

    for (const entry of types) {
        assert.ok(
            notes.includes(`### ${entry.section}`),
            `section "${entry.section}" is missing:\n${notes}`,
        );
    }
});

test('the notes carry commits, not just a header', async () => {
    const notes = await notesFor(commits);
    const body = notes
        .split('\n')
        .filter((line) => line.startsWith('* '))
        .length;

    assert.equal(body, commits.length, `expected ${commits.length} commit lines:\n${notes}`);
});
