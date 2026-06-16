export interface Clip { x: number; y: number; width: number; height: number; }

/** The full canvas size for a spanning hero = two slots side by side. */
export function heroCanvas([w, h]: [number, number]): [number, number] {
  return [w * 2, h];
}

/** Clip rects to slice the rendered hero canvas back into two slot PNGs. */
export function heroClips([w, h]: [number, number]): Clip[] {
  return [
    { x: 0, y: 0, width: w, height: h },
    { x: w, y: 0, width: w, height: h },
  ];
}
