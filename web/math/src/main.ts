// MathJax for JavaScriptCore (M48): TeX in, SVG out, for formulas in topics and notes.
// The app loads dist/nexus-math.js into a JSContext and calls NexusMath.typeset. There is
// no DOM and no loader there, so MathJax runs on its lite adaptor and every font file it
// would fetch later is bundled and set up at start.
import { mathjax } from "@mathjax/src/js/mathjax.js";
import { TeX } from "@mathjax/src/js/input/tex.js";
import { SVG } from "@mathjax/src/js/output/svg.js";
import { liteAdaptor } from "@mathjax/src/js/adaptors/liteAdaptor.js";
import { RegisterHTMLHandler } from "@mathjax/src/js/handlers/html.js";
import { VERSION } from "@mathjax/src/js/components/version.js";
import { MapHandler } from "@mathjax/src/js/input/tex/MapHandler.js";
import "@mathjax/src/js/input/tex/base/BaseConfiguration.js";
import "@mathjax/src/js/input/tex/ams/AmsConfiguration.js";
import "@mathjax/src/js/input/tex/amscd/AmsCdConfiguration.js";
import "@mathjax/src/js/input/tex/bbox/BboxConfiguration.js";
import "@mathjax/src/js/input/tex/boldsymbol/BoldsymbolConfiguration.js";
import "@mathjax/src/js/input/tex/braket/BraketConfiguration.js";
import "@mathjax/src/js/input/tex/cancel/CancelConfiguration.js";
import "@mathjax/src/js/input/tex/cases/CasesConfiguration.js";
import "@mathjax/src/js/input/tex/centernot/CenternotConfiguration.js";
import "@mathjax/src/js/input/tex/color/ColorConfiguration.js";
import "@mathjax/src/js/input/tex/colortbl/ColortblConfiguration.js";
import "@mathjax/src/js/input/tex/configmacros/ConfigMacrosConfiguration.js";
import "@mathjax/src/js/input/tex/empheq/EmpheqConfiguration.js";
import "@mathjax/src/js/input/tex/enclose/EncloseConfiguration.js";
import "@mathjax/src/js/input/tex/extpfeil/ExtpfeilConfiguration.js";
import "@mathjax/src/js/input/tex/gensymb/GensymbConfiguration.js";
import "@mathjax/src/js/input/tex/html/HtmlConfiguration.js";
import "@mathjax/src/js/input/tex/mathtools/MathtoolsConfiguration.js";
import "@mathjax/src/js/input/tex/mhchem/MhchemConfiguration.js";
import "@mathjax/src/js/input/tex/newcommand/NewcommandConfiguration.js";
import "@mathjax/src/js/input/tex/textcomp/TextcompConfiguration.js";
import "@mathjax/src/js/input/tex/textmacros/TextMacrosConfiguration.js";
import "@mathjax/src/js/input/tex/unicode/UnicodeConfiguration.js";
import "@mathjax/src/js/input/tex/upgreek/UpgreekConfiguration.js";
import "@mathjax/src/js/input/tex/verb/VerbConfiguration.js";
import { MathJaxNewcmFont } from "@mathjax/mathjax-newcm-font/js/svg.js";
// The font's glyph ranges that formulas use; the others (non-Latin scripts, accented
// bold and sans letters, braille) fall back to the system's fonts, drawn by the app.
import "@mathjax/mathjax-newcm-font/js/svg/dynamic/latin.js";
import "@mathjax/mathjax-newcm-font/js/svg/dynamic/double-struck.js";
import "@mathjax/mathjax-newcm-font/js/svg/dynamic/fraktur.js";
import "@mathjax/mathjax-newcm-font/js/svg/dynamic/script.js";
import "@mathjax/mathjax-newcm-font/js/svg/dynamic/sans-serif.js";
import "@mathjax/mathjax-newcm-font/js/svg/dynamic/monospace.js";
import "@mathjax/mathjax-newcm-font/js/svg/dynamic/calligraphic.js";
import "@mathjax/mathjax-newcm-font/js/svg/dynamic/math.js";
import "@mathjax/mathjax-newcm-font/js/svg/dynamic/symbols.js";
import "@mathjax/mathjax-newcm-font/js/svg/dynamic/arrows.js";
import "@mathjax/mathjax-newcm-font/js/svg/dynamic/marrows.js";
import "@mathjax/mathjax-newcm-font/js/svg/dynamic/accents.js";
import "@mathjax/mathjax-newcm-font/js/svg/dynamic/shapes.js";
import "@mathjax/mathjax-newcm-font/js/svg/dynamic/mshapes.js";
import "@mathjax/mathjax-newcm-font/js/svg/dynamic/variants.js";
import "@mathjax/mathjax-newcm-font/js/svg/dynamic/PUA.js";
// mhchem's arrows and bonds are a font extension of their own.
import { MathJaxMhchemFontExtension } from "@mathjax/mathjax-mhchem-font-extension/js/svg.js";
import { katexMacros } from "./katex.js";

const BUNDLED = new Set([
  "latin", "double-struck", "fraktur", "script", "sans-serif", "monospace", "calligraphic", "math", "symbols",
  "arrows", "marrows", "accents", "shapes", "mshapes", "variants", "PUA",
]);
const files = MathJaxNewcmFont.dynamicFiles as Record<string, unknown>;
for (const name of Object.keys(files)) if (!BUNDLED.has(name)) delete files[name];
MathJaxNewcmFont.addExtension(MathJaxMhchemFontExtension);

const adaptor = liteAdaptor();
RegisterHTMLHandler(adaptor);
const tex = new TeX({
  packages: [
    "base", "ams", "amscd", "bbox", "boldsymbol", "braket", "cancel", "cases", "centernot", "color", "colortbl",
    "configmacros", "empheq", "enclose", "extpfeil", "gensymb", "html", "mathtools", "mhchem", "newcommand",
    "textcomp", "textmacros", "unicode", "upgreek", "verb", "katex",
  ],
  macros: katexMacros,
  textmacros: { packages: ["text-base", "text-katex"] },
  // A formula with a mistake is an error the app shows, never a red guess.
  formatError: (_jax: unknown, err: Error) => {
    throw err;
  },
});
// One <svg> per formula: a browser can break inline maths at its operators, but here the
// app places each formula whole.
const svg = new SVG({ fontCache: "none", linebreaks: { inline: false } });
const doc = mathjax.document("", { InputJax: tex, OutputJax: svg });

mathjax.asyncLoad = () => null;
mathjax.asyncIsSynchronous = true;
svg.font.loadDynamicFilesSync();

export interface Result {
  /** The formula as one `<svg>` element, in MathJax's units (1000 to the em). */
  svg?: string;
  /** Why the formula couldn't be typeset. */
  error?: string;
}

// Where \newcommand, \def and \newenvironment put their definitions.
const DEFINITIONS = ["new-Command", "new-Environment", "new-Delimiter"];

function typeset(source: string, display: boolean): Result {
  try {
    tex.parseOptions.tags.reset();
    const node = doc.convert(source, { display, em: 16, ex: 8, containerWidth: 1_000_000 });
    const out = adaptor.firstChild(node);
    return { svg: adaptor.serializeXML(out) };
  } catch (e) {
    // TeX's own errors aren't Errors, but carry a message.
    const message = e && typeof e === "object" && "message" in e ? String(e.message) : String(e);
    return { error: message || "This formula can't be typeset" };
  } finally {
    doc.clear();
    // Definitions stay with the formula that makes them, as in KaTeX: one formula's
    // \def\begin mustn't break the next.
    for (const name of DEFINITIONS) (MapHandler.getMap(name) as unknown as { map: Map<string, unknown> }).map.clear();
  }
}

(globalThis as Record<string, unknown>).NexusMath = { typeset, version: VERSION };
