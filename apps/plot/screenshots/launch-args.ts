import type { Mode } from './manifest.ts';

const USER = 'margot.whitcombe@afcmarlow.com';
const FROZEN = '2026-05-01T08:32:00';

/** dart-entrypoint args (without the `--dart-entrypoint-args=` prefix). */
export function dartArgs(scene: string, mode: Mode, platform: string): string[] {
  return [
    `--user=${USER}`,
    `--password=${USER}`,
    `--frozen-time=${FROZEN}`,
    mode === 'dark' ? '--dark-mode' : '--light-mode',
    `--profile=screenshots-${platform}`,
    `--scene=${scene}`,
  ];
}
