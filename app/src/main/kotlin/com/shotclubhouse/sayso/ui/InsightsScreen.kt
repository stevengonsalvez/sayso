package com.shotclubhouse.sayso.ui

import android.text.format.DateUtils
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AssistChip
import androidx.compose.material3.ElevatedCard
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.shotclubhouse.sayso.AppGraph
import com.shotclubhouse.sayso.R
import com.shotclubhouse.sayso.history.Insights
import com.shotclubhouse.sayso.history.InsightsSummary
import com.shotclubhouse.sayso.history.PaceBucket
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.util.Locale
import kotlin.math.roundToInt

/** Speaking stats and visual speech insights dashboard. */
@OptIn(ExperimentalLayoutApi::class)
@Composable
fun InsightsScreen(modifier: Modifier = Modifier) {
    var summary by remember { mutableStateOf<InsightsSummary?>(null) }

    LaunchedEffect(Unit) {
        summary = withContext(Dispatchers.Default) { Insights.compute(AppGraph.history.all()) }
    }

    val stats = summary
    Column(
        modifier
            .fillMaxSize()
            .verticalScroll(rememberScrollState())
            .padding(16.dp),
        verticalArrangement = Arrangement.spacedBy(14.dp),
    ) {
        if (stats == null || stats.sessions == 0) {
            Text(
                stringResource(R.string.insights_empty),
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.padding(top = 16.dp),
            )
            return@Column
        }

        // 1. Speaking Pace Card
        SpeakingPaceCard(stats)

        // 2. Filler Words Card
        FillerWordsCard(stats)

        // 3. Vocabulary & Top Phrases Card
        VocabularyInsightsCard(stats)

        // 4. Most Used Content Words Card
        if (stats.topWords.isNotEmpty()) {
            TopWordsCard(stats)
        }

        // 5. Speech Records & Totals Card
        SpeechRecordsCard(stats)

        Spacer(Modifier.height(24.dp))
    }
}

@Composable
private fun SpeakingPaceCard(stats: InsightsSummary) {
    ElevatedCard(
        shape = RoundedCornerShape(16.dp),
        modifier = Modifier.fillMaxWidth(),
    ) {
        Column(Modifier.padding(16.dp)) {
            Text(
                "Speaking Pace",
                style = MaterialTheme.typography.titleMedium,
                fontWeight = FontWeight.Bold,
            )

            Spacer(Modifier.height(8.dp))

            Row(
                verticalAlignment = Alignment.Bottom,
                horizontalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                Text(
                    text = stats.averageWpm.roundToInt().toString(),
                    fontSize = 36.sp,
                    fontWeight = FontWeight.Bold,
                    color = MaterialTheme.colorScheme.primary,
                )
                Text(
                    text = "wpm average",
                    style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.padding(bottom = 6.dp),
                )
                Spacer(Modifier.weight(1f))
                Surface(
                    shape = RoundedCornerShape(8.dp),
                    color = MaterialTheme.colorScheme.surfaceVariant,
                    modifier = Modifier.padding(bottom = 6.dp),
                ) {
                    Text(
                        text = "median ${stats.medianWpm.roundToInt()} wpm",
                        style = MaterialTheme.typography.labelMedium,
                        modifier = Modifier.padding(horizontal = 8.dp, vertical = 4.dp),
                    )
                }
            }

            Spacer(Modifier.height(12.dp))
            HorizontalDivider(color = MaterialTheme.colorScheme.outlineVariant.copy(alpha = 0.5f))
            Spacer(Modifier.height(12.dp))

            Text(
                "Sessions by pace range",
                style = MaterialTheme.typography.labelMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )

            Spacer(Modifier.height(8.dp))

            val maxCount = stats.paceBuckets.maxOfOrNull { it.count }?.coerceAtLeast(1) ?: 1
            stats.paceBuckets.forEach { bucket ->
                PaceBucketRow(bucket = bucket, maxCount = maxCount)
            }
        }
    }
}

@Composable
private fun PaceBucketRow(bucket: PaceBucket, maxCount: Int) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .padding(vertical = 3.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(
            text = bucket.label,
            style = MaterialTheme.typography.labelSmall,
            fontFamily = FontFamily.Monospace,
            modifier = Modifier.width(64.dp),
        )

        val fraction = bucket.count.toFloat() / maxCount.toFloat()
        Box(
            modifier = Modifier
                .weight(1f)
                .height(12.dp)
                .clip(RoundedCornerShape(6.dp))
                .background(MaterialTheme.colorScheme.surfaceVariant),
        ) {
            Box(
                modifier = Modifier
                    .fillMaxHeight()
                    .fillMaxWidth(fraction.coerceIn(0.02f, 1f))
                    .clip(RoundedCornerShape(6.dp))
                    .background(MaterialTheme.colorScheme.primary),
            )
        }

        Text(
            text = bucket.count.toString(),
            style = MaterialTheme.typography.labelSmall,
            fontWeight = FontWeight.SemiBold,
            modifier = Modifier
                .width(36.dp)
                .padding(start = 8.dp),
        )
    }
}

@OptIn(ExperimentalLayoutApi::class)
@Composable
private fun FillerWordsCard(stats: InsightsSummary) {
    ElevatedCard(
        shape = RoundedCornerShape(16.dp),
        modifier = Modifier.fillMaxWidth(),
    ) {
        Column(Modifier.padding(16.dp)) {
            Text(
                "Filler Words",
                style = MaterialTheme.typography.titleMedium,
                fontWeight = FontWeight.Bold,
            )

            Spacer(Modifier.height(8.dp))

            Row(verticalAlignment = Alignment.Bottom) {
                Text(
                    text = String.format(Locale.getDefault(), "%.1f", stats.fillerRatePer1k),
                    fontSize = 32.sp,
                    fontWeight = FontWeight.Bold,
                    color = if (stats.fillerRatePer1k > 25.0) MaterialTheme.colorScheme.error else MaterialTheme.colorScheme.tertiary,
                )
                Text(
                    text = " per 1,000 words",
                    style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.padding(bottom = 4.dp, start = 4.dp),
                )
            }

            if (stats.topFillers.isNotEmpty()) {
                Spacer(Modifier.height(10.dp))
                Text(
                    "Detected fillers",
                    style = MaterialTheme.typography.labelMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
                Spacer(Modifier.height(6.dp))
                FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    stats.topFillers.forEach { filler ->
                        AssistChip(
                            onClick = {},
                            label = { Text("${filler.word} ×${filler.count}") },
                        )
                    }
                }
            }
        }
    }
}

@OptIn(ExperimentalLayoutApi::class)
@Composable
private fun VocabularyInsightsCard(stats: InsightsSummary) {
    ElevatedCard(
        shape = RoundedCornerShape(16.dp),
        modifier = Modifier.fillMaxWidth(),
    ) {
        Column(Modifier.padding(16.dp)) {
            Text(
                "Vocabulary & Phrases",
                style = MaterialTheme.typography.titleMedium,
                fontWeight = FontWeight.Bold,
            )

            Spacer(Modifier.height(12.dp))

            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceAround,
            ) {
                Column(horizontalAlignment = Alignment.CenterHorizontally) {
                    Text(
                        stats.uniqueWords.toString(),
                        style = MaterialTheme.typography.headlineMedium,
                        fontWeight = FontWeight.Bold,
                        color = MaterialTheme.colorScheme.secondary,
                    )
                    Text(
                        "Unique Words",
                        style = MaterialTheme.typography.labelMedium,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }

                Column(horizontalAlignment = Alignment.CenterHorizontally) {
                    Text(
                        "${stats.richnessPercent.roundToInt()}%",
                        style = MaterialTheme.typography.headlineMedium,
                        fontWeight = FontWeight.Bold,
                        color = MaterialTheme.colorScheme.secondary,
                    )
                    Text(
                        "Lexical Richness",
                        style = MaterialTheme.typography.labelMedium,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
            }

            if (stats.topPhrases.isNotEmpty()) {
                Spacer(Modifier.height(14.dp))
                HorizontalDivider(color = MaterialTheme.colorScheme.outlineVariant.copy(alpha = 0.5f))
                Spacer(Modifier.height(10.dp))
                Text(
                    "Top Repeated Phrases",
                    style = MaterialTheme.typography.labelMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
                Spacer(Modifier.height(6.dp))
                FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    stats.topPhrases.forEach { phrase ->
                        AssistChip(
                            onClick = {},
                            label = { Text("“${phrase.phrase}” ×${phrase.count}") },
                        )
                    }
                }
            }
        }
    }
}

@OptIn(ExperimentalLayoutApi::class)
@Composable
private fun TopWordsCard(stats: InsightsSummary) {
    ElevatedCard(
        shape = RoundedCornerShape(16.dp),
        modifier = Modifier.fillMaxWidth(),
    ) {
        Column(Modifier.padding(16.dp)) {
            Text(
                stringResource(R.string.insights_top_words),
                style = MaterialTheme.typography.titleMedium,
                fontWeight = FontWeight.Bold,
            )
            Spacer(Modifier.height(8.dp))
            FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                for ((word, count) in stats.topWords) {
                    AssistChip(onClick = {}, label = { Text("$word $count") })
                }
            }
        }
    }
}

@Composable
private fun SpeechRecordsCard(stats: InsightsSummary) {
    ElevatedCard(
        shape = RoundedCornerShape(16.dp),
        modifier = Modifier.fillMaxWidth(),
    ) {
        Column(Modifier.padding(16.dp)) {
            Text(
                "Speech Records",
                style = MaterialTheme.typography.titleMedium,
                fontWeight = FontWeight.Bold,
            )

            Spacer(Modifier.height(12.dp))

            RecordRow(label = "Words All-Time", value = stats.totalWords.toString())
            RecordRow(label = "Sessions Analyzed", value = stats.sessions.toString())
            RecordRow(label = "Total Speaking Time", value = DateUtils.formatElapsedTime(stats.totalDurationMs / 1000))
            RecordRow(label = "Longest Single Session", value = DateUtils.formatElapsedTime(stats.longestSessionMs / 1000))
        }
    }
}

@Composable
private fun RecordRow(label: String, value: String) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .padding(vertical = 4.dp),
        horizontalArrangement = Arrangement.SpaceBetween,
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(
            text = label,
            style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
        Text(
            text = value,
            style = MaterialTheme.typography.bodyLarge,
            fontWeight = FontWeight.SemiBold,
        )
    }
}
