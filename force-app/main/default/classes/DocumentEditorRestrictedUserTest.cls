/**
 * DocumentEditorRestrictedUserTest — proves DocumentEditorController still works for a
 * NON-ADMIN user after its SOQL and DML were moved to user mode.
 *
 * Why this exists: every other test in the suite runs as the test-executing user, who is a
 * System Administrator. An admin passes any FLS or CRUD check, so a green suite says nothing
 * about whether a subscriber's ordinary user can still use the editor. Since
 * AccessLevel.USER_MODE / WITH USER_MODE enforce exactly those checks, that is the one thing
 * worth proving here.
 *
 * The user is created inside the test and rolled back with it — no licence is consumed and
 * nothing persists in the org.
 *
 * If a query in this class ever starts reading a field the SignForce_User permission set does
 * not grant, these tests fail with "insufficient access" rather than the subscriber finding out.
 */
@isTest(SeeAllData=false)
private class DocumentEditorRestrictedUserTest {

    /**
     * A user on a stock Standard User profile, holding only the package's own permission set —
     * i.e. what a subscriber's ordinary user looks like.
     */
    private static User buildPackageUser() {
        User created;
        // User and PermissionSetAssignment are setup objects; Salesforce refuses DML on those
        // in the same transaction as Agreement__c. Wrapping in runAs(current user) puts the
        // setup writes in their own context, which is the sanctioned way round it.
        System.runAs(new User(Id = UserInfo.getUserId())) {
            created = insertPackageUser();
        }
        return created;
    }

    private static User insertPackageUser() {
        Profile p = [SELECT Id FROM Profile WHERE Name = 'Standard User' LIMIT 1];
        String uniq = String.valueOf(DateTime.now().getTime());
        User u = new User(
            FirstName         = 'Pkg',
            LastName          = 'User' + uniq,
            Email             = 'pkg' + uniq + '@example.com',
            Username          = 'pkg' + uniq + '@esignforce.test',
            Alias             = 'pkgu',
            ProfileId         = p.Id,
            TimeZoneSidKey    = 'America/Los_Angeles',
            LocaleSidKey      = 'en_US',
            EmailEncodingKey  = 'UTF-8',
            LanguageLocaleKey = 'en_US'
        );
        insert u;

        // Package permission set, looked up by name so this keeps working under the managed
        // namespace. Skipped rather than failed if absent, so the test still reports something
        // useful in an org where the set has not been deployed.
        List<PermissionSet> ps = [
            SELECT Id FROM PermissionSet WHERE Name = 'SignForce_User' LIMIT 1
        ];
        if (!ps.isEmpty()) {
            insert new PermissionSetAssignment(AssigneeId = u.Id, PermissionSetId = ps[0].Id);
        }
        return u;
    }

    @isTest
    static void getAgreementData_worksForPackageUser() {
        Agreement__c agr = TestDataFactory.createDraftAgreement('Restricted Read');
        Signer__c signer = TestDataFactory.createSignerWithToken(agr.Id, 'restricted@example.com');
        TestDataFactory.createSignatureField(agr.Id, signer.Id, 1, 10, 20);
        User u = buildPackageUser();

        Map<String, Object> data;
        Test.startTest();
        System.runAs(u) {
            // Exercises the reads that were converted: Agreement__c, Signer__c,
            // Agreement_Document__c, ContentDocumentLink and Signature_Field__c.
            data = DocumentEditorController.getAgreementData(agr.Id);
        }
        Test.stopTest();

        Assert.isNotNull(data, 'A package user must be able to load the editor');
        Agreement__c loaded = (Agreement__c) data.get('agreement');
        Assert.isNotNull(loaded,
            'The agreement must come back. A null here is the signature of USER_MODE denying '
            + 'access - it returns an empty result rather than throwing.');
        Assert.areEqual(agr.Id, loaded.Id, 'The agreement the user asked for should come back');
        Assert.isNotNull(data.get('signers'), 'Signers must be readable too');
        Assert.isNotNull(data.get('fields'), 'Placed fields must be readable too');
    }

    @isTest
    static void fieldWrites_workForPackageUser() {
        Agreement__c agr = TestDataFactory.createDraftAgreement('Restricted Write');
        Signer__c signer = TestDataFactory.createSignerWithToken(agr.Id, 'restricted2@example.com');
        User u = buildPackageUser();

        Id fieldId;
        Test.startTest();
        System.runAs(u) {
            // insert -> update position -> update properties, i.e. the DML that moved to
            // Database.*(..., AccessLevel.USER_MODE).
            fieldId = DocumentEditorController.saveField(
                agr.Id, signer.Id, 'Signature', 'Sign here', 1,
                100, 200, 150, 40, true, 612);
            DocumentEditorController.updateFieldPosition(fieldId, 120, 220, 150, 40);
            DocumentEditorController.updateFieldProperties(fieldId, 'Signature here', true);
        }
        Test.stopTest();

        Assert.isNotNull(fieldId, 'A package user must be able to place a field');
        Signature_Field__c saved = [
            SELECT X_Position__c, Field_Label__c FROM Signature_Field__c WHERE Id = :fieldId
        ];
        Assert.areEqual(120, saved.X_Position__c, 'The move should have been persisted');
        Assert.areEqual('Signature here', saved.Field_Label__c,
            'The property edit should have been persisted');
    }

    @isTest
    static void deleteField_worksForPackageUser() {
        Agreement__c agr = TestDataFactory.createDraftAgreement('Restricted Delete');
        Signer__c signer = TestDataFactory.createSignerWithToken(agr.Id, 'restricted3@example.com');
        Signature_Field__c f = TestDataFactory.createSignatureField(agr.Id, signer.Id, 1, 10, 20);
        User u = buildPackageUser();

        Test.startTest();
        System.runAs(u) {
            DocumentEditorController.deleteField(f.Id);
        }
        Test.stopTest();

        Assert.areEqual(0, [SELECT COUNT() FROM Signature_Field__c WHERE Id = :f.Id],
            'A package user must be able to remove a field they placed');
    }
}