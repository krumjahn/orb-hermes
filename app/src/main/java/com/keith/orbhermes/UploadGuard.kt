package com.keith.orbhermes

import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.TimeoutException
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Runs the orb's uploads so that one stuck request cannot silence the orb.
 *
 * A request that is written to a socket which has stopped reading can hang
 * for ever: the write has no timeout of its own, and the read timeout only
 * covers the answer. When that happened the orb went deaf - every clip
 * after it was dropped as a backlog, and nothing reached the bridge until
 * the app was started again by hand. It happens whenever the bridge or the
 * relay is restarted underneath it.
 *
 * So every upload runs on a small pool with a deadline. A worker that
 * misses the deadline is given up on: the pool is replaced and a fresh
 * worker takes the next clip. The orb keeps hearing the wake word even
 * when the other end is being restarted.
 */
class UploadGuard(
    private val deadlineMs: Long = 75_000L,
    private val poolSize: Int = 2,
    private val onGiveUp: () -> Unit = {},
) {
    private val lock = Any()
    private var pool: ExecutorService = Executors.newFixedThreadPool(poolSize)
    private val watchdog: ExecutorService = Executors.newSingleThreadExecutor()

    /**
     * Runs [work] on a worker.
     *
     * [onDone] is called exactly once, however the work ends: when it
     * finishes, when it throws, and when it is given up on. The caller can
     * count on it to release whatever it was holding - the count of the
     * uploads in flight, for one.
     */
    fun submit(
        work: () -> Unit,
        onDone: () -> Unit,
        deadlineMs: Long = this.deadlineMs,
    ) {
        val current = synchronized(lock) { pool }
        val finished = AtomicBoolean(false)

        val task = current.submit {
            try {
                work()
            } catch (e: Exception) {
                // the caller says what went wrong; an upload must never take
                // the worker down with it
            } finally {
                if (finished.compareAndSet(false, true)) onDone()
            }
        }

        watchdog.execute {
            try {
                task.get(deadlineMs, TimeUnit.MILLISECONDS)
            } catch (e: TimeoutException) {
                // the worker is stuck in a socket that will never answer
                task.cancel(true)
                if (finished.compareAndSet(false, true)) onDone()
                var replaced = false
                synchronized(lock) {
                    if (pool === current) {
                        pool = Executors.newFixedThreadPool(poolSize)
                        replaced = true
                    }
                }
                if (replaced) {
                    current.shutdownNow()
                    onGiveUp()
                }
            } catch (e: Exception) {
                // the work finished or was cancelled - nothing to do
            }
        }
    }

    fun shutdown() {
        synchronized(lock) { pool.shutdownNow() }
        watchdog.shutdownNow()
    }
}
