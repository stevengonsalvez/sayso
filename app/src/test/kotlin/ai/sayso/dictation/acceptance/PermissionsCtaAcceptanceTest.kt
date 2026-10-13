package ai.sayso.dictation.acceptance

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Acceptance test suite for permissions readiness and CTA evaluations.
 *
 * Verifies that missing Microphone or Accessibility permissions prominently
 * trigger the PERMISSIONS CTA state (red), missing local models trigger SETUP (amber),
 * and complete setup activates the READY state (green).
 */
class PermissionsCtaAcceptanceTest {

    enum class BadgeState {
        READY,
        PERMISSIONS,
        SETUP,
    }

    data class UiReadinessEvaluation(
        val micGranted: Boolean,
        val serviceOn: Boolean,
        val isSttReady: Boolean,
    ) {
        val permissionsMissing: Boolean = !micGranted || !serviceOn
        val isReady: Boolean = micGranted && serviceOn && isSttReady

        val badgeState: BadgeState = when {
            isReady -> BadgeState.READY
            permissionsMissing -> BadgeState.PERMISSIONS
            else -> BadgeState.SETUP
        }

        val showPermissionsDialog: Boolean = permissionsMissing
        val showModelRequiredBanner: Boolean = !isSttReady

        val micActionNeeded: Boolean = !micGranted
        val accessibilityActionNeeded: Boolean = !serviceOn
    }

    @Test
    fun missing_microphone_triggers_permissions_cta_and_mic_action() {
        val eval = UiReadinessEvaluation(
            micGranted = false,
            serviceOn = true,
            isSttReady = true,
        )

        assertEquals(BadgeState.PERMISSIONS, eval.badgeState)
        assertTrue("Permissions missing flag must be true", eval.permissionsMissing)
        assertFalse("App must not be ready", eval.isReady)
        assertTrue("Permissions CTA dialog must show", eval.showPermissionsDialog)
        assertTrue("Microphone grant button needed", eval.micActionNeeded)
        assertFalse("Accessibility is already granted", eval.accessibilityActionNeeded)
    }

    @Test
    fun missing_accessibility_service_triggers_permissions_cta_and_settings_action() {
        val eval = UiReadinessEvaluation(
            micGranted = true,
            serviceOn = false,
            isSttReady = true,
        )

        assertEquals(BadgeState.PERMISSIONS, eval.badgeState)
        assertTrue("Permissions missing flag must be true", eval.permissionsMissing)
        assertFalse("App must not be ready", eval.isReady)
        assertTrue("Permissions CTA dialog must show", eval.showPermissionsDialog)
        assertFalse("Microphone is already granted", eval.micActionNeeded)
        assertTrue("Accessibility enable action needed", eval.accessibilityActionNeeded)
    }

    @Test
    fun missing_both_permissions_highlights_both_requirements() {
        val eval = UiReadinessEvaluation(
            micGranted = false,
            serviceOn = false,
            isSttReady = true,
        )

        assertEquals(BadgeState.PERMISSIONS, eval.badgeState)
        assertTrue("Both actions required", eval.micActionNeeded && eval.accessibilityActionNeeded)
    }

    @Test
    fun permissions_granted_but_model_missing_triggers_setup_cta() {
        val eval = UiReadinessEvaluation(
            micGranted = true,
            serviceOn = true,
            isSttReady = false,
        )

        assertEquals(BadgeState.SETUP, eval.badgeState)
        assertFalse("Permissions themselves are not missing", eval.permissionsMissing)
        assertFalse("App is not yet ready until model downloads", eval.isReady)
        assertFalse("Do not show permissions dialog", eval.showPermissionsDialog)
        assertTrue("Must display ModelRequiredBanner", eval.showModelRequiredBanner)
    }

    @Test
    fun all_permissions_and_model_ready_activates_ready_state() {
        val eval = UiReadinessEvaluation(
            micGranted = true,
            serviceOn = true,
            isSttReady = true,
        )

        assertEquals(BadgeState.READY, eval.badgeState)
        assertFalse(eval.permissionsMissing)
        assertTrue("App is completely ready", eval.isReady)
        assertFalse(eval.showPermissionsDialog)
        assertFalse(eval.showModelRequiredBanner)
    }
}
