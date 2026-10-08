package wtf.openstrap.openstrap_edge

import android.content.Context
import androidx.activity.result.ActivityResultLauncher
import androidx.health.connect.client.HealthConnectClient
import androidx.health.connect.client.HealthConnectFeatures
import androidx.health.connect.client.feature.ExperimentalFeatureAvailabilityApi
import androidx.health.connect.client.PermissionController
import androidx.health.connect.client.changes.DeletionChange
import androidx.health.connect.client.changes.UpsertionChange
import androidx.health.connect.client.permission.HealthPermission
import androidx.health.connect.client.records.WeightRecord
import androidx.health.connect.client.request.ChangesTokenRequest
import androidx.health.connect.client.request.ReadRecordsRequest
import androidx.health.connect.client.time.TimeRangeFilter
import androidx.work.CoroutineWorker
import androidx.work.ExistingPeriodicWorkPolicy
import androidx.work.PeriodicWorkRequestBuilder
import androidx.work.WorkManager
import androidx.work.WorkerParameters
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.time.Duration
import java.time.Instant
import java.util.concurrent.TimeUnit
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout
import kotlin.coroutines.resume

internal fun requireStableWeightSnapshotAccess(
    readGranted: Boolean,
    historyGranted: Boolean,
    historyAtStart: Boolean,
) {
    if (!readGranted || historyGranted != historyAtStart) {
        throw SecurityException("Weight snapshot access changed during import")
    }
}

/** Read-only, weight-only API. The native worker dispatches into Edge's existing
 * engine, so the Dart importer shares HeadlessSyncGate and ResetGate with BLE.
 * https://developer.android.com/health-and-fitness/health-connect/sync-data
 */
object WeightImportBridge {
    private const val CHANNEL = "openstrap/weight_import"
    private const val WORK = "openstrap.weight.import.daily"
    private const val BACKGROUND = "android.permission.health.READ_HEALTH_DATA_IN_BACKGROUND"
    private const val HISTORY = "android.permission.health.READ_HEALTH_DATA_HISTORY"
    private val READ = HealthPermission.getReadPermission(WeightRecord::class)
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)
    private var channel: MethodChannel? = null
    @Volatile private var dartReady = false
    private var launcher: ActivityResultLauncher<Set<String>>? = null
    private var permissionResult: MethodChannel.Result? = null

    fun attach(activity: MainActivity) {
        launcher = activity.activityResultRegistry.register(
            "edge_weight_permissions", activity,
            PermissionController.createRequestPermissionResultContract(),
        ) {
            val result = permissionResult
            permissionResult = null
            scope.launch {
                try { result?.success(status(activity.applicationContext)) }
                catch (error: Exception) { result?.error("permission_error", error.message, null) }
            }
        }
    }

    fun detach(finishing: Boolean) {
        launcher = null
        if (finishing) {
            permissionResult?.error("permission_cancelled", "Permission request cancelled", null)
            permissionResult = null
        }
    }

    fun register(engine: FlutterEngine, context: Context) {
        val app = context.applicationContext
        dartReady = false
        channel = MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL).also { bridge ->
            bridge.setMethodCallHandler { call, result ->
                scope.launch {
                    try {
                        when (call.method) {
                            "ready" -> { dartReady = true; result.success(null) }
                            "status" -> result.success(status(app))
                            "request" -> {
                                val kind = call.argument<String>("kind") ?: "weight"
                                val state = status(app)
                                val permission = when (kind) {
                                    "background" -> if (state["backgroundAvailable"] == true) BACKGROUND else null
                                    "history" -> if (state["historyAvailable"] == true) HISTORY else null
                                    else -> READ
                                }
                                if (state["available"] != true || permission == null) result.success(state)
                                else if (permissionResult != null) result.error("busy", "Permission request in progress", null)
                                else if (launcher == null) result.error("foreground_required", "Open the app to grant access", null)
                                else { permissionResult = result; launcher!!.launch(setOf(permission)) }
                            }
                            "read" -> {
                                val token = call.argument<String>("token")
                                val snapshot = call.argument<Boolean>("snapshot") == true
                                result.success(withContext(Dispatchers.IO) {
                                    withTimeout(90_000) { read(app, if (snapshot) null else token) }
                                })
                            }
                            "schedule" -> {
                                val enabled = call.argument<Boolean>("enabled") == true
                                app.getSharedPreferences("edge_weight_import", Context.MODE_PRIVATE)
                                    .edit().putBoolean("enabled", enabled).apply()
                                val state = status(app)
                                val wm = WorkManager.getInstance(app)
                                if (enabled && state["backgroundGranted"] == true && state["weightGranted"] == true) {
                                    wm.enqueueUniquePeriodicWork(WORK, ExistingPeriodicWorkPolicy.KEEP,
                                        PeriodicWorkRequestBuilder<WeightImportWorker>(24, TimeUnit.HOURS).build())
                                } else { wm.cancelUniqueWork(WORK) }
                                result.success(null)
                            }
                            else -> result.notImplemented()
                        }
                    } catch (error: SecurityException) {
                        result.error("permission_denied", "Weight read access was removed", null)
                    } catch (error: Exception) {
                        if (permissionResult === result) permissionResult = null
                        result.error("weight_import_failed", error.message, null)
                    }
                }
            }
        }
    }

    @OptIn(ExperimentalFeatureAvailabilityApi::class)
    private suspend fun status(context: Context): Map<String, Boolean> {
        if (HealthConnectClient.getSdkStatus(context) != HealthConnectClient.SDK_AVAILABLE) {
            return mapOf("available" to false)
        }
        val client = HealthConnectClient.getOrCreate(context)
        val granted = client.permissionController.getGrantedPermissions()
        fun feature(id: Int) = client.features.getFeatureStatus(id) == HealthConnectFeatures.FEATURE_STATUS_AVAILABLE
        return mapOf("available" to true, "weightGranted" to (READ in granted),
            "backgroundAvailable" to feature(HealthConnectFeatures.FEATURE_READ_HEALTH_DATA_IN_BACKGROUND),
            "historyAvailable" to feature(HealthConnectFeatures.FEATURE_READ_HEALTH_DATA_HISTORY),
            "backgroundGranted" to (BACKGROUND in granted), "historyGranted" to (HISTORY in granted))
    }

    private fun row(context: Context, record: WeightRecord): Map<String, Any> {
        val origin = record.metadata.dataOrigin.packageName
        val label = try {
            context.packageManager.getApplicationLabel(context.packageManager.getApplicationInfo(origin, 0)).toString()
        } catch (_: Exception) { origin }
        return mapOf("record_id" to record.metadata.id, "time_ms" to record.time.toEpochMilli(),
            "kg" to record.weight.inKilograms, "source" to label, "source_id" to origin)
    }

    private suspend fun read(context: Context, oldToken: String?): Map<String, Any> {
        val client = HealthConnectClient.getOrCreate(context)
        val granted = client.permissionController.getGrantedPermissions()
        if (READ !in granted) throw SecurityException("Missing weight access")
        val history = HISTORY in granted
        val records = ArrayList<Map<String, Any>>()
        val deleted = ArrayList<String>()
        // Bounded work, on native IO. Never return a partial snapshot: replacing
        // the old window with a truncated read would invent source deletions.
        if (oldToken.isNullOrEmpty()) {
            val token = client.getChangesToken(ChangesTokenRequest(setOf(WeightRecord::class)))
            val end = Instant.now()
            val start = if (history) Instant.EPOCH else end.minus(Duration.ofDays(30))
            var page: String? = null
            var pages = 0
            do {
                val response = client.readRecords(ReadRecordsRequest(WeightRecord::class,
                    TimeRangeFilter.between(start, end), pageSize = 500, pageToken = page))
                records.addAll(response.records.map { row(context, it) })
                page = response.pageToken
                check(++pages <= 100 && records.size <= 20_000) { "Weight history is too large for one import" }
            } while (!page.isNullOrEmpty())
            val after = client.permissionController.getGrantedPermissions()
            requireStableWeightSnapshotAccess(READ in after, HISTORY in after, history)
            return mapOf("records" to records, "deleted" to deleted, "token" to token,
                "historyGranted" to history, "snapshotStartMs" to start.toEpochMilli(), "snapshotEndMs" to end.toEpochMilli())
        }
        var token = oldToken
        var pages = 0
        do {
            val response = try { client.getChanges(token!!) }
                catch (_: IllegalArgumentException) { return mapOf("expired" to true) }
            if (response.changesTokenExpired) return mapOf("expired" to true)
            for (change in response.changes) {
                when (change) {
                    is UpsertionChange -> (change.record as? WeightRecord)?.let {
                        // Keep change order: a later deletion must win over an
                        // earlier upsert, and an edited record replaces by id.
                        val id = it.metadata.id
                        records.removeAll { r -> r["record_id"] == id }
                        deleted.removeAll { it == id }
                        records.add(row(context, it))
                    }
                    is DeletionChange -> {
                        records.removeAll { it["record_id"] == change.recordId }
                        deleted.add(change.recordId)
                    }
                }
            }
            token = response.nextChangesToken
            check(++pages <= 100 && records.size + deleted.size <= 20_000) { "Too many weight changes" }
        } while (response.hasMore)
        if (READ !in client.permissionController.getGrantedPermissions()) throw SecurityException()
        return mapOf("records" to records, "deleted" to deleted, "token" to token,
            "historyGranted" to history)
    }

    suspend fun runBackground(context: Context): Boolean {
        if (!context.getSharedPreferences("edge_weight_import", Context.MODE_PRIVATE).getBoolean("enabled", false)) return true
        val state = status(context)
        if (state["weightGranted"] != true || state["backgroundGranted"] != true) return true
        return withTimeout(120_000) {
            withContext(Dispatchers.Main) { EdgeApplication.ensureEngine(context) }
            while (!dartReady) delay(250)
            withContext(Dispatchers.Main) {
                suspendCancellableCoroutine { continuation ->
                    channel?.invokeMethod("backgroundImport", null, object : MethodChannel.Result {
                        override fun success(result: Any?) { if (continuation.isActive) continuation.resume(result == true) }
                        override fun error(code: String, message: String?, details: Any?) { if (continuation.isActive) continuation.resume(false) }
                        override fun notImplemented() { if (continuation.isActive) continuation.resume(false) }
                    }) ?: continuation.resume(false)
                }
            }
        }
    }
}

class WeightImportWorker(context: Context, parameters: WorkerParameters) : CoroutineWorker(context, parameters) {
    override suspend fun doWork(): Result = try {
        if (WeightImportBridge.runBackground(applicationContext)) Result.success() else Result.retry()
    } catch (_: Exception) { Result.retry() }
}
