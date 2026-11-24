const { defineConfig, globalIgnores } = require('eslint/config');
const expoConfig = require('eslint-config-expo/flat');

module.exports = defineConfig([
  expoConfig,
  globalIgnores([
    '.cache/**',
    '.expo/**',
    'build/**',
    'dist/**',
    'ios/**',
    'native/olcrtc-tunnel-core/Frameworks/**',
  ]),
  {
    linterOptions: {
      reportUnusedDisableDirectives: 'error',
    },
    settings: {
      react: {
        version: require('react/package.json').version,
      },
    },
  },
]);
