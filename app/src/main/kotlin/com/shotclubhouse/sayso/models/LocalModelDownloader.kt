package com.shotclubhouse.sayso.models

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.flow.flowOn
import okhttp3.OkHttpClient
import okhttp3.Request
import org.apache.commons.compress.archivers.tar.TarArchiveInputStream
import org.apache.commons.compress.compressors.bzip2.BZip2CompressorInputStream
import java.io.BufferedInputStream
import java.io.File
import java.io.IOException
import java.security.MessageDigest
import java.util.concurrent.TimeUnit

private const val BUFFER_BYTES = 64 * 1024

/** Half a percent, so a 487 MB archive reports 200 times rather than 60,000. */
private const val PROGRESS_STEPS = 200

/**
 * Model archives are served from a release URL that redirects to object storage, so this
 * client follows redirects, unlike the provider client that carries API keys. A 500 MB
 * transfer has no useful overall deadline, only a per-read one.
 */
private val downloadClient: OkHttpClient = OkHttpClient.Builder()
    .connectTimeout(15, TimeUnit.SECONDS)
    .readTimeout(120, TimeUnit.SECONDS)
    .build()

sealed class DownloadState {
    data class Downloading(val progress: Float) : DownloadState()
    data object Extracting : DownloadState()
    data object Done : DownloadState()
    data class Error(val message: String) : DownloadState()
}

/**
 * Fetches a model archive and unpacks it into the models directory. The archive
 * lands in the cache first so a failure part way through never leaves a usable
 * looking but incomplete model folder behind.
 */
class LocalModelDownloader(private val client: OkHttpClient = downloadClient) {

    fun download(model: LocalModel, modelsDir: File, cacheDir: File): Flow<DownloadState> = flow {
        val archive = File(cacheDir, "${model.dirName}.tar.bz2")
        val target = File(modelsDir, model.dirName)
        // Unpacked beside the installed copy, never over it: a download that fails, or that the
        // user walks away from, leaves the model they already had working.
        val staging = File(modelsDir, "${model.dirName}.tmp")
        try {
            cacheDir.mkdirs()
            modelsDir.mkdirs()
            staging.deleteRecursively()

            val digest = fetch(model, archive) { emit(DownloadState.Downloading(it)) }
            if (model.sha256.isNotBlank() && !digest.equals(model.sha256, ignoreCase = true)) {
                throw IOException("Downloaded archive did not match its checksum")
            }

            emit(DownloadState.Extracting)
            // bzip2 on int8 weights gains little, so three times the archive is generous.
            extract(archive, staging, maxBytes = model.sizeMb * 3L * 1_000_000)
            val unpacked = File(staging, model.dirName)
            if (!isInstalled(model, staging)) throw IOException("Archive did not contain ${model.dirName}")

            target.deleteRecursively()
            if (!unpacked.renameTo(target)) throw IOException("Could not install ${model.dirName}")

            emit(DownloadState.Done)
        } catch (e: IOException) {
            emit(DownloadState.Error(e.message ?: "Download failed"))
        } finally {
            // Also the cancellation path: a cancelled collector unwinds through here.
            staging.deleteRecursively()
            archive.delete()
        }
    }.flowOn(Dispatchers.IO)

    fun isInstalled(model: LocalModel, modelsDir: File): Boolean {
        val dir = File(modelsDir, model.dirName)
        return dir.isDirectory && dir.listFiles().orEmpty().any { it.name.endsWith(".onnx") }
    }

    fun delete(model: LocalModel, modelsDir: File): Boolean =
        File(modelsDir, model.dirName).deleteRecursively()

    /** Streams the archive to disk and returns its SHA-256, hashed as it goes. */
    private suspend inline fun fetch(model: LocalModel, archive: File, onProgress: (Float) -> Unit): String {
        val sha = MessageDigest.getInstance("SHA-256")
        val request = Request.Builder().url(model.url).build()
        client.newCall(request).execute().use { response ->
            if (!response.isSuccessful) throw IOException("Download failed with HTTP ${response.code}")
            val body = response.body ?: throw IOException("Empty response body")
            val total = body.contentLength().takeIf { it > 0 } ?: (model.sizeMb * 1_000_000L)

            val source = body.byteStream()
            archive.outputStream().use { sink ->
                val buffer = ByteArray(BUFFER_BYTES)
                var read = source.read(buffer)
                var written = 0L
                var lastStep = -1
                while (read >= 0) {
                    currentCoroutineContext().ensureActive()
                    sink.write(buffer, 0, read)
                    sha.update(buffer, 0, read)
                    written += read
                    val step = (written * PROGRESS_STEPS / total).toInt()
                    if (step != lastStep) {
                        lastStep = step
                        onProgress((written.toFloat() / total).coerceIn(0f, 1f))
                    }
                    read = source.read(buffer)
                }
            }
        }
        return sha.digest().joinToString("") { "%02x".format(it) }
    }
}

/**
 * Unpacks a tar.bz2 under [destDir]. Entry names come from an archive we did not
 * build, so every resolved path is checked to stay inside the destination, links are
 * refused outright, and no more than [maxBytes] is ever written: a small archive that
 * expands without end fills the phone otherwise.
 */
internal suspend fun extract(archive: File, destDir: File, maxBytes: Long = Long.MAX_VALUE) {
    val root = destDir.canonicalFile
    root.mkdirs()
    val prefix = root.path + File.separator
    var budget = maxBytes

    TarArchiveInputStream(BZip2CompressorInputStream(BufferedInputStream(archive.inputStream()))).use { tar ->
        var entry = tar.nextEntry
        while (entry != null) {
            // Half a gigabyte of entries: without this, a cancelled download keeps unpacking.
            currentCoroutineContext().ensureActive()
            if (entry.isSymbolicLink || entry.isLink) {
                throw IOException("Refusing link entry ${entry.name}")
            }
            val out = File(root, entry.name).canonicalFile
            // Archives built with "tar -cf x.tar ." carry a "./" entry that resolves
            // to the destination itself; that is legitimate, anything above it is not.
            if (out != root && !out.path.startsWith(prefix)) {
                throw IOException("Refusing entry outside the models directory: ${entry.name}")
            }
            if (entry.isDirectory) {
                out.mkdirs()
            } else {
                out.parentFile?.mkdirs()
                out.outputStream().use { sink ->
                    val buffer = ByteArray(BUFFER_BYTES)
                    var read = tar.read(buffer)
                    while (read >= 0) {
                        budget -= read
                        if (budget < 0) throw IOException("Archive is larger than expected for this model")
                        sink.write(buffer, 0, read)
                        read = tar.read(buffer)
                    }
                }
            }
            entry = tar.nextEntry
        }
    }
}
