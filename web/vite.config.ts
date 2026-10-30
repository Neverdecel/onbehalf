import tailwindcss from '@tailwindcss/vite';
import react from '@vitejs/plugin-react';
import {defineConfig} from 'vite';

export default defineConfig({
  // GitHub Pages serves the project at /onbehalf/.
  base: '/onbehalf/',
  plugins: [react(), tailwindcss()],
  build: {
    target: 'es2020',
    // The Jekyll site already has an assets/ directory (blog images, favicon).
    // The two builds go into one directory, so the bundle uses its own name.
    assetsDir: 'app',
  },
});
