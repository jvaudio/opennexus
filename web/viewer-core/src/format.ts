// The app's format strings ("%d of %d", "%lld", "%@", "%1$d"): a positional one takes
// the argument it names (translations reorder them), the rest the next in order.

export function format(s: string, ...args: (string | number)[]): string {
  let i = 0;
  return s.replace(/%(?:(\d+)\$)?(?:lld|d|@)/g, (_, n?: string) =>
    String((n ? args[Number(n) - 1] : args[i++]) ?? ""),
  );
}
