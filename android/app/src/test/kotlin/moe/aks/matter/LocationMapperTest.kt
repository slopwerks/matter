package moe.aks.matter

import android.app.Application
import android.location.Location
import android.os.Bundle
import com.baseflow.geolocator.location.LocationMapper
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [31, 34], application = Application::class, manifest = Config.NONE)
class LocationMapperTest {
    @Test
    fun preservesNumericProviderExtrasAcrossAndroidBundleApis() {
        for (value in listOf<Number>(1.25, 1.25f, 12, 12L)) {
            val location = Location("test").apply {
                extras = Bundle().apply {
                    putSerializable("geolocator_verticalSpeed", value)
                    putSerializable("geolocator_verticalSpeedAccuracy", value)
                }
            }
            val position = LocationMapper.toHashMap(location)
            assertEquals(value.toDouble(), position["vertical_speed"])
            assertEquals(value.toDouble(), position["vertical_speed_accuracy"])
        }
    }

    @Test
    fun skipsInvalidExtrasAndUsesTheNextProviderKey() {
        val location = Location("test").apply {
            extras = Bundle().apply {
                putString("geolocator_verticalSpeed", "invalid")
                putDouble("vertical_speed", Double.NaN)
                putDouble("verticalSpeed", Double.POSITIVE_INFINITY)
                putFloat("vVel", -1.25f)
                putDouble("geolocator_verticalSpeedAccuracy", -1.0)
            }
        }
        val position = LocationMapper.toHashMap(location)
        assertEquals(-1.25, position["vertical_speed"])
        assertFalse(position.containsKey("vertical_speed_accuracy"))
    }
}
