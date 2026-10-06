plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    id("org.jetbrains.kotlin.plugin.compose")
}

android {
    namespace = "com.androiddsh"
    compileSdk = 36

    defaultConfig {
        applicationId = "com.androiddsh"
        minSdk = 26          // 与 scripts/build-node-android.sh 里的 DSH_NODE_API 保持一致
        targetSdk = 36
        versionCode = 2
        versionName = "0.2.0"
    }

    // 每个 ABI 一个 APK：单包里两套 libnode.so 加起来近 200MB，
    // 分开之后真机包只有一半大小，安装快很多。
    splits {
        abi {
            isEnable = true
            reset()
            include("arm64-v8a", "x86_64")
            isUniversalApk = false
        }
    }

    packaging {
        jniLibs {
            // 必须为 true。Node 二进制是以 libnode.so 的名义放进 jniLibs 的：
            // Android 10+ 的 W^X 禁止从 app 可写数据目录 exec()，而 nativeLibraryDir
            // （/data/app/~~xxx/pkg-yyy==/lib/<abi>/）是只读的，允许执行。
            // 默认的 useLegacyPackaging=false 会把 .so 留在 APK 内直接 mmap，
            // nativeLibraryDir 下没有真实文件，exec 会失败。
            useLegacyPackaging = true
            // 别让 AGP 去 strip 这两个"其实不是 .so"的可执行文件
            keepDebugSymbols += listOf("**/libnode.so", "**/libbash.so")
        }
    }

    androidResources {
        // 运行时包用自定义后缀：AAPT 会把 ".gz" 当压缩标记处理并把文件改名成
        // "dsh-runtime.tar"（实测踩过），导致按原名读不到。用不受特殊处理的后缀并
        // 声明不压缩（内容本身已是 gzip）。
        noCompress += listOf("pkg")
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    buildFeatures {
        compose = true
        // DshWebView 用 BuildConfig.DEBUG 决定要不要开 chrome://inspect 远程调试
        buildConfig = true
    }
}

kotlin {
    compilerOptions {
        jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17)
    }
}

dependencies {
    implementation(platform("androidx.compose:compose-bom:2026.06.01"))
    implementation("androidx.compose.material3:material3")
    implementation("androidx.compose.ui:ui")
    implementation("androidx.activity:activity-compose:1.12.4")
    // 解压运行时用的 tar.gz（Android 无内置 tar 支持）
    implementation("org.apache.commons:commons-compress:1.27.1")
}
