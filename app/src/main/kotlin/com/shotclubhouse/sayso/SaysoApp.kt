package com.shotclubhouse.sayso

import android.app.Application

class SaysoApp : Application() {
    override fun onCreate() {
        super.onCreate()
        AppGraph.init(this)
    }
}
