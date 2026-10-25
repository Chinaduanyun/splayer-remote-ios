#!/usr/bin/env python3
"""在无 Xcode/Swift 的 Linux 环境下，对工程做可执行的结构一致性检查。

这不是编译或语义类型检查，只验证：
  1. project.pbxproj 能被 OpenStep plist 解析，且所有引用都存在；
  2. 磁盘上的每个 Swift 源文件都被工程引用并加入对应 target 的 Sources 阶段；
  3. Info.plist 是合法 plist 且包含必需键；
  4. 资源目录 Contents.json 合法，AppIcon 引用的 PNG 存在且是合法 PNG；
  5. mock fixtures 为合法 JSON；
  6. 仓库内不存在疑似真实 Token 的明文。
"""
import hashlib
import json
import plistlib
import re
import struct
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
PBXPROJ = ROOT / "SPlayerRemote.xcodeproj" / "project.pbxproj"
INFO_PLIST = ROOT / "SPlayerRemote/Info.plist"
ASSETS = ROOT / "SPlayerRemote/Resources/Assets.xcassets"
MOCK_FIXTURES = ROOT / "mockserver/fixtures"

errors = []
notes = []


def check(cond, message):
    if cond:
        notes.append(f"PASS: {message}")
    else:
        errors.append(f"FAIL: {message}")


# ---------------------------------------------------------------- OpenStep 解析

def strip_comments(text):
    out = []
    i, n = 0, len(text)
    in_string = False
    while i < n:
        c = text[i]
        if in_string:
            out.append(c)
            if c == "\\" and i + 1 < n:
                out.append(text[i + 1])
                i += 2
                continue
            if c == '"':
                in_string = False
            i += 1
            continue
        if c == '"':
            in_string = True
            out.append(c)
            i += 1
            continue
        if c == "/" and i + 1 < n and text[i + 1] == "/":
            while i < n and text[i] != "\n":
                i += 1
            continue
        if c == "/" and i + 1 < n and text[i + 1] == "*":
            i += 2
            while i + 1 < n and not (text[i] == "*" and text[i + 1] == "/"):
                i += 1
            i += 2
            continue
        out.append(c)
        i += 1
    return "".join(out)


class OpenStepParser:
    def __init__(self, text):
        self.s = text
        self.i = 0

    def ws(self):
        while self.i < len(self.s) and self.s[self.i] in " \t\r\n":
            self.i += 1

    def parse(self):
        self.ws()
        value = self.value()
        self.ws()
        if self.i != len(self.s):
            raise ValueError(f"解析未到文件末尾，位置 {self.i}")
        return value

    def value(self):
        self.ws()
        c = self.s[self.i]
        if c == "{":
            return self.dict()
        if c == "(":
            return self.array()
        if c == '"':
            return self.string()
        return self.bare()

    def dict(self):
        self.i += 1  # {
        result = {}
        while True:
            self.ws()
            if self.s[self.i] == "}":
                self.i += 1
                return result
            key = self.value()
            self.ws()
            if self.s[self.i] != "=":
                raise ValueError(f"期望 = 于 {self.i}")
            self.i += 1
            val = self.value()
            self.ws()
            if self.s[self.i] == ";":
                self.i += 1
            result[key] = val

    def array(self):
        self.i += 1  # (
        result = []
        while True:
            self.ws()
            if self.s[self.i] == ")":
                self.i += 1
                return result
            result.append(self.value())
            self.ws()
            if self.s[self.i] == ",":
                self.i += 1

    def string(self):
        self.i += 1  # "
        buf = []
        while self.s[self.i] != '"':
            if self.s[self.i] == "\\":
                buf.append(self.s[self.i + 1])
                self.i += 2
            else:
                buf.append(self.s[self.i])
                self.i += 1
        self.i += 1
        return "".join(buf)

    def bare(self):
        start = self.i
        while self.i < len(self.s) and self.s[self.i] not in " \t\r\n,;}{()=":
            self.i += 1
        return self.s[start:self.i]


# ---------------------------------------------------------------- checks

def check_pbxproj():
    text = PBXPROJ.read_text(encoding="utf-8")
    try:
        parsed = OpenStepParser(strip_comments(text)).parse()
    except Exception as exc:  # noqa: BLE001
        check(False, f"project.pbxproj 可解析（{exc}）")
        return None
    check(True, "project.pbxproj 可被 OpenStep 解析")

    objects = parsed.get("objects", {})
    root = parsed.get("rootObject")
    check(root in objects, "rootObject 指向已定义对象")
    check(objects.get(root, {}).get("isa") == "PBXProject", "rootObject 是 PBXProject")

    # 所有 fileRef 引用都存在
    dangling = []
    for obj_id, body in objects.items():
        if isinstance(body, dict) and "fileRef" in body:
            ref = body["fileRef"]
            if ref not in objects:
                dangling.append(f"{obj_id}->fileRef {ref}")
    check(not dangling, f"无悬空 fileRef 引用（{dangling[:5]}）")

    products_ref = objects.get(root, {}).get("productRefGroup")
    check(products_ref in objects, "productRefGroup 已定义")

    targets = objects.get(root, {}).get("targets", [])
    target_names = {objects[t].get("name") for t in targets if t in objects}
    check({"SPlayerRemote", "SPlayerRemoteTests", "SPlayerRemoteLiveActivity"} <= target_names, f"包含三个 target：{target_names}")

    # 每个 Swift 文件都在 Sources 阶段（按 fileRef path 匹配）
    referenced_paths = {
        b.get("path")
        for b in objects.values()
        if isinstance(b, dict) and b.get("isa") == "PBXFileReference"
    }
    for path in sorted(set(referenced_paths)):
        if path and path.endswith(".swift"):
            disk = ROOT / path
            check(disk.is_file(), f"工程引用的源文件存在: {path}")

    disk_swift = {
        p.relative_to(ROOT).as_posix()
        for p in list((ROOT / "SPlayerRemote").rglob("*.swift"))
        + list((ROOT / "SPlayerRemoteShared").rglob("*.swift"))
        + list((ROOT / "SPlayerRemoteLiveActivity").rglob("*.swift"))
        + list((ROOT / "SPlayerRemoteTests").rglob("*.swift"))
    }
    referenced_swift = {p for p in referenced_paths if p and p.endswith(".swift")}
    missing = disk_swift - referenced_swift
    extra = referenced_swift - disk_swift
    check(not missing, f"磁盘上所有 Swift 文件均被工程引用（缺失：{sorted(missing)}）")
    check(not extra, f"工程未引用不存在的 Swift 文件（多余：{sorted(extra)}）")

    # Sources 阶段引用的 build file 都解析到 fileRef
    build_refs = {
        i: b.get("fileRef")
        for i, b in objects.items()
        if isinstance(b, dict) and b.get("isa") == "PBXBuildFile"
    }
    for obj_id, body in objects.items():
        if isinstance(body, dict) and body.get("isa") in ("PBXSourcesBuildPhase", "PBXResourcesBuildPhase"):
            for bf in body.get("files", []):
                if bf not in build_refs:
                    errors.append(f"FAIL: 构建阶段引用了未知 build file {bf}")
                elif build_refs[bf] not in objects:
                    errors.append(f"FAIL: build file {bf} 指向未知 fileRef")
    check(True, "Sources/Resources 阶段引用的 build file 均已定义")
    return parsed


def check_test_target_unit_test(parsed):
    if not parsed:
        return
    objects = parsed["objects"]
    test_target = next((t for t in objects.get(parsed["rootObject"], {}).get("targets", [])
                        if objects.get(t, {}).get("name") == "SPlayerRemoteTests"), None)
    check(test_target is not None, "存在测试 target")
    check(objects[test_target].get("productType") == "com.apple.product-type.bundle.unit-test", "测试 target 是 unit-test bundle")


def check_extension_target(parsed):
    if not parsed:
        return
    objects = parsed["objects"]
    targets = objects.get(parsed["rootObject"], {}).get("targets", [])
    ext_target = next((t for t in targets if objects.get(t, {}).get("name") == "SPlayerRemoteLiveActivity"), None)
    check(ext_target is not None, "存在 Live Activity 扩展 target")
    if ext_target is None:
        return
    check(objects[ext_target].get("productType") == "com.apple.product-type.app-extension", "扩展 target 是 app-extension")

    # 扩展构建设置：APPLICATION_EXTENSION_API_ONLY / SKIP_INSTALL。
    configs = objects.get(objects[ext_target].get("buildConfigurationList"), {}).get("buildConfigurations", [])
    settings_seen = [objects.get(c, {}).get("buildSettings", {}) for c in configs if c in objects]
    check(any(s.get("APPLICATION_EXTENSION_API_ONLY") == "YES" for s in settings_seen),
          "扩展设置 APPLICATION_EXTENSION_API_ONLY=YES")
    check(any(s.get("SKIP_INSTALL") == "YES" for s in settings_seen), "扩展设置 SKIP_INSTALL=YES")

    # App 必须通过 Embed App Extensions（dstSubfolderSpec=13）嵌入扩展。
    app_target = next((t for t in targets if objects.get(t, {}).get("name") == "SPlayerRemote"), None)
    embed_phase = next((p for p in objects.get(app_target, {}).get("buildPhases", [])
                        if objects.get(p, {}).get("isa") == "PBXCopyFilesBuildPhase"), None)
    check(embed_phase is not None, "App 含 Embed App Extensions 阶段")
    if embed_phase is not None:
        body = objects.get(embed_phase, {})
        check(body.get("dstSubfolderSpec") == "13", "嵌入目标为 PlugIns（dstSubfolderSpec=13）")
        build_refs = {i: b.get("fileRef") for i, b in objects.items()
                      if isinstance(b, dict) and b.get("isa") == "PBXBuildFile"}
        embedded = [objects.get(build_refs.get(bf), {}).get("path") for bf in body.get("files", [])]
        check(any((p or "").endswith(".appex") for p in embedded), f"嵌入阶段包含 .appex：{embedded}")

    check(any(objects.get(d, {}).get("target") == ext_target
              for d in objects.get(app_target, {}).get("dependencies", [])),
          "App 依赖扩展 target")


def check_extension_plist():
    with (ROOT / "SPlayerRemoteLiveActivity/Info.plist").open("rb") as fh:
        data = plistlib.load(fh)
    check(data.get("NSExtension", {}).get("NSExtensionPointIdentifier") == "com.apple.widgetkit-extension",
          "扩展 Info.plist 声明 widgetkit-extension 扩展点")


def check_info_plist():
    with INFO_PLIST.open("rb") as fh:
        data = plistlib.load(fh)
    required = [
        "CFBundleIdentifier", "CFBundleExecutable", "CFBundleShortVersionString", "CFBundleVersion",
        "NSLocalNetworkUsageDescription", "NSAppTransportSecurity", "UISupportedInterfaceOrientations",
        "NSSupportsLiveActivities",
    ]
    for key in required:
        check(key in data, f"Info.plist 含 {key}")
    check(data.get("NSSupportsLiveActivities") is True, "Info.plist NSSupportsLiveActivities 为 true")
    ats = data.get("NSAppTransportSecurity", {})
    check(ats.get("NSAllowsArbitraryLoads") is True or ats.get("NSAllowsLocalNetworking") is True,
          "ATS 允许本地 HTTP（记录为宽泛放行）")
    check(data["CFBundleIdentifier"] == "$(PRODUCT_BUNDLE_IDENTIFIER)", "CFBundleIdentifier 使用构建设置变量")
    check("NSAllowsArbitraryLoads" not in ats or ats["NSAllowsArbitraryLoads"] is True, "ATS 值类型正确")


def check_assets():
    contents = json.loads((ASSETS / "Contents.json").read_text())
    check("info" in contents, "Assets.xcassets/Contents.json 合法")
    icon = json.loads((ASSETS / "AppIcon.appiconset/Contents.json").read_text())
    filenames = [img.get("filename") for img in icon.get("images", [])]
    check(filenames and all(filenames), "AppIcon 声明了文件名")
    for name in filenames:
        p = ASSETS / "AppIcon.appiconset" / name
        check(p.is_file(), f"AppIcon 文件存在: {name}")
        if p.is_file():
            header = p.read_bytes()[:24]
            check(header[:8] == b"\x89PNG\r\n\x1a\n", f"AppIcon 是合法 PNG: {name}")
            w, h = struct.unpack(">II", header[16:24])
            check((w, h) == (1024, 1024), f"AppIcon 尺寸 1024x1024: {name} 实际 {w}x{h}")
    color = json.loads((ASSETS / "AccentColor.colorset/Contents.json").read_text())
    check("colors" in color, "AccentColor.colorset 合法")


def check_fixtures():
    for p in sorted(MOCK_FIXTURES.glob("*.json")):
        try:
            json.loads(p.read_text())
            check(True, f"fixture 合法 JSON: {p.name}")
        except json.JSONDecodeError as exc:
            check(False, f"fixture 非法: {p.name} ({exc})")
    now = json.loads((MOCK_FIXTURES / "now-playing.json").read_text())
    check(now.get("songId") == 7 and "src" in now, "now-playing fixture 覆盖 songId 且包含上游 src 字段")


def check_no_secrets():
    suspicious = re.compile(r"(?i)(token\s*[:=]\s*[\"'][A-Za-z0-9]{16,})")
    offenders = []
    for p in ROOT.rglob("*"):
        if not p.is_file() or ".git" in p.parts:
            continue
        if p.suffix in {".png"}:
            continue
        try:
            text = p.read_text(encoding="utf-8")
        except (UnicodeDecodeError, OSError):
            continue
        if p.name in {"mock_server.py"}:
            continue  # 默认 dev token 仅用于本地 mock
        if suspicious.search(text):
            offenders.append(str(p.relative_to(ROOT)))
    check(not offenders, f"未发现疑似真实 Token 明文（{offenders}）")


def check_target_membership(parsed):
    """校验每个 target 的 Sources 阶段恰好包含对应目录下的 Swift 文件。"""
    if not parsed:
        return
    objects = parsed["objects"]
    build_refs = {
        i: b.get("fileRef")
        for i, b in objects.items()
        if isinstance(b, dict) and b.get("isa") == "PBXBuildFile"
    }

    def phase_paths(phase_id):
        body = objects.get(phase_id, {})
        paths = []
        for bf in body.get("files", []):
            fr = build_refs.get(bf)
            paths.append(objects.get(fr, {}).get("path"))
        return paths

    app_swift = {p.relative_to(ROOT).as_posix() for p in (ROOT / "SPlayerRemote").rglob("*.swift")}
    shared_swift = {p.relative_to(ROOT).as_posix() for p in (ROOT / "SPlayerRemoteShared").rglob("*.swift")}
    ext_swift = {p.relative_to(ROOT).as_posix() for p in (ROOT / "SPlayerRemoteLiveActivity").rglob("*.swift")}
    tests_swift = {p.relative_to(ROOT).as_posix() for p in (ROOT / "SPlayerRemoteTests").rglob("*.swift")}
    expectations = {
        "SPlayerRemote": app_swift | shared_swift,
        "SPlayerRemoteTests": tests_swift,
        "SPlayerRemoteLiveActivity": ext_swift | shared_swift,
    }
    for target_id in objects[parsed["rootObject"]].get("targets", []):
        target = objects.get(target_id, {})
        name = target.get("name")
        if name not in expectations:
            continue
        sources_phase = next((p for p in target.get("buildPhases", []) if objects.get(p, {}).get("isa") == "PBXSourcesBuildPhase"), None)
        actual = {p for p in phase_paths(sources_phase) if p}
        check(actual == expectations[name], f"target {name} 的 Sources 与磁盘 Swift 文件一致（多余 {sorted(actual - expectations[name])}，缺失 {sorted(expectations[name] - actual)}）")
    # 资源阶段应包含 AppIcon 资产目录
    app_target = next((t for t in objects[parsed["rootObject"]].get("targets", []) if objects.get(t, {}).get("name") == "SPlayerRemote"), None)
    resources_phase = next((p for p in objects.get(app_target, {}).get("buildPhases", []) if objects.get(p, {}).get("isa") == "PBXResourcesBuildPhase"), None)
    check(any((p or "").endswith(".xcassets") for p in phase_paths(resources_phase)), "App target Resources 阶段包含 Assets.xcassets")


def main():
    parsed = check_pbxproj()
    check_test_target_unit_test(parsed)
    check_extension_target(parsed)
    check_target_membership(parsed)
    check_info_plist()
    check_extension_plist()
    check_assets()
    check_fixtures()
    check_no_secrets()

    print("\n".join(notes))
    if errors:
        print("\n" + "\n".join(errors))
        print(f"\n结构校验失败：{len(errors)} 项错误")
        return 1
    print(f"\n结构校验通过：{len(notes)} 项检查全部通过（注意：不含编译/类型检查）")
    return 0


if __name__ == "__main__":
    sys.exit(main())
