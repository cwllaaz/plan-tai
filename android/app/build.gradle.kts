import java.io.File
import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// ---------------------------------------------------------------------------
// release 签名（维护说明见 docs/android/ANDROID_SIGNING_AND_RELEASE.md）
//
// 约定：
// - `android/key.properties` 与 keystore 文件**绝不入库**（已在 android/.gitignore 忽略）；
// - 缺失 key.properties 时回退 debug 签名并打印醒目警告：这样可以继续跑
//   `flutter build apk --release` 做功能验证，但这种包**不能发布、也不能覆盖升级**
//   到正式签名的包；
// - storeFile 支持绝对路径，也支持相对 `android/` 目录的路径。
// ---------------------------------------------------------------------------
val keystorePropertiesFile = rootProject.file("key.properties")
val keystoreProperties = Properties()
val hasReleaseKeystore = keystorePropertiesFile.exists()
if (hasReleaseKeystore) {
    keystorePropertiesFile.inputStream().use { keystoreProperties.load(it) }
}
val signingRequested =
    gradle.startParameter.taskNames.any { it.contains("release", ignoreCase = true) }

if (signingRequested && !hasReleaseKeystore) {
    logger.warn(
        "==============================================================\n" +
            "WARNING: 未找到 android/key.properties，release 包将回退 DEBUG 签名。\n" +
            "         该包仅用于功能验证，不能发布、不能覆盖升级正式签名的安装。\n" +
            "         生成方式见 scripts/android/gen_keystore.ps1。\n" +
            "==============================================================",
    )
}

android {
    // 冻结：Android 应用身份，发布后永不修改（否则无法覆盖升级）。
    namespace = "com.jihuatai.planner"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // 冻结：正式发布身份（与 docs/android/ARCHITECTURE.md 一致）。
        // 注意：必须在 packaging 之前确定，不可设置 applicationIdSuffix 导致双包名。
        applicationId = "com.jihuatai.planner"
        // 与 Flutter 模板一致（24 = Android 7.0）。低版本系统的 SQLite 缺少
        // VACUUM INTO 等能力，本地库必须用随包分发的 SQLite（见 pubspec hooks）。
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        // versionCode/versionName 唯一来源是 pubspec.yaml 的 `version: x.y.z+N`：
        // 每次发布必须让 +N 单调递增（split-per-abi 时 Flutter 会再叠加 ABI 偏移）。
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        if (hasReleaseKeystore) {
            create("release") {
                keyAlias = keystoreProperties.getProperty("keyAlias")
                keyPassword = keystoreProperties.getProperty("keyPassword")
                storePassword = keystoreProperties.getProperty("storePassword")
                val storeFileValue = keystoreProperties.getProperty("storeFile")
                storeFile =
                    when {
                        storeFileValue.isNullOrBlank() -> null
                        File(storeFileValue).isAbsolute -> File(storeFileValue)
                        else -> rootProject.file(storeFileValue)
                    }
            }
        }
    }

    buildTypes {
        release {
            signingConfig =
                if (hasReleaseKeystore) {
                    signingConfigs.getByName("release")
                } else {
                    // 回退：仅供本机功能验证。构建日志里已打印 WARNING。
                    signingConfigs.getByName("debug")
                }
            // 不混淆：Flutter release 自身会做 AOT 与资源裁剪；本项目没有反射式
            // 依赖需要 ProGuard 规则，开启混淆反而增加「正式包与调试包行为不同」的风险。
            isMinifyEnabled = false
            isShrinkResources = false
        }
    }

    // 原生代码只来自 Flutter 引擎与 sqlite3 预编译库；这里显式声明不压缩 .so。
    packaging {
        jniLibs {
            useLegacyPackaging = false
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}
