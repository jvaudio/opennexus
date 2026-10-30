#!/usr/bin/env python3
"""Writes App/OpenNexusiOS.xcodeproj/project.pbxproj (M47b): OpenNexus for iPad and iPhone.

A project of its own, so the Mac project stays as it is (D395). Like make_project.py,
it lists the targets, their sources (synchronised folders), package products, plists and
entitlements, and object ids are stable hashes, so regenerating produces the same file.

    python3 App/tools/make_ios_project.py
"""
import hashlib
import os

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))  # App/
NAME = "OpenNexusiOS"
OUT = os.path.join(ROOT, f"{NAME}.xcodeproj", "project.pbxproj")
BUNDLE = "com.opennexus.OpenNexus"


def oid(*parts):
    return hashlib.sha1(("ios/" + "/".join(parts)).encode()).hexdigest()[:24].upper()


APP = dict(
    name="OpenNexus", type="com.apple.product-type.application", product="OpenNexus.app",
    wrapper="wrapper.application", folder="iOS/OpenNexus", packages=["OpenNexusKit", "NexusTouchKit", "NexusNetKit"],
    settings={
        "ASSETCATALOG_COMPILER_APPICON_NAME": "AppIcon",
        "ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME": "AccentColor",
        "CODE_SIGN_ENTITLEMENTS": "iOS/Support/OpenNexus.entitlements",
        "INFOPLIST_FILE": "iOS/Support/Info.plist",
        "INFOPLIST_KEY_CFBundleDisplayName": "OpenNexus",
        "INFOPLIST_KEY_LSApplicationCategoryType": "public.app-category.productivity",
        "INFOPLIST_KEY_NSHumanReadableCopyright": "OpenNexus contributors",
        "INFOPLIST_KEY_NSMicrophoneUsageDescription": "OpenNexus records audio notes on this device. Recordings stay in your document.",
        "INFOPLIST_KEY_NSSpeechRecognitionUsageDescription": "Record to Map transcribes speech on this device. Nothing leaves your device.",
        "INFOPLIST_KEY_NSCameraUsageDescription": "Image to map scans a whiteboard or a page with the camera. The picture stays on this device.",
        "INFOPLIST_KEY_UILaunchScreen_Generation": "YES",
        "LD_RUNPATH_SEARCH_PATHS": ["$(inherited)", "@executable_path/Frameworks"],
        "PRODUCT_BUNDLE_IDENTIFIER": BUNDLE,
        "PRODUCT_NAME": "OpenNexus",
        "SWIFT_DEFAULT_ACTOR_ISOLATION": "MainActor",
        # The "Localized strings" phase reads the package's resource bundle.
        "ENABLE_USER_SCRIPT_SANDBOXING": "NO",
    },
)

EXTENSIONS = [
    dict(name="QuickLookPreview", packages=["OpenNexusKit", "NexusTouchKit"]),
    dict(name="QuickLookThumbnail", packages=["OpenNexusKit", "NexusTouchKit"]),
    dict(name="Share", packages=["NexusShared"]),
    dict(name="Widgets", packages=["NexusShared", "NexusWidgetsKit"]),
]
for t in EXTENSIONS:
    n = t["name"]
    t.update(
        ext=True, type="com.apple.product-type.app-extension", product=f"{n}.appex", wrapper="wrapper.app-extension",
        folder=f"iOS/Extensions/{n}",
        settings={
            "CODE_SIGN_ENTITLEMENTS": f"iOS/Support/{n}/{n}.entitlements",
            "INFOPLIST_FILE": f"iOS/Support/{n}/Info.plist",
            "INFOPLIST_KEY_CFBundleDisplayName": "OpenNexus",
            "INFOPLIST_KEY_NSHumanReadableCopyright": "OpenNexus contributors",
            "LD_RUNPATH_SEARCH_PATHS": ["$(inherited)", "@executable_path/Frameworks", "@executable_path/../../Frameworks"],
            "PRODUCT_BUNDLE_IDENTIFIER": f"{BUNDLE}.{n}",
            "SKIP_INSTALL": "YES",
            "APPLICATION_EXTENSION_API_ONLY": "YES",
        },
    )

TESTS = [
    # Unit tests run inside the app (goldens, text parity, keys, gestures, network, timing).
    dict(
        name="OpenNexusiOSTests", type="com.apple.product-type.bundle.unit-test", product="OpenNexusiOSTests.xctest",
        wrapper="wrapper.cfbundle", folder="iOS/Tests", packages=["OpenNexusKit", "NexusTouchKit"], test=True,
        settings={
            "BUNDLE_LOADER": "$(TEST_HOST)",
            "TEST_HOST": "$(BUILT_PRODUCTS_DIR)/OpenNexus.app/OpenNexus",
            "PRODUCT_BUNDLE_IDENTIFIER": f"{BUNDLE}.Tests",
            "GENERATE_INFOPLIST_FILE": "YES",
            "SKIP_INSTALL": "YES",
            "LD_RUNPATH_SEARCH_PATHS": ["$(inherited)", "@executable_path/Frameworks", "@loader_path/Frameworks"],
        },
    ),
    dict(
        name="OpenNexusiOSUITests", type="com.apple.product-type.bundle.ui-testing", product="OpenNexusiOSUITests.xctest",
        wrapper="wrapper.cfbundle", folder="iOS/UITests", packages=[], test=True,
        settings={
            "PRODUCT_BUNDLE_IDENTIFIER": f"{BUNDLE}.UITests",
            "TEST_TARGET_NAME": "OpenNexus",
            "GENERATE_INFOPLIST_FILE": "YES",
            "SKIP_INSTALL": "YES",
            "LD_RUNPATH_SEARCH_PATHS": ["$(inherited)", "@executable_path/Frameworks", "@loader_path/Frameworks"],
        },
    ),
]
TARGETS = [APP] + EXTENSIONS + TESTS

COMMON = {
    "CURRENT_PROJECT_VERSION": "1",
    "GENERATE_INFOPLIST_FILE": "YES",
    "MARKETING_VERSION": "0.3",
    "PRODUCT_NAME": "$(TARGET_NAME)",
    "SWIFT_APPROACHABLE_CONCURRENCY": "YES",
    "SWIFT_EMIT_LOC_STRINGS": "YES",
    "SWIFT_UPCOMING_FEATURE_MEMBER_IMPORT_VISIBILITY": "YES",
}

PROJECT = {
    "ALWAYS_SEARCH_USER_PATHS": "NO",
    "ASSETCATALOG_COMPILER_GENERATE_SWIFT_ASSET_SYMBOL_EXTENSIONS": "YES",
    "CLANG_ENABLE_MODULES": "YES",
    "CLANG_ENABLE_OBJC_ARC": "YES",
    "COPY_PHASE_STRIP": "NO",
    "ENABLE_STRICT_OBJC_MSGSEND": "YES",
    "ENABLE_USER_SCRIPT_SANDBOXING": "YES",
    "IPHONEOS_DEPLOYMENT_TARGET": "27.0",
    "LOCALIZATION_PREFERS_STRING_CATALOGS": "YES",
    "SDKROOT": "iphoneos",
    "SUPPORTED_PLATFORMS": "iphoneos iphonesimulator",
    "SUPPORTS_MACCATALYST": "NO",
    "SWIFT_STRICT_CONCURRENCY": "complete",
    "SWIFT_VERSION": "6.0",
    # The iPhone (M47c) and the iPad (M47b): one app, laid out by size class (D412).
    "TARGETED_DEVICE_FAMILY": "1,2",
}
DEBUG = {
    "DEBUG_INFORMATION_FORMAT": "dwarf",
    "ENABLE_TESTABILITY": "YES",
    "GCC_OPTIMIZATION_LEVEL": "0",
    "GCC_PREPROCESSOR_DEFINITIONS": ["DEBUG=1", "$(inherited)"],
    "ONLY_ACTIVE_ARCH": "YES",
    "SWIFT_ACTIVE_COMPILATION_CONDITIONS": "DEBUG $(inherited)",
    "SWIFT_OPTIMIZATION_LEVEL": "-Onone",
}
RELEASE = {
    "DEBUG_INFORMATION_FORMAT": "dwarf-with-dsym",
    "ENABLE_NS_ASSERTIONS": "NO",
    "SWIFT_COMPILATION_MODE": "wholemodule",
    "VALIDATE_PRODUCT": "YES",
}


def q(v):
    s = str(v)
    if s and all(c.isalnum() or c in "._/" for c in s) and not s[0].isdigit() or s in ("YES", "NO"):
        return s
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"') + '"'


def settings_block(d, indent):
    pad = "\t" * indent
    lines = []
    for k in sorted(d):
        v = d[k]
        if isinstance(v, list):
            lines.append(f"{pad}{k} = (")
            lines += [f"{pad}\t{q(x)}," for x in v]
            lines.append(f"{pad});")
        else:
            lines.append(f"{pad}{k} = {q(v)};")
    return "\n".join(lines)


def listing(items, indent=4):
    pad = "\t" * indent
    return "".join(f"{pad}{i},\n" for i in items)


objs = {}


def add(section, ident, text):
    objs.setdefault(section, []).append((ident, text))


PROJ = oid("project")
MAIN_GROUP = oid("group", "main")
PRODUCTS = oid("group", "products")
SUPPORT = oid("group", "support")
PKG = oid("package", "..")
CONFIG_REF = oid("file", "Config/Base.xcconfig")
add("PBXFileReference", CONFIG_REF, f'{CONFIG_REF} /* Base.xcconfig */ = {{isa = PBXFileReference; lastKnownFileType = text.xcconfig; name = Base.xcconfig; path = Config/Base.xcconfig; sourceTree = "<group>"; }};')

product_deps = {}
for t in TARGETS:
    n = t["name"]
    t["id"] = oid("target", n)
    t["ref"] = oid("product", n)
    t["sync"] = oid("sync", n)
    t["phases"] = {k: oid("phase", n, k) for k in ("sources", "frameworks", "resources")}
    t["configs"] = oid("configlist", n)
    add("PBXFileReference", t["ref"], f'{t["ref"]} /* {t["product"]} */ = {{isa = PBXFileReference; explicitFileType = {t["wrapper"]}; includeInIndex = 0; path = {q(t["product"])}; sourceTree = BUILT_PRODUCTS_DIR; }};')
    folder_name = os.path.basename(t["folder"])
    add("PBXFileSystemSynchronizedRootGroup", t["sync"], f'{t["sync"]} /* {folder_name} */ = {{isa = PBXFileSystemSynchronizedRootGroup; path = {q(t["folder"])}; sourceTree = "<group>"; }};')
    files = []
    for p in t["packages"]:
        dep = oid("pkgdep", n, p)
        bf = oid("buildfile", n, p)
        product_deps.setdefault(n, []).append(f"{dep} /* {p} */")
        add("XCSwiftPackageProductDependency", dep, f"{dep} /* {p} */ = {{\n\t\t\tisa = XCSwiftPackageProductDependency;\n\t\t\tpackage = {PKG} /* XCLocalSwiftPackageReference \"..\" */;\n\t\t\tproductName = {p};\n\t\t}};")
        add("PBXBuildFile", bf, f"{bf} /* {p} in Frameworks */ = {{isa = PBXBuildFile; productRef = {dep} /* {p} */; }};")
        files.append(f"{bf} /* {p} in Frameworks */")
    add("PBXFrameworksBuildPhase", t["phases"]["frameworks"], f'{t["phases"]["frameworks"]} /* Frameworks */ = {{\n\t\t\tisa = PBXFrameworksBuildPhase;\n\t\t\tbuildActionMask = 2147483647;\n\t\t\tfiles = (\n{listing(files)}\t\t\t);\n\t\t\trunOnlyForDeploymentPostprocessing = 0;\n\t\t}};')
    add("PBXSourcesBuildPhase", t["phases"]["sources"], f'{t["phases"]["sources"]} /* Sources */ = {{\n\t\t\tisa = PBXSourcesBuildPhase;\n\t\t\tbuildActionMask = 2147483647;\n\t\t\tfiles = (\n\t\t\t);\n\t\t\trunOnlyForDeploymentPostprocessing = 0;\n\t\t}};')
    add("PBXResourcesBuildPhase", t["phases"]["resources"], f'{t["phases"]["resources"]} /* Resources */ = {{\n\t\t\tisa = PBXResourcesBuildPhase;\n\t\t\tbuildActionMask = 2147483647;\n\t\t\tfiles = (\n\t\t\t);\n\t\t\trunOnlyForDeploymentPostprocessing = 0;\n\t\t}};')


def depend(on, tag):
    proxy = oid("proxy", tag)
    dep = oid("dependency", tag)
    add("PBXContainerItemProxy", proxy, f'{proxy} /* PBXContainerItemProxy */ = {{\n\t\t\tisa = PBXContainerItemProxy;\n\t\t\tcontainerPortal = {PROJ} /* Project object */;\n\t\t\tproxyType = 1;\n\t\t\tremoteGlobalIDString = {on["id"]};\n\t\t\tremoteInfo = {q(on["name"])};\n\t\t}};')
    add("PBXTargetDependency", dep, f'{dep} /* PBXTargetDependency */ = {{\n\t\t\tisa = PBXTargetDependency;\n\t\t\ttarget = {on["id"]} /* {on["name"]} */;\n\t\t\ttargetProxy = {proxy} /* PBXContainerItemProxy */;\n\t\t}};')
    return f"{dep} /* PBXTargetDependency */"


# The app embeds the extensions (PlugIns), signing on copy; the tests depend on the app.
EMBED = oid("phase", "OpenNexus", "embed-extensions")
embed_files, app_deps = [], []
for t in EXTENSIONS:
    bf = oid("embed", t["name"])
    add("PBXBuildFile", bf, f'{bf} /* {t["product"]} in Embed Foundation Extensions */ = {{isa = PBXBuildFile; fileRef = {t["ref"]} /* {t["product"]} */; settings = {{ATTRIBUTES = (RemoveHeadersOnCopy, ); }}; }};')
    embed_files.append(f'{bf} /* {t["product"]} in Embed Foundation Extensions */')
    app_deps.append(depend(t, t["name"]))
add("PBXCopyFilesBuildPhase", EMBED, f'{EMBED} /* Embed Foundation Extensions */ = {{\n\t\t\tisa = PBXCopyFilesBuildPhase;\n\t\t\tbuildActionMask = 2147483647;\n\t\t\tdstPath = "";\n\t\t\tdstSubfolderSpec = 13;\n\t\t\tfiles = (\n{listing(embed_files)}\t\t\t);\n\t\t\tname = "Embed Foundation Extensions";\n\t\t\trunOnlyForDeploymentPostprocessing = 0;\n\t\t}};')
test_deps = {t["name"]: [depend(APP, t["name"] + "-app")] for t in TESTS}

# SwiftUI literals in the package resolve against the main bundle, so the app carries the
# package catalog's compiled strings as its own Localizable table (M10). iOS bundles are flat.
LOC_PHASE = oid("phase", "OpenNexus", "localized-strings")
LOC_SCRIPT = """src="$BUILT_PRODUCTS_DIR/OpenNexus_NexusScene.bundle"
dst="$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH"
for d in "$src"/*.lproj; do
  [ -d "$d" ] || continue
  mkdir -p "$dst/$(basename "$d")"
  for f in "$d"/Localizable.strings "$d"/Localizable.stringsdict; do [ -f "$f" ] && cp -f "$f" "$dst/$(basename "$d")/"; done
done
exit 0
"""
LOC_SCRIPT_Q = LOC_SCRIPT.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n")
add("PBXShellScriptBuildPhase", LOC_PHASE, f'{LOC_PHASE} /* Localized strings */ = {{\n\t\t\tisa = PBXShellScriptBuildPhase;\n\t\t\talwaysOutOfDate = 1;\n\t\t\tbuildActionMask = 2147483647;\n\t\t\tfiles = (\n\t\t\t);\n\t\t\tinputPaths = (\n\t\t\t);\n\t\t\tname = "Localized strings";\n\t\t\toutputPaths = (\n\t\t\t);\n\t\t\trunOnlyForDeploymentPostprocessing = 0;\n\t\t\tshellPath = /bin/sh;\n\t\t\tshellScript = "{LOC_SCRIPT_Q}";\n\t\t}};')

for t in TARGETS:
    n = t["name"]
    phases = [f'{t["phases"]["sources"]} /* Sources */', f'{t["phases"]["frameworks"]} /* Frameworks */', f'{t["phases"]["resources"]} /* Resources */']
    deps = []
    if t is APP:
        phases += [f"{EMBED} /* Embed Foundation Extensions */", f"{LOC_PHASE} /* Localized strings */"]
        deps = app_deps
    elif t.get("test"):
        deps = test_deps[n]
    add("PBXNativeTarget", t["id"], f'{t["id"]} /* {n} */ = {{\n\t\t\tisa = PBXNativeTarget;\n\t\t\tbuildConfigurationList = {t["configs"]} /* Build configuration list for PBXNativeTarget "{n}" */;\n\t\t\tbuildPhases = (\n{listing(phases)}\t\t\t);\n\t\t\tbuildRules = (\n\t\t\t);\n\t\t\tdependencies = (\n{listing(deps)}\t\t\t);\n\t\t\tfileSystemSynchronizedGroups = (\n\t\t\t\t{t["sync"]} /* {os.path.basename(t["folder"])} */,\n\t\t\t);\n\t\t\tname = {q(n)};\n\t\t\tpackageProductDependencies = (\n{listing(product_deps.get(n, []))}\t\t\t);\n\t\t\tproductName = {q(n)};\n\t\t\tproductReference = {t["ref"]} /* {t["product"]} */;\n\t\t\tproductType = "{t["type"]}";\n\t\t}};')
    ids = []
    for cfg in ("Debug", "Release"):
        cid = oid("config", n, cfg)
        ids.append(cid)
        s = dict(COMMON)
        s.update(t["settings"])
        add("XCBuildConfiguration", cid, f"{cid} /* {cfg} */ = {{\n\t\t\tisa = XCBuildConfiguration;\n\t\t\tbuildSettings = {{\n{settings_block(s, 4)}\n\t\t\t}};\n\t\t\tname = {cfg};\n\t\t}};")
    add("XCConfigurationList", t["configs"], f'{t["configs"]} /* Build configuration list for PBXNativeTarget "{n}" */ = {{\n\t\t\tisa = XCConfigurationList;\n\t\t\tbuildConfigurations = (\n\t\t\t\t{ids[0]} /* Debug */,\n\t\t\t\t{ids[1]} /* Release */,\n\t\t\t);\n\t\t\tdefaultConfigurationIsVisible = 0;\n\t\t\tdefaultConfigurationName = Release;\n\t\t}};')

proj_cfgs = []
for cfg, extra in (("Debug", DEBUG), ("Release", RELEASE)):
    cid = oid("config", "project", cfg)
    proj_cfgs.append(cid)
    s = dict(PROJECT)
    s.update(extra)
    add("XCBuildConfiguration", cid, f"{cid} /* {cfg} */ = {{\n\t\t\tisa = XCBuildConfiguration;\n\t\t\tbaseConfigurationReference = {CONFIG_REF} /* Base.xcconfig */;\n\t\t\tbuildSettings = {{\n{settings_block(s, 4)}\n\t\t\t}};\n\t\t\tname = {cfg};\n\t\t}};")
PROJ_CFGS = oid("configlist", "project")
add("XCConfigurationList", PROJ_CFGS, f'{PROJ_CFGS} /* Build configuration list for PBXProject "{NAME}" */ = {{\n\t\t\tisa = XCConfigurationList;\n\t\t\tbuildConfigurations = (\n\t\t\t\t{proj_cfgs[0]} /* Debug */,\n\t\t\t\t{proj_cfgs[1]} /* Release */,\n\t\t\t);\n\t\t\tdefaultConfigurationIsVisible = 0;\n\t\t\tdefaultConfigurationName = Release;\n\t\t}};')

# Support files (plists and entitlements), grouped as on disk.
support_children = []
for f in ("Info.plist", "OpenNexus.entitlements"):
    fid = oid("file", "Support", f)
    kind = "text.plist.xml" if f.endswith(".plist") else "text.plist.entitlements"
    add("PBXFileReference", fid, f'{fid} /* {f} */ = {{isa = PBXFileReference; lastKnownFileType = {kind}; path = {q(f)}; sourceTree = "<group>"; }};')
    support_children.append(f"{fid} /* {f} */")
for t in EXTENSIONS:
    n = t["name"]
    gid = oid("group", "Support", n)
    kids = []
    for f in ("Info.plist", f"{n}.entitlements"):
        fid = oid("file", "Support", n, f)
        kind = "text.plist.xml" if f.endswith(".plist") else "text.plist.entitlements"
        add("PBXFileReference", fid, f'{fid} /* {f} */ = {{isa = PBXFileReference; lastKnownFileType = {kind}; path = {q(f)}; sourceTree = "<group>"; }};')
        kids.append(f"{fid} /* {f} */")
    add("PBXGroup", gid, f'{gid} /* {n} */ = {{\n\t\t\tisa = PBXGroup;\n\t\t\tchildren = (\n{listing(kids)}\t\t\t);\n\t\t\tpath = {q(n)};\n\t\t\tsourceTree = "<group>";\n\t\t}};')
    support_children.append(f"{gid} /* {n} */")
add("PBXGroup", SUPPORT, f'{SUPPORT} /* Support */ = {{\n\t\t\tisa = PBXGroup;\n\t\t\tchildren = (\n{listing(support_children)}\t\t\t);\n\t\t\tpath = iOS/Support;\n\t\t\tsourceTree = "<group>";\n\t\t}};')
EXT_GROUP = oid("group", "Extensions")
add("PBXGroup", EXT_GROUP, f'{EXT_GROUP} /* Extensions */ = {{\n\t\t\tisa = PBXGroup;\n\t\t\tchildren = (\n{listing(t["sync"] + " /* " + t["name"] + " */" for t in EXTENSIONS)}\t\t\t);\n\t\t\tname = Extensions;\n\t\t\tsourceTree = "<group>";\n\t\t}};')
add("PBXGroup", PRODUCTS, f'{PRODUCTS} /* Products */ = {{\n\t\t\tisa = PBXGroup;\n\t\t\tchildren = (\n{listing(t["ref"] + " /* " + t["product"] + " */" for t in TARGETS)}\t\t\t);\n\t\t\tname = Products;\n\t\t\tsourceTree = "<group>";\n\t\t}};')
main_children = [f'{APP["sync"]} /* OpenNexus */', f"{EXT_GROUP} /* Extensions */"] + [
    f'{t["sync"]} /* {os.path.basename(t["folder"])} */' for t in TESTS
] + [f"{SUPPORT} /* Support */", f"{CONFIG_REF} /* Base.xcconfig */", f"{PRODUCTS} /* Products */"]
add("PBXGroup", MAIN_GROUP, f'{MAIN_GROUP} = {{\n\t\t\tisa = PBXGroup;\n\t\t\tchildren = (\n{listing(main_children)}\t\t\t);\n\t\t\tsourceTree = "<group>";\n\t\t}};')
add("XCLocalSwiftPackageReference", PKG, f'{PKG} /* XCLocalSwiftPackageReference ".." */ = {{\n\t\t\tisa = XCLocalSwiftPackageReference;\n\t\t\trelativePath = ..;\n\t\t}};')

attrs = "".join(
    f'\t\t\t\t\t{t["id"]} = {{\n\t\t\t\t\t\tCreatedOnToolsVersion = 27.0;\n'
    + (f'\t\t\t\t\t\tTestTargetID = {APP["id"]};\n' if t.get("test") else "")
    + "\t\t\t\t\t};\n"
    for t in TARGETS
)
add("PBXProject", PROJ, f'{PROJ} /* Project object */ = {{\n\t\t\tisa = PBXProject;\n\t\t\tattributes = {{\n\t\t\t\tBuildIndependentTargetsInParallel = 1;\n\t\t\t\tLastSwiftUpdateCheck = 2700;\n\t\t\t\tLastUpgradeCheck = 2700;\n\t\t\t\tTargetAttributes = {{\n{attrs}\t\t\t\t}};\n\t\t\t}};\n\t\t\tbuildConfigurationList = {PROJ_CFGS} /* Build configuration list for PBXProject "{NAME}" */;\n\t\t\tdevelopmentRegion = en;\n\t\t\thasScannedForEncodings = 0;\n\t\t\tknownRegions = (\n\t\t\t\ten,\n\t\t\t\tBase,\n\t\t\t);\n\t\t\tmainGroup = {MAIN_GROUP};\n\t\t\tminimizedProjectReferenceProxies = 1;\n\t\t\tpackageReferences = (\n\t\t\t\t{PKG} /* XCLocalSwiftPackageReference ".." */,\n\t\t\t);\n\t\t\tpreferredProjectObjectVersion = 77;\n\t\t\tproductRefGroup = {PRODUCTS} /* Products */;\n\t\t\tprojectDirPath = "";\n\t\t\tprojectRoot = "";\n\t\t\ttargets = (\n{listing(t["id"] + " /* " + t["name"] + " */" for t in TARGETS)}\t\t\t);\n\t\t}};')

ORDER = [
    "PBXBuildFile", "PBXContainerItemProxy", "PBXCopyFilesBuildPhase", "PBXFileReference",
    "PBXFileSystemSynchronizedRootGroup", "PBXFrameworksBuildPhase", "PBXGroup", "PBXNativeTarget", "PBXProject",
    "PBXResourcesBuildPhase", "PBXShellScriptBuildPhase", "PBXSourcesBuildPhase", "PBXTargetDependency",
    "XCBuildConfiguration", "XCConfigurationList", "XCLocalSwiftPackageReference", "XCSwiftPackageProductDependency",
]
out = ["// !$*UTF8*$!", "{", "\tarchiveVersion = 1;", "\tclasses = {", "\t};", "\tobjectVersion = 77;", "\tobjects = {", ""]
for sec in ORDER:
    items = sorted(objs.get(sec, []))
    if not items:
        continue
    out.append(f"/* Begin {sec} section */")
    out += [f"\t\t{text}" for _, text in items]
    out.append(f"/* End {sec} section */")
    out.append("")
out += ["\t};", f"\trootObject = {PROJ} /* Project object */;", "}", ""]
os.makedirs(os.path.dirname(OUT), exist_ok=True)
open(OUT, "w").write("\n".join(out))


def ref(t):
    return (
        f'<BuildableReference BuildableIdentifier = "primary" BlueprintIdentifier = "{t["id"]}" '
        f'BuildableName = "{t["product"]}" BlueprintName = "{t["name"]}" ReferencedContainer = "container:{NAME}.xcodeproj">'
        "</BuildableReference>"
    )


testables = "".join(
    f'         <TestableReference skipped = "NO">\n            {ref(t)}\n         </TestableReference>\n' for t in TESTS
)
scheme = f"""<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion = "2700" version = "1.7">
   <BuildAction parallelizeBuildables = "YES" buildImplicitDependencies = "YES">
      <BuildActionEntries>
         <BuildActionEntry buildForTesting = "YES" buildForRunning = "YES" buildForProfiling = "YES" buildForArchiving = "YES" buildForAnalyzing = "YES">
            {ref(APP)}
         </BuildActionEntry>
      </BuildActionEntries>
   </BuildAction>
   <TestAction buildConfiguration = "Debug" selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv = "YES">
      <Testables>
{testables}      </Testables>
   </TestAction>
   <LaunchAction buildConfiguration = "Debug" selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB" launchStyle = "0" useCustomWorkingDirectory = "NO" ignoresPersistentStateOnLaunch = "NO" debugDocumentVersioning = "YES" allowLocationSimulation = "YES">
      <BuildableProductRunnable runnableDebuggingMode = "0">
         {ref(APP)}
      </BuildableProductRunnable>
   </LaunchAction>
   <ProfileAction buildConfiguration = "Release" shouldUseLaunchSchemeArgsEnv = "YES" savedToolIdentifier = "" useCustomWorkingDirectory = "NO" debugDocumentVersioning = "YES">
      <BuildableProductRunnable runnableDebuggingMode = "0">
         {ref(APP)}
      </BuildableProductRunnable>
   </ProfileAction>
   <AnalyzeAction buildConfiguration = "Debug"></AnalyzeAction>
   <ArchiveAction buildConfiguration = "Release" revealArchiveInOrganizer = "YES"></ArchiveAction>
</Scheme>
"""
scheme_dir = os.path.join(ROOT, f"{NAME}.xcodeproj", "xcshareddata", "xcschemes")
os.makedirs(scheme_dir, exist_ok=True)
old = os.path.join(scheme_dir, "OpenNexus iPad.xcscheme")
if os.path.exists(old):
    os.remove(old)
open(os.path.join(scheme_dir, "OpenNexus iOS.xcscheme"), "w").write(scheme)
