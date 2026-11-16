package com.jihuatai.planner

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.provider.OpenableColumns
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.PluginRegistry
import java.io.File
import java.io.IOException

/**
 * Android 文件选择通道（平台通道 `com.jihuatai.planner/storage`）。
 *
 * 为什么自己写而不是引第三方：本项目 `pubspec.yaml` 统一维护，
 * 且 `file_picker` / `share_plus` 会带一串 Android 依赖；备份导出/导入只需要
 * 两个系统 Intent + 一个 `MethodChannel`，自己实现约 150 行、零新增依赖、
 * 不申请任何存储权限。
 *
 * 能力：
 * - `createDocument(fileName, mimeType, bytes)`：`ACTION_CREATE_DOCUMENT`，
 *   让用户选保存位置（下载目录 / 网盘 / U 盘…），把字节写入用户选中的 URI。
 *   用户取消返回 `null`（不是错误）。
 * - `openDocument(mimeTypes)`：`ACTION_OPEN_DOCUMENT`，把用户选中的文件**拷贝**到
 *   应用缓存目录 `cache/imports/` 后返回本地路径。上层（Dart）只在这个临时副本上
 *   做校验与恢复，避免直接持有 content:// URI 的生命周期问题。
 * - `isAvailable`：Activity 已就绪才可用（纯后台时选择器没有宿主）。
 *
 * 安全/健壮性：
 * - 写文件走 `openOutputStream(uri, "wt")`（截断写），失败返回错误码；
 * - 导入上限 64MB，超过直接拒绝，避免 OOM；
 * - 同一时刻只允许一个选择器请求，避免回调串号；
 * - Activity 分离时把未完成请求以 `activity_detached` 失败返回，不悬挂 Future。
 */
class StoragePlugin :
    FlutterPlugin,
    ActivityAware,
    MethodChannel.MethodCallHandler,
    PluginRegistry.ActivityResultListener {

    companion object {
        const val CHANNEL = "com.jihuatai.planner/storage"

        private const val REQUEST_CREATE_DOCUMENT = 7401
        private const val REQUEST_OPEN_DOCUMENT = 7402
        private const val MAX_IMPORT_BYTES = 64L * 1024 * 1024
        private const val COPY_BUFFER = 64 * 1024
    }

    private sealed interface Pending {
        class Create(val bytes: ByteArray, val result: MethodChannel.Result) : Pending
        class Open(val result: MethodChannel.Result) : Pending
    }

    private var channel: MethodChannel? = null
    private var activity: Activity? = null
    private var activityBinding: ActivityPluginBinding? = null
    private var pending: Pending? = null

    // ---------------------------------------------------------------------
    // FlutterPlugin
    // ---------------------------------------------------------------------

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel =
            MethodChannel(binding.binaryMessenger, CHANNEL).also {
                it.setMethodCallHandler(this)
            }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel?.setMethodCallHandler(null)
        channel = null
    }

    // ---------------------------------------------------------------------
    // ActivityAware
    // ---------------------------------------------------------------------

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activity = binding.activity
        activityBinding = binding
        binding.addActivityResultListener(this)
    }

    override fun onDetachedFromActivityForConfigChanges() {
        detachActivity()
    }

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) {
        onAttachedToActivity(binding)
    }

    override fun onDetachedFromActivity() {
        detachActivity()
    }

    private fun detachActivity() {
        activityBinding?.removeActivityResultListener(this)
        activityBinding = null
        activity = null
        failPending("activity_detached", "系统文件选择器宿主 Activity 已销毁，请重试")
    }

    private fun failPending(code: String, message: String) {
        val current = pending ?: return
        pending = null
        current.let {
            when (it) {
                is Pending.Create -> it.result.error(code, message, null)
                is Pending.Open -> it.result.error(code, message, null)
            }
        }
    }

    // ---------------------------------------------------------------------
    // MethodChannel
    // ---------------------------------------------------------------------

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "isAvailable" -> result.success(activity != null)
            "createDocument" -> createDocument(call, result)
            "openDocument" -> openDocument(call, result)
            else -> result.notImplemented()
        }
    }

    private fun createDocument(call: MethodCall, result: MethodChannel.Result) {
        val host = activity
        if (host == null) {
            result.error("activity_unavailable", "当前没有可用的 Activity，无法打开系统保存对话框", null)
            return
        }
        if (pending != null) {
            result.error("busy", "另一个文件选择器请求尚未结束", null)
            return
        }

        val fileName = call.argument<String>("fileName")?.trim().orEmpty()
        if (fileName.isEmpty()) {
            result.error("invalid_argument", "fileName 不能为空", null)
            return
        }
        val mimeType = call.argument<String>("mimeType")?.trim().takeUnless { it.isNullOrEmpty() }
            ?: "application/octet-stream"
        val bytes = call.argument<ByteArray>("bytes")
        if (bytes == null) {
            result.error("invalid_argument", "bytes 不能为空", null)
            return
        }

        pending = Pending.Create(bytes, result)
        try {
            val intent =
                Intent(Intent.ACTION_CREATE_DOCUMENT).apply {
                    addCategory(Intent.CATEGORY_OPENABLE)
                    type = mimeType
                    putExtra(Intent.EXTRA_TITLE, fileName)
                }
            host.startActivityForResult(intent, REQUEST_CREATE_DOCUMENT)
        } catch (error: Throwable) {
            pending = null
            result.error("intent_failed", "无法打开系统保存对话框：${error.javaClass.simpleName}", null)
        }
    }

    private fun openDocument(call: MethodCall, result: MethodChannel.Result) {
        val host = activity
        if (host == null) {
            result.error("activity_unavailable", "当前没有可用的 Activity，无法打开系统文件选择器", null)
            return
        }
        if (pending != null) {
            result.error("busy", "另一个文件选择器请求尚未结束", null)
            return
        }

        val mimeTypes =
            (call.argument<List<String>>("mimeTypes") ?: emptyList())
                .mapNotNull { it.takeUnless { item -> item.isBlank() } }
        val primaryType = if (mimeTypes.size == 1) mimeTypes.first() else "*/*"

        pending = Pending.Open(result)
        try {
            val intent =
                Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
                    addCategory(Intent.CATEGORY_OPENABLE)
                    type = primaryType
                    if (mimeTypes.isNotEmpty()) {
                        putExtra(Intent.EXTRA_MIME_TYPES, mimeTypes.toTypedArray())
                    }
                }
            host.startActivityForResult(intent, REQUEST_OPEN_DOCUMENT)
        } catch (error: Throwable) {
            pending = null
            result.error("intent_failed", "无法打开系统文件选择器：${error.javaClass.simpleName}", null)
        }
    }

    // ---------------------------------------------------------------------
    // ActivityResult
    // ---------------------------------------------------------------------

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode != REQUEST_CREATE_DOCUMENT && requestCode != REQUEST_OPEN_DOCUMENT) {
            return false
        }
        val current = pending
        pending = null
        if (current == null) return true

        if (resultCode != Activity.RESULT_OK) {
            // 用户取消：不是错误，返回 null 让 Dart 侧当作「未导出」。
            when (current) {
                is Pending.Create -> current.result.success(null)
                is Pending.Open -> current.result.success(null)
            }
            return true
        }

        val uri = data?.data
        if (uri == null) {
            when (current) {
                is Pending.Create -> current.result.error("no_uri", "系统未返回目标文件地址", null)
                is Pending.Open -> current.result.error("no_uri", "系统未返回所选文件地址", null)
            }
            return true
        }

        when (current) {
            is Pending.Create -> finishCreate(uri, current)
            is Pending.Open -> finishOpen(uri, current)
        }
        return true
    }

    private fun finishCreate(uri: Uri, pending: Pending.Create) {
        val resolver = activity?.contentResolver
        if (resolver == null) {
            pending.result.error("activity_unavailable", "Activity 已销毁，无法写入文件", null)
            return
        }
        try {
            resolver.openOutputStream(uri, "wt")?.use { output ->
                output.write(pending.bytes)
                output.flush()
            } ?: run {
                pending.result.error("open_failed", "无法打开目标文件写入通道", null)
                return
            }
            pending.result.success(
                mapOf(
                    "uri" to uri.toString(),
                    "name" to (displayName(uri) ?: uri.lastPathSegment ?: "backup.json"),
                    "bytes" to pending.bytes.size,
                ),
            )
        } catch (error: Throwable) {
            pending.result.error("write_failed", "写入备份文件失败：${error.javaClass.simpleName}", null)
        }
    }

    private fun finishOpen(uri: Uri, pending: Pending.Open) {
        val host = activity
        val resolver = host?.contentResolver
        if (host == null || resolver == null) {
            pending.result.error("activity_unavailable", "Activity 已销毁，无法读取文件", null)
            return
        }
        val displayName = displayName(uri) ?: uri.lastPathSegment ?: "import.bin"
        val directory = File(host.cacheDir, "imports")
        if (!directory.exists() && !directory.mkdirs()) {
            pending.result.error("io_failed", "无法创建导入缓存目录", null)
            return
        }
        val target = File(directory, "${System.currentTimeMillis()}-${sanitize(displayName)}")
        var copied = 0L
        try {
            resolver.openInputStream(uri)?.use { input ->
                target.outputStream().use { output ->
                    val buffer = ByteArray(COPY_BUFFER)
                    while (true) {
                        val read = input.read(buffer)
                        if (read < 0) break
                        copied += read
                        if (copied > MAX_IMPORT_BYTES) {
                            throw IOException("文件超过 ${MAX_IMPORT_BYTES / (1024 * 1024)}MB 上限")
                        }
                        output.write(buffer, 0, read)
                    }
                    output.flush()
                }
            } ?: run {
                pending.result.error("open_failed", "无法读取所选文件", null)
                return
            }
            pending.result.success(
                mapOf(
                    "path" to target.absolutePath,
                    "name" to displayName,
                    "bytes" to copied,
                ),
            )
        } catch (error: Throwable) {
            target.delete()
            val tooLarge = error.message?.contains("上限") == true
            pending.result.error(
                if (tooLarge) "file_too_large" else "read_failed",
                "导入文件失败：${error.message ?: error.javaClass.simpleName}",
                null,
            )
        }
    }

    private fun displayName(uri: Uri): String? =
        try {
            activity?.contentResolver?.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)
                ?.use { cursor ->
                    if (cursor.moveToFirst()) {
                        val index = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                        if (index >= 0) cursor.getString(index) else null
                    } else {
                        null
                    }
                }
        } catch (error: Throwable) {
            null
        }

    private fun sanitize(name: String): String {
        val cleaned = name.replace(Regex("[\\\\/:*?\"<>|\\r\\n\\t]"), "_").trim()
        return if (cleaned.isEmpty()) "import.bin" else cleaned.take(120)
    }
}
