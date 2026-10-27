import type { CapacitorConfig } from '@capacitor/cli';

const config: CapacitorConfig = {
  appId: 'io.corelo.ghostgpt',
  appName: 'GhostGPT',
  webDir: 'www',
  server: {
    allowNavigation: ['ghostgpt.live', '*.ghostgpt.live'],
  },
};

export default config;
