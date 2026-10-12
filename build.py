"""不用 Gradle 打包小柯 APK：aapt2 → javac → d8 → zipalign → apksigner。

需要：Python 3.8+、JDK 17、Android SDK（build-tools 34.0.0、platforms/android-34）。
SDK / JDK 位置依序讀取：local.properties（sdk.dir= / jdk.dir=）→ ANDROID_HOME / JAVA_HOME。
用法：python build.py          產生 build/xiaoke.apk
      python build.py install  另外用 adb 安裝並啟動
"""
import glob
import os
import shutil
import subprocess
import sys
import zipfile

ROOT = os.path.dirname(os.path.abspath(__file__))
BUILD = os.path.join(ROOT, "build")
EXE = ".exe" if os.name == "nt" else ""
BAT = ".bat" if os.name == "nt" else ""


def props():
    p = {}
    f = os.path.join(ROOT, "local.properties")
    if os.path.exists(f):
        for line in open(f, encoding="utf-8"):
            if "=" in line and not line.startswith("#"):
                k, v = line.split("=", 1)
                p[k.strip()] = v.strip().replace("\\:", ":").replace("\\\\", "\\")
    return p


P = props()
SDK = P.get("sdk.dir") or os.environ.get("ANDROID_HOME") or os.environ.get("ANDROID_SDK_ROOT") \
    or os.path.join(os.environ.get("LOCALAPPDATA", ""), "Android", "Sdk")
JDK = P.get("jdk.dir") or os.environ.get("JAVA_HOME", "")


def latest(pattern):
    found = sorted(glob.glob(pattern))
    if not found:
        sys.exit("找不到 " + pattern)
    return found[-1]


BT = latest(os.path.join(SDK, "build-tools", "*"))
ANDROID_JAR = latest(os.path.join(SDK, "platforms", "android-*", "android.jar"))
JAVAC = os.path.join(JDK, "bin", "javac" + EXE) if JDK else "javac"
KEYTOOL = os.path.join(JDK, "bin", "keytool" + EXE) if JDK else "keytool"
ADB = os.path.join(SDK, "platform-tools", "adb" + EXE)
if JDK:   # d8.bat / apksigner.bat 靠 JAVA_HOME 找 java
    os.environ["JAVA_HOME"] = JDK


def rel(p):
    """aapt2 打不開含中文的絕對路徑，改用相對於專案的路徑（cwd = ROOT）。"""
    try:
        return os.path.relpath(p, ROOT)
    except ValueError:   # 不同磁碟
        return p


def run(*cmd):
    print(">", " ".join(os.path.basename(c) if i == 0 else c for i, c in enumerate(cmd)))
    subprocess.check_call(list(cmd), cwd=ROOT)


def main():
    if not os.path.exists(os.path.join(ROOT, "src", "com", "achir", "xiaoke", "Config.java")):
        sys.exit("請先把 Config.example.java.txt 複製成 Config.java 並填入 OPENAI_API_KEY")

    shutil.rmtree(BUILD, ignore_errors=True)
    for d in ("res", "gen", "classes", "dex"):
        os.makedirs(os.path.join(BUILD, d))

    # 1. 資源
    run(os.path.join(BT, "aapt2" + EXE), "compile", "--dir", "res", "-o", rel(os.path.join(BUILD, "res.zip")))
    unsigned = os.path.join(BUILD, "unsigned.apk")
    link = [os.path.join(BT, "aapt2" + EXE), "link", "-o", rel(unsigned),
            "-I", rel(ANDROID_JAR), "--manifest", "AndroidManifest.xml",
            "--java", rel(os.path.join(BUILD, "gen")), "--auto-add-overlay", rel(os.path.join(BUILD, "res.zip"))]
    if os.path.isdir(os.path.join(ROOT, "assets")):
        link += ["-A", "assets"]       # 病房助理工作站的 tools.json 與 QR 圖
    run(*link)

    # 2. Java
    sources = glob.glob(os.path.join(ROOT, "src", "**", "*.java"), recursive=True)
    sources += glob.glob(os.path.join(BUILD, "gen", "**", "*.java"), recursive=True)
    run(JAVAC, "-encoding", "UTF-8", "--release", "8", "-nowarn",
        "-classpath", ANDROID_JAR, "-d", os.path.join(BUILD, "classes"), *sources)

    # 3. dex
    classes = glob.glob(os.path.join(BUILD, "classes", "**", "*.class"), recursive=True)
    run(os.path.join(BT, "d8" + BAT), "--release", "--min-api", "24", "--lib", ANDROID_JAR,
        "--output", os.path.join(BUILD, "dex"), *classes)
    with zipfile.ZipFile(unsigned, "a") as z:
        z.write(os.path.join(BUILD, "dex", "classes.dex"), "classes.dex")

    # 4. 對齊 + 簽章
    aligned = os.path.join(BUILD, "aligned.apk")
    run(os.path.join(BT, "zipalign" + EXE), "-f", "4", unsigned, aligned)
    ks = os.path.join(ROOT, "xiaoke.jks")
    if not os.path.exists(ks):
        run(KEYTOOL, "-genkeypair", "-keystore", ks, "-storepass", "android", "-keypass", "android",
            "-alias", "xiaoke", "-keyalg", "RSA", "-keysize", "2048", "-validity", "10000",
            "-dname", "CN=XiaoKe")
    out = os.path.join(BUILD, "xiaoke.apk")
    run(os.path.join(BT, "apksigner" + BAT), "sign", "--ks", ks, "--ks-pass", "pass:android",
        "--out", out, aligned)
    print("完成：", out)

    if "install" in sys.argv[1:]:
        run(ADB, "install", "-r", "-g", out)
        run(ADB, "shell", "am", "start", "-n", "com.achir.xiaoke/.MainActivity")


if __name__ == "__main__":
    main()
