package moe.aks.matter

import android.app.Application
import android.util.Log
import com.google.firebase.FirebaseApp
import com.google.firebase.FirebaseOptions
import org.json.JSONObject

/** Initialize the selected project before activities or background FCM services.
 * SharedPreferences' legacy Flutter API stores strings in this file/prefix.
 */
class PushFirebaseApplication : Application() {
    override fun onCreate() {
        super.onCreate()
        try {
            val raw =
                getSharedPreferences("FlutterSharedPreferences", MODE_PRIVATE)
                    .getString("flutter.fcm_firebase_options", null)
            val options =
                if (raw == null) {
                    FirebaseOptions.fromResource(this)
                } else {
                    val config = JSONObject(raw)
                    FirebaseOptions
                        .Builder()
                        .setApiKey(config.getString("api_key"))
                        .setApplicationId(config.getString("app_id"))
                        .setGcmSenderId(config.getString("sender_id"))
                        .setProjectId(config.getString("project_id"))
                        .build()
                }
            if (options != null) FirebaseApp.initializeApp(this, options)
        } catch (error: org.json.JSONException) {
            Log.e("MatterPush", "Invalid saved Firebase client configuration")
        } catch (error: IllegalArgumentException) {
            Log.e("MatterPush", "Invalid Firebase client options")
        }
    }
}
