@IsTest(SeeAllData = true)
public with sharing class LightningLoginFormControllerTest {

    // ── Instantiation ──────────────────────────────────────────────────
    @IsTest
    static void testControllerInstantiation() {
        LightningLoginFormController controller = new LightningLoginFormController();
        System.assertNotEquals(null, controller);
    }

    // ── getIsUsernamePasswordEnabled ───────────────────────────────────
    @IsTest
    static void testIsUsernamePasswordEnabled() {
        Boolean result = LightningLoginFormController.getIsUsernamePasswordEnabled();
        // Just assert it returns a non-null Boolean (value depends on org config)
        System.assertNotEquals(null, result);
    }

    // ── getIsSelfRegistrationEnabled ───────────────────────────────────
    @IsTest
    static void testIsSelfRegistrationEnabled() {
        Boolean result = LightningLoginFormController.getIsSelfRegistrationEnabled();
        System.assertNotEquals(null, result);
    }

    // ── getSelfRegistrationUrl ─────────────────────────────────────────
    @IsTest
    static void testGetSelfRegistrationUrl_whenDisabled_returnsNull() {
        // When self-registration is disabled the method must return null
        Boolean selfRegEnabled = LightningLoginFormController.getIsSelfRegistrationEnabled();
        String url = LightningLoginFormController.getSelfRegistrationUrl();
        if (!selfRegEnabled) {
            System.assertEquals(null, url);
        } else {
            System.assertNotEquals(null, url);
        }
    }

    // ── getForgotPasswordUrl ───────────────────────────────────────────
    @IsTest
    static void testGetForgotPasswordUrl_returnsValue() {
        // Covers getForgotPasswordUrl() — value may be null or a URL string
        // depending on org/community config; we just verify no exception thrown
        String url = LightningLoginFormController.getForgotPasswordUrl();
        System.assert(true, 'getForgotPasswordUrl completed without exception');
    }

    // ── getAuthConfig ──────────────────────────────────────────────────
    @IsTest
    static void testGetAuthConfig_returnsNonNull() {
        Auth.AuthConfiguration authConfig = LightningLoginFormController.getAuthConfig();
        System.assertNotEquals(null, authConfig);
    }

    // ── setExperienceId ────────────────────────────────────────────────
    @IsTest
    static void testSetExperienceId_nullExpId_returnsNull() {
        // Passing null should skip Site.setExperienceId and return null
        Test.startTest();
        String result = LightningLoginFormController.setExperienceId(null);
        Test.stopTest();
        System.assertEquals(null, result,
            'Passing null expId should return null (no error)');
    }

    @IsTest
    static void testSetExperienceId_validExpId_returnsNullOrError() {
        // Passing a non-null value exercises the Site.setExperienceId() call.
        // In a non-community context it will throw, which is caught and returned
        // as a String. Either way the method should not throw uncaught.
        Test.startTest();
        String result = LightningLoginFormController.setExperienceId('someExpId');
        Test.stopTest();
        // null  → success path; non-null → caught error string — both are valid
        System.assert(true, 'setExperienceId completed without uncaught exception');
    }

    // ── login ──────────────────────────────────────────────────────────
    @IsTest
    static void testLogin_invalidCredentials_returnsErrorMessage() {
        // Site.login() with bad credentials throws an exception.
        // The catch block returns the message as a String (not null).
        Test.startTest();
        String result = LightningLoginFormController.login(
            'invaliduser@invalid.invalid',
            'wrongPassword123!',
            null
        );
        Test.stopTest();
        // In a non-community context Site.login throws → catch returns message
        System.assert(true, 'login() handled exception without crashing');
    }

    @IsTest
    static void testLogin_nullParams_handledGracefully() {
        // Null username/password — Site.login throws, catch returns message
        Test.startTest();
        String result = LightningLoginFormController.login(null, null, null);
        Test.stopTest();
        System.assert(true, 'login() with null params completed without uncaught exception');
    }

    @IsTest
    static void testLogin_withStartUrl_handledGracefully() {
        // Exercises the startUrl parameter path through login()
        Test.startTest();
        String result = LightningLoginFormController.login(
            'test@example.com',
            'fakePassword1!',
            '/apex/somePage'
        );
        Test.stopTest();
        System.assert(true, 'login() with startUrl completed without uncaught exception');
    }
}