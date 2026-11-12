package com.iptv.lunar

import android.os.Bundle
import androidx.core.view.WindowCompat
import io.flutter.embedding.android.FlutterActivity

class MainActivity : FlutterActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        // Draw behind the status / navigation bars on every Android version
        // (Android 15+ does this by default for apps targeting it; this makes
        // older versions match). Flutter's SafeArea handles the insets.
        WindowCompat.enableEdgeToEdge(window)
        super.onCreate(savedInstanceState)
    }
}
