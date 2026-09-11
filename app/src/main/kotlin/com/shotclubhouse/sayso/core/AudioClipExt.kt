package com.shotclubhouse.sayso.core

/**
 * Converts the clip to the normalised float samples that on-device recognisers
 * expect. A trailing odd byte, if any, is dropped.
 */
fun AudioClip.toFloatSamples(): FloatArray {
    val count = pcm16.size / 2
    val samples = FloatArray(count)
    for (i in 0 until count) {
        val low = pcm16[i * 2].toInt() and 0xFF
        val high = pcm16[i * 2 + 1].toInt()
        samples[i] = ((high shl 8) or low).toShort() / 32768f
    }
    return samples
}
