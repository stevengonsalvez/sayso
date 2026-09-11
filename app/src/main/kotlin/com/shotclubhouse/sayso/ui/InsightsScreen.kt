package com.shotclubhouse.sayso.ui

import android.text.format.DateUtils
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AssistChip
import androidx.compose.material3.ElevatedCard
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import com.shotclubhouse.sayso.AppGraph
import com.shotclubhouse.sayso.R
import com.shotclubhouse.sayso.history.Insights
import com.shotclubhouse.sayso.history.InsightsSummary
import kotlin.math.roundToInt

/** Speaking stats derived from what is stored in history. */
@OptIn(ExperimentalLayoutApi::class)
@Composable
fun InsightsScreen(modifier: Modifier = Modifier) {
    var summary by remember { mutableStateOf<InsightsSummary?>(null) }

    LaunchedEffect(Unit) {
        summary = Insights.compute(AppGraph.history.all())
    }

    val stats = summary
    Column(
        modifier
            .fillMaxSize()
            .verticalScroll(rememberScrollState())
            .padding(16.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        if (stats == null || stats.sessions == 0) {
            Text(
                stringResource(R.string.insights_empty),
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
            return@Column
        }

        StatCard(stringResource(R.string.insights_sessions), stats.sessions.toString())
        StatCard(stringResource(R.string.insights_total_words), stats.totalWords.toString())
        StatCard(
            stringResource(R.string.insights_average_wpm),
            stringResource(R.string.insights_wpm_unit, stats.averageWpm.roundToInt()),
        )
        StatCard(
            stringResource(R.string.insights_filler_rate),
            stringResource(
                R.string.insights_filler_unit,
                String.format("%.1f", stats.fillerRatePer1k),
            ),
        )
        StatCard(
            stringResource(R.string.insights_longest),
            DateUtils.formatElapsedTime(stats.longestSessionMs / 1000),
        )

        if (stats.topWords.isNotEmpty()) {
            Text(
                stringResource(R.string.insights_top_words),
                style = MaterialTheme.typography.titleSmall,
            )
            FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                for ((word, count) in stats.topWords) {
                    AssistChip(onClick = {}, label = { Text("$word $count") })
                }
            }
        }
    }
}

@Composable
private fun StatCard(label: String, value: String) {
    ElevatedCard(Modifier.fillMaxWidth()) {
        Column(Modifier.padding(16.dp)) {
            Text(
                label,
                style = MaterialTheme.typography.labelLarge,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
            Text(value, style = MaterialTheme.typography.headlineSmall)
        }
    }
}
