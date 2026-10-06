package com.androiddsh

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import android.util.Log
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/**
 * 用 Android Keystore 保护的凭证存储。
 *
 * 原先 API key 直接明文躺在 SharedPreferences 里（README 的待办 #4）。
 * 这里改成：密钥材料由 Keystore 生成且**永远不出安全硬件/TEE**，磁盘上只存
 * `iv + ciphertext`。app 被 root 之外的常规手段拖库时拿不到明文。
 *
 * 用的是 AndroidKeyStore 的 AES/GCM/NoPadding，`setUserAuthenticationRequired(false)`
 * —— agent 要在后台无人值守地跑，不能要求每次解锁。
 */
object SecretStore {

    const val KEY_API_KEY = "apiKey"

    private const val TAG = "SecretStore"
    private const val KEYSTORE = "AndroidKeyStore"
    private const val ALIAS = "androiddsh-secrets"
    private const val TRANSFORM = "AES/GCM/NoPadding"
    private const val IV_BYTES = 12
    private const val TAG_BITS = 128

    private const val PREFS = "android-dsh-secrets"

    private fun prefs(context: Context) =
        context.applicationContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    private fun secretKey(): SecretKey {
        val ks = KeyStore.getInstance(KEYSTORE).apply { load(null) }
        (ks.getEntry(ALIAS, null) as? KeyStore.SecretKeyEntry)?.let { return it.secretKey }
        val generator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, KEYSTORE)
        generator.init(
            KeyGenParameterSpec.Builder(
                ALIAS,
                KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT,
            )
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setKeySize(256)
                .build()
        )
        return generator.generateKey()
    }

    fun put(context: Context, key: String, value: String) {
        runCatching {
            if (value.isEmpty()) {
                prefs(context).edit().remove(key).apply()
                return
            }
            val cipher = Cipher.getInstance(TRANSFORM).apply { init(Cipher.ENCRYPT_MODE, secretKey()) }
            val payload = cipher.iv + cipher.doFinal(value.toByteArray(Charsets.UTF_8))
            prefs(context).edit()
                .putString(key, Base64.encodeToString(payload, Base64.NO_WRAP))
                .apply()
        }.onFailure { Log.e(TAG, "写入 $key 失败", it) }
    }

    fun get(context: Context, key: String): String? {
        val stored = prefs(context).getString(key, null) ?: return null
        return runCatching {
            val payload = Base64.decode(stored, Base64.NO_WRAP)
            val cipher = Cipher.getInstance(TRANSFORM).apply {
                init(
                    Cipher.DECRYPT_MODE, secretKey(),
                    GCMParameterSpec(TAG_BITS, payload, 0, IV_BYTES),
                )
            }
            String(cipher.doFinal(payload, IV_BYTES, payload.size - IV_BYTES), Charsets.UTF_8)
        }.onFailure {
            // 密钥被清除（重装/恢复出厂/换机）时旧密文解不开，按"没有"处理
            Log.w(TAG, "读取 $key 失败，按空值处理", it)
            prefs(context).edit().remove(key).apply()
        }.getOrNull()
    }
}
