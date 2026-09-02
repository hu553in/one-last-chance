const { defineConfig, globalIgnores } = require('eslint/config');
const expoConfig = require('eslint-config-expo/flat');
const eslintConfigPrettier = require('eslint-config-prettier/flat');

module.exports = defineConfig([
  expoConfig,
  globalIgnores([
    '.cache/**',
    '.expo/**',
    'build/**',
    'coverage/**',
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
        version: '19',
      },
    },
  },
  eslintConfigPrettier,
]);
