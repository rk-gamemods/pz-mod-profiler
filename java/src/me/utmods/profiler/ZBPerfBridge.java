package me.utmods.profiler;

import me.zed_0xff.zombie_buddy.Exposer;
import java.lang.management.GarbageCollectorMXBean;
import java.lang.management.ManagementFactory;
import java.util.List;

/**
 * Java-side performance bridge exposed to Lua via ZombieBuddy.
 * Provides heap memory and GC stats that are unavailable in single-player
 * through PZ's getPerformanceLocal() API.
 *
 * Lua usage:
 *   if ZBPerfBridge then
 *       ZBPerfBridge.snapshotGc()
 *       local used = ZBPerfBridge.getHeapUsedMb()
 *       local gcCount = ZBPerfBridge.getGcDeltaCount()
 *       local gcMs = ZBPerfBridge.getGcDeltaTimeMs()
 *   end
 */
@Exposer.LuaClass
public class ZBPerfBridge {

    private static final Runtime RT = Runtime.getRuntime();

    // --- GC snapshot state (main-thread only, no sync needed) ---
    private static long prevGcCount = 0;
    private static long prevGcTimeMs = 0;
    private static long deltaGcCount = 0;
    private static long deltaGcTimeMs = 0;

    // ================================================================
    //  Heap — direct from Runtime, works in single-player
    // ================================================================

    /** Free heap memory in MB. */
    public static double getHeapFreeMb() {
        return RT.freeMemory() / (1024.0 * 1024.0);
    }

    /** Currently allocated heap in MB (may grow up to max). */
    public static double getHeapTotalMb() {
        return RT.totalMemory() / (1024.0 * 1024.0);
    }

    /** Maximum heap the JVM will attempt to use, in MB. */
    public static double getHeapMaxMb() {
        return RT.maxMemory() / (1024.0 * 1024.0);
    }

    /** Heap currently in use (total - free), in MB. */
    public static double getHeapUsedMb() {
        return (RT.totalMemory() - RT.freeMemory()) / (1024.0 * 1024.0);
    }

    // ================================================================
    //  GC — from JMX GarbageCollectorMXBeans
    // ================================================================

    /** Total GC collections since JVM start, across all collectors. */
    public static long getGcTotalCount() {
        long total = 0;
        for (GarbageCollectorMXBean bean : ManagementFactory.getGarbageCollectorMXBeans()) {
            long c = bean.getCollectionCount();
            if (c >= 0) total += c;
        }
        return total;
    }

    /** Total GC pause time in ms since JVM start, across all collectors. */
    public static long getGcTotalTimeMs() {
        long total = 0;
        for (GarbageCollectorMXBean bean : ManagementFactory.getGarbageCollectorMXBeans()) {
            long t = bean.getCollectionTime();
            if (t >= 0) total += t;
        }
        return total;
    }

    /**
     * Capture current GC counters and compute delta since previous call.
     * Call once per profiler interval, then read deltas with
     * getGcDeltaCount() / getGcDeltaTimeMs().
     */
    public static void snapshotGc() {
        long nowCount = getGcTotalCount();
        long nowTime = getGcTotalTimeMs();
        deltaGcCount = nowCount - prevGcCount;
        deltaGcTimeMs = nowTime - prevGcTimeMs;
        prevGcCount = nowCount;
        prevGcTimeMs = nowTime;
    }

    /** GC collections since last snapshotGc() call. */
    public static long getGcDeltaCount() {
        return deltaGcCount;
    }

    /** GC pause time in ms since last snapshotGc() call. */
    public static long getGcDeltaTimeMs() {
        return deltaGcTimeMs;
    }

    // ================================================================
    //  Availability check
    // ================================================================

    /** Always true — lets Lua confirm the bridge is loaded. */
    public static boolean isAvailable() {
        return true;
    }
}
