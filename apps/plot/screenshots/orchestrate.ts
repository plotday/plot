import { execFileSync } from 'node:child_process';
import { PLANS, capturesFor } from './manifest.ts';
import { dartArgs } from './launch-args.ts';
import { composePlatform } from './compose/compose.ts';

const cap = (f: string) => new URL(`./capture/${f}`, import.meta.url).pathname;
const CAPTURE: Record<string, string> = {
  'iphone-6.9': cap('ios.sh'),
  'ipad-13': cap('ipad.sh'),
  'android-phone': cap('android.sh'),
  'android-tablet': cap('android.sh'),
  'macos': cap('macos.sh'),
  'windows': cap('macos.sh'),
};
// S12 is an OS-level share-sheet flow, not an in-app scene; captured by a
// separate script that takes only <out> and needs Plot already installed.
const ANDROID_SHARE = cap('android-share.sh');

// Android picks its AVD / orientation / adb port from the environment; each
// android platform gets its own emulator port so phone and tablet don't collide.
function captureEnv(platform: string): Record<string, string | undefined> {
  if (platform === 'android-phone')
    return { ...process.env, SS_AVD: 'Galaxy_S25', SS_PORT: '5554' };
  if (platform === 'android-tablet')
    return { ...process.env, SS_AVD: 'Galaxy_Tab_S8_Ultra', SS_PORT: '5556', SS_LANDSCAPE: '1' };
  return process.env;
}
const RAW = new URL('./raw/', import.meta.url).pathname;
const REPO = new URL('../../../', import.meta.url).pathname;

const SEED = new URL('../../../libs/db/seeds/margot.yaml', import.meta.url).pathname;

function seed() {
  // `pnpm gen-seed` forwards to `--filter @plotday/db`, which runs the seed
  // script with cwd=libs/db — so a repo-root-relative path double-resolves
  // (libs/db/libs/db/...). Pass an absolute path so cwd doesn't matter.
  execFileSync('pnpm', ['gen-seed', SEED, '--apply'],
    { cwd: REPO, stdio: 'inherit' });
}

async function main() {
  const only = process.argv[2];           // optional platform filter
  if (process.env.SS_NO_SEED !== '1') seed();   // SS_NO_SEED=1 reuses existing margot data
  for (const p of PLANS) {
    if (only && only !== '--recapture' && p.platform !== only) continue;
    const env = captureEnv(p.platform);
    for (const c of capturesFor(p)) {
      const out = `${RAW}${p.platform}/${c.scene}-${c.mode}.png`;
      if (c.scene === 'S12' && p.platform.startsWith('android')) {
        // Share-sheet scene: out-only script; relies on a prior scene's install.
        execFileSync('bash', [ANDROID_SHARE, out], { stdio: 'inherit', env });
      } else {
        execFileSync('bash', [CAPTURE[p.platform], c.scene, c.mode, out,
          ...dartArgs(c.scene, c.mode, p.platform)], { stdio: 'inherit', env });
      }
    }
    await composePlatform(p);
    console.log(`done ${p.platform}`);
  }
}
main().catch((e) => {
  console.error(e);
  process.exitCode = 1;
});
