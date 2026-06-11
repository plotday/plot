import { describe, it, expect } from "vitest";
import { wilsonInterval, mcnemarExact } from "../src/scoring/stats";

describe("wilsonInterval", () => {
  it("8 of 10 ≈ {lo: 0.49, hi: 0.943}", () => {
    const { lo, hi } = wilsonInterval(8, 10);
    expect(lo).toBeCloseTo(0.49, 1); // within ±0.01
    expect(hi).toBeCloseTo(0.943, 1);
  });

  it("0 of 0 → {lo: 0, hi: 1}", () => {
    const { lo, hi } = wilsonInterval(0, 0);
    expect(lo).toBe(0);
    expect(hi).toBe(1);
  });

  it("10 of 10 → hi capped at 1, lo ≈ 0.722", () => {
    const { lo, hi } = wilsonInterval(10, 10);
    expect(hi).toBe(1);
    expect(lo).toBeCloseTo(0.722, 1);
  });
});

describe("mcnemarExact", () => {
  it("mcnemarExact(6, 0) ≈ 0.03125", () => {
    expect(mcnemarExact(6, 0)).toBeCloseTo(0.03125, 4);
  });

  it("mcnemarExact(8, 1) ≈ 0.0391", () => {
    expect(mcnemarExact(8, 1)).toBeCloseTo(0.0391, 3);
  });

  it("mcnemarExact(0, 0) === 1", () => {
    expect(mcnemarExact(0, 0)).toBe(1);
  });

  it("symmetry: mcnemarExact(5, 2) === mcnemarExact(2, 5)", () => {
    expect(mcnemarExact(5, 2)).toBe(mcnemarExact(2, 5));
  });

  it("equal split mcnemarExact(3, 3) <= 1", () => {
    expect(mcnemarExact(3, 3)).toBeLessThanOrEqual(1);
  });
});
