#!/usr/bin/env python3
"""Generates the Xcode project, both Info.plist files and the Dawn alarm sound.

The output is deterministic, so regenerating without source changes leaves git
clean. Signing values come from Config/Signing.xcconfig and an optional,
untracked Config/Local.xcconfig.
"""
from pathlib import Path
import hashlib, math, plistlib, struct, wave

NAME = 'FitheWake'
WIDGET = 'WakeActivity'
UITESTS = f'{NAME}UITests'
VERSION, BUILD = '0.2.0', '3'
ROOT = Path(__file__).resolve().parents[1]

objects = []

def uid(key):
    return hashlib.sha1(key.encode()).hexdigest()[:24].upper()

def obj(key, body):
    objects.append(f'{uid(key)} = {{ {body} }};')

def refs(keys):
    return '(' + ''.join(uid(k) + ', ' for k in keys) + ')'

def settings(values):
    return '{' + ' '.join(f'{k} = {v};' for k, v in values.items()) + '}'

def swift_files(folder):
    return sorted(str(p.relative_to(ROOT)) for p in (ROOT / folder).rglob('*.swift'))

# Sources per target. Shared/ files are compiled into more than one target.
APP_FILES = swift_files('App') + ['Shared/AppInfo.swift', 'Shared/LaunchFlag.swift', 'Shared/WakeMetadata.swift']
WIDGET_FILES = swift_files('Widgets') + ['Shared/AppInfo.swift', 'Shared/WakeMetadata.swift']
UITEST_FILES = swift_files('UITests') + ['Shared/LaunchFlag.swift']
SOUND = 'App/Dawn.wav'
SIGNING = 'Config/Signing.xcconfig'

# File references, grouped by folder as on disk.
files = sorted(set(APP_FILES + WIDGET_FILES + UITEST_FILES + [SOUND, SIGNING]))
kinds = {'.swift': 'sourcecode.swift', '.wav': 'audio.wav', '.xcconfig': 'text.xcconfig'}
folders = {}
for path in files:
    p = Path(path)
    obj(path, f'isa = PBXFileReference; name = "{p.name}"; path = "{path}"; sourceTree = SOURCE_ROOT; '
              f'lastKnownFileType = {kinds[p.suffix]};')
    for depth in range(1, len(p.parts)):
        folders.setdefault('/'.join(p.parts[:depth]), set())
    folders.setdefault(str(p.parent), set()).add(path)
for folder in folders:
    parent = str(Path(folder).parent)
    if parent != '.':
        folders[parent].add(folder)
for folder, children in folders.items():
    obj('group:' + folder, f'isa = PBXGroup; name = "{Path(folder).name}"; '
                           f'children = {refs(["group:" + c if c in folders else c for c in sorted(children)])}; sourceTree = "<group>";')

products = {'app': f'{NAME}.app', 'widget': f'{WIDGET}.appex', 'uitest': f'{UITESTS}.xctest'}
product_types = {'app': 'wrapper.application', 'widget': '"wrapper.app-extension"', 'uitest': 'wrapper.cfbundle'}
for target, product in products.items():
    obj('product:' + target, f'isa = PBXFileReference; path = {product}; sourceTree = BUILT_PRODUCTS_DIR; '
                             f'explicitFileType = {product_types[target]};')
obj('products', f'isa = PBXGroup; name = Products; children = {refs("product:" + t for t in products)}; sourceTree = "<group>";')
top = sorted(f for f in folders if '/' not in f)
obj('main', f'isa = PBXGroup; children = {refs(["group:" + f for f in top] + ["products"])}; sourceTree = "<group>";')

# The app links the FitheWakeCore package product and embeds the widget.
obj('package', 'isa = XCLocalSwiftPackageReference; relativePath = .;')
obj('core', f'isa = XCSwiftPackageProductDependency; package = {uid("package")}; productName = FitheWakeCore;')
obj('build:core', f'isa = PBXBuildFile; productRef = {uid("core")};')
obj('build:embed', f'isa = PBXBuildFile; fileRef = {uid("product:widget")}; settings = {{ATTRIBUTES = (RemoveHeadersOnCopy,);}};')
obj('embed', f'isa = PBXCopyFilesBuildPhase; buildActionMask = 2147483647; runOnlyForDeploymentPostprocessing = 0; '
             f'dstPath = ""; dstSubfolderSpec = 13; files = {refs(["build:embed"])}; name = "Embed Extensions";')

COMMON = {'PRODUCT_NAME': '"$(TARGET_NAME)"', 'SWIFT_VERSION': '5.0', 'IPHONEOS_DEPLOYMENT_TARGET': '26.0',
          'CODE_SIGN_STYLE': 'Automatic'}
targets = {
    'app': dict(name=NAME, files=APP_FILES, kind='application', bundle=f'$(BUNDLE_ID_PREFIX).{NAME}',
                extra={'INFOPLIST_FILE': 'App/Info.plist', 'GENERATE_INFOPLIST_FILE': 'NO',
                       'TARGETED_DEVICE_FAMILY': '"1,2"', 'CURRENT_PROJECT_VERSION': BUILD, 'MARKETING_VERSION': VERSION},
                resources=[SOUND], frameworks=['build:core'], phases=['embed'], depends=['widget'], packages=['core']),
    'widget': dict(name=WIDGET, files=WIDGET_FILES, kind='app-extension', bundle=f'$(BUNDLE_ID_PREFIX).{NAME}.Activity',
                   extra={'INFOPLIST_FILE': 'Widgets/Info.plist', 'GENERATE_INFOPLIST_FILE': 'NO',
                          'TARGETED_DEVICE_FAMILY': '"1,2"', 'CURRENT_PROJECT_VERSION': BUILD, 'MARKETING_VERSION': VERSION,
                          'APPLICATION_EXTENSION_API_ONLY': 'YES', 'SKIP_INSTALL': 'YES'},
                   resources=[], frameworks=[], phases=[], depends=[], packages=[]),
    'uitest': dict(name=UITESTS, files=UITEST_FILES, kind='bundle.ui-testing', bundle=f'$(BUNDLE_ID_PREFIX).{NAME}.UITests',
                   extra={'GENERATE_INFOPLIST_FILE': 'YES', 'TEST_TARGET_NAME': NAME},
                   resources=[], frameworks=[], phases=[], depends=['app'], packages=[]),
}
for key, t in targets.items():
    for path in t['files'] + t['resources']:
        obj(f'build:{key}:{path}', f'isa = PBXBuildFile; fileRef = {uid(path)};')
    phase = 'buildActionMask = 2147483647; runOnlyForDeploymentPostprocessing = 0;'
    obj(f'{key}:sources', f'isa = PBXSourcesBuildPhase; {phase} files = {refs(f"build:{key}:{p}" for p in t["files"])};')
    obj(f'{key}:resources', f'isa = PBXResourcesBuildPhase; {phase} files = {refs(f"build:{key}:{p}" for p in t["resources"])};')
    obj(f'{key}:frameworks', f'isa = PBXFrameworksBuildPhase; {phase} files = {refs(t["frameworks"])};')
    for other in t['depends']:
        obj(f'{key}:needs:{other}', f'isa = PBXTargetDependency; target = {uid(other)};')
    values = COMMON | {'PRODUCT_BUNDLE_IDENTIFIER': f'"{t["bundle"]}"'} | t['extra']
    for config in ['Debug', 'Release']:
        obj(f'{key}:{config}', f'isa = XCBuildConfiguration; name = {config}; buildSettings = {settings(values)};')
    obj(f'{key}:configs', f'isa = XCConfigurationList; buildConfigurations = {refs([f"{key}:Debug", f"{key}:Release"])}; '
                          'defaultConfigurationName = Release;')
    phases = [f'{key}:sources', f'{key}:frameworks', f'{key}:resources'] + t['phases']
    obj(key, f'isa = PBXNativeTarget; name = {t["name"]}; productType = "com.apple.product-type.{t["kind"]}"; '
             f'productReference = {uid("product:" + key)}; buildConfigurationList = {uid(key + ":configs")}; '
             f'buildPhases = {refs(phases)}; dependencies = {refs(f"{key}:needs:{o}" for o in t["depends"])}; '
             f'packageProductDependencies = {refs(t["packages"])};')

for config in ['Debug', 'Release']:
    values = {'SDKROOT': 'iphoneos', 'CLANG_ENABLE_MODULES': 'YES',
              'SWIFT_OPTIMIZATION_LEVEL': '"-Onone"' if config == 'Debug' else '"-O"'}
    if config == 'Debug':
        values['SWIFT_ACTIVE_COMPILATION_CONDITIONS'] = '"DEBUG $(inherited)"'
    obj('project:' + config, f'isa = XCBuildConfiguration; name = {config}; baseConfigurationReference = {uid(SIGNING)}; '
                             f'buildSettings = {settings(values)};')
obj('project:configs', f'isa = XCConfigurationList; buildConfigurations = {refs(["project:Debug", "project:Release"])}; '
                       'defaultConfigurationName = Release;')
obj('project', f'isa = PBXProject; buildConfigurationList = {uid("project:configs")}; compatibilityVersion = "Xcode 14.0"; '
               f'mainGroup = {uid("main")}; productRefGroup = {uid("products")}; targets = {refs(targets)}; '
               f'packageReferences = {refs(["package"])}; attributes = {{LastUpgradeCheck = 2600;}};')

project = ROOT / f'{NAME}.xcodeproj'
project.mkdir(exist_ok=True)
(project / 'project.pbxproj').write_text('// !$*UTF8*$!\n{ archiveVersion = 1; classes = {}; objectVersion = 56; objects = {\n'
                                         + '\n'.join(objects) + f'\n}}; rootObject = {uid("project")}; }}\n')

def buildable(key):
    t = targets[key]
    return (f'<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{uid(key)}" '
            f'BuildableName="{products[key]}" BlueprintName="{t["name"]}" ReferencedContainer="container:{NAME}.xcodeproj"/>')

debugger = 'selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB"'
schemes = project / 'xcshareddata/xcschemes'
schemes.mkdir(parents=True, exist_ok=True)
(schemes / f'{NAME}.xcscheme').write_text(
    '<?xml version="1.0" encoding="UTF-8"?>\n'
    '<Scheme LastUpgradeVersion="2600" version="1.3">'
    '<BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries>'
    '<BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">'
    f'{buildable("app")}</BuildActionEntry></BuildActionEntries></BuildAction>'
    f'<TestAction buildConfiguration="Debug" {debugger}><Testables><TestableReference skipped="NO">{buildable("uitest")}'
    '</TestableReference></Testables></TestAction>'
    f'<LaunchAction buildConfiguration="Debug" {debugger} launchStyle="0"><BuildableProductRunnable runnableDebuggingMode="0">'
    f'{buildable("app")}</BuildableProductRunnable></LaunchAction>'
    '<ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/></Scheme>')

base = dict(CFBundleIdentifier='$(PRODUCT_BUNDLE_IDENTIFIER)', CFBundleExecutable='$(EXECUTABLE_NAME)',
            CFBundleName='$(PRODUCT_NAME)', CFBundleDisplayName=NAME, CFBundleVersion=BUILD, CFBundleShortVersionString=VERSION)
app_plist = base | dict(
    CFBundlePackageType='APPL',
    NSAlarmKitUsageDescription=f'{NAME} sounds your scheduled wake-up alarm, even in Silent Mode.',
    NSBluetoothAlwaysUsageDescription='Receive live heart rate from your selected wearable for Experimental Smart Wake.',
    UIUserInterfaceStyle='Dark', UIBackgroundModes=['bluetooth-central'], NSSupportsLiveActivities=True,
    UILaunchScreen={}, UIApplicationSceneManifest={'UIApplicationSupportsMultipleScenes': False})
widget_plist = base | dict(CFBundlePackageType='XPC!', NSExtension={'NSExtensionPointIdentifier': 'com.apple.widgetkit-extension'})
for path, data in [('App/Info.plist', app_plist), ('Widgets/Info.plist', widget_plist)]:
    with (ROOT / path).open('wb') as f:
        plistlib.dump(data, f)

# A 24-second two-tone chime. The rising loudness is in the recording itself,
# because an alarm sound cannot change the device volume.
RATE, SECONDS = 22050, 24
with wave.open(str(ROOT / SOUND), 'wb') as sound:
    sound.setnchannels(1); sound.setsampwidth(2); sound.setframerate(RATE)
    frames = bytearray()
    for i in range(SECONDS * RATE):
        t = i / RATE
        pulse = t % 2
        envelope = min(1, pulse / 0.03) * math.exp(-2.2 * pulse)
        ramp = 0.08 + 0.7 * (t / SECONDS)
        fade = min(1, (SECONDS - t) / 0.1)
        value = ramp * envelope * fade * (math.sin(2 * math.pi * 523.25 * t) + 0.3 * math.sin(2 * math.pi * 783.99 * t)) / 1.3
        frames.extend(struct.pack('<h', int(value * 30000)))
    sound.writeframes(frames)
print(f'Generated {NAME}.xcodeproj, both Info.plist files and {SOUND}.')
