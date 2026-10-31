// The app's format strings ("%d of %d", "%lld", "%@", "%1$d"), filled in order.

export function format(s: string, ...args: (string | number)[]): string {
  let i = 0;
  return s.replace(/%(?:\d\$)?(?:lld|d|@)/g, () => String(args[i++] ?? ""));
}
