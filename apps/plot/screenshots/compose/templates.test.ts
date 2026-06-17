import { test } from 'node:test';
import assert from 'node:assert/strict';
import { multipanelWindows } from './templates.ts';

test('multipanelWindows renders the headline inside a Windows-style framed image', () => {
  const html = multipanelWindows({
    src: 'data:image/png;base64,AAAA',
    w: 3840,
    h: 2160,
    headline: 'Drive it from the keyboard',
  });
  assert.match(html, /Drive it from the keyboard/);
  assert.match(html, /border-radius:\d+px/);    // Windows 11 rounded corners
  assert.match(html, /border:1px solid/);        // subtle window border
  assert.match(html, /box-shadow:/);             // drop shadow
  assert.match(html, /data:image\/png;base64,AAAA/);
});
