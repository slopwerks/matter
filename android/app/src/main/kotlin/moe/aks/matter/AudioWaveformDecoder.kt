package moe.aks.matter

import android.content.Context
import android.media.AudioFormat
import android.media.MediaCodec
import android.media.MediaExtractor
import android.media.MediaFormat
import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.nio.ByteOrder
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.math.min
import kotlin.math.sqrt

/** A bounded PCM envelope extractor; it never owns a player or reads a whole file. */
internal object AudioWaveformDecoder {
    private val executor = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())
    private val jobs = ConcurrentHashMap<String, AtomicBoolean>()

    fun handle(
        call: MethodCall,
        context: Context,
        result: MethodChannel.Result,
    ) {
        val id = call.argument<String>("jobId")
        if (call.method == "cancelWaveform") {
            jobs[id]?.set(true)
            result.success(null)
            return
        }
        try {
            require(id != null && id.length <= 80 && jobs.size < 8) { "Invalid waveform job" }
            val input = File(call.argument<String>("path") ?: error("Missing path")).canonicalFile
            val roots = listOf("matter_decrypted_media", "matter_audio_cache").map { File(context.cacheDir, it).canonicalFile }
            require(input.isFile && roots.any { input.toPath().startsWith(it.toPath()) }) { "Expected prepared media file" }
            val samples = call.argument<Number>("sampleCount")?.toInt() ?: 160
            require(samples in 1..512)
            val cancelled = AtomicBoolean(false)
            require(jobs.putIfAbsent(id, cancelled) == null) { "Duplicate waveform job" }
            executor.execute {
                val outcome = runCatching { decode(input, samples, cancelled) }
                jobs.remove(id, cancelled)
                main.post {
                    outcome.fold(
                        onSuccess = { result.success(it) },
                        onFailure = { result.error("waveform_failed", "无法提取此音频的波形", null) },
                    )
                }
            }
        } catch (error: Exception) {
            result.error("waveform_invalid", "无法读取音频波形来源", null)
        }
    }

    private fun decode(
        file: File,
        samples: Int,
        cancelled: AtomicBoolean,
    ): List<Double> {
        val deadline = System.nanoTime() + 45_000_000_000L

        fun checkRunning() {
            check(!cancelled.get() && System.nanoTime() < deadline) { "Waveform cancelled or timed out" }
        }
        val extractor = MediaExtractor()
        var codec: MediaCodec? = null
        try {
            checkRunning()
            extractor.setDataSource(file.path)
            val track =
                (0 until extractor.trackCount).firstOrNull {
                    extractor.getTrackFormat(it).getString(MediaFormat.KEY_MIME)?.startsWith("audio/") == true
                } ?: error("No audio track")
            val format = extractor.getTrackFormat(track)
            val duration = format.getLong(MediaFormat.KEY_DURATION)
            require(duration > 0)
            extractor.selectTrack(track)
            val mime = format.getString(MediaFormat.KEY_MIME) ?: error("No codec")
            val decoder = MediaCodec.createDecoderByType(mime)
            codec = decoder
            decoder.configure(format, null, null, 0)
            decoder.start()
            var rate = format.getInteger(MediaFormat.KEY_SAMPLE_RATE)
            var channels = format.getInteger(MediaFormat.KEY_CHANNEL_COUNT)
            var encoding = AudioFormat.ENCODING_PCM_16BIT
            var inputEnded = false
            val info = MediaCodec.BufferInfo()
            val energy = DoubleArray(samples)
            val counts = LongArray(samples)
            var framesRead = 0L
            while (true) {
                checkRunning()
                if (!inputEnded) {
                    val index = decoder.dequeueInputBuffer(10_000)
                    if (index >= 0) {
                        val buffer = decoder.getInputBuffer(index) ?: error("No input buffer")
                        val size = extractor.readSampleData(buffer, 0)
                        if (size < 0) {
                            decoder.queueInputBuffer(index, 0, 0, 0, MediaCodec.BUFFER_FLAG_END_OF_STREAM)
                            inputEnded = true
                        } else {
                            decoder.queueInputBuffer(index, 0, size, extractor.sampleTime, 0)
                            extractor.advance()
                        }
                    }
                }
                val index = decoder.dequeueOutputBuffer(info, 10_000)
                if (index == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED) {
                    val output = decoder.outputFormat
                    rate = output.getInteger(MediaFormat.KEY_SAMPLE_RATE)
                    channels = output.getInteger(MediaFormat.KEY_CHANNEL_COUNT)
                    if (output.containsKey(MediaFormat.KEY_PCM_ENCODING)) encoding = output.getInteger(MediaFormat.KEY_PCM_ENCODING)
                } else if (index >= 0) {
                    try {
                        require(rate > 0 && channels > 0)
                        val output = decoder.getOutputBuffer(index)?.order(ByteOrder.LITTLE_ENDIAN)
                        if (output != null && info.size > 0) {
                            output.position(info.offset)
                            output.limit(info.offset + info.size)
                            val bytesPerSample =
                                when (encoding) {
                                    AudioFormat.ENCODING_PCM_16BIT -> 2
                                    AudioFormat.ENCODING_PCM_FLOAT -> 4
                                    else -> error("Unsupported PCM format")
                                }
                            var frame = 0L
                            while (output.remaining() >= bytesPerSample * channels) {
                                val time = info.presentationTimeUs.coerceAtLeast(0) + frame * 1_000_000L / rate
                                val bucket = min(samples - 1, (time.toDouble() / duration * samples).toInt().coerceAtLeast(0))
                                repeat(channels) {
                                    val value = if (bytesPerSample == 2) output.short.toDouble() / 32768 else output.float.toDouble()
                                    if (value.isFinite()) {
                                        energy[bucket] += value * value
                                        counts[bucket]++
                                    }
                                }
                                frame++
                                framesRead++
                            }
                        }
                    } finally {
                        decoder.releaseOutputBuffer(index, false)
                    }
                    if (info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) break
                }
            }
            checkRunning()
            require(framesRead > 0)
            val rms = DoubleArray(samples) { if (counts[it] == 0L) 0.0 else sqrt(energy[it] / counts[it]) }
            val maximum = rms.maxOrNull() ?: 0.0
            return rms.map { if (maximum == 0.0) 0.0 else (it / maximum).coerceIn(0.0, 1.0) }
        } finally {
            runCatching { codec?.stop() }
            codec?.release()
            extractor.release()
        }
    }
}
