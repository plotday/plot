import { execFileSync } from 'node:child_process';
import { PLANS, capturesFor } from './manifest.ts';
import { dartArgs } from './launch-args.ts';
import { composePlatform } from './compose/compose.ts';

const CAPTURE: Record<string, string> = {
  'iphone-6.9': new URL('./capture/ios.sh', import.meta.url).pathname,
  'macos': new URL('./capture/macos.sh', import.meta.url).pathname,
};
const RAW = new URL('./raw/', import.meta.url).pathname;
const REPO = new URL('../../../', import.meta.url).pathname;

function seed() {
  execFileSync('pnpm', ['gen-seed', '--apply', 'libs/db/seeds/margot.yaml'],
    { cwd: REPO, stdio: 'inherit' });
}

async function main() {
  const only = process.argv[2];           // optional platform filter
  seed();
  for (const p of PLANS) {
    if (only && only !== '--recapture' && p.platform !== only) continue;
    for (const c of capturesFor(p)) {
      const out = `${RAW}${p.platform}/${c.scene}-${c.mode}.png`;
      execFileSync('bash', [CAPTURE[p.platform], c.scene, c.mode, out,
        ...dartArgs(c.scene, c.mode, p.platform)], { stdio: 'inherit' });
    }
    await composePlatform(p);
    console.log(`done ${p.platform}`);
  }
}
main().catch((e) => {
  console.error(e);
  process.exitCode = 1;
});
