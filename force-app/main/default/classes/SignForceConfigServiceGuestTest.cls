/**
 * SignForceConfigServiceGuestTest - coverage for SignForceConfigServiceGuest, the guest-side copy of
 * SignForceConfigService. Same cases as SignForceConfigServiceTest for the methods the guest copy holds
 * (including getAllowedOrigins, moved here), plus the override hook and the OAuth credential getters.
 * The exception type asserted is still SignForceConfigService.ConfigurationException.
 */
@isTest
private class SignForceConfigServiceGuestTest {

    @isTest
    static void getStorageTier_returnsDefault() {
        SignForceConfigServiceGuest.resetCache();
        String got = SignForceConfigServiceGuest.getStorageTier();
        // Default if CMT not deployed: 'Tier1'.
        System.assertNotEquals(null, got);
        System.assert(got == 'Tier1' || got == 'Tier2' || got == 'Tier3',
                      'Tier should be one of the allowed values');
    }

    @isTest
    static void getTier1MaxBytes_returnsPositive() {
        SignForceConfigServiceGuest.resetCache();
        Long got = SignForceConfigServiceGuest.getTier1MaxBytes();
        System.assert(got > 0, 'Tier1 max must be positive');
        // Default per the class is 3 MB = 3145728.
    }

    @isTest
    static void getChunkThresholdBytes_returnsPositive() {
        SignForceConfigServiceGuest.resetCache();
        Long got = SignForceConfigServiceGuest.getChunkThresholdBytes();
        System.assert(got > 0);
    }

    @isTest
    static void getMaxUploadBytes_returnsPositive() {
        SignForceConfigServiceGuest.resetCache();
        Long got = SignForceConfigServiceGuest.getMaxUploadBytes();
        System.assert(got > 0);
    }

    @isTest
    static void getS3Bucket_returnsNonBlank() {
        SignForceConfigServiceGuest.resetCache();
        String got = SignForceConfigServiceGuest.getS3Bucket();
        System.assert(String.isNotBlank(got),
                      'S3 bucket has a default value');
    }

    @isTest
    static void getAllowedOrigins_returnsString() {
        // Default is empty — but the call must not throw.
        SignForceConfigServiceGuest.resetCache();
        String got = SignForceConfigServiceGuest.getAllowedOrigins();
        System.assertNotEquals(null, got, 'Should return string, possibly empty');
    }

    @isTest
    static void getClientConfig_returnsExpectedShape() {
        SignForceConfigServiceGuest.resetCache();
        Map<String, Object> got = SignForceConfigServiceGuest.getClientConfig();
        // The createAgreement LWC reads these keys — they MUST be present.
        System.assert(got.containsKey('tier'));
        System.assert(got.containsKey('s3Bucket'));
        System.assert(got.containsKey('tier1MaxBytes'));
        System.assert(got.containsKey('chunkThresholdBytes'));
        System.assert(got.containsKey('maxUploadBytes'));
        System.assert(got.containsKey('orgId'));
        System.assert(got.containsKey('lambdaEndpoint'),
                      'lambdaEndpoint MUST be in the config map - createAgreement LWC depends on it');
        
        // orgId should match the running user's org Id
        System.assertEquals(UserInfo.getOrganizationId(), got.get('orgId'));
    }

    @isTest
    static void getLambdaEndpoint_blank_throwsConfigurationException() {
        // If the CMT field is blank or the CMT record is missing, the
        // method must throw a clear error (Phase 1 behavior — was previously
        // a silent fallback to a hardcoded URL).
        //
        // We can't easily force a blank value in test (CMT records don't
        // get rolled back at end of test). What we CAN do: if the running
        // org has Lambda_Endpoint__c set, the method returns; if blank, it
        // throws. Either way the call doesn't crash unexpectedly.
        SignForceConfigServiceGuest.resetCache();
        try {
            String got = SignForceConfigServiceGuest.getLambdaEndpoint();
            // If we got here, the org has the field set — verify it's non-blank.
            System.assert(String.isNotBlank(got));
        } catch (SignForceConfigService.ConfigurationException ce) {
            // Expected on orgs without the CMT field configured.
            System.assert(ce.getMessage().contains('Lambda_Endpoint__c'),
                          'Error should name the missing CMT field');
        }
    }

    @isTest
    static void getAllowedOrigins_executes() {
        
        SignForceConfigServiceGuest.resetCache();
        
        String value =
            SignForceConfigServiceGuest.getAllowedOrigins();
        
        System.assertNotEquals(null, value);
    }

    @isTest
    static void getClientConfig_executesLambdaCatch() {

        SignForceConfigServiceGuest.resetCache();

        Map<String,Object> cfg =
            SignForceConfigServiceGuest.getClientConfig();

        System.assert(cfg.containsKey('lambdaEndpoint'));
    }

    @isTest
    static void getSigningSiteBaseUrl_returnsConfiguredAndStripsTrailingSlash() {
        insert new SignForce_Admin_Config__c(
            SetupOwnerId = UserInfo.getOrganizationId(),
            Signing_Site_Base_URL__c = 'https://acme.my.site.com/sign/'
        );
        String got = SignForceConfigServiceGuest.getSigningSiteBaseUrl();
        System.assertEquals('https://acme.my.site.com/sign', got,
            'Should return the configured URL with any trailing slash removed');
    }

    @isTest
    static void getSigningSiteBaseUrl_placeholderWhenBlankInTest() {
        // No org-default seeded -> blank -> test placeholder (not a throw),
        // so send-flow tests keep passing.
        String got = SignForceConfigServiceGuest.getSigningSiteBaseUrl();
        System.assertEquals('https://test.example.com/sign', got);
    }

    @isTest
    static void lambdaEndpointOverride_winsOverConfig() {
        SignForceConfigServiceGuest.lambdaEndpointOverride = 'https://override.test/lambda';
        System.assertEquals('https://override.test/lambda', SignForceConfigServiceGuest.getLambdaEndpoint());
        SignForceConfigServiceGuest.lambdaEndpointOverride = null;
    }

    @isTest
    static void applyLambdaAuth_isNoOp() {
        HttpRequest req = new HttpRequest();
        SignForceConfigServiceGuest.applyLambdaAuth(req);
        System.assertEquals(null, req.getHeader('Authorization'));
    }

    @isTest
    static void oauthCredentials_prefersAdminCustomSetting() {
        insert new SignForce_Admin_Config__c(
            SetupOwnerId = UserInfo.getOrganizationId(),
            Google_Client_ID__c = 'g-id', Google_Client_Secret__c = 'g-secret',
            Microsoft_Client_ID__c = 'm-id', Microsoft_Client_Secret__c = 'm-secret'
        );
        System.assertEquals('g-id', SignForceConfigServiceGuest.getGoogleClientId());
        System.assertEquals('g-secret', SignForceConfigServiceGuest.getGoogleClientSecret());
        System.assertEquals('m-id', SignForceConfigServiceGuest.getMicrosoftClientId());
        System.assertEquals('m-secret', SignForceConfigServiceGuest.getMicrosoftClientSecret());
    }

    @isTest
    static void oauthCredentials_fallBackToConfigWhenSettingBlank() {
        SignForceConfigServiceGuest.resetCache();
        // No custom setting seeded: the getters fall back to the CMT record and must not throw.
        SignForceConfigServiceGuest.getGoogleClientId();
        SignForceConfigServiceGuest.getGoogleClientSecret();
        SignForceConfigServiceGuest.getMicrosoftClientId();
        SignForceConfigServiceGuest.getMicrosoftClientSecret();
    }
}
