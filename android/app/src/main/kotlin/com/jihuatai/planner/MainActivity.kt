package com.jihuatai.planner

import android.content.ComponentCallbacks2
import android.os.Bundle
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * 计划台 Android 入口 Activity。
 *
 * 只做引擎装配与「系统内存压力」转发，业务逻辑全部在 Flutter 侧：
 * - 注册三个原生通道插件（安全存储 / 文件选择 / 内存压力）；
 * - 把 `onTrimMemory` / `onLowMemory` 转给 Dart，让数据层执行
 *   `wal_checkpoint(TRUNCATE)` + `PRAGMA shrink_memory`（见 lib/platform/planner_lifecycle.dart）。
 *
 * 生命周期说明（见 docs/android/ARCHITECTURE.md）：
 * - 横竖屏、字体缩放、深色模式切换由 `configChanges` 声明为自处理，
 *   Activity **不会**重建，数据库连接与界面状态都保留；
 * - 退到后台 / 锁屏：Flutter 引擎发送 `AppLifecycleState.inactive/paused`，
 *   Dart 侧做 checkpoint；
 * - 进程被系统回收：SQLite WAL + `synchronous=FULL` 保证已提交事务不丢，
 *   下次冷启动 `PlannerDatabase.open` 自动恢复并做完整性检查；
 * - 低内存：`onTrimMemory` → 释放 SQLite 页缓存，不关闭文件连接（连接由
 *   Repository 持有，关闭会让正在展示的界面直接报错；彻底释放交给进程回收）。
 */
class MainActivity : FlutterActivity() {

    companion object {
        private const val MEMORY_CHANNEL = "com.jihuatai.planner/memory"
        private const val MAX_BUFFERED_EVENTS = 16
    }

    private var memoryChannel: MethodChannel? = null

    /** 尚未被 Dart 侧取走的内存压力事件（Dart 侧在 resumed 时 drain）。 */
    private val bufferedEvents = ArrayDeque<Int>()

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        flutterEngine.plugins.add(SecureStorePlugin())
        flutterEngine.plugins.add(StoragePlugin())

        memoryChannel =
            MethodChannel(flutterEngine.dartExecutor.binaryMessenger, MEMORY_CHANNEL).also { channel ->
                channel.setMethodCallHandler { call, result ->
                    when (call.method) {
                        "drainEvents" -> result.success(drainEvents())
                        else -> result.notImplemented()
                    }
                }
            }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // 不做 window 装饰/导航栏改色：移动 UI 由 Flutter 侧统一控制；
        // 这里保持系统默认，避免与界面布局实现冲突。
    }

    // ---------------------------------------------------------------------
    // 内存压力：Activity 本身就是 ComponentCallbacks2
    // ---------------------------------------------------------------------

    override fun onTrimMemory(level: Int) {
        super.onTrimMemory(level)
        recordMemoryPressure(level)
    }

    override fun onLowMemory() {
        super.onLowMemory()
        recordMemoryPressure(ComponentCallbacks2.TRIM_MEMORY_RUNNING_CRITICAL)
    }

    private fun recordMemoryPressure(level: Int) {
        synchronized(bufferedEvents) {
            if (bufferedEvents.size >= MAX_BUFFERED_EVENTS) {
                bufferedEvents.removeFirst()
            }
            bufferedEvents.addLast(level)
        }
        // 尽量即时通知；Dart 没注册处理器时会静默丢弃，靠 drain 兜底。
        memoryChannel?.invokeMethod("onTrimMemory", level, null)
    }

    private fun drainEvents(): List<Int> =
        synchronized(bufferedEvents) {
            val drained = bufferedEvents.toList()
            bufferedEvents.clear()
            drained
        }

    override fun onDestroy() {
        memoryChannel?.setMethodCallHandler(null)
        memoryChannel = null
        super.onDestroy()
    }
}
