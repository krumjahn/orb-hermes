package com.keith.orbhermes

import android.app.Activity
import android.graphics.Color
import android.widget.ScrollView
import android.widget.TextView
import androidx.appcompat.app.AlertDialog

/**
 * The licence notice that has to travel with the app.
 *
 * The orb's look is a re-implementation of the shader in LerSent001/orb, which
 * is MIT, so the notice and the licence text have to be inside every copy -
 * including an APK that somebody installs from a download link and never sees
 * this repository.
 */
object Licences {

    const val NOTICE = """Orb Hermes - Copyright (c) 2026 Keith Rumjahn

Released under the MIT License.

Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

Liquid-glass orb
The orb's look is a re-implementation of the shader in https://github.com/LerSent001/orb (MIT Licence, Copyright (c) its authors). The preset names and the palette come from that project; the renderer here is a native OpenGL ES 3.0 rewrite, because the reference project is WebGPU/WGSL.

Third-party components (Apache-2.0)
- AndroidX AppCompat, Core KTX, ConstraintLayout
- Material Components for Android

The full source is published at https://github.com/krumjahn/orb-hermes"""

    fun show(activity: Activity) {
        val pad = (20 * activity.resources.displayMetrics.density).toInt()
        val body = TextView(activity).apply {
            text = NOTICE
            textSize = 12f
            setTextColor(Color.parseColor("#9AA3B8"))
            setPadding(pad, pad, pad, pad)
        }
        val scroll = ScrollView(activity).apply { addView(body) }
        AlertDialog.Builder(activity)
            .setTitle("Open-source licences")
            .setView(scroll)
            .setPositiveButton("Close", null)
            .show()
    }
}
