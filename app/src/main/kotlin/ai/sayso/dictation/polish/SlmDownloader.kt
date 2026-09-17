package ai.sayso.dictation.polish

import ai.sayso.dictation.models.DownloadState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.flow.flowOn
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import okhttp3.OkHttpClient
import okhttp3.Request
import java.io.File
import java.io.IOException
import java.security.MessageDigest
import java.util.concurrent.TimeUnit

private const val BUFFER_BYTES = 64 * 1024
private const val PROGRESS_STEPS = 200

private val downloadClient: OkHttpClient = OkHttpClient.Builder()
    .connectTimeout(15, TimeUnit.SECONDS)
    .readTimeout(120, TimeUnit.SECONDS)
    .build()

/**
 * Downloads on-device Small Language Model (SLM) weights into the local storage folder.
 */
class SlmDownloader(private val client: OkHttpClient = downloadClient) {

    fun download(model: SlmModelInfo, storageDir: File): Flow<DownloadState> = flow {
        val target = File(storageDir, model.fileName)
        val staging = File(storageDir, "${model.fileName}.tmp")
        try {
            storageDir.mkdirs()
            staging.delete()

            emit(DownloadState.Downloading(0f))
            val sha = MessageDigest.getInstance("SHA-256")
            val request = Request.Builder().url(model.downloadUrl).build()

            client.newCall(request).execute().use { response ->
                if (!response.isSuccessful) {
                    throw IOException("Download failed with HTTP ${response.code}")
                }
                val body = response.body ?: throw IOException("Empty response body")
                val totalBytes = body.contentLength().takeIf { it > 0 } ?: (model.quantizedSizeMb * 1_000_000L)
                val maxBytes = model.quantizedSizeMb * 2L * 1_000_000

                val source = body.byteStream()
                staging.outputStream().use { sink ->
                    val buffer = ByteArray(BUFFER_BYTES)
                    var read = source.read(buffer)
                    var written = 0L
                    var lastStep = -1
                    while (read >= 0) {
                        currentCoroutineContext().ensureActive()
                        sink.write(buffer, 0, read)
                        sha.update(buffer, 0, read)
                        written += read
                        if (written > maxBytes) throw IOException("Download exceeded the expected size")
                        val step = (written * PROGRESS_STEPS / totalBytes).toInt()
                        if (step != lastStep) {
                            lastStep = step
                            emit(DownloadState.Downloading((written.toFloat() / totalBytes).coerceIn(0f, 1f)))
                        }
                        read = source.read(buffer)
                    }
                }
            }

            if (model.sha256.isNotBlank()) {
                val digest = sha.digest().joinToString("") { "%02x".format(it) }
                if (!digest.equals(model.sha256, ignoreCase = true)) {
                    throw IOException("Downloaded SLM weights did not match checksum")
                }
            }

            target.delete()
            if (!staging.renameTo(target)) {
                throw IOException("Could not install ${model.fileName}")
            }
            emit(DownloadState.Done)
        } catch (e: IOException) {
            emit(DownloadState.Error(e.message ?: "Download failed"))
        } finally {
            staging.delete()
        }
    }.flowOn(Dispatchers.IO)

    fun isInstalled(model: SlmModelInfo, storageDir: File): Boolean {
        val file = File(storageDir, model.fileName)
        return file.exists() && file.length() > 10_000_000L
    }

    fun delete(model: SlmModelInfo, storageDir: File): Boolean =
        File(storageDir, model.fileName).delete()
}

/**
 * Process-wide manager for in-flight SLM downloads.
 */
class SlmDownloads(private val scope: CoroutineScope) {
    private val downloader = SlmDownloader()

    var activeModelId by mutableStateOf<String?>(null)
        private set
    var state by mutableStateOf<DownloadState?>(null)
        private set

    val busy: Boolean
        get() = state is DownloadState.Downloading

    fun start(model: SlmModelInfo, storageDir: File, onFinished: () -> Unit) {
        if (busy) return
        activeModelId = model.id
        state = DownloadState.Downloading(0f)
        scope.launch {
            downloader.download(model, storageDir).collect { state = it }
            onFinished()
        }
    }

    fun isInstalled(model: SlmModelInfo, storageDir: File): Boolean =
        downloader.isInstalled(model, storageDir)

    fun delete(model: SlmModelInfo, storageDir: File, onDone: () -> Unit) {
        scope.launch {
            withContext(Dispatchers.IO) {
                downloader.delete(model, storageDir)
            }
            if (activeModelId == model.id) {
                activeModelId = null
                state = null
            }
            onDone()
        }
    }
}
