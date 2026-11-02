// KaTeX's functions that MathJax spells differently or lacks (M48), so a formula written
// for KaTeX typesets here too: its aliases as macros, a few stretchy accents as commands,
// and the letters and accents KaTeX allows inside \text.
import { Configuration } from "@mathjax/src/js/input/tex/Configuration.js";
import { CommandMap } from "@mathjax/src/js/input/tex/TokenMap.js";
import BaseMethods from "@mathjax/src/js/input/tex/base/BaseMethods.js";
import { TextMacrosMethods } from "@mathjax/src/js/input/tex/textmacros/TextMacrosMethods.js";
import type TexParser from "@mathjax/src/js/input/tex/TexParser.js";
import type { StackItem } from "@mathjax/src/js/input/tex/StackItem.js";

// MathJax places an UnderOver accent by the command's name ("\o…" over, else under).
const over = (parser: TexParser, name: string, c: string, stack: StackItem) =>
  BaseMethods.UnderOver(parser, "\\o" + name.slice(1), c, stack);
const under = (parser: TexParser, name: string, c: string, stack: StackItem) =>
  BaseMethods.UnderOver(parser, "\\u" + name.slice(1), c, stack);

new CommandMap("katex-commands", {
  Overrightarrow: [over, "21D2"],
  overleftharpoon: [over, "21BC"],
  overrightharpoon: [over, "21C0"],
  overgroup: [over, "23E0"],
  undergroup: [under, "23E1"],
  utilde: [under, "007E"],
  overlinesegment: [over, "2015"],
  underlinesegment: [under, "2015"],
  widecheck: [BaseMethods.Accent, "02C7", true],
});

new CommandMap("text-katex-commands", {
  H: [TextMacrosMethods.Accent, "\u02DD"],
  r: [TextMacrosMethods.Accent, "\u02DA"],
  o: [TextMacrosMethods.Insert, "\u00F8"],
  O: [TextMacrosMethods.Insert, "\u00D8"],
  oe: [TextMacrosMethods.Insert, "\u0153"],
  OE: [TextMacrosMethods.Insert, "\u0152"],
  ae: [TextMacrosMethods.Insert, "\u00E6"],
  AE: [TextMacrosMethods.Insert, "\u00C6"],
  aa: [TextMacrosMethods.Insert, "\u00E5"],
  ss: [TextMacrosMethods.Insert, "\u00DF"],
  i: [TextMacrosMethods.Insert, "\u0131"],
  j: [TextMacrosMethods.Insert, "\u0237"],
  P: [TextMacrosMethods.Insert, "\u00B6"],
  sect: [TextMacrosMethods.Insert, "\u00A7"],
  pounds: [TextMacrosMethods.Insert, "\u00A3"],
  copyright: [TextMacrosMethods.Insert, "\u00A9"],
  textcircled: [TextMacrosMethods.Macro, "$\\enclose{circle}{\\kern1mu\\text{#1}\\kern1mu}$", 1],
  sout: [TextMacrosMethods.Macro, "$\\enclose{horizontalstrike}{\\text{#1}}$", 1],
});

Configuration.create("katex", { handler: { macro: ["katex-commands"] } });
Configuration.create("text-katex", { parser: "text", priority: 1, handler: { macro: ["text-katex-commands"] } });

const op = (name: string) => `\\operatorname{${name}}`;
const rel = (code: string) => `\\mathrel{\\unicode{x${code}}}`;

/** KaTeX's aliases, as TeX macros. */
export const katexMacros: Record<string, string | [string, number]> = {
  // \htmlClass and friends keep their content; there's no HTML here.
  htmlClass: ["#2", 2],
  htmlId: ["#2", 2],
  htmlStyle: ["#2", 2],
  htmlData: ["#2", 2],
  // Letters and sets
  Alpha: "\\mathrm{A}", Beta: "\\mathrm{B}", Epsilon: "\\mathrm{E}", Zeta: "\\mathrm{Z}", Eta: "\\mathrm{H}",
  Iota: "\\mathrm{I}", Kappa: "\\mathrm{K}", Mu: "\\mathrm{M}", Nu: "\\mathrm{N}", Omicron: "\\mathrm{O}",
  Rho: "\\mathrm{P}", Tau: "\\mathrm{T}", Chi: "\\mathrm{X}", thetasym: "\\vartheta",
  R: "\\mathbb{R}", Reals: "\\mathbb{R}", reals: "\\mathbb{R}", N: "\\mathbb{N}", natnums: "\\mathbb{N}",
  Z: "\\mathbb{Z}", cnums: "\\mathbb{C}", Complex: "\\mathbb{C}",
  image: "\\Im", real: "\\Re", weierp: "\\wp", alef: "\\aleph", alefsym: "\\aleph",
  empty: "\\emptyset", exist: "\\exists", isin: "\\in", notni: "\\not\\ni", infin: "\\infty",
  // Symbols
  dag: "\\dagger", ddag: "\\ddagger", Dagger: "\\ddagger", sdot: "\\cdot", mathellipsis: "\\ldots",
  lq: "\\text{\u2018}", rq: "\\text{\u2019}", pounds: "\\text{\u00A3}", mathsterling: "\\text{\u00A3}",
  copyright: "\\text{\u00A9}", clubs: "\\clubsuit", diamonds: "\\diamondsuit", hearts: "\\heartsuit",
  spades: "\\spadesuit", minuso: "\\mathbin{\\unicode{x29B5}}",
  // Delimiters
  lang: "\\langle", rang: "\\rangle",
  llbracket: "\\mathopen{\\unicode{x27E6}}", rrbracket: "\\mathclose{\\unicode{x27E7}}",
  lBrace: "\\mathopen{\\unicode{x2983}}", rBrace: "\\mathclose{\\unicode{x2984}}",
  // Arrows
  rarr: "\\rightarrow", rArr: "\\Rightarrow", Rarr: "\\Rightarrow", larr: "\\leftarrow", lArr: "\\Leftarrow",
  Larr: "\\Leftarrow", uarr: "\\uparrow", uArr: "\\Uparrow", Uarr: "\\Uparrow", darr: "\\downarrow",
  dArr: "\\Downarrow", Darr: "\\Downarrow", harr: "\\leftrightarrow", hArr: "\\Leftrightarrow",
  Harr: "\\Leftrightarrow", lrarr: "\\leftrightarrow", lrArr: "\\Leftrightarrow", Lrarr: "\\Leftrightarrow",
  mapsfrom: rel("21A4"),
  // Relations
  vcentcolon: "\\mathrel{:}", approxcoloncolon: "\\mathrel{\\approx\\!::}",
  simcoloncolon: "\\mathrel{\\sim\\!::}", origof: rel("22B6"), imageof: rel("22B7"),
  // Operators
  cosec: op("cosec"), arctg: op("arctg"), arcctg: op("arcctg"), cotg: op("cotg"), ctg: op("ctg"),
  tg: op("tg"), sh: op("sh"), ch: op("ch"), th: op("th"), cth: op("cth"),
  argmax: "\\operatorname*{arg\\,max}", argmin: "\\operatorname*{arg\\,min}", plim: "\\operatorname*{plim}",
  operatornamewithlimits: ["\\operatorname*{#1}", 1],
  // Fonts and boxes
  bold: ["\\mathbf{#1}", 1], bm: ["\\boldsymbol{#1}", 1], textmd: ["\\text{#1}", 1],
  emph: ["\\textit{#1}", 1], underbar: ["\\underline{#1}", 1],
  raisebox: ["\\raise #1 {\\text{#2}}", 2],
  // Mirrored by the app's SVG reader.
  reflectbox: ["\\class{nexus-reflect}{\\text{#1}}", 1], mathreflectbox: ["\\class{nexus-reflect}{#1}", 1],
  // Notation
  angl: ["\\enclose{actuarial}{#1}", 1], angln: "\\enclose{actuarial}{n}", phase: ["\\enclose{phasorangle}{#1}", 1],
  sout: ["\\enclose{horizontalstrike}{\\text{#1}}", 1],
  url: ["\\href{#1}{\\texttt{#1}}", 1],
  gdef: "\\def",
  KaTeX: "\\mathrm{K\\kern-.17em\\raise.21em{\\scriptstyle{A}}\\kern-.15em\\TeX}",
};
