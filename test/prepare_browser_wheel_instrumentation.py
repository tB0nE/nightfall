#!/usr/bin/env python3
"""Prepare a tiny isolated APK for the real WebView wheel-event test.

No Godot scene, models, account data, or release signing credentials are used.
Run the Gradle/ADB commands in docs/guides/agent-testing.md after preparation.
"""
import argparse
import os
from pathlib import Path
import shutil
import zipfile

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--sdk', type=Path, required=True)
    parser.add_argument('--template', type=Path, default=Path(os.environ.get(
        'NIGHTFALL_ANDROID_SOURCE_TEMPLATE',
        str(Path.home() / '.local/share/godot/export_templates/4.7.stable/android_source.zip'))))
    parser.add_argument('--output', type=Path, default=ROOT / '.build-cache/browser-wheel-instrumentation')
    args = parser.parse_args()
    out = args.output.resolve()
    out.mkdir(parents=True, exist_ok=True)
    # Only copy the trusted local template's wrapper; do not unpack its runtime.
    with zipfile.ZipFile(args.template) as archive:
        for name in ['gradlew', 'gradle/wrapper/gradle-wrapper.jar', 'gradle/wrapper/gradle-wrapper.properties']:
            target = out / name
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(archive.read(name))
    (out / 'gradlew').chmod(0o755)
    (out / 'settings.gradle').write_text('''pluginManagement { repositories { google(); mavenCentral(); gradlePluginPortal() } }
dependencyResolutionManagement { repositories { google(); mavenCentral() } }
rootProject.name="NightfallBrowserTests"
''')
    (out / 'build.gradle').write_text('''plugins { id 'com.android.application' version '8.6.1' }
android {
 namespace 'com.godot.game'
 compileSdk 36
 buildToolsVersion "36.1.0"
 defaultConfig {
  applicationId 'app.nightfall.quest.instrumented'
  minSdk 29
  targetSdk 32
  versionCode 1
  versionName 'wheel-test'
  testInstrumentationRunner 'androidx.test.runner.AndroidJUnitRunner'
 }
 compileOptions { sourceCompatibility JavaVersion.VERSION_17; targetCompatibility JavaVersion.VERSION_17 }
}
dependencies {
 implementation 'androidx.webkit:webkit:1.12.1'
 androidTestImplementation 'androidx.test.ext:junit:1.3.0'
 androidTestImplementation 'androidx.test:runner:1.7.0'
}
''')
    (out / 'gradle.properties').write_text('android.useAndroidX=true\norg.gradle.jvmargs=-Xmx2g\nandroid.suppressUnsupportedCompileSdk=36\n')
    sdk = str(args.sdk.resolve()).replace('\\', '\\\\').replace(':', '\\:')
    (out / 'local.properties').write_text(f'sdk.dir={sdk}\n')
    source = ROOT / 'android/src/main/java/com/godot/game'
    java = out / 'src/main/java/com/godot/game'
    java.mkdir(parents=True, exist_ok=True)
    for file in [*source.glob('Browser*.java'), source / 'DiagnosticLog.java',
                 ROOT / 'android/src/instrumented/java/com/godot/game/BrowserTestActivity.java']:
        shutil.copyfile(file, java / file.name)
    (out / 'src/main/AndroidManifest.xml').write_text('''<manifest xmlns:android="http://schemas.android.com/apk/res/android"><uses-permission android:name="android.permission.INTERNET"/><application android:usesCleartextTraffic="true" android:theme="@android:style/Theme.Material.Light.NoActionBar"><activity android:name="com.godot.game.BrowserTestActivity" android:exported="false"/></application></manifest>''')
    tests = out / 'src/androidTest/java/com/godot/game'
    tests.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(ROOT / 'android/src/androidTest/java/com/godot/game/BrowserWebViewIntegrationTest.java',
                    tests / 'BrowserWebViewIntegrationTest.java')
    print(f'Prepared {out} (app.nightfall.quest.instrumented only)')


if __name__ == '__main__':
    main()
