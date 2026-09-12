package com.shotclubhouse.sayso

import android.app.Application
import com.shotclubhouse.sayso.service.WakeWordService

class SaysoApp : Application() {
    override fun onCreate() {
        super.onCreate()
        AppGraph.init(this)
        if (AppGraph.settings.wakeWordEnabled) {
            WakeWordService.start(this)
        }
    }
}
