import { sqlCurrentClassifier } from "./sql-current";
import type { Classifier } from "./types";

const REGISTRY: Map<string, Classifier> = new Map([
  [sqlCurrentClassifier.name, sqlCurrentClassifier],
]);

export function getClassifier(name: string): Classifier {
  const c = REGISTRY.get(name);
  if (!c) {
    throw new Error(
      `Unknown classifier: ${name}. Registered: ${[...REGISTRY.keys()].join(", ")}`
    );
  }
  return c;
}

export function listClassifiers(): string[] {
  return [...REGISTRY.keys()];
}

export function registerClassifier(c: Classifier): void {
  REGISTRY.set(c.name, c);
}
