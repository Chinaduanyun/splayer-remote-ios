#!/usr/bin/env python3
"""生成真实可用的 SPlayerRemote.xcodeproj（纯标准库，无需 XcodeGen）。

用法:
    python3 scripts/generate_xcodeproj.py

生成物:
    SPlayerRemote.xcodeproj/project.pbxproj

脚本是幂等的：重复运行会得到完全相同的 project.pbxproj。
所有对象 ID 由路径的 md5 派生，因此稳定可复现。
"""
import hashlib
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
PROJECT_PATH = ROOT / "SPlayerRemote.xcodeproj" / "project.pbxproj"

APP_TARGET = "SPlayerRemote"
TEST_TARGET = "SPlayerRemoteTests"
BUNDLE_ID = "com.example.splayerremote"

APP_SOURCES = [
    "SPlayerRemote/App/SPlayerRemoteApp.swift",
    "SPlayerRemote/Models/RemoteModels.swift",
    "SPlayerRemote/Networking/RemoteAPIError.swift",
    "SPlayerRemote/Networking/HostValidator.swift",
    "SPlayerRemote/Networking/APIRequestFactory.swift",
    "SPlayerRemote/Networking/RemoteAPIClient.swift",
    "SPlayerRemote/Security/KeychainStore.swift",
    "SPlayerRemote/Persistence/SettingsStore.swift",
    "SPlayerRemote/ViewModels/RemoteViewModel.swift",
    "SPlayerRemote/Views/GlassSupport.swift",
    "SPlayerRemote/Views/Components.swift",
    "SPlayerRemote/Views/RootView.swift",
    "SPlayerRemote/Views/SettingsView.swift",
]

APP_RESOURCES = [
    "SPlayerRemote/Resources/Assets.xcassets",
]

TEST_SOURCES = [
    "SPlayerRemoteTests/TestSupport.swift",
    "SPlayerRemoteTests/HostValidatorTests.swift",
    "SPlayerRemoteTests/RequestEncodingTests.swift",
    "SPlayerRemoteTests/RemoteAPIClientTests.swift",
    "SPlayerRemoteTests/SettingsStoreTests.swift",
    "SPlayerRemoteTests/RemoteViewModelTests.swift",
]

INFO_PLIST = "SPlayerRemote/Info.plist"


def oid(key: str) -> str:
    return hashlib.md5(key.encode("utf-8")).hexdigest()[:24].upper()


def q(value: str) -> str:
    """始终以引号包裹字符串，避免 OpenStep 特殊字符歧义。"""
    escaped = value.replace("\\", "\\\\").replace('"', '\\"')
    return f'"{escaped}"'


class Project:
    def __init__(self):
        self.objects = {}  # id -> body string
        self._order = []

    def add(self, obj_id, body):
        if obj_id in self.objects:
            raise SystemExit(f"duplicate object id: {obj_id}")
        self.objects[obj_id] = body
        self._order.append(obj_id)

    def render(self):
        lines = ["// !$*UTF8*$!", "{", "\tarchiveVersion = 1;", "\tclasses = {", "\t};", "\tobjectVersion = 56;", "\tobjects = {"]
        for obj_id in self._order:
            lines.append(f"\t\t{obj_id} = {self.objects[obj_id]};")
        lines.append("\t};")
        lines.append(f"\trootObject = {oid('project')} /* Project object */;")
        lines.append("}")
        return "\n".join(lines) + "\n"


def build_file(obj_id, name, file_ref, phase_label, phase_isa):
    return (
        "{\n"
        "\t\t\tisa = %s;\n"
        "\t\t\tfileRef = %s /* %s */;\n"
        "\t\t}" % (phase_isa, file_ref, name)
    )


def main():
    project = Project()
    project_id = oid("project")

    # ---- 文件引用 ----
    file_refs = {}
    for path in APP_SOURCES + TEST_SOURCES:
        fr = oid("file:" + path)
        file_refs[path] = fr
        name = path.split("/")[-1]
        kind = "sourcecode.swift"
        if path == INFO_PLIST:
            kind = "text.plist.xml"
        project.add(
            fr,
            "{\n\t\t\tisa = PBXFileReference;\n\t\t\tlastKnownFileType = %s;\n\t\t\tpath = %s;\n\t\t\tsourceTree = \"<group>\";\n\t\t}"
            % (kind, q(path)),
        )
    for path in APP_RESOURCES:
        fr = oid("file:" + path)
        file_refs[path] = fr
        project.add(
            fr,
            "{\n\t\t\tisa = PBXFileReference;\n\t\t\tlastKnownFileType = folder.assetcatalog;\n\t\t\tpath = %s;\n\t\t\tsourceTree = \"<group>\";\n\t\t}"
            % q(path),
        )
    info_ref = oid("file:" + INFO_PLIST)
    project.add(
        info_ref,
        "{\n\t\t\tisa = PBXFileReference;\n\t\t\tlastKnownFileType = text.plist.xml;\n\t\t\tpath = %s;\n\t\t\tsourceTree = \"<group>\";\n\t\t}"
        % q(INFO_PLIST),
    )

    app_product = oid("product:app")
    test_product = oid("product:tests")
    project.add(
        app_product,
        "{\n\t\t\tisa = PBXFileReference;\n\t\t\texplicitFileType = wrapper.application;\n\t\t\tincludeInIndex = 0;\n\t\t\tpath = %s.app;\n\t\t\tsourceTree = BUILT_PRODUCTS_DIR;\n\t\t}"
        % APP_TARGET,
    )
    project.add(
        test_product,
        "{\n\t\t\tisa = PBXFileReference;\n\t\t\texplicitFileType = wrapper.cfbundle;\n\t\t\tincludeInIndex = 0;\n\t\t\tpath = %s.xctest;\n\t\t\tsourceTree = BUILT_PRODUCTS_DIR;\n\t\t}"
        % TEST_TARGET,
    )

    # ---- 构建文件 ----
    app_source_builds, app_resource_builds, test_source_builds = [], [], []
    for path in APP_SOURCES:
        bf = oid("build:app:" + path)
        name = path.split("/")[-1]
        project.add(bf, build_file(bf, name, file_refs[path], "Sources", "PBXBuildFile"))
        app_source_builds.append((bf, name))
    for path in APP_RESOURCES:
        bf = oid("build:app:" + path)
        name = path.split("/")[-1]
        project.add(bf, build_file(bf, name, file_refs[path], "Resources", "PBXBuildFile"))
        app_resource_builds.append((bf, name))
    for path in TEST_SOURCES:
        bf = oid("build:tests:" + path)
        name = path.split("/")[-1]
        project.add(bf, build_file(bf, name, file_refs[path], "Sources", "PBXBuildFile"))
        test_source_builds.append((bf, name))

    # ---- 组 ----
    main_group = oid("group:main")
    app_group = oid("group:app")
    tests_group = oid("group:tests")
    products_group = oid("group:products")

    def group(obj_id, name, children, path=None, kind="PBXGroup"):
        base = "{\n\t\t\tisa = %s;\n\t\t\tchildren = (\n" % kind
        for c in children:
            base += "\t\t\t\t%s,\n" % c
        base += "\t\t\t);\n"
        if name:
            base += "\t\t\tname = %s;\n" % q(name)
        if path:
            base += "\t\t\tpath = %s;\n" % q(path)
        base += "\t\t\tsourceTree = \"<group>\";\n\t\t}"
        project.add(obj_id, base)

    app_children = [file_refs[p] for p in APP_SOURCES] + [file_refs[p] for p in APP_RESOURCES] + [info_ref]
    tests_children = [file_refs[p] for p in TEST_SOURCES]
    # File references already contain paths relative to SOURCE_ROOT. Named groups
    # must not add the target directory a second time.
    group(app_group, APP_TARGET, app_children)
    group(tests_group, TEST_TARGET, tests_children)
    group(products_group, "Products", [app_product, test_product])
    group(main_group, None, [app_group, tests_group, products_group])

    # ---- 构建阶段 ----
    def phase(obj_id, isa, entries):
        body = "{\n\t\t\tisa = %s;\n\t\t\tbuildActionMask = 2147483647;\n\t\t\tfiles = (\n" % isa
        for bf, name in entries:
            body += "\t\t\t\t%s /* %s */,\n" % (bf, name)
        body += "\t\t\t);\n\t\t\trunOnlyForDeploymentPostprocessing = 0;\n\t\t}"
        project.add(obj_id, body)

    app_sources_phase = oid("phase:app:sources")
    app_resources_phase = oid("phase:app:resources")
    app_frameworks_phase = oid("phase:app:frameworks")
    test_sources_phase = oid("phase:tests:sources")
    test_frameworks_phase = oid("phase:tests:frameworks")

    phase(app_sources_phase, "PBXSourcesBuildPhase", app_source_builds)
    phase(app_resources_phase, "PBXResourcesBuildPhase", app_resource_builds)
    phase(app_frameworks_phase, "PBXFrameworksBuildPhase", [])
    phase(test_sources_phase, "PBXSourcesBuildPhase", test_source_builds)
    phase(test_frameworks_phase, "PBXFrameworksBuildPhase", [])

    # ---- 目标 ----
    app_target = oid("target:app")
    test_target = oid("target:tests")

    project.add(
        app_target,
        "{\n\t\t\tisa = PBXNativeTarget;\n\t\t\tbuildConfigurationList = %s /* Build configuration list for PBXNativeTarget \"%s\" */;\n"
        "\t\t\tbuildPhases = (\n\t\t\t\t%s /* Sources */,\n\t\t\t\t%s /* Frameworks */,\n\t\t\t\t%s /* Resources */,\n\t\t\t);\n"
        "\t\t\tbuildRules = (\n\t\t\t);\n\t\t\tdependencies = (\n\t\t\t);\n\t\t\tname = %s;\n\t\t\tproductName = %s;\n"
        "\t\t\tproductReference = %s /* %s.app */;\n\t\t\tproductType = \"com.apple.product-type.application\";\n\t\t}"
        % (
            oid("cfglist:app"), APP_TARGET,
            app_sources_phase, app_frameworks_phase, app_resources_phase,
            q(APP_TARGET), q(APP_TARGET), app_product, APP_TARGET,
        ),
    )

    test_proxy = oid("proxy:tests")
    test_dep = oid("dep:tests")
    project.add(
        test_proxy,
        "{\n\t\t\tisa = PBXContainerItemProxy;\n\t\t\tcontainerPortal = %s /* Project object */;\n\t\t\tproxyType = 1;\n"
        "\t\t\tremoteGlobalIDString = %s;\n\t\t\tremoteInfo = %s;\n\t\t}"
        % (project_id, app_target, APP_TARGET),
    )
    project.add(
        test_dep,
        "{\n\t\t\tisa = PBXTargetDependency;\n\t\t\ttarget = %s /* %s */;\n\t\t\ttargetProxy = %s /* PBXContainerItemProxy */;\n\t\t}"
        % (app_target, APP_TARGET, test_proxy),
    )
    project.add(
        test_target,
        "{\n\t\t\tisa = PBXNativeTarget;\n\t\t\tbuildConfigurationList = %s /* Build configuration list for PBXNativeTarget \"%s\" */;\n"
        "\t\t\tbuildPhases = (\n\t\t\t\t%s /* Sources */,\n\t\t\t\t%s /* Frameworks */,\n\t\t\t);\n"
        "\t\t\tbuildRules = (\n\t\t\t);\n\t\t\tdependencies = (\n\t\t\t\t%s /* PBXTargetDependency */,\n\t\t\t);\n"
        "\t\t\tname = %s;\n\t\t\tproductName = %s;\n\t\t\tproductReference = %s /* %s.xctest */;\n"
        "\t\t\tproductType = \"com.apple.product-type.bundle.unit-test\";\n\t\t}"
        % (
            oid("cfglist:tests"), TEST_TARGET,
            test_sources_phase, test_frameworks_phase, test_dep,
            q(TEST_TARGET), q(TEST_TARGET), test_product, TEST_TARGET,
        ),
    )

    # ---- 工程 ----
    project.add(
        project_id,
        "{\n\t\t\tisa = PBXProject;\n\t\t\tattributes = {\n\t\t\t\tBuildIndependentTargetsInParallel = 1;\n"
        "\t\t\t\tLastSwiftUpdateCheck = 1600;\n\t\t\t\tLastUpgradeCheck = 1600;\n\t\t\t\tTargetAttributes = {\n"
        "\t\t\t\t\t%s = {\n\t\t\t\t\t\tCreatedOnToolsVersion = 16.0;\n\t\t\t\t\t};\n"
        "\t\t\t\t\t%s = {\n\t\t\t\t\t\tCreatedOnToolsVersion = 16.0;\n\t\t\t\t\t\tTestTargetID = %s;\n\t\t\t\t\t};\n"
        "\t\t\t\t};\n\t\t\t};\n\t\t\tbuildConfigurationList = %s /* Build configuration list for PBXProject \"%s\" */;\n"
        "\t\t\tcompatibilityVersion = \"Xcode 14.0\";\n\t\t\tdevelopmentRegion = en;\n\t\t\thasScannedForEncodings = 0;\n"
        "\t\t\tknownRegions = (\n\t\t\t\ten,\n\t\t\t\tBase,\n\t\t\t\t\"zh-Hans\",\n\t\t\t);\n\t\t\tmainGroup = %s;\n"
        "\t\t\tproductRefGroup = %s /* Products */;\n\t\t\tprojectDirPath = \"\";\n\t\t\tprojectRoot = \"\";\n"
        "\t\t\ttargets = (\n\t\t\t\t%s /* %s */,\n\t\t\t\t%s /* %s */,\n\t\t\t);\n\t\t}"
        % (app_target, test_target, app_target, oid("cfglist:project"), APP_TARGET,
           main_group, products_group, app_target, APP_TARGET, test_target, TEST_TARGET),
    )

    # ---- 构建设置 ----
    common_project = {
        "ALWAYS_SEARCH_USER_PATHS": "NO",
        "CLANG_ANALYZER_NONNULL": "YES",
        "CLANG_ENABLE_MODULES": "YES",
        "CLANG_ENABLE_OBJC_ARC": "YES",
        "CLANG_WARN_BOOL_CONVERSION": "YES",
        "CLANG_WARN_CONSTANT_CONVERSION": "YES",
        "CLANG_WARN_EMPTY_BODY": "YES",
        "CLANG_WARN_ENUM_CONVERSION": "YES",
        "CLANG_WARN_INFINITE_RECURSION": "YES",
        "CLANG_WARN_INT_CONVERSION": "YES",
        "CLANG_WARN_UNREACHABLE_CODE": "YES",
        "COPY_PHASE_STRIP": "NO",
        "ENABLE_STRICT_OBJC_MSGSEND": "YES",
        "GCC_C_LANGUAGE_STANDARD": "gnu17",
        "GCC_NO_COMMON_BLOCKS": "YES",
        "IPHONEOS_DEPLOYMENT_TARGET": "17.0",
        "MTL_FAST_MATH": "YES",
        "SDKROOT": "iphoneos",
        "SWIFT_VERSION": "5.0",
        "TARGETED_DEVICE_FAMILY": "1",
    }
    debug_project = dict(common_project, **{
        "DEBUG_INFORMATION_FORMAT": "dwarf",
        "ENABLE_TESTABILITY": "YES",
        "GCC_DYNAMIC_NO_PIC": "NO",
        "GCC_OPTIMIZATION_LEVEL": "0",
        "GCC_PREPROCESSOR_DEFINITIONS": '("DEBUG=1", "$(inherited)")',
        "MTL_ENABLE_DEBUG_INFO": "INCLUDE_SOURCE",
        "ONLY_ACTIVE_ARCH": "YES",
        "SWIFT_ACTIVE_COMPILATION_CONDITIONS": "DEBUG",
        "SWIFT_OPTIMIZATION_LEVEL": '"-Onone"',
    })
    release_project = dict(common_project, **{
        "DEBUG_INFORMATION_FORMAT": '"dwarf-with-dsym"',
        "ENABLE_NS_ASSERTIONS": "NO",
        "GCC_OPTIMIZATION_LEVEL": "s",
        "MTL_ENABLE_DEBUG_INFO": "NO",
        "SWIFT_COMPILATION_MODE": "wholemodule",
        "SWIFT_OPTIMIZATION_LEVEL": '"-O"',
        "VALIDATE_PRODUCT": "YES",
    })

    common_app = {
        "ASSETCATALOG_COMPILER_APPICON_NAME": "AppIcon",
        "ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME": "AccentColor",
        "CODE_SIGN_STYLE": "Automatic",
        "CURRENT_PROJECT_VERSION": "1",
        "ENABLE_PREVIEWS": "YES",
        "GENERATE_INFOPLIST_FILE": "NO",
        "INFOPLIST_FILE": q(INFO_PLIST),
        "IPHONEOS_DEPLOYMENT_TARGET": "17.0",
        "LD_RUNPATH_SEARCH_PATHS": '("$(inherited)", "@executable_path/Frameworks")',
        "MARKETING_VERSION": "1.0",
        "PRODUCT_BUNDLE_IDENTIFIER": q(BUNDLE_ID),
        "PRODUCT_NAME": '"$(TARGET_NAME)"',
        "SUPPORTED_PLATFORMS": '"iphoneos iphonesimulator"',
        "SWIFT_EMIT_LOC_STRINGS": "YES",
        "SWIFT_VERSION": "5.0",
        "TARGETED_DEVICE_FAMILY": "1",
    }
    common_tests = {
        "BUNDLE_LOADER": '"$(TEST_HOST)"',
        "CODE_SIGN_STYLE": "Automatic",
        "CURRENT_PROJECT_VERSION": "1",
        "GENERATE_INFOPLIST_FILE": "YES",
        "IPHONEOS_DEPLOYMENT_TARGET": "17.0",
        "MARKETING_VERSION": "1.0",
        "PRODUCT_BUNDLE_IDENTIFIER": q(BUNDLE_ID + ".tests"),
        "PRODUCT_NAME": '"$(TARGET_NAME)"',
        "SUPPORTED_PLATFORMS": '"iphoneos iphonesimulator"',
        "SWIFT_EMIT_LOC_STRINGS": "NO",
        "SWIFT_VERSION": "5.0",
        "TARGETED_DEVICE_FAMILY": "1",
        "TEST_HOST": '"$(BUILT_PRODUCTS_DIR)/%s.app/$(BUNDLE_EXECUTABLE_FOLDER_PATH)/%s"' % (APP_TARGET, APP_TARGET),
    }

    def config(obj_id, name, settings):
        body = "{\n\t\t\tisa = XCBuildConfiguration;\n\t\t\tbuildSettings = {\n"
        for key in sorted(settings):
            body += "\t\t\t\t%s = %s;\n" % (key, settings[key])
        body += "\t\t\t};\n\t\t\tname = %s;\n\t\t}" % name
        project.add(obj_id, body)

    config(oid("cfg:project:debug"), "Debug", debug_project)
    config(oid("cfg:project:release"), "Release", release_project)
    config(oid("cfg:app:debug"), "Debug", common_app)
    config(oid("cfg:app:release"), "Release", common_app)
    config(oid("cfg:tests:debug"), "Debug", common_tests)
    config(oid("cfg:tests:release"), "Release", common_tests)

    def cfg_list(obj_id, label, debug_id, release_id):
        project.add(
            obj_id,
            "{\n\t\t\tisa = XCConfigurationList;\n\t\t\tbuildConfigurations = (\n\t\t\t\t%s /* Debug */,\n\t\t\t\t%s /* Release */,\n\t\t\t);\n"
            "\t\t\tdefaultConfigurationIsVisible = 0;\n\t\t\tdefaultConfigurationName = Release;\n\t\t}"
            % (debug_id, release_id),
        )

    cfg_list(oid("cfglist:project"), "PBXProject", oid("cfg:project:debug"), oid("cfg:project:release"))
    cfg_list(oid("cfglist:app"), "PBXNativeTarget", oid("cfg:app:debug"), oid("cfg:app:release"))
    cfg_list(oid("cfglist:tests"), "PBXNativeTarget", oid("cfg:tests:debug"), oid("cfg:tests:release"))

    PROJECT_PATH.parent.mkdir(parents=True, exist_ok=True)
    PROJECT_PATH.write_text(project.render(), encoding="utf-8")
    write_scheme()
    print(f"wrote {PROJECT_PATH} ({len(project.objects)} objects, {PROJECT_PATH.stat().st_size} bytes)")


def write_scheme():
    """写入共享 scheme，使 `xcodebuild -scheme SPlayerRemote` 可用。"""
    app_target = oid("target:app")
    test_target = oid("target:tests")

    def buildable(blueprint_id, buildable_name, blueprint_name):
        return (
            '<BuildableReference BuildableIdentifier = "primary" BlueprintIdentifier = "%s" '
            'BuildableName = "%s" BlueprintName = "%s" ReferencedContainer = "container:SPlayerRemote.xcodeproj"></BuildableReference>'
            % (blueprint_id, buildable_name, blueprint_name)
        )

    app_ref = buildable(app_target, "SPlayerRemote.app", "SPlayerRemote")
    test_ref = buildable(test_target, "SPlayerRemoteTests.xctest", "SPlayerRemoteTests")

    scheme = f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme
   LastUpgradeVersion = "1600"
   version = "1.7">
   <BuildAction
      parallelizeBuildables = "YES"
      buildImplicitDependencies = "YES">
      <BuildActionEntries>
         <BuildActionEntry
            buildForTesting = "YES"
            buildForRunning = "YES"
            buildForProfiling = "YES"
            buildForArchiving = "YES"
            buildForAnalyzing = "YES">
            {app_ref}
         </BuildActionEntry>
      </BuildActionEntries>
   </BuildAction>
   <TestAction
      buildConfiguration = "Debug"
      selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB"
      selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB"
      shouldUseLaunchSchemeArgsEnv = "YES">
      <Testables>
         <TestableReference
            skipped = "NO">
            {test_ref}
         </TestableReference>
      </Testables>
   </TestAction>
   <LaunchAction
      buildConfiguration = "Debug"
      selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB"
      selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB"
      launchStyle = "0"
      useCustomWorkingDirectory = "NO"
      ignoresPersistentStateOnLaunch = "NO"
      debugDocumentVersioning = "YES"
      debugServiceExtension = "internal"
      allowLocationSimulation = "YES">
      <BuildableProductRunnable
         runnableDebuggingMode = "0">
         {app_ref}
      </BuildableProductRunnable>
   </LaunchAction>
   <ProfileAction
      buildConfiguration = "Release"
      shouldUseLaunchSchemeArgsEnv = "YES"
      savedToolIdentifier = ""
      useCustomWorkingDirectory = "NO"
      debugDocumentVersioning = "YES">
      <BuildableProductRunnable
         runnableDebuggingMode = "0">
         {app_ref}
      </BuildableProductRunnable>
   </ProfileAction>
   <AnalyzeAction
      buildConfiguration = "Debug">
   </AnalyzeAction>
   <ArchiveAction
      buildConfiguration = "Release"
      revealArchiveInOrganizer = "YES">
   </ArchiveAction>
</Scheme>
'''
    scheme_path = PROJECT_PATH.parent / "xcshareddata" / "xcschemes" / "SPlayerRemote.xcscheme"
    scheme_path.parent.mkdir(parents=True, exist_ok=True)
    scheme_path.write_text(scheme, encoding="utf-8")
    print(f"wrote {scheme_path}")


if __name__ == "__main__":
    main()
