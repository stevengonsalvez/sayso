package com.shotclubhouse.sayso.service

import android.accessibilityservice.AccessibilityService
import android.content.ClipData
import android.content.ClipDescription
import android.content.ClipboardManager
import android.os.Build
import android.os.Bundle
import android.os.PersistableBundle
import android.util.Log
import android.view.accessibility.AccessibilityNodeInfo
import com.shotclubhouse.sayso.core.OutputMethod

/** Class name fragment of the terminal emulators that expose paste only by label. */
private const val TERMINAL_CLASS = "TerminalView"

/**
 * Splices [insert] into [existing] at the selection, mimicking what typing would do.
 *
 * A missing selection (either index below zero) appends instead. Spaces are added on
 * either side when the neighbouring character is not already whitespace, so dictating
 * twice in a row, or into the middle of a sentence, does not run words together.
 */
fun spliceAtSelection(existing: String, insert: String, selectionStart: Int, selectionEnd: Int): String {
    val hasSelection = selectionStart >= 0 && selectionEnd >= 0
    val start = if (hasSelection) minOf(selectionStart, selectionEnd).coerceIn(0, existing.length) else existing.length
    val end = if (hasSelection) maxOf(selectionStart, selectionEnd).coerceIn(0, existing.length) else existing.length
    val prefix = existing.substring(0, start)
    val suffix = existing.substring(end)
    val before = if (prefix.isNotEmpty() && !prefix.last().isWhitespace()) " " else ""
    val after = if (suffix.isNotEmpty() && !suffix.first().isWhitespace()) " " else ""
    return prefix + before + insert + after + suffix
}

/**
 * Only a terminal emulator gets its paste action picked out by label. Anywhere else that
 * would sooner or later fire whatever unrelated action happens to be called "paste", in
 * whatever language the app is in.
 */
internal fun matchesPasteByLabel(className: String?): Boolean =
    className?.contains(TERMINAL_CLASS) == true

/**
 * Whether the transcript has to be on the clipboard before the chosen action runs.
 *
 * A paste action, custom or standard, can only deliver what is already on the clipboard:
 * firing one without copying first pastes whatever the user copied last and still reports
 * success. Setting the text carries the transcript itself, so that path stays clipboard
 * free, which matters because dictation is often a password or a private message.
 *
 * Mirrors the order [TextInjector] tries the actions in: a custom paste wins over editing.
 */
internal fun needsClipboardBeforeAction(hasCustomPaste: Boolean, isEditable: Boolean): Boolean =
    hasCustomPaste || !isEditable

/**
 * Decides how the text reached the user, and copies only when it did not.
 *
 * [copyToClipboard] is a fallback, not a belt and braces: dictated text is often a
 * password or a message, and pushing every successful dictation onto a clipboard that
 * every foreground app can read gives it away for nothing.
 */
internal inline fun deliveryOutcome(inserted: Boolean, copyToClipboard: () -> Boolean): OutputMethod = when {
    inserted -> OutputMethod.INSERTED
    copyToClipboard() -> OutputMethod.CLIPBOARD
    else -> OutputMethod.NONE
}

/**
 * Puts dictated text where the user is typing.
 *
 * The most promising editable node in the active windows is asked to take the text,
 * preferring a terminal's own paste action, then a direct text edit, then the generic
 * paste action. A paste can only deliver what the clipboard holds, so those two paths put
 * the text there first; editing the text directly does not. If no node takes it at all the
 * text goes to the clipboard anyway, one long-press away rather than lost.
 */
class TextInjector(private val service: AccessibilityService) {

    /** Returns how the text reached the user. */
    fun inject(text: String): OutputMethod {
        val inserted = candidates().sortedByDescending(::score).any { insertInto(it, text) }
        return deliveryOutcome(inserted) { copyToClipboard(text) }
    }

    private fun copyToClipboard(text: String): Boolean {
        val clipboard = service.getSystemService(ClipboardManager::class.java) ?: return false
        val clip = ClipData.newPlainText(CLIP_LABEL, text).apply {
            // Keeps the dictated text out of the clipboard preview the system shows on paste.
            // The flag landed in Android 13; older releases simply show the preview.
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                description.extras = PersistableBundle().apply {
                    putBoolean(ClipDescription.EXTRA_IS_SENSITIVE, true)
                }
            }
        }
        return runCatching { clipboard.setPrimaryClip(clip) }
            .onFailure { Log.d(TAG, "Clipboard write refused", it) }
            .isSuccess
    }

    /**
     * Focused nodes first, then a bounded walk of the active windows. The budget is
     * shared across roots because every node access is a binder round trip.
     */
    private fun candidates(): List<AccessibilityNodeInfo> {
        val roots = buildList {
            service.rootInActiveWindow?.let(::add)
            service.windows
                .filter { it.isActive || it.isFocused }
                .forEach { window -> window.root?.let(::add) }
        }

        val found = LinkedHashSet<AccessibilityNodeInfo>()
        var budget = MAX_NODES
        for (root in roots) {
            root.findFocus(AccessibilityNodeInfo.FOCUS_INPUT)?.let(found::add)
            root.findFocus(AccessibilityNodeInfo.FOCUS_ACCESSIBILITY)?.let(found::add)

            val stack = ArrayDeque<AccessibilityNodeInfo>()
            stack.addLast(root)
            while (stack.isNotEmpty() && budget > 0) {
                val node = stack.removeLast()
                budget--
                if (isTextTarget(node)) found.add(node)
                for (i in node.childCount - 1 downTo 0) {
                    node.getChild(i)?.let(stack::addLast)
                }
            }
        }
        return found.filter { score(it) > 0 }
    }

    private fun isTextTarget(node: AccessibilityNodeInfo): Boolean =
        node.isEditable ||
            node.isFocused ||
            node.className?.contains(EDIT_TEXT_CLASS) == true ||
            acceptsPaste(node) ||
            customPasteAction(node) != null

    private fun score(node: AccessibilityNodeInfo): Int {
        val className = node.className?.toString().orEmpty()
        var score = 0
        if (acceptsPaste(node) || customPasteAction(node) != null) score += 100
        if (matchesPasteByLabel(className)) score += 80
        if (node.isEditable) score += 60
        if (node.isFocused) score += 40
        if (className.contains(EDIT_TEXT_CLASS)) score += 20
        return score
    }

    /** The standard paste, identified by its action id rather than by what it is called. */
    private fun acceptsPaste(node: AccessibilityNodeInfo): Boolean =
        node.actionList.any { it.id == AccessibilityNodeInfo.ACTION_PASTE }

    /** Terminal emulators expose paste only as a custom action carrying a "paste" label. */
    private fun customPasteAction(node: AccessibilityNodeInfo): AccessibilityNodeInfo.AccessibilityAction? {
        if (!matchesPasteByLabel(node.className?.toString())) return null
        return node.actionList.firstOrNull { it.label?.contains(PASTE_LABEL, ignoreCase = true) == true }
    }

    private fun insertInto(node: AccessibilityNodeInfo, text: String): Boolean {
        node.performAction(AccessibilityNodeInfo.ACTION_FOCUS)

        val customPaste = customPasteAction(node)
        val editable = node.isEditable
        if (needsClipboardBeforeAction(hasCustomPaste = customPaste != null, isEditable = editable) &&
            !copyToClipboard(text)
        ) {
            Log.d(TAG, "Not pasting: the transcript never reached the clipboard")
            return false
        }

        if (customPaste != null) {
            return node.performAction(customPaste.id).also { Log.d(TAG, "Custom paste returned $it") }
        }

        if (editable) {
            val merged = spliceAtSelection(
                existing = node.text?.toString().orEmpty(),
                insert = text,
                selectionStart = node.textSelectionStart,
                selectionEnd = node.textSelectionEnd,
            )
            val arguments = Bundle().apply {
                putCharSequence(AccessibilityNodeInfo.ACTION_ARGUMENT_SET_TEXT_CHARSEQUENCE, merged)
            }
            return node.performAction(AccessibilityNodeInfo.ACTION_SET_TEXT, arguments)
                .also { Log.d(TAG, "Set text returned $it") }
        }

        return node.performAction(AccessibilityNodeInfo.ACTION_PASTE)
            .also { Log.d(TAG, "Paste returned $it") }
    }

    private companion object {
        const val TAG = "SaysoInjector"
        const val CLIP_LABEL = "Sayso"
        const val PASTE_LABEL = "paste"
        const val EDIT_TEXT_CLASS = "EditText"

        /** Bounds a walk to roughly 200 ms of binder traffic on a busy screen. */
        const val MAX_NODES = 400
    }
}
