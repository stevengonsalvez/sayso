package ai.sayso.dictation

import android.app.Application
import ai.sayso.dictation.service.WakeWordService

class SaysoApp : Application() {
    override fun onCreate() {
        super.onCreate()
        AppGraph.init(this)
        if (AppGraph.settings.wakeWordEnabled) {
            WakeWordService.start(this)
        }
    }
}
