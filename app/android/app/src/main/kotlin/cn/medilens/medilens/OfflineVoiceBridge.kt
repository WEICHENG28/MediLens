package cn.medilens.medilens

import android.Manifest
import android.app.Activity
import android.content.pm.PackageManager
import android.media.AudioFormat
import android.media.AudioRecord
import android.media.MediaRecorder
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.EventChannel
import org.json.JSONObject
import org.vosk.LibVosk
import org.vosk.LogLevel
import org.vosk.Model
import org.vosk.Recognizer
import java.io.File
import java.security.MessageDigest
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean
import java.util.zip.ZipInputStream

/** Offline-only microphone recognition. No audio files, network requests or transcript logs. */
class OfflineVoiceBridge(private val activity: Activity, engine: FlutterEngine) {
    private val channel = MethodChannel(engine.dartExecutor.binaryMessenger, "cn.medilens.medilens/offline_voice")
    private val events = EventChannel(engine.dartExecutor.binaryMessenger, "cn.medilens.medilens/voice_events")
    private var sink: EventChannel.EventSink? = null
    private val worker = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())
    private var model: Model? = null
    @Volatile private var active: Session? = null
    @Volatile private var closed = false
    private class Session(val result: MethodChannel.Result) {
        val stopped = AtomicBoolean(false)
        val cancelled = AtomicBoolean(false)
        @Volatile var recorder: AudioRecord? = null
    }
    init {
        events.setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, eventSink: EventChannel.EventSink?) { sink = eventSink }
            override fun onCancel(arguments: Any?) { sink = null }
        })
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "status" -> result.success(mapOf("available" to true, "permission" to allowed(), "ready" to (model != null), "foreground" to activity.hasWindowFocus(), "recording" to (active?.recorder?.recordingState == AudioRecord.RECORDSTATE_RECORDING), "busy" to (active != null)))
                "permission" -> {
                    if (allowed()) result.success(true)
                    else {
                        if (activity.hasWindowFocus()) activity.requestPermissions(arrayOf(Manifest.permission.RECORD_AUDIO), REQUEST)
                        // Never hold a Flutter reply across the system permission dialog.
                        // A new explicit listen action rechecks permission after returning.
                        result.success(false)
                    }
                }
                "listen", "listenRealtime" -> {
                    if (!allowed()) result.error("permission", "请先允许麦克风权限", null)
                    else if (!activity.hasWindowFocus()) result.error("foreground", "请在APP前台手动开始", null)
                    else begin(result, null, call.method == "listenRealtime")
                }
                "stop" -> { stop(false); result.success(null) }
                "cancel" -> { stop(true); result.success(null) }
                // Same decoder, fixed PCM16/16kHz mono. Used by synthetic device verification.
                "recognizePcm" -> {
                    val pcm = call.argument<ByteArray>("pcm")
                    if (pcm == null || pcm.isEmpty() || pcm.size > 960000 || pcm.size % 2 != 0) result.error("audio", "音频格式不支持", null)
                    else begin(result, pcm, call.argument<Boolean>("endpoint") == true)
                }
                else -> result.notImplemented()
            }
        }
    }
    private fun allowed() = activity.checkSelfPermission(Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED
    private fun loadModel(): Model {
        model?.let { return it }
        LibVosk.setLogLevel(LogLevel.WARNINGS)
        val parent = File(activity.noBackupFilesDir, "voice-cn-0.22-v1")
        val folder = File(parent, "vosk-model-small-cn-0.22")
        val ready = File(parent, "ready")
        if (!ready.exists()) {
            parent.deleteRecursively(); parent.mkdirs()
            try {
                val asset = "flutter_assets/assets/asr/vosk-model-small-cn-0.22.zip"
                val digest = MessageDigest.getInstance("SHA-256")
                activity.assets.open(asset).use { stream ->
                    java.security.DigestInputStream(stream, digest).use { input ->
                        ZipInputStream(input).use { zip ->
                            while (true) {
                                val entry = zip.nextEntry ?: break
                                val target = File(parent, entry.name)
                                require(target.canonicalPath.startsWith(parent.canonicalPath + File.separator))
                                if (entry.isDirectory) target.mkdirs()
                                else { target.parentFile?.mkdirs(); target.outputStream().use { zip.copyTo(it) } }
                                zip.closeEntry()
                            }
                            // Drain archive footer so the checksum covers the complete asset.
                            val buffer = ByteArray(8192)
                            while (input.read(buffer) != -1) {}
                        }
                    }
                }
                require(digest.digest().joinToString("") { "%02x".format(it) } == MODEL_HASH)
                require(File(folder, "am/final.mdl").isFile && File(folder, "conf/model.conf").isFile)
                ready.writeText(MODEL_HASH)
            } catch (e: Exception) { parent.deleteRecursively(); throw e }
        }
        return Model(folder.absolutePath).also { model = it }
    }
    private fun text(json: String) = JSONObject(json).optString("text", "").trim()
    private fun begin(result: MethodChannel.Result, pcm: ByteArray?, endpoint: Boolean = false) {
        if (active != null) { result.error("busy", "识别尚未结束，请稍后再试", null); return }
        val session = Session(result); active = session
        worker.execute {
            var answer = ""; var failure = false
            try {
                val loaded = loadModel()
                if (!session.cancelled.get() && !session.stopped.get()) {
                    Recognizer(loaded, 16000f).use { recognizer ->
                        val pieces = mutableListOf<String>()
                        if (endpoint) recognizer.setEndpointerDelays(8f, 0.9f, 30f)
                        var lastPartial = ""
                        var lastEvent = 0L
                        fun consume(block: ByteArray, count: Int): Boolean {
                            if (recognizer.acceptWaveForm(block, count)) {
                                val resultText = text(recognizer.result)
                                pieces.add(resultText)
                                if (endpoint && resultText.isNotEmpty()) return true
                            }
                            if (endpoint) {
                                val partial = JSONObject(recognizer.partialResult).optString("partial", "").trim()
                                val now = SystemClock.elapsedRealtime()
                                if (partial != lastPartial && now - lastEvent >= 150) {
                                    lastPartial = partial; lastEvent = now
                                    main.post { if (!closed && active === session && !session.cancelled.get()) sink?.success(partial) }
                                }
                            }
                            return false
                        }
                        if (pcm != null) {
                            var offset = 0
                            while (offset < pcm.size && !session.cancelled.get()) {
                                val end = minOf(offset + 6400, pcm.size)
                                val block = pcm.copyOfRange(offset, end)
                                if (consume(block, block.size)) break
                                offset = end
                            }
                        } else {
                            val size = maxOf(6400, AudioRecord.getMinBufferSize(16000, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT))
                            val recorder = AudioRecord(MediaRecorder.AudioSource.VOICE_RECOGNITION, 16000, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT, size)
                            session.recorder = recorder
                            try {
                                check(recorder.state == AudioRecord.STATE_INITIALIZED)
                                if (!session.cancelled.get() && !session.stopped.get()) {
                                    recorder.startRecording()
                                    val started = SystemClock.elapsedRealtime()
                                    val limit = started + 30000
                                    val buffer = ByteArray(3200)
                                    while (!session.stopped.get() && !session.cancelled.get() && SystemClock.elapsedRealtime() < limit) {
                                        val count = try { recorder.read(buffer, 0, buffer.size, AudioRecord.READ_NON_BLOCKING) } catch (e: Exception) {
                                            if (session.stopped.get() || session.cancelled.get()) break else throw e
                                        }
                                        if (count > 0) { if (consume(buffer, count)) break }
                                        else if (count == 0) Thread.sleep(15)
                                        else if (!session.stopped.get() && !session.cancelled.get()) error("microphone")
                                        if (endpoint && SystemClock.elapsedRealtime() - started >= 8000 && lastPartial.isEmpty() && pieces.all { it.isEmpty() }) break
                                    }
                                }
                            } finally { try { recorder.stop() } catch (_: Exception) {}; recorder.release(); session.recorder = null }
                        }
                        pieces.add(text(recognizer.finalResult))
                        answer = pieces.filter { it.isNotEmpty() }.joinToString(" ")
                            .replace(Regex("(?<=[\\u4e00-\\u9fff])\\s+(?=[\\u4e00-\\u9fff])"), "")
                    }
                }
            } catch (_: Exception) { failure = !session.cancelled.get() && !session.stopped.get() }
            main.post {
                if (active === session) active = null
                if (closed) return@post
                if (session.cancelled.get()) result.success("")
                else if (failure) result.error("unavailable", "本机语音识别未完成，请重试或改用文字", null)
                else result.success(answer)
            }
        }
    }
    fun stop(cancel: Boolean = true) {
        val session = active ?: return
        if (cancel) session.cancelled.set(true)
        session.stopped.set(true)
        // Flags only. The worker owns AudioRecord.stop/release; never block the UI thread.
    }
    fun close() {
        if (closed) return
        closed = true
        stop(true)
        channel.setMethodCallHandler(null)
        events.setStreamHandler(null); sink = null
        worker.execute { model?.close(); model = null }; worker.shutdown()
    }
    companion object {
        const val REQUEST = 3821
        private const val MODEL_HASH = "3af8b0e7e0f835ae9d414ce5df580237a3cfb08d586c9fbbb0f7ff29ad5b14ba"
    }
}
