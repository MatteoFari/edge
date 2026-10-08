package wtf.openstrap.openstrap_edge

import org.junit.Assert.assertEquals
import org.junit.Test

class EdgeTrackingLocalizationTest {
    @Test
    fun savedAppLanguageWinsOverSystemLanguage() {
        assertEquals("it", trackingLanguage("it", listOf("en")))
        assertEquals("en", trackingLanguage("en", listOf("it")))
        assertEquals("fr", trackingLanguage("fr", listOf("it")))
    }

    @Test
    fun systemDefaultUsesFirstAppSupportedLanguage() {
        assertEquals("it", trackingLanguage(null, listOf("it", "en")))
        assertEquals("it", trackingLanguage(null, listOf("ja", "it")))
        assertEquals("en", trackingLanguage(null, listOf("en", "it")))
        assertEquals("en", trackingLanguage(null, listOf("ja")))
    }

    @Test
    fun staleOverrideFollowsSystemWithoutChangingPreferences() {
        assertEquals("it", trackingLanguage("unsupported", listOf("it")))
        assertEquals("en", trackingLanguage("", emptyList()))
    }
}
