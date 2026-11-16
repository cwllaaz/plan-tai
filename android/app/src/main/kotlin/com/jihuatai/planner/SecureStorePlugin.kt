package com.jihuatai.planner

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/**
 * Android 安全令牌存储的原生实现（平台通道 `com.jihuatai.planner/secure_store`）。
 *
 * 契约见 `docs/android/MODULE_CONTRACT.md` §9.2（Dart 侧实现
 * `AndroidSecureTokenStore`）。这里只做三件事：
 *
 * 1. 在 **Android Keystore** 里生成一把不可导出的 AES-256-GCM 密钥；
 * 2. 把「IV + 密文」用 Base64 编码后存进应用私有 `SharedPreferences`；
 * 3. 提供 read / write / delete / isAvailable 四个方法。
 *
 * 安全约束（违反即视为缺陷）：
 * - **禁止**任何明文落盘：SharedPreferences 里只有密文与 IV，没有密钥；
 * - 密钥永不导出（`KeyGenParameterSpec` + `setUserAuthenticationRequired(false)`，
 *   仅要求设备已解锁，不要求每次使用都验证生物特征——同步在后台也要能跑）；
 * - 解密失败（Keystore 被系统作废、备份恢复到新机、密文损坏）时，删除该条并返回
 *   `null`，让上层当作「未登录」重新走登录流程；**不回退**到明文或内存伪造。
 *
 * 参数容错：Dart 侧可以用 `{'key': ..., 'value': ...}` 形式的命名参数，也允许
 * 位置参数 `[key]` / `[key, value]`，两种写法等价，避免与 C 的 Dart 实现因参数
 * 风格不同而联调失败。
 */
class SecureStorePlugin : FlutterPlugin, MethodChannel.MethodCallHandler {

    companion object {
        const val CHANNEL = "com.jihuatai.planner/secure_store"

        private const val KEYSTORE_PROVIDER = "AndroidKeyStore"
        private const val KEY_ALIAS = "jihuatai.token.aes256gcm.v1"
        private const val PREFS_NAME = "jihuatai_secure_store"
        private const val KEY_PREFIX = "JihuaTai/"
        private const val TRANSFORMATION = "AES/GCM/NoPadding"
        private const val GCM_TAG_BITS = 128
        private const val GCM_IV_BYTES = 12
        private const val MAX_VALUE_BYTES = 8 * 1024
        private const val ENVELOPE_VERSION = "v1"
    }

    private var channel: MethodChannel? = null
    private var context: Context? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        channel =
            MethodChannel(binding.binaryMessenger, CHANNEL).also {
                it.setMethodCallHandler(this)
            }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel?.setMethodCallHandler(null)
        channel = null
        context = null
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "isAvailable" -> result.success(isAvailable())
            "read" -> {
                val key = readArgument(call, 0, "key")
                if (key.isNullOrEmpty()) {
                    result.error("invalid_key", "安全存储的 key 不能为空", null)
                    return
                }
                read(key, result)
            }
            "write" -> {
                val key = readArgument(call, 0, "key")
                val value = readArgument(call, 1, "value")
                if (key.isNullOrEmpty()) {
                    result.error("invalid_key", "安全存储的 key 不能为空", null)
                    return
                }
                if (value == null) {
                    result.error("invalid_value", "安全存储的 value 不能为 null", null)
                    return
                }
                write(key, value, result)
            }
            "delete" -> {
                val key = readArgument(call, 0, "key")
                if (key.isNullOrEmpty()) {
                    result.error("invalid_key", "安全存储的 key 不能为空", null)
                    return
                }
                delete(key, result)
            }
            else -> result.notImplemented()
        }
    }

    // ---------------------------------------------------------------------
    // 参数解析：同时接受命名参数与位置参数
    // ---------------------------------------------------------------------

    private fun readArgument(call: MethodCall, index: Int, name: String): String? {
        val fromName = call.argument<String>(name)
        if (fromName != null) return fromName
        val arguments = call.arguments
        if (arguments is List<*>) {
            return arguments.getOrNull(index)?.toString()
        }
        return null
    }

    // ---------------------------------------------------------------------
    // read / write / delete
    // ---------------------------------------------------------------------

    private fun read(key: String, result: MethodChannel.Result) {
        try {
            val stored = preferences().getString(KEY_PREFIX + key, null)
            if (stored == null) {
                result.success(null)
                return
            }
            val plain = decryptEnvelope(stored)
            if (plain == null) {
                // 密文无法解密：视为「没有会话」，并清掉这条无效记录。
                preferences().edit().remove(KEY_PREFIX + key).commit()
                result.success(null)
                return
            }
            result.success(plain)
        } catch (error: Throwable) {
            result.error("secure_store_read_failed", "读取安全存储失败：${error.javaClass.simpleName}", null)
        }
    }

    private fun write(key: String, value: String, result: MethodChannel.Result) {
        val bytes = value.toByteArray(Charsets.UTF_8)
        if (bytes.size > MAX_VALUE_BYTES) {
            result.error(
                "value_too_large",
                "安全存储的值过大（${bytes.size} 字节，上限 $MAX_VALUE_BYTES 字节）",
                null,
            )
            return
        }
        try {
            val envelope = encryptEnvelope(bytes)
            val committed = preferences().edit().putString(KEY_PREFIX + key, envelope).commit()
            if (!committed) {
                result.error("secure_store_write_failed", "写入安全存储失败（SharedPreferences commit 返回 false）", null)
                return
            }
            result.success(null)
        } catch (error: Throwable) {
            result.error("secure_store_write_failed", "写入安全存储失败：${error.javaClass.simpleName}", null)
        }
    }

    private fun delete(key: String, result: MethodChannel.Result) {
        try {
            preferences().edit().remove(KEY_PREFIX + key).commit()
            result.success(null)
        } catch (error: Throwable) {
            result.error("secure_store_delete_failed", "删除安全存储失败：${error.javaClass.simpleName}", null)
        }
    }

    // ---------------------------------------------------------------------
    // Keystore / 加解密
    // ---------------------------------------------------------------------

    private fun isAvailable(): Boolean =
        try {
            // 真机验证项：能拿到 AndroidKeyStore 且支持 AES/GCM。
            KeyStore.getInstance(KEYSTORE_PROVIDER).load(null)
            KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, KEYSTORE_PROVIDER)
            true
        } catch (error: Throwable) {
            false
        }

    private fun preferences() =
        requireNotNull(context) { "SecureStorePlugin 未绑定 Context" }
            .getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)

    private fun secretKey(): SecretKey {
        val keyStore = KeyStore.getInstance(KEYSTORE_PROVIDER).apply { load(null) }
        val existing = keyStore.getEntry(KEY_ALIAS, null)
        if (existing is KeyStore.SecretKeyEntry) return existing.secretKey

        val generator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, KEYSTORE_PROVIDER)
        generator.init(
            KeyGenParameterSpec.Builder(
                KEY_ALIAS,
                KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT,
            )
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setKeySize(256)
                // 同步可能发生在后台：不要求每次使用都做生物特征验证。
                .setUserAuthenticationRequired(false)
                .setRandomizedEncryptionRequired(true)
                .build(),
        )
        return generator.generateKey()
    }

    /** 返回 `v1:<base64(iv)>:<base64(ciphertext)>`。 */
    private fun encryptEnvelope(plain: ByteArray): String {
        val cipher = Cipher.getInstance(TRANSFORMATION)
        cipher.init(Cipher.ENCRYPT_MODE, secretKey())
        val iv = cipher.iv
        require(iv.size == GCM_IV_BYTES) { "意外的 GCM IV 长度：${iv.size}" }
        val ciphertext = cipher.doFinal(plain)
        val encoder = Base64.NO_WRAP
        return "$ENVELOPE_VERSION:${Base64.encodeToString(iv, encoder)}:${Base64.encodeToString(ciphertext, encoder)}"
    }

    /** 解密失败（含格式不认识）返回 null；由调用方当作「无会话」处理。 */
    private fun decryptEnvelope(envelope: String): String? {
        val parts = envelope.split(':')
        if (parts.size != 3 || parts[0] != ENVELOPE_VERSION) return null
        return try {
            val decoder = Base64.NO_WRAP
            val iv = Base64.decode(parts[1], decoder)
            val ciphertext = Base64.decode(parts[2], decoder)
            if (iv.size != GCM_IV_BYTES || ciphertext.isEmpty()) return null
            val cipher = Cipher.getInstance(TRANSFORMATION)
            cipher.init(
                Cipher.DECRYPT_MODE,
                secretKey(),
                GCMParameterSpec(GCM_TAG_BITS, iv),
            )
            String(cipher.doFinal(ciphertext), Charsets.UTF_8)
        } catch (error: Throwable) {
            null
        }
    }
}
