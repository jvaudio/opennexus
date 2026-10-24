#!/usr/bin/env python3
"""Writes App/OpenNexus.xcodeproj/project.pbxproj (M9).

The project is generated so its structure stays reviewable: one place lists the
targets, their sources (synchronised folders), package products, plists and
entitlements. Object ids are stable hashes, so regenerating produces the same file.

    python3 App/tools/make_project.py
"""
import hashlib
import os

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))  # App/
OUT = os.path.join(ROOT, "OpenNexus.xcodeproj", "project.pbxproj")
BUNDLE = "com.opennexus.OpenNexus"


def oid(*parts):
    return hashlib.sha1("/".join(parts).encode()).hexdigest()[:24].upper()


# name, product type, product file, sources folder (relative to App/), package products,
# extra build settings
TARGETS = [
    dict(
        name="OpenNexus", type="com.apple.product-type.application", product="OpenNexus.app",
        wrapper="wrapper.application", folder="OpenNexus", packages=["OpenNexusKit"], remote=["Sparkle"],
        settings={
            "ASSETCATALOG_COMPILER_APPICON_NAME": "AppIcon",
            "ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME": "AccentColor",
            "CODE_SIGN_ENTITLEMENTS": "Support/OpenNexus.entitlements",
            "COMBINE_HIDPI_IMAGES": "YES",
            "INFOPLIST_FILE": "Support/Info.plist",
            "INFOPLIST_KEY_CFBundleDisplayName": "OpenNexus",
            "INFOPLIST_KEY_LSApplicationCategoryType": "public.app-category.productivity",
            "INFOPLIST_KEY_NSHumanReadableCopyright": "OpenNexus contributors",
            "INFOPLIST_KEY_NSMicrophoneUsageDescription": "OpenNexus records audio notes and Record to Map on this Mac. Recordings stay in your document.",
            "INFOPLIST_KEY_NSSpeechRecognitionUsageDescription": "Record to Map transcribes speech on this Mac. Nothing leaves your computer.",
            "INFOPLIST_KEY_NSPrincipalClass": "NSApplication",
            "LD_RUNPATH_SEARCH_PATHS": ["$(inherited)", "@executable_path/../Frameworks"],
            "PRODUCT_BUNDLE_IDENTIFIER": BUNDLE,
            "SWIFT_DEFAULT_ACTOR_ISOLATION": "MainActor",
            # The "Localized strings" phase reads the package's resource bundle.
            "ENABLE_USER_SCRIPT_SANDBOXING": "NO",
        },
    ),
    dict(name="QuickLookPreview", ext=True, packages=["OpenNexusKit"]),
    dict(name="QuickLookThumbnail", ext=True, packages=["OpenNexusKit"]),
    dict(name="SpotlightImporter", ext=True, packages=["NexusShared"]),
    dict(name="Share", ext=True, packages=["NexusShared"]),
    dict(name="Widgets", ext=True, packages=["NexusShared", "NexusWidgetsKit"]),
    dict(
        name="OpenNexusUITests", type="com.apple.product-type.bundle.ui-testing", product="OpenNexusUITests.xctest",
        wrapper="wrapper.cfbundle", folder="UITests", packages=[], test=True,
        settings={
            "PRODUCT_BUNDLE_IDENTIFIER": f"{BUNDLE}.UITests",
            "TEST_TARGET_NAME": "OpenNexus",
            "GENERATE_INFOPLIST_FILE": "YES",
            "SKIP_INSTALL": "YES",
            "LD_RUNPATH_SEARCH_PATHS": ["$(inherited)", "@executable_path/../Frameworks", "@loader_path/../Frameworks"],
        },
    ),
    dict(
        name="nexus", type="com.apple.product-type.tool", product="nexus", wrapper="compiled.mach-o.executable",
        folder="../Sources/nexus", packages=["NexusAgentKit"],
        settings={
            "CODE_SIGN_ENTITLEMENTS": "Support/nexus.entitlements",
            "PRODUCT_BUNDLE_IDENTIFIER": "com.opennexus.nexus",
            "SKIP_INSTALL": "YES",
            "CREATE_INFOPLIST_SECTION_IN_BINARY": "YES",
            "GENERATE_INFOPLIST_FILE": "YES",
        },
    ),
]

for t in TARGETS:
    if t.get("ext"):
        n = t["name"]
        t.update(
            type="com.apple.product-type.app-extension", product=f"{n}.appex", wrapper="wrapper.app-extension",
            folder=f"Extensions/{n}",
            settings={
                "CODE_SIGN_ENTITLEMENTS": f"Support/{n}/{n}.entitlements",
                "INFOPLIST_FILE": f"Support/{n}/Info.plist",
                "INFOPLIST_KEY_CFBundleDisplayName": "OpenNexus",
                "INFOPLIST_KEY_NSHumanReadableCopyright": "OpenNexus contributors",
                "LD_RUNPATH_SEARCH_PATHS": ["$(inherited)", "@executable_path/../Frameworks", "@executable_path/../../../../Frameworks"],
                "PRODUCT_BUNDLE_IDENTIFIER": f"{BUNDLE}.{n}",
                "SKIP_INSTALL": "YES",
                "APPLICATION_EXTENSION_API_ONLY": "YES",
            },
        )

COMMON = {
    "CURRENT_PROJECT_VERSION": "1",
    "ENABLE_HARDENED_RUNTIME": "YES",
    "GENERATE_INFOPLIST_FILE": "YES",
    "MARKETING_VERSION": "0.2",
    "PRODUCT_NAME": "$(TARGET_NAME)",
    "SWIFT_APPROACHABLE_CONCURRENCY": "YES",
    "SWIFT_EMIT_LOC_STRINGS": "YES",
    "SWIFT_UPCOMING_FEATURE_MEMBER_IMPORT_VISIBILITY": "YES",
}

PROJECT = {
    "ALWAYS_SEARCH_USER_PATHS": "NO",
    "ARCHS": "arm64",
    "ASSETCATALOG_COMPILER_GENERATE_SWIFT_ASSET_SYMBOL_EXTENSIONS": "YES",
    "CLANG_ENABLE_MODULES": "YES",
    "CLANG_ENABLE_OBJC_ARC": "YES",
    "COPY_PHASE_STRIP": "NO",
    "DEAD_CODE_STRIPPING": "YES",
    "ENABLE_STRICT_OBJC_MSGSEND": "YES",
    "ENABLE_USER_SCRIPT_SANDBOXING": "YES",
    "LOCALIZATION_PREFERS_STRING_CATALOGS": "YES",
    "MACOSX_DEPLOYMENT_TARGET": "27.0",
    "SDKROOT": "macosx",
    "SWIFT_STRICT_CONCURRENCY": "complete",
    "SWIFT_VERSION": "6.0",
}
DEBUG = {
    "DEBUG_INFORMATION_FORMAT": "dwarf",
    "ENABLE_TESTABILITY": "YES",
    "GCC_OPTIMIZATION_LEVEL": "0",
    "GCC_PREPROCESSOR_DEFINITIONS": ["DEBUG=1", "$(inherited)"],
    "MTL_ENABLE_DEBUG_INFO": "INCLUDE_SOURCE",
    "ONLY_ACTIVE_ARCH": "YES",
    "SWIFT_ACTIVE_COMPILATION_CONDITIONS": "DEBUG $(inherited)",
    "SWIFT_OPTIMIZATION_LEVEL": "-Onone",
}
RELEASE = {
    "DEBUG_INFORMATION_FORMAT": "dwarf-with-dsym",
    "ENABLE_NS_ASSERTIONS": "NO",
    "SWIFT_COMPILATION_MODE": "wholemodule",
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


objs = {}  # section -> list of (id, text)


def add(section, ident, text):
    objs.setdefault(section, []).append((ident, text))


PROJ = oid("project")
MAIN_GROUP = oid("group", "main")
PRODUCTS = oid("group", "products")
SUPPORT = oid("group", "support")
PKG = oid("package", "..")
# Remote packages (M38): name → (repository, minimum version), resolved up to the next major
# version. Package.resolved pins the exact one.
REMOTE = {"Sparkle": ("https://github.com/sparkle-project/Sparkle", "2.6.4")}
REMOTE_REF = {name: oid("remote", name) for name in REMOTE}
CONFIG_REF = oid("file", "Config/Base.xcconfig")
LOCAL_REF = oid("file", "Config/Signing.local.xcconfig")

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
    add("PBXFileSystemSynchronizedRootGroup", t["sync"], f'{t["sync"]} /* {folder_name} */ = {{isa = PBXFileSystemSynchronizedRootGroup; name = {q(folder_name if n != "nexus" else "nexus (CLI)")}; path = {q(t["folder"])}; sourceTree = "<group>"; }};')
    files = []
    for p in t["packages"]:
        dep = oid("pkgdep", n, p)
        bf = oid("buildfile", n, p)
        product_deps.setdefault(n, []).append(dep)
        add("XCSwiftPackageProductDependency", dep, f"{dep} /* {p} */ = {{\n\t\t\tisa = XCSwiftPackageProductDependency;\n\t\t\tpackage = {PKG} /* XCLocalSwiftPackageReference \"..\" */;\n\t\t\tproductName = {p};\n\t\t}};")
        add("PBXBuildFile", bf, f"{bf} /* {p} in Frameworks */ = {{isa = PBXBuildFile; productRef = {dep} /* {p} */; }};")
        files.append(f"{bf} /* {p} in Frameworks */")
    for p in t.get("remote", []):
        dep = oid("pkgdep", n, p)
        bf = oid("buildfile", n, p)
        product_deps.setdefault(n, []).append(dep)
        add("XCSwiftPackageProductDependency", dep, f'{dep} /* {p} */ = {{\n\t\t\tisa = XCSwiftPackageProductDependency;\n\t\t\tpackage = {REMOTE_REF[p]} /* XCRemoteSwiftPackageReference "{p}" */;\n\t\t\tproductName = {p};\n\t\t}};')
        add("PBXBuildFile", bf, f"{bf} /* {p} in Frameworks */ = {{isa = PBXBuildFile; productRef = {dep} /* {p} */; }};")
        files.append(f"{bf} /* {p} in Frameworks */")
    add("PBXFrameworksBuildPhase", t["phases"]["frameworks"], "{} /* Frameworks */ = {{\n\t\t\tisa = PBXFrameworksBuildPhase;\n\t\t\tbuildActionMask = 2147483647;\n\t\t\tfiles = (\n{}\t\t\t);\n\t\t\trunOnlyForDeploymentPostprocessing = 0;\n\t\t}};".format(t["phases"]["frameworks"], "".join(f"\t\t\t\t{f},\n" for f in files)))
    add("PBXSourcesBuildPhase", t["phases"]["sources"], f'{t["phases"]["sources"]} /* Sources */ = {{\n\t\t\tisa = PBXSourcesBuildPhase;\n\t\t\tbuildActionMask = 2147483647;\n\t\t\tfiles = (\n\t\t\t);\n\t\t\trunOnlyForDeploymentPostprocessing = 0;\n\t\t}};')
    add("PBXResourcesBuildPhase", t["phases"]["resources"], f'{t["phases"]["resources"]} /* Resources */ = {{\n\t\t\tisa = PBXResourcesBuildPhase;\n\t\t\tbuildActionMask = 2147483647;\n\t\t\tfiles = (\n\t\t\t);\n\t\t\trunOnlyForDeploymentPostprocessing = 0;\n\t\t}};')

app = TARGETS[0]
embedded = [t for t in TARGETS[1:] if not t.get("test")]
# The app embeds the extensions (PlugIns) and the CLI (Contents/Helpers), signing on copy.
embed_ext = oid("phase", "OpenNexus", "embed-extensions")
embed_cli = oid("phase", "OpenNexus", "embed-cli")
ext_files, cli_files, deps = [], [], []
for t in embedded:
    bf = oid("embed", t["name"])
    add("PBXBuildFile", bf, f'{bf} /* {t["product"]} in Embed */ = {{isa = PBXBuildFile; fileRef = {t["ref"]} /* {t["product"]} */; settings = {{ATTRIBUTES = (CodeSignOnCopy, {"RemoveHeadersOnCopy, " if t.get("ext") else ""}); }}; }};')
    (ext_files if t.get("ext") else cli_files).append(f'{bf} /* {t["product"]} in Embed */')
    proxy = oid("proxy", t["name"])
    dep = oid("dependency", t["name"])
    add("PBXContainerItemProxy", proxy, f'{proxy} /* PBXContainerItemProxy */ = {{\n\t\t\tisa = PBXContainerItemProxy;\n\t\t\tcontainerPortal = {PROJ} /* Project object */;\n\t\t\tproxyType = 1;\n\t\t\tremoteGlobalIDString = {t["id"]};\n\t\t\tremoteInfo = {q(t["name"])};\n\t\t}};')
    add("PBXTargetDependency", dep, f'{dep} /* PBXTargetDependency */ = {{\n\t\t\tisa = PBXTargetDependency;\n\t\t\ttarget = {t["id"]} /* {t["name"]} */;\n\t\t\ttargetProxy = {proxy} /* PBXContainerItemProxy */;\n\t\t}};')
    deps.append(f"{dep} /* PBXTargetDependency */")


# The UI tests depend on (and launch) the app.
ui_proxy = oid("proxy", "uitests-app")
ui_dep_id = oid("dependency", "uitests-app")
add("PBXContainerItemProxy", ui_proxy, f'{ui_proxy} /* PBXContainerItemProxy */ = {{\n\t\t\tisa = PBXContainerItemProxy;\n\t\t\tcontainerPortal = {PROJ} /* Project object */;\n\t\t\tproxyType = 1;\n\t\t\tremoteGlobalIDString = {app["id"]};\n\t\t\tremoteInfo = OpenNexus;\n\t\t}};')
add("PBXTargetDependency", ui_dep_id, f'{ui_dep_id} /* PBXTargetDependency */ = {{\n\t\t\tisa = PBXTargetDependency;\n\t\t\ttarget = {app["id"]} /* OpenNexus */;\n\t\t\ttargetProxy = {ui_proxy} /* PBXContainerItemProxy */;\n\t\t}};')
ui_dep = f"{ui_dep_id} /* PBXTargetDependency */"


def copy_phase(ident, name, spec, path, files):
    body = "".join(f"\t\t\t\t{f},\n" for f in files)
    add("PBXCopyFilesBuildPhase", ident, f'{ident} /* {name} */ = {{\n\t\t\tisa = PBXCopyFilesBuildPhase;\n\t\t\tbuildActionMask = 2147483647;\n\t\t\tdstPath = {q(path)};\n\t\t\tdstSubfolderSpec = {spec};\n\t\t\tfiles = (\n{body}\t\t\t);\n\t\t\tname = {q(name)};\n\t\t\trunOnlyForDeploymentPostprocessing = 0;\n\t\t}};')


copy_phase(embed_ext, "Embed Foundation Extensions", 13, "", ext_files)

# SwiftUI literals in the package resolve against the main bundle, so the app carries the
# package catalog's compiled strings as its own Localizable table (M10).
LOC_PHASE = oid("phase", "OpenNexus", "localized-strings")
LOC_SCRIPT = """src="$BUILT_PRODUCTS_DIR/OpenNexus_NexusCanvas.bundle/Contents/Resources"
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
copy_phase(embed_cli, "Embed Command-Line Tool", 1, "Contents/Helpers", cli_files)

for t in TARGETS:
    n = t["name"]
    phases = [f'{t["phases"]["sources"]} /* Sources */', f'{t["phases"]["frameworks"]} /* Frameworks */', f'{t["phases"]["resources"]} /* Resources */']
    if n == "OpenNexus":
        phases += [
            f"{embed_ext} /* Embed Foundation Extensions */", f"{embed_cli} /* Embed Command-Line Tool */",
            f"{LOC_PHASE} /* Localized strings */",
        ]
    own_deps = deps if n == "OpenNexus" else ([ui_dep] if t.get("test") else [])
    dep_text = "".join(f"\t\t\t\t{d},\n" for d in own_deps)
    pkgs = "".join(f"\t\t\t\t{d},\n" for d in product_deps.get(n, []))
    add("PBXNativeTarget", t["id"], f'{t["id"]} /* {n} */ = {{\n\t\t\tisa = PBXNativeTarget;\n\t\t\tbuildConfigurationList = {t["configs"]} /* Build configuration list for PBXNativeTarget "{n}" */;\n\t\t\tbuildPhases = (\n' + "".join(f"\t\t\t\t{p},\n" for p in phases) + f'\t\t\t);\n\t\t\tbuildRules = (\n\t\t\t);\n\t\t\tdependencies = (\n{dep_text}\t\t\t);\n\t\t\tfileSystemSynchronizedGroups = (\n\t\t\t\t{t["sync"]} /* {os.path.basename(t["folder"])} */,\n\t\t\t);\n\t\t\tname = {q(n)};\n\t\t\tpackageProductDependencies = (\n{pkgs}\t\t\t);\n\t\t\tproductName = {q(n)};\n\t\t\tproductReference = {t["ref"]} /* {t["product"]} */;\n\t\t\tproductType = "{t["type"]}";\n\t\t}};')
    ids = []
    for cfg, extra in (("Debug", {}), ("Release", {})):
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
add("XCConfigurationList", PROJ_CFGS, f'{PROJ_CFGS} /* Build configuration list for PBXProject "OpenNexus" */ = {{\n\t\t\tisa = XCConfigurationList;\n\t\t\tbuildConfigurations = (\n\t\t\t\t{proj_cfgs[0]} /* Debug */,\n\t\t\t\t{proj_cfgs[1]} /* Release */,\n\t\t\t);\n\t\t\tdefaultConfigurationIsVisible = 0;\n\t\t\tdefaultConfigurationName = Release;\n\t\t}};')

support_files = ["Info.plist", "OpenNexus.entitlements", "nexus.entitlements"]
support_children = []
for f in support_files:
    fid = oid("file", "Support", f)
    kind = "text.plist.xml" if f.endswith(".plist") else "text.plist.entitlements"
    add("PBXFileReference", fid, f'{fid} /* {f} */ = {{isa = PBXFileReference; lastKnownFileType = {kind}; path = {q(f)}; sourceTree = "<group>"; }};')
    support_children.append(f"{fid} /* {f} */")
for t in TARGETS:
    if t.get("ext"):
        n = t["name"]
        gid = oid("group", "Support", n)
        kids = []
        for f in ("Info.plist", f"{n}.entitlements"):
            fid = oid("file", "Support", n, f)
            kind = "text.plist.xml" if f.endswith(".plist") else "text.plist.entitlements"
            add("PBXFileReference", fid, f'{fid} /* {f} */ = {{isa = PBXFileReference; lastKnownFileType = {kind}; path = {q(f)}; sourceTree = "<group>"; }};')
            kids.append(f"{fid} /* {f} */")
        add("PBXGroup", gid, f'{gid} /* {n} */ = {{\n\t\t\tisa = PBXGroup;\n\t\t\tchildren = (\n' + "".join(f"\t\t\t\t{k},\n" for k in kids) + f'\t\t\t);\n\t\t\tpath = {q(n)};\n\t\t\tsourceTree = "<group>";\n\t\t}};')
        support_children.append(f"{gid} /* {n} */")
add("PBXGroup", SUPPORT, f'{SUPPORT} /* Support */ = {{\n\t\t\tisa = PBXGroup;\n\t\t\tchildren = (\n' + "".join(f"\t\t\t\t{c},\n" for c in support_children) + '\t\t\t);\n\t\t\tpath = Support;\n\t\t\tsourceTree = "<group>";\n\t\t};')
EXT_GROUP = oid("group", "Extensions")
add("PBXGroup", EXT_GROUP, f'{EXT_GROUP} /* Extensions */ = {{\n\t\t\tisa = PBXGroup;\n\t\t\tchildren = (\n' + "".join(f'\t\t\t\t{t["sync"]} /* {t["name"]} */,\n' for t in TARGETS if t.get("ext")) + '\t\t\t);\n\t\t\tname = Extensions;\n\t\t\tsourceTree = "<group>";\n\t\t};')
add("PBXGroup", PRODUCTS, f'{PRODUCTS} /* Products */ = {{\n\t\t\tisa = PBXGroup;\n\t\t\tchildren = (\n' + "".join(f'\t\t\t\t{t["ref"]} /* {t["product"]} */,\n' for t in TARGETS) + '\t\t\t);\n\t\t\tname = Products;\n\t\t\tsourceTree = "<group>";\n\t\t};')
add("PBXGroup", MAIN_GROUP, f'{MAIN_GROUP} = {{\n\t\t\tisa = PBXGroup;\n\t\t\tchildren = (\n\t\t\t\t{app["sync"]} /* OpenNexus */,\n\t\t\t\t{EXT_GROUP} /* Extensions */,\n\t\t\t\t{TARGETS[-1]["sync"]} /* nexus */,\n\t\t\t\t{oid("sync", "OpenNexusUITests")} /* UITests */,\n\t\t\t\t{SUPPORT} /* Support */,\n\t\t\t\t{CONFIG_REF} /* Base.xcconfig */,\n\t\t\t\t{PRODUCTS} /* Products */,\n\t\t\t);\n\t\t\tsourceTree = "<group>";\n\t\t}};')
add("XCLocalSwiftPackageReference", PKG, f'{PKG} /* XCLocalSwiftPackageReference ".." */ = {{\n\t\t\tisa = XCLocalSwiftPackageReference;\n\t\t\trelativePath = ..;\n\t\t}};')
for name, (url, minimum) in REMOTE.items():
    r = REMOTE_REF[name]
    add("XCRemoteSwiftPackageReference", r, f'{r} /* XCRemoteSwiftPackageReference "{name}" */ = {{\n\t\t\tisa = XCRemoteSwiftPackageReference;\n\t\t\trepositoryURL = "{url}";\n\t\t\trequirement = {{\n\t\t\t\tkind = upToNextMajorVersion;\n\t\t\t\tminimumVersion = {minimum};\n\t\t\t}};\n\t\t}};')
remote_refs = "".join(f'\t\t\t\t{REMOTE_REF[n]} /* XCRemoteSwiftPackageReference "{n}" */,\n' for n in REMOTE)

attrs = "".join(f'\t\t\t\t\t{t["id"]} = {{\n\t\t\t\t\t\tCreatedOnToolsVersion = 27.0;\n\t\t\t\t\t}};\n' for t in TARGETS)
add("PBXProject", PROJ, f'{PROJ} /* Project object */ = {{\n\t\t\tisa = PBXProject;\n\t\t\tattributes = {{\n\t\t\t\tBuildIndependentTargetsInParallel = 1;\n\t\t\t\tLastSwiftUpdateCheck = 2700;\n\t\t\t\tLastUpgradeCheck = 2700;\n\t\t\t\tTargetAttributes = {{\n{attrs}\t\t\t\t}};\n\t\t\t}};\n\t\t\tbuildConfigurationList = {PROJ_CFGS} /* Build configuration list for PBXProject "OpenNexus" */;\n\t\t\tdevelopmentRegion = en;\n\t\t\thasScannedForEncodings = 0;\n\t\t\tknownRegions = (\n\t\t\t\ten,\n\t\t\t\tBase,\n\t\t\t);\n\t\t\tmainGroup = {MAIN_GROUP};\n\t\t\tminimizedProjectReferenceProxies = 1;\n\t\t\tpackageReferences = (\n\t\t\t\t{PKG} /* XCLocalSwiftPackageReference ".." */,\n{remote_refs}\t\t\t);\n\t\t\tpreferredProjectObjectVersion = 77;\n\t\t\tproductRefGroup = {PRODUCTS} /* Products */;\n\t\t\tprojectDirPath = "";\n\t\t\tprojectRoot = "";\n\t\t\ttargets = (\n' + "".join(f'\t\t\t\t{t["id"]} /* {t["name"]} */,\n' for t in TARGETS) + "\t\t\t);\n\t\t};")

ORDER = [
    "PBXBuildFile", "PBXContainerItemProxy", "PBXCopyFilesBuildPhase", "PBXFileReference",
    "PBXFileSystemSynchronizedRootGroup", "PBXFrameworksBuildPhase", "PBXGroup", "PBXNativeTarget", "PBXProject",
    "PBXResourcesBuildPhase", "PBXShellScriptBuildPhase", "PBXSourcesBuildPhase", "PBXTargetDependency", "XCBuildConfiguration",
    "XCConfigurationList", "XCLocalSwiftPackageReference", "XCRemoteSwiftPackageReference",
    "XCSwiftPackageProductDependency",
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
ui = next(t for t in TARGETS if t.get("test"))
scheme_dir = os.path.join(ROOT, "OpenNexus.xcodeproj", "xcshareddata", "xcschemes")
os.makedirs(scheme_dir, exist_ok=True)


def ref(t):
    return (
        f'<BuildableReference BuildableIdentifier = "primary" BlueprintIdentifier = "{t["id"]}" '
        f'BuildableName = "{t["product"]}" BlueprintName = "{t["name"]}" ReferencedContainer = "container:OpenNexus.xcodeproj">'
        "</BuildableReference>"
    )


scheme = f"""<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion = "2700" version = "1.7">
   <BuildAction parallelizeBuildables = "YES" buildImplicitDependencies = "YES">
      <BuildActionEntries>
         <BuildActionEntry buildForTesting = "YES" buildForRunning = "YES" buildForProfiling = "YES" buildForArchiving = "YES" buildForAnalyzing = "YES">
            {ref(app)}
         </BuildActionEntry>
      </BuildActionEntries>
   </BuildAction>
   <TestAction buildConfiguration = "Debug" selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv = "YES">
      <Testables>
         <TestableReference skipped = "NO">
            {ref(ui)}
         </TestableReference>
      </Testables>
   </TestAction>
   <LaunchAction buildConfiguration = "Debug" selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB" launchStyle = "0" useCustomWorkingDirectory = "NO" ignoresPersistentStateOnLaunch = "NO" debugDocumentVersioning = "YES" allowLocationSimulation = "YES">
      <BuildableProductRunnable runnableDebuggingMode = "0">
         {ref(app)}
      </BuildableProductRunnable>
   </LaunchAction>
   <ProfileAction buildConfiguration = "Release" shouldUseLaunchSchemeArgsEnv = "YES" savedToolIdentifier = "" useCustomWorkingDirectory = "NO" debugDocumentVersioning = "YES">
      <BuildableProductRunnable runnableDebuggingMode = "0">
         {ref(app)}
      </BuildableProductRunnable>
   </ProfileAction>
   <AnalyzeAction buildConfiguration = "Debug"></AnalyzeAction>
   <ArchiveAction buildConfiguration = "Release" revealArchiveInOrganizer = "YES"></ArchiveAction>
</Scheme>
"""
open(os.path.join(scheme_dir, "OpenNexus.xcscheme"), "w").write(scheme)
open(OUT, "w").write("\n".join(out))
print(f"wrote {OUT} ({len(TARGETS)} targets)")
