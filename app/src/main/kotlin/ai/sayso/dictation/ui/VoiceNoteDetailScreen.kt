package ai.sayso.dictation.ui

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.media.MediaPlayer
import android.media.PlaybackParams
import android.net.Uri
import android.widget.Toast
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.AutoFixHigh
import androidx.compose.material.icons.filled.ContentCopy
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.Edit
import androidx.compose.material.icons.filled.Forward5
import androidx.compose.material.icons.filled.Headphones
import androidx.compose.material.icons.filled.Pause
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material.icons.filled.Replay5
import androidx.compose.material.icons.filled.Share
import androidx.compose.material.icons.filled.SmartToy
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FilterChip
import androidx.compose.material3.FilterChipDefaults
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Slider
import androidx.compose.material3.SliderDefaults
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.core.content.FileProvider
import ai.sayso.dictation.AppGraph
import ai.sayso.dictation.core.PolishResult
import ai.sayso.dictation.service.LongRecordingService
import ai.sayso.dictation.voicenotes.VoiceNote
import ai.sayso.dictation.voicenotes.VoiceNoteSegment
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.File
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

enum class SummaryStyle(val label: String, val prompt: String) {
    EXECUTIVE(
        "Executive Summary",
        "You are an executive assistant. Provide a concise, clear executive summary of this transcribed voice note with core takeaways.",
    ),
    KEY_POINTS(
        "Key Highlights",
        "You are an assistant. Extract the key highlights, discussions, and decisions from this transcribed voice note as clean bullet points.",
    ),
    ACTION_ITEMS(
        "Action Items",
        "You are a project manager. Extract all concrete action items, owners, deliverables, and next steps mentioned in this voice note.",
    ),
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun VoiceNoteDetailScreen(
    noteId: String,
    onBack: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val serviceState by LongRecordingService.state.collectAsState()

    var note by remember { mutableStateOf<VoiceNote?>(null) }
    var showEditTitleDialog by remember { mutableStateOf(false) }
    var editedTitleText by remember { mutableStateOf("") }
    var showShareMenu by remember { mutableStateOf(false) }
    var isSummarizing by remember { mutableStateOf(false) }
    var selectedSummaryStyle by remember { mutableStateOf(SummaryStyle.EXECUTIVE) }
    var reloadTrigger by remember { mutableIntStateOf(0) }

    // Audio Playback state
    var mediaPlayer by remember { mutableStateOf<MediaPlayer?>(null) }
    var isPlaying by remember { mutableStateOf(false) }
    var currentPositionMs by remember { mutableLongStateOf(0L) }
    var totalDurationMs by remember { mutableLongStateOf(0L) }
    var playbackSpeed by remember { mutableFloatStateOf(1.0f) }
    var isUserScrubbing by remember { mutableStateOf(false) }
    var scrubPositionMs by remember { mutableLongStateOf(0L) }

    // Load Note
    LaunchedEffect(
        noteId,
        reloadTrigger,
        serviceState.isTranscribing,
        serviceState.transcriptionProgress,
    ) {
        val loaded = withContext(Dispatchers.IO) {
            AppGraph.voiceNotes.get(noteId)
        }
        note = loaded
        if (loaded != null && totalDurationMs == 0L) {
            totalDurationMs = loaded.durationMs
        }
    }

    // Initialize MediaPlayer when note audio file is available
    LaunchedEffect(note?.audioPath) {
        val path = note?.audioPath ?: return@LaunchedEffect
        val audioFile = File(path)
        if (!audioFile.exists()) return@LaunchedEffect

        try {
            mediaPlayer?.runCatching {
                if (isPlaying) stop()
                release()
            }
            mediaPlayer = null

            val player = MediaPlayer().apply {
                setDataSource(audioFile.absolutePath)
                prepare()
                setOnCompletionListener {
                    isPlaying = false
                    currentPositionMs = 0L
                }
            }
            totalDurationMs = player.duration.toLong().coerceAtLeast(note?.durationMs ?: 0L)
            mediaPlayer = player
        } catch (t: Throwable) {
            android.util.Log.e("VoiceNoteDetail", "Failed to prepare MediaPlayer", t)
        }
    }

    // Playback Position Polling Coroutine
    LaunchedEffect(isPlaying, isUserScrubbing) {
        if (isPlaying && !isUserScrubbing) {
            while (isActive && isPlaying) {
                mediaPlayer?.let { player ->
                    if (runCatching { player.isPlaying }.getOrDefault(false)) {
                        currentPositionMs = player.currentPosition.toLong()
                    }
                }
                delay(80)
            }
        }
    }

    // Release MediaPlayer on dispose or when note changes
    DisposableEffect(noteId) {
        onDispose {
            runCatching {
                mediaPlayer?.stop()
                mediaPlayer?.release()
            }
            mediaPlayer = null
            isPlaying = false
            currentPositionMs = 0L
        }
    }

    val currentNote = note

    Scaffold(
        topBar = {
            TopAppBar(
                title = {
                    Text(
                        text = currentNote?.title ?: "Voice Note",
                        style = MaterialTheme.typography.titleMedium,
                        fontWeight = FontWeight.Bold,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                    )
                },
                navigationIcon = {
                    IconButton(onClick = onBack) {
                        Icon(
                            imageVector = Icons.AutoMirrored.Filled.ArrowBack,
                            contentDescription = "Back",
                        )
                    }
                },
                actions = {
                    IconButton(onClick = {
                        editedTitleText = currentNote?.title.orEmpty()
                        showEditTitleDialog = true
                    }) {
                        Icon(Icons.Default.Edit, contentDescription = "Edit title")
                    }
                    IconButton(onClick = { showShareMenu = true }) {
                        Icon(Icons.Default.Share, contentDescription = "Share")
                    }
                },
                colors = TopAppBarDefaults.topAppBarColors(
                    containerColor = MaterialTheme.colorScheme.background,
                ),
            )
        },
        modifier = modifier,
    ) { innerPadding ->
        if (currentNote == null) {
            Box(
                modifier = Modifier
                    .fillMaxSize()
                    .padding(innerPadding),
                contentAlignment = Alignment.Center,
            ) {
                CircularProgressIndicator()
            }
        } else {
            LazyColumn(
                modifier = Modifier
                    .fillMaxSize()
                    .padding(innerPadding)
                    .padding(horizontal = 16.dp),
                verticalArrangement = Arrangement.spacedBy(16.dp),
            ) {
                // Audio Player Card
                item {
                    AudioPlayerCard(
                        isPlaying = isPlaying,
                        currentPositionMs = if (isUserScrubbing) scrubPositionMs else currentPositionMs,
                        totalDurationMs = totalDurationMs,
                        playbackSpeed = playbackSpeed,
                        onPlayPause = {
                            mediaPlayer?.let { player ->
                                if (isPlaying) {
                                    player.pause()
                                    isPlaying = false
                                } else {
                                    applyPlaybackSpeed(player, playbackSpeed)
                                    player.start()
                                    isPlaying = true
                                }
                            }
                        },
                        onScrubStart = {
                            isUserScrubbing = true
                            scrubPositionMs = currentPositionMs
                        },
                        onScrubChange = { newPos ->
                            scrubPositionMs = newPos
                        },
                        onScrubEnd = { finalPos ->
                            isUserScrubbing = false
                            currentPositionMs = finalPos
                            mediaPlayer?.seekTo(finalPos.toInt())
                        },
                        onSkipBackward5 = {
                            mediaPlayer?.let { player ->
                                val target = (currentPositionMs - 5000L).coerceAtLeast(0L)
                                currentPositionMs = target
                                player.seekTo(target.toInt())
                            }
                        },
                        onSkipForward5 = {
                            mediaPlayer?.let { player ->
                                val target = (currentPositionMs + 5000L).coerceAtMost(totalDurationMs)
                                currentPositionMs = target
                                player.seekTo(target.toInt())
                            }
                        },
                        onSpeedChange = { newSpeed ->
                            playbackSpeed = newSpeed
                            mediaPlayer?.let { applyPlaybackSpeed(it, newSpeed) }
                        },
                    )
                }

                // AI Summarization Section
                item {
                    AiSummarizationSection(
                        summary = currentNote.summary,
                        isSummarizing = isSummarizing,
                        hasTranscript = currentNote.fullText.isNotBlank(),
                        selectedStyle = selectedSummaryStyle,
                        onSelectStyle = { selectedSummaryStyle = it },
                        onGenerateSummary = {
                            scope.launch(Dispatchers.IO) {
                                isSummarizing = true
                                generateAiSummary(currentNote, selectedSummaryStyle) { errorMsg ->
                                    scope.launch(Dispatchers.Main) {
                                        Toast.makeText(context, errorMsg, Toast.LENGTH_LONG).show()
                                    }
                                }
                                isSummarizing = false
                                reloadTrigger++
                            }
                        },
                    )
                }

                // Interactive Transcript Header
                item {
                    Row(
                        modifier = Modifier.fillMaxWidth(),
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.SpaceBetween,
                    ) {
                        Column {
                            Text(
                                text = "SYNCHRONIZED TRANSCRIPT",
                                style = MaterialTheme.typography.labelSmall,
                                fontWeight = FontWeight.Bold,
                                color = MaterialTheme.colorScheme.onSurfaceVariant,
                                letterSpacing = 0.8.sp,
                            )
                            val segmentCount = currentNote.segments.size
                            Text(
                                text = if (segmentCount > 0) "$segmentCount timestamped segments" else "Full speech text",
                                style = MaterialTheme.typography.bodySmall,
                                color = MaterialTheme.colorScheme.onSurfaceVariant,
                            )
                        }

                        IconButton(onClick = {
                            copyToClipboard(context, "Transcript", currentNote.fullText)
                            Toast.makeText(context, "Transcript copied", Toast.LENGTH_SHORT).show()
                        }) {
                            Icon(
                                imageVector = Icons.Default.ContentCopy,
                                contentDescription = "Copy transcript",
                                tint = MaterialTheme.colorScheme.primary,
                                modifier = Modifier.size(20.dp),
                            )
                        }
                    }
                }

                // Transcript Segments List
                if (currentNote.segments.isEmpty()) {
                    item {
                        Surface(
                            shape = RoundedCornerShape(16.dp),
                            color = MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.35f),
                            border = BorderStroke(1.dp, MaterialTheme.colorScheme.outlineVariant.copy(alpha = 0.5f)),
                            modifier = Modifier.fillMaxWidth(),
                        ) {
                            Column(
                                modifier = Modifier.padding(16.dp),
                                verticalArrangement = Arrangement.spacedBy(8.dp),
                            ) {
                                if (currentNote.fullText.isNotBlank()) {
                                    Text(
                                        text = currentNote.fullText,
                                        style = MaterialTheme.typography.bodyMedium,
                                        lineHeight = 22.sp,
                                    )
                                } else {
                                    Text(
                                        text = "Audio recorded without transcript. Tap below to transcribe on-device.",
                                        style = MaterialTheme.typography.bodyMedium,
                                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                                    )
                                    Button(
                                        onClick = {
                                            scope.launch(Dispatchers.IO) {
                                                transcribeCurrentNote(currentNote)
                                                reloadTrigger++
                                            }
                                        },
                                        shape = RoundedCornerShape(12.dp),
                                    ) {
                                        Text("Transcribe Note Now")
                                    }
                                }
                            }
                        }
                    }
                } else {
                    itemsIndexed(currentNote.segments, key = { _, seg -> seg.id }) { _, segment ->
                        val isActiveSegment = currentPositionMs in segment.startMs..segment.endMs
                        TranscriptSegmentCard(
                            segment = segment,
                            isActive = isActiveSegment,
                            onSeekToSegment = {
                                currentPositionMs = segment.startMs
                                mediaPlayer?.seekTo(segment.startMs.toInt())
                                if (!isPlaying) {
                                    mediaPlayer?.let { player ->
                                        applyPlaybackSpeed(player, playbackSpeed)
                                        player.start()
                                        isPlaying = true
                                    }
                                }
                            },
                        )
                    }
                }

                item {
                    Spacer(Modifier.height(40.dp))
                }
            }
        }
    }

    // Edit Title Dialog
    if (showEditTitleDialog) {
        AlertDialog(
            onDismissRequest = { showEditTitleDialog = false },
            title = { Text("Edit Title") },
            text = {
                OutlinedTextField(
                    value = editedTitleText,
                    onValueChange = { editedTitleText = it },
                    singleLine = true,
                    modifier = Modifier.fillMaxWidth(),
                )
            },
            confirmButton = {
                Button(onClick = {
                    val newTitle = editedTitleText.trim().ifBlank { "Voice Note" }
                    showEditTitleDialog = false
                    currentNote?.let { n ->
                        scope.launch(Dispatchers.IO) {
                            AppGraph.voiceNotes.update(n.copy(title = newTitle))
                            reloadTrigger++
                        }
                    }
                }) {
                    Text("Save")
                }
            },
            dismissButton = {
                TextButton(onClick = { showEditTitleDialog = false }) {
                    Text("Cancel")
                }
            },
            shape = RoundedCornerShape(18.dp),
        )
    }

    // Share Options Dialog
    if (showShareMenu) {
        AlertDialog(
            onDismissRequest = { showShareMenu = false },
            title = { Text("Share Voice Note") },
            text = {
                Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    TextButton(
                        onClick = {
                            showShareMenu = false
                            currentNote?.let { shareAudioWav(context, it) }
                        },
                        modifier = Modifier.fillMaxWidth(),
                    ) {
                        Row(
                            modifier = Modifier.fillMaxWidth(),
                            verticalAlignment = Alignment.CenterVertically,
                            horizontalArrangement = Arrangement.spacedBy(10.dp),
                        ) {
                            Icon(Icons.Default.Headphones, contentDescription = null)
                            Text("Share Audio File (.WAV)", fontWeight = FontWeight.SemiBold)
                        }
                    }
                    TextButton(
                        onClick = {
                            showShareMenu = false
                            currentNote?.let { shareTranscriptText(context, it) }
                        },
                        modifier = Modifier.fillMaxWidth(),
                    ) {
                        Row(
                            modifier = Modifier.fillMaxWidth(),
                            verticalAlignment = Alignment.CenterVertically,
                            horizontalArrangement = Arrangement.spacedBy(10.dp),
                        ) {
                            Icon(Icons.Default.ContentCopy, contentDescription = null)
                            Text("Share Transcript Text", fontWeight = FontWeight.SemiBold)
                        }
                    }
                }
            },
            confirmButton = {
                TextButton(onClick = { showShareMenu = false }) {
                    Text("Close")
                }
            },
            shape = RoundedCornerShape(18.dp),
        )
    }
}

@Composable
private fun AudioPlayerCard(
    isPlaying: Boolean,
    currentPositionMs: Long,
    totalDurationMs: Long,
    playbackSpeed: Float,
    onPlayPause: () -> Unit,
    onScrubStart: () -> Unit,
    onScrubChange: (Long) -> Unit,
    onScrubEnd: (Long) -> Unit,
    onSkipBackward5: () -> Unit,
    onSkipForward5: () -> Unit,
    onSpeedChange: (Float) -> Unit,
) {
    Card(
        shape = RoundedCornerShape(20.dp),
        colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surface),
        border = BorderStroke(1.dp, MaterialTheme.colorScheme.outlineVariant),
        modifier = Modifier.fillMaxWidth(),
    ) {
        Column(
            modifier = Modifier.padding(18.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            // Scrubber Slider
            val progressFraction = if (totalDurationMs > 0) {
                (currentPositionMs.toFloat() / totalDurationMs.toFloat()).coerceIn(0f, 1f)
            } else 0f

            Column {
                Slider(
                    value = progressFraction,
                    onValueChange = { frac ->
                        onScrubStart()
                        val pos = (frac * totalDurationMs).toLong()
                        onScrubChange(pos)
                    },
                    onValueChangeFinished = {
                        val pos = (progressFraction * totalDurationMs).toLong()
                        onScrubEnd(pos)
                    },
                    colors = SliderDefaults.colors(
                        thumbColor = MaterialTheme.colorScheme.primary,
                        activeTrackColor = MaterialTheme.colorScheme.primary,
                        inactiveTrackColor = MaterialTheme.colorScheme.surfaceVariant,
                    ),
                    modifier = Modifier.fillMaxWidth(),
                )

                // Time labels
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    horizontalArrangement = Arrangement.SpaceBetween,
                ) {
                    Text(
                        text = LongRecordingService.formatDuration(currentPositionMs),
                        style = MaterialTheme.typography.labelSmall,
                        fontWeight = FontWeight.Bold,
                        color = MaterialTheme.colorScheme.primary,
                    )
                    Text(
                        text = LongRecordingService.formatDuration(totalDurationMs),
                        style = MaterialTheme.typography.labelSmall,
                        fontWeight = FontWeight.Bold,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
            }

            // Transport Playback Controls
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceEvenly,
                verticalAlignment = Alignment.CenterVertically,
            ) {
                IconButton(onClick = onSkipBackward5) {
                    Icon(
                        imageVector = Icons.Default.Replay5,
                        contentDescription = "Rewind 5 seconds",
                        tint = MaterialTheme.colorScheme.onSurface,
                        modifier = Modifier.size(28.dp),
                    )
                }

                Surface(
                    shape = CircleShape,
                    color = MaterialTheme.colorScheme.primary,
                    modifier = Modifier
                        .size(56.dp)
                        .clickable(onClick = onPlayPause),
                ) {
                    Box(contentAlignment = Alignment.Center) {
                        Icon(
                            imageVector = if (isPlaying) Icons.Default.Pause else Icons.Default.PlayArrow,
                            contentDescription = if (isPlaying) "Pause" else "Play",
                            tint = Color.White,
                            modifier = Modifier.size(32.dp),
                        )
                    }
                }

                IconButton(onClick = onSkipForward5) {
                    Icon(
                        imageVector = Icons.Default.Forward5,
                        contentDescription = "Fast forward 5 seconds",
                        tint = MaterialTheme.colorScheme.onSurface,
                        modifier = Modifier.size(28.dp),
                    )
                }
            }

            HorizontalDivider(color = MaterialTheme.colorScheme.outlineVariant.copy(alpha = 0.5f))

            // Playback Speed Selector Row
            Row(
                modifier = Modifier.fillMaxWidth(),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(6.dp),
            ) {
                Text(
                    text = "SPEED",
                    style = MaterialTheme.typography.labelSmall,
                    fontWeight = FontWeight.Bold,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    letterSpacing = 0.5.sp,
                )
                Spacer(Modifier.weight(1f))
                listOf(0.75f, 1.0f, 1.25f, 1.5f, 2.0f).forEach { speed ->
                    val isSelected = (playbackSpeed == speed)
                    FilterChip(
                        selected = isSelected,
                        onClick = { onSpeedChange(speed) },
                        label = {
                            Text(
                                text = "${speed}x",
                                style = MaterialTheme.typography.labelSmall,
                                fontWeight = if (isSelected) FontWeight.Bold else FontWeight.Normal,
                            )
                        },
                        colors = FilterChipDefaults.filterChipColors(
                            selectedContainerColor = MaterialTheme.colorScheme.primaryContainer,
                            selectedLabelColor = MaterialTheme.colorScheme.primary,
                        ),
                        modifier = Modifier.height(28.dp),
                    )
                }
            }
        }
    }
}

@Composable
private fun AiSummarizationSection(
    summary: String?,
    isSummarizing: Boolean,
    hasTranscript: Boolean,
    selectedStyle: SummaryStyle,
    onSelectStyle: (SummaryStyle) -> Unit,
    onGenerateSummary: () -> Unit,
) {
    Card(
        shape = RoundedCornerShape(20.dp),
        colors = CardDefaults.cardColors(
            containerColor = if (summary != null) Color(0xFFFAF5FF) else MaterialTheme.colorScheme.surface,
        ),
        border = BorderStroke(
            1.dp,
            if (summary != null) Color(0xFFC084FC) else MaterialTheme.colorScheme.outlineVariant,
        ),
        modifier = Modifier.fillMaxWidth(),
    ) {
        Column(
            modifier = Modifier.padding(18.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            Row(
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                Box(
                    modifier = Modifier
                        .size(34.dp)
                        .clip(RoundedCornerShape(10.dp))
                        .background(
                            Brush.linearGradient(
                                listOf(Color(0xFF9333EA), Color(0xFFC084FC)),
                            ),
                        ),
                    contentAlignment = Alignment.Center,
                ) {
                    Icon(
                        imageVector = Icons.Default.SmartToy,
                        contentDescription = null,
                        tint = Color.White,
                        modifier = Modifier.size(18.dp),
                    )
                }
                Column(Modifier.weight(1f)) {
                    Text(
                        text = "AI SUMMARIZATION",
                        style = MaterialTheme.typography.labelSmall,
                        fontWeight = FontWeight.Black,
                        color = Color(0xFF7E22CE),
                        letterSpacing = 0.8.sp,
                    )
                    Text(
                        text = "Synthesize key points, decisions, and action items",
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
            }

            if (summary != null) {
                Surface(
                    shape = RoundedCornerShape(14.dp),
                    color = Color.White,
                    border = BorderStroke(1.dp, Color(0xFFE9D5FF)),
                    modifier = Modifier.fillMaxWidth(),
                ) {
                    Text(
                        text = summary,
                        style = MaterialTheme.typography.bodyMedium,
                        lineHeight = 22.sp,
                        color = Color(0xFF3B0764),
                        modifier = Modifier.padding(14.dp),
                    )
                }
            }

            // Style selector chips
            Row(
                horizontalArrangement = Arrangement.spacedBy(6.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                SummaryStyle.entries.forEach { style ->
                    val isSelected = selectedStyle == style
                    FilterChip(
                        selected = isSelected,
                        onClick = { onSelectStyle(style) },
                        label = {
                            Text(
                                text = style.label,
                                style = MaterialTheme.typography.labelSmall,
                            )
                        },
                        colors = FilterChipDefaults.filterChipColors(
                            selectedContainerColor = Color(0xFFF3E8FF),
                            selectedLabelColor = Color(0xFF7E22CE),
                        ),
                    )
                }
            }

            Button(
                onClick = onGenerateSummary,
                enabled = hasTranscript && !isSummarizing,
                colors = ButtonDefaults.buttonColors(
                    containerColor = Color(0xFF7E22CE),
                    contentColor = Color.White,
                ),
                shape = RoundedCornerShape(12.dp),
                modifier = Modifier.fillMaxWidth(),
            ) {
                if (isSummarizing) {
                    CircularProgressIndicator(
                        modifier = Modifier.size(16.dp),
                        color = Color.White,
                        strokeWidth = 2.dp,
                    )
                    Spacer(Modifier.width(8.dp))
                    Text("Summarizing voice note...")
                } else {
                    Icon(Icons.Default.AutoFixHigh, contentDescription = null, modifier = Modifier.size(18.dp))
                    Spacer(Modifier.width(8.dp))
                    Text(if (summary != null) "Regenerate AI Summary" else "Generate AI Summary")
                }
            }
        }
    }
}

@Composable
private fun TranscriptSegmentCard(
    segment: VoiceNoteSegment,
    isActive: Boolean,
    onSeekToSegment: () -> Unit,
) {
    Card(
        shape = RoundedCornerShape(14.dp),
        colors = CardDefaults.cardColors(
            containerColor = if (isActive) MaterialTheme.colorScheme.primaryContainer.copy(alpha = 0.45f) else MaterialTheme.colorScheme.surface,
        ),
        border = BorderStroke(
            if (isActive) 1.5.dp else 1.dp,
            if (isActive) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.outlineVariant.copy(alpha = 0.6f),
        ),
        modifier = Modifier.fillMaxWidth(),
    ) {
        Column(
            modifier = Modifier.padding(14.dp),
            verticalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            Row(
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                Surface(
                    shape = RoundedCornerShape(8.dp),
                    color = if (isActive) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.surfaceVariant,
                    modifier = Modifier.clickable(onClick = onSeekToSegment),
                ) {
                    Text(
                        text = "${LongRecordingService.formatDuration(segment.startMs)} - ${LongRecordingService.formatDuration(segment.endMs)}",
                        style = MaterialTheme.typography.labelSmall,
                        fontWeight = FontWeight.Bold,
                        color = if (isActive) Color.White else MaterialTheme.colorScheme.onSurfaceVariant,
                        modifier = Modifier.padding(horizontal = 8.dp, vertical = 4.dp),
                    )
                }

                if (isActive) {
                    Text(
                        text = "● PLAYING",
                        style = MaterialTheme.typography.labelSmall,
                        fontWeight = FontWeight.Black,
                        color = MaterialTheme.colorScheme.primary,
                        letterSpacing = 0.5.sp,
                    )
                }
            }

            Text(
                text = segment.text,
                style = MaterialTheme.typography.bodyMedium,
                lineHeight = 20.sp,
                color = if (isActive) MaterialTheme.colorScheme.onSurface else MaterialTheme.colorScheme.onSurface.copy(alpha = 0.85f),
            )
        }
    }
}

private fun applyPlaybackSpeed(player: MediaPlayer, speed: Float) {
    try {
        val params = player.playbackParams
        player.playbackParams = params.setSpeed(speed)
    } catch (t: Throwable) {
        android.util.Log.e("VoiceNoteDetail", "Could not set playback speed", t)
    }
}

private suspend fun generateAiSummary(
    note: VoiceNote,
    style: SummaryStyle,
    onError: (String) -> Unit = {},
) {
    val polishRegistry = AppGraph.polish
    val settings = AppGraph.settings
    val secrets = AppGraph.secrets

    val activeModelId = settings.polishModelId
    val configuredPair = polishRegistry.find(activeModelId)

    // Verify user explicitly selected a model capable of freeform AI summarization
    val isCapable = configuredPair != null &&
        configuredPair.first.supportsCustomPrompt &&
        configuredPair.first.id != "local-slm" &&
        configuredPair.first.id != "rules"

    if (!isCapable) {
        val msg = "AI summarization requires a cloud model. Please select Gemini, Anthropic, or OpenAI in Cleanup settings."
        android.util.Log.w("VoiceNoteDetail", msg)
        onError(msg)
        return
    }

    val (provider, model) = configuredPair
    val apiKey = secrets.get(provider.id)
    if (provider.needsApiKey && apiKey.isNullOrBlank()) {
        val msg = "API key required for ${provider.displayName}. Please configure it in Settings."
        android.util.Log.w("VoiceNoteDetail", msg)
        onError(msg)
        return
    }

    val prompt = style.prompt
    val result = provider.polish(
        systemPrompt = prompt,
        userMessage = note.fullText,
        modelName = model.modelName,
        apiKey = apiKey,
    )

    when (result) {
        is PolishResult.Success -> {
            val updated = note.copy(summary = result.text.trim())
            AppGraph.voiceNotes.update(updated)
        }
        is PolishResult.Failure -> {
            val msg = "Summary generation failed: ${result.message}"
            android.util.Log.w("VoiceNoteDetail", msg)
            onError(msg)
        }
    }
}

private suspend fun transcribeCurrentNote(note: VoiceNote) {
    val audioFile = File(note.audioPath)
    if (!audioFile.exists()) return

    val installedModels = AppGraph.local.models
    val preferredModelId = AppGraph.settings.sttModelId
    val chosenModel = installedModels.firstOrNull { it.id == preferredModelId } ?: installedModels.firstOrNull()
    val modelId = chosenModel?.id
    val modelName = modelId?.substringAfter('/') ?: return

    val transcriber = AppGraph.local.asChunkTranscriber(
        modelName = modelName,
        language = AppGraph.settings.language,
    )

    val result = AppGraph.chunker.transcribeFile(
        wavFile = audioFile,
        transcriber = transcriber,
    )

    val updated = note.copy(
        fullText = result.fullText,
        segments = result.segments,
        isTranscribed = true,
        transcriptionProgress = 1.0f,
        modelUsed = modelId,
    )
    AppGraph.voiceNotes.update(updated)
}

private fun shareAudioWav(context: Context, note: VoiceNote) {
    val file = File(note.audioPath)
    if (!file.exists()) {
        Toast.makeText(context, "Audio file not found", Toast.LENGTH_SHORT).show()
        return
    }

    try {
        val uri = FileProvider.getUriForFile(context, "${context.packageName}.fileprovider", file)
        val shareIntent = Intent(Intent.ACTION_SEND).apply {
            type = "audio/wav"
            putExtra(Intent.EXTRA_STREAM, uri)
            putExtra(Intent.EXTRA_SUBJECT, note.title)
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }
        context.startActivity(Intent.createChooser(shareIntent, "Share Voice Note Audio"))
    } catch (t: Throwable) {
        Toast.makeText(context, "Failed to share audio: ${t.message}", Toast.LENGTH_SHORT).show()
    }
}

private fun shareTranscriptText(context: Context, note: VoiceNote) {
    val content = buildString {
        appendLine(note.title)
        appendLine("Recorded: ${SimpleDateFormat("MMM d, yyyy h:mm a", Locale.getDefault()).format(Date(note.createdAt))}")
        appendLine("Duration: ${LongRecordingService.formatDuration(note.durationMs)}")
        if (!note.summary.isNullOrBlank()) {
            appendLine()
            appendLine("AI SUMMARY:")
            appendLine(note.summary)
        }
        appendLine()
        appendLine("FULL TRANSCRIPT:")
        appendLine(note.fullText)
    }

    val shareIntent = Intent(Intent.ACTION_SEND).apply {
        type = "text/plain"
        putExtra(Intent.EXTRA_SUBJECT, note.title)
        putExtra(Intent.EXTRA_TEXT, content)
    }
    context.startActivity(Intent.createChooser(shareIntent, "Share Voice Note Transcript"))
}

private fun copyToClipboard(context: Context, label: String, text: String) {
    val clipboard = context.getSystemService(Context.CLIPBOARD_SERVICE) as? ClipboardManager
    val clip = ClipData.newPlainText(label, text)
    clipboard?.setPrimaryClip(clip)
}
