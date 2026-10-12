@isTest
private class SignForceFLSTest {

    // ─── requireCreateable Tests ───────────────────────────────────────────────

    @isTest
    static void testRequireCreateable_PassesWhenCreateable() {
        // Standard users typically can create Agreements in test context
        // This should NOT throw when the object is createable
        Boolean exceptionThrown = false;
        try {
            Test.startTest();
            SignForceFLS.requireCreateable(Agreement__c.SObjectType);
            Test.stopTest();
        } catch (SignForceFLS.SignForceFLSException e) {
            exceptionThrown = true;
        }
        System.assertEquals(false, exceptionThrown, 'Should not throw when object is createable');
    }

    @isTest
    static void testRequireCreateable_ThrowsWhenForceThrowEnabled() {
        SignForceFLS.forceThrowForTest = true;

        Boolean exceptionThrown = false;
        String exceptionMessage = '';

        try {
            Test.startTest();
            SignForceFLS.requireCreateable(Agreement__c.SObjectType);
            Test.stopTest();
        } catch (SignForceFLS.SignForceFLSException e) {
            exceptionThrown = true;
            exceptionMessage = e.getMessage();
        }

        System.assertEquals(true, exceptionThrown, 'Should throw SignForceFLSException');
        System.assert(exceptionMessage.contains('create'), 'Message should mention create action');
        System.assert(exceptionMessage.contains('Contact your administrator'), 
            'Message should contain admin contact suggestion');

        // Reset flag
        SignForceFLS.forceThrowForTest = false;
    }

    // ─── requireUpdateable Tests ───────────────────────────────────────────────

    @isTest
    static void testRequireUpdateable_PassesWhenUpdateable() {
        Boolean exceptionThrown = false;
        try {
            Test.startTest();
            SignForceFLS.requireUpdateable(Agreement__c.SObjectType);
            Test.stopTest();
        } catch (SignForceFLS.SignForceFLSException e) {
            exceptionThrown = true;
        }
        System.assertEquals(false, exceptionThrown, 'Should not throw when object is updateable');
    }

    @isTest
    static void testRequireUpdateable_ThrowsForNonUpdateable() {
        // Use a read-only system object to simulate non-updateable
        Boolean exceptionThrown = false;
        try {
            Test.startTest();
            // EntityDefinition is read-only — isUpdateable() returns false
            SignForceFLS.requireUpdateable(EntityDefinition.SObjectType);
            Test.stopTest();
        } catch (SignForceFLS.SignForceFLSException e) {
            exceptionThrown = true;
            System.assert(e.getMessage().contains('update'), 'Message should mention update action');
        }
        System.assertEquals(true, exceptionThrown, 'Should throw for non-updateable object');
    }

    // ─── requireDeletable Tests ────────────────────────────────────────────────

    @isTest
    static void testRequireDeletable_PassesWhenDeletable() {
        Boolean exceptionThrown = false;
        try {
            Test.startTest();
            SignForceFLS.requireDeletable(Agreement__c.SObjectType);
            Test.stopTest();
        } catch (SignForceFLS.SignForceFLSException e) {
            exceptionThrown = true;
        }
        System.assertEquals(false, exceptionThrown, 'Should not throw when object is deletable');
    }

    @isTest
    static void testRequireDeletable_ThrowsForNonDeletable() {
        Boolean exceptionThrown = false;
        try {
            Test.startTest();
            SignForceFLS.requireDeletable(EntityDefinition.SObjectType);
            Test.stopTest();
        } catch (SignForceFLS.SignForceFLSException e) {
            exceptionThrown = true;
            System.assert(e.getMessage().contains('delete'), 'Message should mention delete action');
        }
        System.assertEquals(true, exceptionThrown, 'Should throw for non-deletable object');
    }

    // ─── requireAccessible Tests ───────────────────────────────────────────────

    @isTest
    static void testRequireAccessible_PassesWhenAccessible() {
        Boolean exceptionThrown = false;
        try {
            Test.startTest();
            SignForceFLS.requireAccessible(Agreement__c.SObjectType);
            Test.stopTest();
        } catch (SignForceFLS.SignForceFLSException e) {
            exceptionThrown = true;
        }
        System.assertEquals(false, exceptionThrown, 'Should not throw when object is accessible');
    }

    // ─── stripInaccessibleForCreate Tests ─────────────────────────────────────

    @isTest
    static void testStripInaccessibleForCreate_ReturnsRecords() {
        List<Agreement__c> agreements = new List<Agreement__c>{
            new Agreement__c(Name = 'Agr 1'),
            new Agreement__c(Name = 'Agr 2')
        };

        Test.startTest();
        List<SObject> result = SignForceFLS.stripInaccessibleForCreate(agreements);
        Test.stopTest();

        System.assertNotEquals(null, result, 'Result should not be null');
        System.assertEquals(2, result.size(), 'Both records should be returned');
    }

    @isTest
    static void testStripInaccessibleForCreate_HandlesNullInput() {
        Test.startTest();
        List<SObject> result = SignForceFLS.stripInaccessibleForCreate(null);
        Test.stopTest();

        System.assertEquals(null, result, 'Should return null for null input');
    }

    @isTest
    static void testStripInaccessibleForCreate_HandlesEmptyList() {
        Test.startTest();
        List<SObject> result = SignForceFLS.stripInaccessibleForCreate(new List<Agreement__c>());
        Test.stopTest();

        System.assertNotEquals(null, result, 'Result should not be null');
        System.assertEquals(0, result.size(), 'Should return empty list');
    }

    // ─── stripInaccessibleForUpdate Tests ─────────────────────────────────────

    @isTest
    static void testStripInaccessibleForUpdate_ReturnsRecords() {
        Agreement__c agr = new Agreement__c(Name = 'Test Agr');
        insert agr;

        List<Agreement__c> agreements = [SELECT Id, Name FROM Agreement__c WHERE Id = :agr.Id];

        Test.startTest();
        List<SObject> result = SignForceFLS.stripInaccessibleForUpdate(agreements);
        Test.stopTest();

        System.assertNotEquals(null, result, 'Result should not be null');
        System.assertEquals(1, result.size(), 'One record should be returned');
    }

    @isTest
    static void testStripInaccessibleForUpdate_HandlesNullInput() {
        Test.startTest();
        List<SObject> result = SignForceFLS.stripInaccessibleForUpdate(null);
        Test.stopTest();

        System.assertEquals(null, result, 'Should return null for null input');
    }

    @isTest
    static void testStripInaccessibleForUpdate_HandlesEmptyList() {
        Test.startTest();
        List<SObject> result = SignForceFLS.stripInaccessibleForUpdate(new List<Agreement__c>());
        Test.stopTest();

        System.assertEquals(0, result.size(), 'Should return empty list');
    }

    // ─── stripInaccessibleForRead Tests ───────────────────────────────────────

    @isTest
    static void testStripInaccessibleForRead_ReturnsRecords() {
        Agreement__c agr = new Agreement__c(Name = 'Read Test Agr');
        insert agr;

        List<Agreement__c> agreements = [SELECT Id, Name FROM Agreement__c WHERE Id = :agr.Id];

        Test.startTest();
        List<SObject> result = SignForceFLS.stripInaccessibleForRead(agreements);
        Test.stopTest();

        System.assertNotEquals(null, result, 'Result should not be null');
        System.assertEquals(1, result.size(), 'One record should be returned');
    }

    @isTest
    static void testStripInaccessibleForRead_HandlesNullInput() {
        Test.startTest();
        List<SObject> result = SignForceFLS.stripInaccessibleForRead(null);
        Test.stopTest();

        System.assertEquals(null, result, 'Should return null for null input');
    }

    @isTest
    static void testStripInaccessibleForRead_HandlesEmptyList() {
        Test.startTest();
        List<SObject> result = SignForceFLS.stripInaccessibleForRead(new List<Agreement__c>());
        Test.stopTest();

        System.assertEquals(0, result.size(), 'Should return empty list');
    }

    // ─── Exception Message Tests ───────────────────────────────────────────────

    @isTest
    static void testExceptionMessage_ContainsObjectLabelAndAction() {
        SignForceFLS.forceThrowForTest = true;

        String exceptionMessage = '';
        try {
            Test.startTest();
            SignForceFLS.requireCreateable(Agreement__c.SObjectType);
            Test.stopTest();
        } catch (SignForceFLS.SignForceFLSException e) {
            exceptionMessage = e.getMessage();
        }

        // Verify message structure
        System.assert(String.isNotBlank(exceptionMessage), 'Exception message should not be blank');
        System.assert(exceptionMessage.contains('create'), 'Should contain action name');
        System.assert(exceptionMessage.contains('Contact your administrator'), 
            'Should contain admin contact instruction');

        SignForceFLS.forceThrowForTest = false;
    }

    @isTest
    static void testSignForceFLSException_IsCorrectType() {
        SignForceFLS.forceThrowForTest = true;

        Exception caughtEx = null;
        try {
            Test.startTest();
            SignForceFLS.requireCreateable(Agreement__c.SObjectType);
            Test.stopTest();
        } catch (SignForceFLS.SignForceFLSException e) {
            caughtEx = e;
        }

        System.assertNotEquals(null, caughtEx, 'Exception should have been thrown');
        System.assert(caughtEx instanceof SignForceFLS.SignForceFLSException,
            'Thrown exception should be of type SignForceFLSException');

        SignForceFLS.forceThrowForTest = false;
    }
}