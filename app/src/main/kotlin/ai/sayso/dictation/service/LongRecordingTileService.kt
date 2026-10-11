package ai.sayso.dictation.service

import android.graphics.drawable.Icon
import android.service.quicksettings.Tile
import android.service.quicksettings.TileService
import ai.sayso.dictation.R
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch

/**
 * Quick Settings Tile to start or stop long-form voice note recordings with one tap.
 */
class LongRecordingTileService : TileService() {

    private val serviceScope = CoroutineScope(SupervisorJob() + Dispatchers.Main)
    private var stateJob: Job? = null

    override fun onStartListening() {
        super.onStartListening()
        stateJob?.cancel()
        stateJob = serviceScope.launch {
            LongRecordingService.state.collect { state ->
                updateTileState(state)
            }
        }
    }

    override fun onStopListening() {
        super.onStopListening()
        stateJob?.cancel()
        stateJob = null
    }

    override fun onClick() {
        super.onClick()
        val current = LongRecordingService.state.value
        if (current.isRecording) {
            LongRecordingService.stop(this)
        } else {
            LongRecordingService.start(this)
        }
    }

    override fun onDestroy() {
        super.onDestroy()
        serviceScope.cancel()
    }

    private fun updateTileState(state: LongRecordingState) {
        val tile = qsTile ?: return
        if (state.isRecording) {
            tile.state = Tile.STATE_ACTIVE
            tile.label = if (state.isPaused) "Paused" else "Recording"
            tile.subtitle = LongRecordingService.formatDuration(state.durationMs)
            tile.icon = Icon.createWithResource(this, R.drawable.ic_bubble_idle)
        } else {
            tile.state = Tile.STATE_INACTIVE
            tile.label = "Voice Note"
            tile.subtitle = "Tap to record"
            tile.icon = Icon.createWithResource(this, R.drawable.ic_bubble_idle)
        }
        tile.updateTile()
    }
}
