const fs = require('fs');
const path = require('path');
const CopyPlugin = require('copy-webpack-plugin');

module.exports = (env, argv) => {
  const isDev = argv.mode === 'development';
  const browser = (env && env.browser) || 'chrome';

  if (browser !== 'chrome' && browser !== 'firefox') {
    throw new Error(`Unknown target browser "${browser}". Use --env browser=chrome or --env browser=firefox.`);
  }

  const baseManifest = browser === 'firefox' ? 'manifest.firefox.json' : 'manifest.json';
  const devManifest = browser === 'firefox' ? 'manifest.firefox.dev.json' : 'manifest.dev.json';

  // manifest.dev.json (and its firefox equivalent) are gitignored, developer-local
  // overrides (e.g. pointing host_permissions at localhost). Fall back to the base
  // manifest when no local override exists.
  const manifestFile = isDev && fs.existsSync(path.resolve(__dirname, 'public', devManifest))
    ? devManifest
    : baseManifest;

  console.log(`Building for ${browser} (${argv.mode || 'production'}) using ${manifestFile}`);

  return {
    mode: argv.mode || 'production',
    devtool: isDev ? 'cheap-module-source-map' : false,
    entry: {
      background: './src/background/index.ts',
      content: './src/content/index.ts',
      popup: './src/popup/index.ts'
    },
    output: {
      path: path.resolve(__dirname, 'dist'),
      filename: '[name].js',
      clean: true,
    },
    resolve: {
      extensions: ['.ts', '.js'],
    },
    module: {
      rules: [
        {
          test: /\.ts$/,
          use: 'ts-loader',
          exclude: /node_modules/,
        },
      ],
    },
    plugins: [
      new CopyPlugin({
        patterns: [
          {
            from: 'public',
            to: '.',
            globOptions: {
              ignore: ['**/manifest*.json'],
            },
          },
          { from: `public/${manifestFile}`, to: 'manifest.json' },
          { from: 'src/assets', to: 'assets' },
        ],
      }),
    ],
  };
};
