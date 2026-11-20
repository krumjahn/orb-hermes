import com.keith.orbhermes.UploadGuard
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger

/**
 * The orb must never go deaf.
 *
 * A request that is written to a socket which has stopped reading can hang
 * for ever - the write has no timeout of its own. When the upload thread
 * was stuck like that, every clip after it was dropped and the orb stopped
 * answering until the app was started again by hand.
 *
 * These checks pin down that a stuck upload is given up on, that the count
 * of the uploads in flight comes down exactly once however the upload ends,
 * and that a fresh worker takes the next clip.
 */
private var failures = 0

private fun check(label: String, ok: Boolean, detail: String = "") {
    println("  ${if (ok) "PASS" else "FAIL"}  $label" + if (detail.isNotEmpty()) "  $detail" else "")
    if (!ok) failures++
}

private fun waitFor(latch: CountDownLatch, millis: Long): Boolean =
    latch.await(millis, TimeUnit.MILLISECONDS)

fun main() {
    println("UPLOAD GUARD")

    // 1. a normal upload runs, and the count comes down once
    run {
        val guard = UploadGuard(deadlineMs = 5_000L, poolSize = 2)
        val ran = CountDownLatch(1)
        val done = AtomicInteger(0)
        guard.submit(work = { ran.countDown() }, onDone = { done.incrementAndGet() })
        check("the work runs", waitFor(ran, 3_000))
        Thread.sleep(200)
        check("the count comes down once", done.get() == 1, "count=${done.get()}")
        guard.shutdown()
    }

    // 2. a work that throws still comes down exactly once
    run {
        val guard = UploadGuard(deadlineMs = 5_000L, poolSize = 2)
        val done = AtomicInteger(0)
        guard.submit(
            work = { throw IllegalStateException("the bridge is gone") },
            onDone = { done.incrementAndGet() },
        )
        Thread.sleep(400)
        check("a failed upload comes down once", done.get() == 1, "count=${done.get()}")
        guard.shutdown()
    }

    // 3. a work that hangs for ever is given up on, and the count still
    //    comes down - otherwise every later clip is dropped as a backlog
    run {
        val guard = UploadGuard(deadlineMs = 600L, poolSize = 2)
        val gaveUp = AtomicInteger(0)
        val done = AtomicInteger(0)
        val started = CountDownLatch(1)
        val stuck = UploadGuard(
            deadlineMs = 600L,
            poolSize = 2,
            onGiveUp = { gaveUp.incrementAndGet() },
        )
        stuck.submit(
            work = {
                started.countDown()
                Thread.sleep(600_000L) // never comes back
            },
            onDone = { done.incrementAndGet() },
        )
        check("the stuck work starts", waitFor(started, 2_000))
        Thread.sleep(1_500)
        check("the stuck upload is given up on", gaveUp.get() == 1, "gaveUp=${gaveUp.get()}")
        check("the count comes down once even when it is stuck", done.get() == 1, "count=${done.get()}")
        stuck.shutdown()
        guard.shutdown()
    }

    // 4. after a stuck upload, a fresh worker still takes the next clip
    run {
        val gaveUp = AtomicInteger(0)
        val guard = UploadGuard(
            deadlineMs = 500L,
            poolSize = 2,
            onGiveUp = { gaveUp.incrementAndGet() },
        )
        guard.submit(work = { Thread.sleep(600_000L) }, onDone = {})
        Thread.sleep(1_200)
        check("the guard gave up on the stuck one", gaveUp.get() >= 1, "gaveUp=${gaveUp.get()}")

        val ran = CountDownLatch(1)
        guard.submit(work = { ran.countDown() }, onDone = {})
        check("a fresh worker still takes the next clip", waitFor(ran, 3_000))
        guard.shutdown()
    }

    println()
    if (failures > 0) {
        println("UPLOAD GUARD: $failures FAILURE(S)")
        kotlin.system.exitProcess(1)
    }
    println("ALL UPLOAD GUARD TESTS PASS")
}
