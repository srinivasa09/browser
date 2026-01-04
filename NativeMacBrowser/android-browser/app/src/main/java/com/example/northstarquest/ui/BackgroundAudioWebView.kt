package com.example.northstarquest.ui

import android.content.Context
import android.util.AttributeSet
import android.webkit.WebView

/**
 * Custom WebView that keeps audio playing when screen is off.
 * 
 * The key trick is overriding onWindowVisibilityChanged to prevent the WebView
 * from pausing media when the window becomes invisible (screen off / app backgrounded).
 */
class BackgroundAudioWebView @JvmOverloads constructor(
    context: Context,
    attrs: AttributeSet? = null,
    defStyleAttr: Int = 0
) : WebView(context, attrs, defStyleAttr) {

    private var keepPlayingInBackground = false
    
    init {
        // Enable focus for keyboard input
        isFocusable = true
        isFocusableInTouchMode = true
        
        // Request focus when touched to ensure keyboard appears
        setOnTouchListener { v, _ ->
            if (!v.hasFocus()) {
                v.requestFocus()
            }
            false // Return false to allow the touch event to propagate
        }
    }
    
    /**
     * Tell the system this view can accept text input.
     * This is crucial for the soft keyboard to appear when input fields are focused.
     */
    override fun onCheckIsTextEditor(): Boolean {
        return true
    }

    /**
     * Enable or disable background audio playback.
     * When enabled, the WebView will not pause media when screen turns off.
     */
    fun setBackgroundAudioEnabled(enabled: Boolean) {
        keepPlayingInBackground = enabled
    }

    fun isBackgroundAudioEnabled(): Boolean = keepPlayingInBackground

    /**
     * Override to prevent WebView from pausing when window visibility changes.
     * This is the key method that keeps audio playing when screen is off.
     */
    override fun onWindowVisibilityChanged(visibility: Int) {
        if (keepPlayingInBackground) {
            // Always report as VISIBLE to prevent media pause
            super.onWindowVisibilityChanged(VISIBLE)
        } else {
            super.onWindowVisibilityChanged(visibility)
        }
    }
}
