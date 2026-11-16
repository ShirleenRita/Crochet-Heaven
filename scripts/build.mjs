import { mkdir, readFile, writeFile } from 'node:fs/promises';

const rootFiles = ['index.html', 'app.js', 'styles.css'];
const outputDir = new URL('../dist/', import.meta.url);

await mkdir(outputDir, { recursive: true });

for (const file of rootFiles) {
  const source = new URL(`../${file}`, import.meta.url);
  const content = await readFile(source);
  await writeFile(new URL(file, outputDir), content);
}

const localConfig = await import(new URL('../supabase-config.js', import.meta.url));
const supabaseUrl = process.env.SUPABASE_URL || localConfig.SUPABASE_URL || '';
const publishableKey = process.env.SUPABASE_PUBLISHABLE_KEY || localConfig.SUPABASE_PUBLISHABLE_KEY || '';
const config = [
  `export const SUPABASE_URL = ${JSON.stringify(supabaseUrl)};`,
  `export const SUPABASE_PUBLISHABLE_KEY = ${JSON.stringify(publishableKey)};`,
  ''
].join('\n');

await writeFile(new URL('supabase-config.js', outputDir), config, 'utf8');
console.log(`Built Crochet Haven into ${new URL('../dist/', import.meta.url).pathname}`);
