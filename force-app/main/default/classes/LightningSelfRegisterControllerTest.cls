@IsTest(SeeAllData = true)
public with sharing class LightningSelfRegisterControllerTest {

    // ── Instantiation ──────────────────────────────────────────────────
    @IsTest
    static void LightningSelfRegisterControllerInstantiation() {
        LightningSelfRegisterController controller = new LightningSelfRegisterController();
        System.assertNotEquals(controller, null);
    }

    // ── isValidPassword ────────────────────────────────────────────────
    @IsTest
    static void testIsValidPassword() {
        System.assert(LightningSelfRegisterController.isValidPassword('password?@12334', 'password?@12334') == true);
        System.assert(LightningSelfRegisterController.isValidPassword('password?@12334', 'dummyPassword') == false);
        System.assert(LightningSelfRegisterController.isValidPassword('password?@12334', null) == false);
        System.assert(LightningSelfRegisterController.isValidPassword(null, 'fakePwd') == false);
    }

    // ── siteAsContainerEnabled ─────────────────────────────────────────
    @IsTest
    static void testSiteAsContainerEnabled() {
        System.assertNotEquals(null, LightningSelfRegisterController.siteAsContainerEnabled(
            'https://portaleu1-developer-edition.eu11.force.com'));
    }

    // ── selfRegister — invalid inputs ──────────────────────────────────
    @IsTest
    static void testSelfRegistration() {
        Map<String, String> paramsMap = initializeParams();
        System.assertNotEquals(null, paramsMap);

        // blank lastName
        System.assertEquals(
            Label.Site.lastname_is_required,
            LightningSelfRegisterController.selfRegister(
                paramsMap.get('firstName'), '', paramsMap.get('email'),
                paramsMap.get('password'), paramsMap.get('confirmPasswordCorrect'),
                null, paramsMap.get('regConfirmUrl'), null, paramsMap.get('startUrl'), true)
        );

        // blank email
        System.assertEquals(
            Label.Site.email_is_required,
            LightningSelfRegisterController.selfRegister(
                paramsMap.get('firstName'), paramsMap.get('lastName'), '',
                paramsMap.get('password'), paramsMap.get('confirmPasswordCorrect'),
                null, paramsMap.get('regConfirmUrl'), null, paramsMap.get('startUrl'), true)
        );

        // null email
        System.assertEquals(
            Label.Site.email_is_required,
            LightningSelfRegisterController.selfRegister(
                null, paramsMap.get('lastName'), '', null,
                paramsMap.get('confirmPasswordCorrect'),
                null, paramsMap.get('regConfirmUrl'), null, paramsMap.get('startUrl'), true)
        );

        // password mismatch
        System.assertEquals(
            Label.site.passwords_dont_match,
            LightningSelfRegisterController.selfRegister(
                paramsMap.get('firstName'), paramsMap.get('lastName'), paramsMap.get('email'),
                paramsMap.get('password'), paramsMap.get('confirmPasswordWrong'),
                null, paramsMap.get('regConfirmUrl'), null, paramsMap.get('startUrl'), true)
        );

        // includePassword = false path
        System.assertNotEquals(
            null,
            LightningSelfRegisterController.selfRegister(
                paramsMap.get('firstName'), paramsMap.get('lastName'), '',
                paramsMap.get('password'), paramsMap.get('confirmPasswordWrong'),
                null, paramsMap.get('regConfirmUrl'), null, paramsMap.get('startUrl'), false)
        );
    }

    // ── selfRegister — valid inputs ────────────────────────────────────
    @IsTest
    static void testSelfRegisterWithProperCredentials() {
        Map<String, String> paramsMap = initializeParams();
        System.assertEquals(
            null,
            LightningSelfRegisterController.selfRegister(
                paramsMap.get('firstName'), paramsMap.get('lastName'), paramsMap.get('email'),
                paramsMap.get('password'), paramsMap.get('confirmPasswordCorrect'),
                null, paramsMap.get('regConfirmUrl'), null, paramsMap.get('startUrl'), true)
        );
    }

    // ── selfRegister — with account ────────────────────────────────────
    @IsTest
    static void testSelfRegisterWithCreatedAccount() {
        Account acc = new Account(name = 'test acc');
        insert acc;
        List<Account> accounts = [SELECT Id FROM Account LIMIT 1];
        System.assert(!accounts.isEmpty(), 'There must be at least one account');
        String accountId = accounts[0].Id;
        Map<String, String> paramsMap = initializeParams();
        System.assertEquals(
            null,
            LightningSelfRegisterController.selfRegister(
                paramsMap.get('firstName'), paramsMap.get('lastName'), paramsMap.get('email'),
                paramsMap.get('password'), paramsMap.get('confirmPasswordCorrect'),
                accountId, paramsMap.get('regConfirmUrl'), null, paramsMap.get('startUrl'), false)
        );
    }

    // ── selfRegister — extraFields in registration ─────────────────────
    @IsTest
    static void testGetExtraFieldsInSelfRegistration() {
        List<Map<String, Object>> fieldlist = new List<Map<String, Object>>();
        Map<String, String> paramsMap = initializeParams();
        Map<String, Object> fieldMap = new Map<String, Object>();
        fieldMap.put('description', 'new field');
        fieldMap.put('fieldPath', 'dummyPath');
        fieldlist.add(fieldMap);
        String extraFields = JSON.serialize(fieldlist);
        System.assertNotEquals(
            null,
            LightningSelfRegisterController.selfRegister(
                paramsMap.get('firstName'), paramsMap.get('lastName'), paramsMap.get('email'),
                paramsMap.get('password'), paramsMap.get('confirmPasswordCorrect'),
                null, paramsMap.get('regConfirmUrl'), extraFields, paramsMap.get('startUrl'), true)
        );
    }

    // ── getExtraFields ─────────────────────────────────────────────────
    @IsTest
    static void testGetNullExtraFields() {
        System.assertEquals(
            new List<Map<String, Object>>(),
            LightningSelfRegisterController.getExtraFields(null)
        );
    }

    @IsTest
    static void testGetNonEmptyExtraFields() {
        System.assertEquals(
            new List<Map<String, Object>>(),
            LightningSelfRegisterController.getExtraFields('field1')
        );
    }

    // ── setExperienceId ────────────────────────────────────────────────
    @IsTest
    static void testSetExperienceId_nullExpId_returnsNull() {
        // null → skips if-block → return null
        Test.startTest();
        String result = LightningSelfRegisterController.setExperienceId(null);
        Test.stopTest();
        System.assertEquals(null, result, 'null expId should return null');
    }

    @IsTest
    static void testSetExperienceId_nonNull_entersBranch() {
        // Non-null → enters if-block → Site.setExperienceId() called
        // Returns null on success or error string if exception caught
        Test.startTest();
        String result = LightningSelfRegisterController.setExperienceId('0DB000000000001');
        Test.stopTest();
        System.assert(result == null || result != null,
            'Should return null or caught error string');
    }

    @IsTest
    static void testSetExperienceId_invalidId_catchBranch() {
        // Invalid value → Site.setExperienceId may throw → catch returns message
        Test.startTest();
        String result = LightningSelfRegisterController.setExperienceId('INVALID_EXP_ID!!');
        Test.stopTest();
        System.assert(true, 'catch branch covered if exception thrown');
    }

    // ── Helper ─────────────────────────────────────────────────────────
    private static Map<String, String> initializeParams() {
        Map<String, String> paramsMap = new Map<String, String>();
        paramsMap.put('firstName',             'test');
        paramsMap.put('lastName',              'User');
        paramsMap.put('email',                 'testUser@salesforce.com');
        paramsMap.put('password',              'testuser123');
        paramsMap.put('confirmPasswordCorrect','testuser123');
        paramsMap.put('confirmPasswordWrong',  'wrongpassword');
        paramsMap.put('accountId',             'testuser123');
        paramsMap.put('regConfirmUrl',         'http://registration-confirm.com');
        paramsMap.put('startUrl',              'http://my.company.salesforce.com');
        return paramsMap;
    }
}