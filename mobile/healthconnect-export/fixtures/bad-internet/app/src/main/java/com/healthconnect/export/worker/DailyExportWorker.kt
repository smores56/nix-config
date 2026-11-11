package com.healthconnect.export.worker

import androidx.work.PeriodicWorkRequestBuilder

class DailyExportWorker {
    fun schedule() = PeriodicWorkRequestBuilder<DailyExportWorker>(24, java.util.concurrent.TimeUnit.HOURS)
}
