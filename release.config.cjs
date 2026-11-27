module.exports = {
  branches: ['main'],
  tagFormat: 'v${version}',
  plugins: [
    [
      '@semantic-release/commit-analyzer',
      {
        releaseRules: [
          { type: 'chore', scope: 'major-release', release: 'major' },
        ],
      },
    ],
    '@semantic-release/release-notes-generator',
    [
      '@semantic-release/exec',
      {
        generateNotesCmd: 'if [ -f "docs/releases/${nextRelease.version}.md" ]; then cat "docs/releases/${nextRelease.version}.md"; fi',
        prepareCmd: 'bash .github/scripts/set-version ${nextRelease.version}',
      },
    ],
    [
      '@semantic-release/git',
      {
        assets: ['herdr-plugin.toml'],
        message: 'chore(release): ${nextRelease.version} [skip ci]',
      },
    ],
    [
      '@semantic-release/github',
      {
        successComment: false,
        failComment: false,
        failTitle: false,
        labels: false,
        releasedLabels: false,
      },
    ],
  ],
};
