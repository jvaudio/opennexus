import { describe, expect, it } from "vitest";
import { format } from "../src/format";

describe("the app's format strings", () => {
  it("fill in order", () => {
    expect(format("%d of %d", 2, 5)).toBe("2 of 5");
    expect(format("%lld topics in %@", 12, "Plan")).toBe("12 topics in Plan");
  });

  it("fill a positional specifier from the argument it names, as translations reorder them", () => {
    expect(format("%2$d / %1$d", 2, 5)).toBe("5 / 2");
    expect(format("%1$@ · %1$@", "A")).toBe("A · A");
    expect(format("%12$d", ...Array.from({ length: 12 }, (_, k) => k + 1))).toBe("12");
  });

  it("leave a missing argument empty", () => {
    expect(format("%d and %d", 1)).toBe("1 and ");
  });
});
