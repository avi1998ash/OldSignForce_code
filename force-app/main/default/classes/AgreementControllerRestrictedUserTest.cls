/**
 * AgreementControllerRestrictedUserTest — proves the AgreementController methods whose SOQL
 * and DML were just moved to user mode still work for a NON-ADMIN user.
 *
 * Why this exists: every other test in the suite runs as the test-executing user, who is a
 * System Administrator. An admin passes every FLS, CRUD and sharing check, so a green suite
 * says nothing about whether a subscriber's ordinary user can still use the product. Since
 * WITH USER_MODE / AccessLevel.USER_MODE enforce exactly those checks, that is the one thing
 * worth proving here. Companion to DocumentEditorRestrictedUserTest and
 * ServiceLayerRestrictedUserTest, which did the same job for their classes.
 *
 * Scope — the converted internal entry points a real package user actually reaches from the
 * SignForce app pages: agreement reads (getMyAgreements / getAgreementDetail / getSigners /
 * getAuditTrail), agreement update, the signer lifecycle (addSigner / updateSigner /
 * deleteSigner), templates (saveAsTemplate / getTemplates / createFromTemplate), bulkSend,
 * startInPersonSigning, field conditions (updateFieldCondition / getFieldsWithConditions)
 * and searchExistingSigners.
 *
 * Deliberately NOT here: the stamping path (generateStampedPDFServerInternal / generateStampedPDFServerGuest and their helpers). It runs
 * in guest context and stays in system mode by design — its guardianship is
 * GuestSigningApiTest, not this class.
 *
 * The user is created inside the test and rolled back with it — no licence is consumed and
 * nothing persists in the org.
 *
 * If a converted statement ever starts touching a field or object the SignForce_User
 * permission set does not grant, these tests fail with an access error rather than the
 * subscriber finding out.
 */
@isTest(SeeAllData=false)
private class AgreementControllerRestrictedUserTest {

    // ═════════════════════════════════════════════════════════════════════
    //  The restricted user
    // ═════════════════════════════════════════════════════════════════════

    /**
     * A user on a stock Standard User profile, holding only the package's own permission set —
     * i.e. what a subscriber's ordinary user looks like.
     */
    private static User buildPackageUser() {
        return buildUser(true);
    }

    /**
     * The same user WITHOUT the package permission set. Used only by the control test
     * below, to prove these tests can actually fail.
     */
    private static User buildBareUser() {
        return buildUser(false);
    }

    private static User buildUser(Boolean withPermissionSet) {
        User created;
        // User and PermissionSetAssignment are setup objects; Salesforce refuses DML on those
        // in the same transaction as Agreement__c. Wrapping in runAs(current user) puts the
        // setup writes in their own context, which is the sanctioned way round it.
        System.runAs(new User(Id = UserInfo.getUserId())) {
            created = insertPackageUser(withPermissionSet);
        }
        return created;
    }

    private static User insertPackageUser(Boolean withPermissionSet) {
        Profile p = [SELECT Id FROM Profile WHERE Name = 'Standard User' LIMIT 1];
        String uniq = String.valueOf(DateTime.now().getTime()) + String.valueOf(Math.round(Math.random() * 100000));
        User u = new User(
            FirstName         = 'Agr',
            LastName          = 'User' + uniq,
            Email             = 'agr' + uniq + '@example.com',
            Username          = 'agr' + uniq + '@esignforce.test',
            Alias             = 'agru',
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
        if (withPermissionSet) {
            List<PermissionSet> ps = [
                SELECT Id FROM PermissionSet WHERE Name = 'SignForce_User' LIMIT 1
            ];
            if (!ps.isEmpty()) {
                insert new PermissionSetAssignment(AssigneeId = u.Id, PermissionSetId = ps[0].Id);
            }
        }
        return u;
    }

    // ═════════════════════════════════════════════════════════════════════
    //  Control — proves the other tests in this class can actually fail
    // ═════════════════════════════════════════════════════════════════════

    /**
     * A green restricted-user test is worthless unless the harness bites. This runs the same
     * converted read as agreementReads_workForPackageUser, as the same kind of Standard User,
     * with exactly one difference: no SignForce_User permission set. It must be refused.
     *
     * If this test ever starts passing silently — i.e. the call succeeds for a user with no
     * object access — then System.runAs or the user-mode enforcement has stopped working and
     * every other assertion in this class has quietly become a no-op.
     */
    @isTest
    static void control_withoutPermissionSet_accessIsRefused() {
        Agreement__c agr = TestDataFactory.createDraftAgreement('Agr Control');
        User bare = buildBareUser();

        Boolean refused = false;
        Test.startTest();
        System.runAs(bare) {
            try {
                AgreementController.getAgreementDetail(agr.Id);
            } catch (Exception e) {
                // Object-level denial under WITH USER_MODE raises rather than returning
                // an empty list — that distinction is the whole reason the audit was needed.
                refused = true;
            }
        }
        Test.stopTest();

        Assert.isTrue(refused,
            'A Standard User WITHOUT SignForce_User must be refused by WITH USER_MODE. '
            + 'This call succeeding means user-mode enforcement is not actually running under '
            + 'System.runAs, which would invalidate every other test in this class.');
    }

    // ═════════════════════════════════════════════════════════════════════
    //  Agreement reads
    // ═════════════════════════════════════════════════════════════════════

    @isTest
    static void agreementReads_workForPackageUser() {
        Agreement__c agr = TestDataFactory.createDraftAgreement('Restricted Agr Read');
        Signer__c signer = TestDataFactory.createSignerWithToken(agr.Id, 'agrread@example.com');
        // An audit row to read back — written as the admin so its insert cannot fail.
        AuditTrailService.log(agr.Id, 'Created', 'agrread@example.com', null, null);
        User u = buildPackageUser();

        List<Agreement__c> mine;
        Agreement__c detail;
        List<Signer__c> signers;
        List<Signing_Event__c> trail;
        Test.startTest();
        System.runAs(u) {
            mine    = AgreementController.getMyAgreements();
            detail  = AgreementController.getAgreementDetail(agr.Id);
            signers = AgreementController.getSigners(agr.Id);
            trail   = AgreementController.getAuditTrail(agr.Id);
        }
        Test.stopTest();

        // Under USER_MODE a sharing denial returns an EMPTY result rather than throwing,
        // so every assertion below checks the rows actually came back.
        Set<Id> mineIds = new Map<Id, Agreement__c>(mine).keySet();
        Assert.isTrue(mineIds.contains(agr.Id),
            'getMyAgreements must return the agreement to a package user. An empty result '
            + 'here is the signature of USER_MODE silently denying access.');
        Assert.areEqual(agr.Id, detail.Id, 'getAgreementDetail must return the record');
        Assert.areEqual(1, signers.size(), 'getSigners must see the signer');
        Assert.areEqual(signer.Id, signers[0].Id, 'and it must be the right signer');
        Assert.areEqual(1, trail.size(), 'getAuditTrail must see the audit row');
    }

    // ═════════════════════════════════════════════════════════════════════
    //  Agreement update
    // ═════════════════════════════════════════════════════════════════════

    @isTest
    static void updateAgreement_worksForPackageUser() {
        Agreement__c agr = TestDataFactory.createDraftAgreement('Restricted Agr Update');
        User u = buildPackageUser();
        DateTime expiry = DateTime.now().addDays(7);

        Test.startTest();
        System.runAs(u) {
            AgreementController.updateAgreement(
                agr.Id, 'Renamed by Package User', 'NDA', 'Sequential', 'Please sign', expiry);
        }
        Test.stopTest();

        Agreement__c saved = [
            SELECT Name, Message_to_Signers__c, Expiry_Date__c
            FROM Agreement__c WHERE Id = :agr.Id
        ];
        Assert.areEqual('Renamed by Package User', saved.Name,
            'The rename must have been persisted by the USER_MODE update');
        Assert.areEqual('Please sign', saved.Message_to_Signers__c,
            'The message must have been persisted');
        Assert.isNotNull(saved.Expiry_Date__c, 'The expiry must have been persisted');
    }

    // ═════════════════════════════════════════════════════════════════════
    //  Signer lifecycle — add, update, delete (with an assigned field)
    // ═════════════════════════════════════════════════════════════════════

    @isTest
    static void signerLifecycle_worksForPackageUser() {
        Agreement__c agr = TestDataFactory.createDraftAgreement('Restricted Signer Lifecycle');
        User u = buildPackageUser();

        Id signerId;
        Test.startTest();
        System.runAs(u) {
            signerId = AgreementController.addSigner(
                agr.Id, 'Life Cycle', 'lifecycle@example.com', 'Signer', 1);
            AgreementController.updateSigner(
                signerId, 'Life Cycle Jr', 'lifecycle2@example.com', 'Signer', 2);
            // A field assigned to the signer, so deleteSigner exercises its
            // USER_MODE field query + delete as well as the signer delete.
            TestDataFactory.createSignatureField(agr.Id, signerId, 1, 10, 20);
            AgreementController.deleteSigner(signerId);
        }
        Test.stopTest();

        Assert.isNotNull(signerId, 'A package user must be able to add a signer');
        Assert.areEqual(0, [SELECT COUNT() FROM Signer__c WHERE Id = :signerId],
            'The signer must have been deleted by the USER_MODE delete');
        Assert.areEqual(0, [SELECT COUNT() FROM Signature_Field__c WHERE Assigned_Signer__c = :signerId],
            'The assigned field must have been deleted with the signer');
    }

    // ═════════════════════════════════════════════════════════════════════
    //  Templates — save, list, instantiate
    // ═════════════════════════════════════════════════════════════════════

    @isTest
    static void templates_workForPackageUser() {
        Agreement__c agr = TestDataFactory.createDraftAgreement('Restricted Template Source');
        Signer__c signer = TestDataFactory.createSignerWithToken(agr.Id, 'tmpl@example.com');
        TestDataFactory.createSignatureField(agr.Id, signer.Id, 1, 100, 200);
        User u = buildPackageUser();

        Id templateId;
        List<Agreement__c> templates;
        Id newAgrId;
        Test.startTest();
        System.runAs(u) {
            templateId = AgreementController.saveAsTemplate(agr.Id, 'Restricted Tmpl');
            templates  = AgreementController.getTemplates();
            newAgrId   = AgreementController.createFromTemplate(templateId, 'From Restricted Tmpl');
        }
        Test.stopTest();

        Assert.isNotNull(templateId, 'A package user must be able to save a template');
        Set<Id> templateIds = new Map<Id, Agreement__c>(templates).keySet();
        Assert.isTrue(templateIds.contains(templateId),
            'getTemplates must list the template just saved. An empty result here is the '
            + 'signature of USER_MODE silently denying access.');
        Assert.isNotNull(newAgrId, 'A package user must be able to instantiate a template');
        Assert.areEqual(1, [SELECT COUNT() FROM Signer__c WHERE Agreement__c = :newAgrId],
            'The template signer must have been copied onto the new agreement');
        Assert.areEqual(1, [SELECT COUNT() FROM Signature_Field__c WHERE Agreement__c = :newAgrId],
            'The template field must have been copied onto the new agreement');
    }

    // ═════════════════════════════════════════════════════════════════════
    //  Document upload (Tier1 — the no-callout upload path)
    // ═════════════════════════════════════════════════════════════════════

    /**
     * uploadTier1Document is the document step of creating an agreement: it inserts
     * the ContentVersion, replaces any prior 'Original' Agreement_Document__c (a
     * USER_MODE delete) and inserts the new one. All of it now runs in user mode,
     * and none of it needs a callout — so it belongs in this proof. The second
     * upload matters as much as the first: it exercises the Draft-scoped delete of
     * the prior Original.
     */
    @isTest
    static void uploadTier1Document_worksForPackageUser() {
        Agreement__c agr = TestDataFactory.createDraftAgreement('Restricted Upload');
        User u = buildPackageUser();
        String pdfBase64 = EncodingUtil.base64Encode(Blob.valueOf('%PDF-1.4 restricted-upload-test'));

        Id firstDocId;
        Id secondDocId;
        Test.startTest();
        System.runAs(u) {
            firstDocId  = AgreementController.uploadTier1Document(agr.Id, 'First.pdf', pdfBase64, 31);
            // Second upload must replace the first Original, not duplicate it.
            secondDocId = AgreementController.uploadTier1Document(agr.Id, 'Second.pdf', pdfBase64, 31);
        }
        Test.stopTest();

        Assert.isNotNull(firstDocId, 'A package user must be able to upload a document');
        Assert.areEqual(0, [SELECT COUNT() FROM Agreement_Document__c WHERE Id = :firstDocId],
            'The first Original must have been deleted by the USER_MODE delete on re-upload');
        List<Agreement_Document__c> originals = [
            SELECT Id, Name, Content_Version_ID__c
            FROM Agreement_Document__c
            WHERE Agreement__c = :agr.Id AND Document_Type__c = 'Original'
        ];
        Assert.areEqual(1, originals.size(),
            'Exactly one Original must remain after the second upload');
        Assert.areEqual(secondDocId, originals[0].Id, 'and it must be the second one');
        Assert.areEqual('Second.pdf', originals[0].Name,
            'The surviving Original must be the re-uploaded file');
        Assert.isTrue(String.isNotBlank(originals[0].Content_Version_ID__c),
            'The USER_MODE ContentVersion insert must have produced a file id');
    }

    // ═════════════════════════════════════════════════════════════════════
    //  Bulk send
    // ═════════════════════════════════════════════════════════════════════

    @isTest
    static void bulkSend_worksForPackageUser() {
        Agreement__c agr = TestDataFactory.createDraftAgreement('Restricted Bulk Send');
        User u = buildPackageUser();
        String signersJson = JSON.serialize(new List<Map<String, Object>>{
            new Map<String, Object>{ 'name' => 'Bulk One', 'email' => 'bulk1@example.com', 'order' => 1 },
            new Map<String, Object>{ 'name' => 'Bulk Two', 'email' => 'bulk2@example.com', 'order' => 2 }
        });

        Map<String, Object> result;
        Test.startTest();
        System.runAs(u) {
            result = AgreementController.bulkSend(agr.Id, signersJson);
        }
        Test.stopTest();

        Assert.areEqual(2, (Integer) result.get('successCount'),
            'Both signers must have been accepted for a package user');
        Assert.areEqual(0, (Integer) result.get('failCount'), 'No row should have failed');
        Assert.areEqual(2, [SELECT COUNT() FROM Signer__c WHERE Agreement__c = :agr.Id],
            'Both signers must actually exist after the USER_MODE insert');
    }

    // ═════════════════════════════════════════════════════════════════════
    //  In-person signing
    // ═════════════════════════════════════════════════════════════════════

    @isTest
    static void startInPersonSigning_worksForPackageUser() {
        Agreement__c agr = TestDataFactory.createDraftAgreement('Restricted In-Person');
        Signer__c signer = TestDataFactory.createSignerWithToken(agr.Id, 'inperson@example.com');
        String oldToken = signer.Access_Token__c;
        User u = buildPackageUser();

        Map<String, Object> result;
        Test.startTest();
        System.runAs(u) {
            result = AgreementController.startInPersonSigning(signer.Id);
        }
        Test.stopTest();

        String newToken = (String) result.get('token');
        Assert.isTrue(String.isNotBlank(newToken), 'A signing token must come back');
        Assert.areNotEqual(oldToken, newToken,
            'The token must have been rotated — proof the USER_MODE update persisted');
        String url = (String) result.get('signingUrl');
        Assert.isTrue(url.contains(newToken), 'The signing URL must carry the new token');
        Signer__c saved = [SELECT Access_Token__c FROM Signer__c WHERE Id = :signer.Id];
        Assert.areEqual(newToken, saved.Access_Token__c,
            'The rotated token must be on the record, not just in the response');
    }

    // ═════════════════════════════════════════════════════════════════════
    //  Field conditions
    // ═════════════════════════════════════════════════════════════════════

    @isTest
    static void fieldConditions_workForPackageUser() {
        Agreement__c agr = TestDataFactory.createDraftAgreement('Restricted Conditions');
        Signer__c signer = TestDataFactory.createSignerWithToken(agr.Id, 'cond@example.com');
        Signature_Field__c controller = TestDataFactory.createSignatureField(agr.Id, signer.Id, 1, 10, 20);
        Signature_Field__c dependent  = TestDataFactory.createSignatureField(agr.Id, signer.Id, 1, 10, 120);
        User u = buildPackageUser();

        List<Map<String, Object>> fields;
        Test.startTest();
        System.runAs(u) {
            AgreementController.updateFieldCondition(
                dependent.Id, 'Show When', controller.Id, 'checked');
            fields = AgreementController.getFieldsWithConditions(signer.Id);
        }
        Test.stopTest();

        Assert.areEqual(2, fields.size(),
            'Both fields must be readable. Fewer is the signature of USER_MODE silently '
            + 'denying access.');
        Boolean foundCondition = false;
        for (Map<String, Object> f : fields) {
            if ((Id) f.get('Id') == dependent.Id) {
                Assert.areEqual('Show When', f.get('conditionType'),
                    'The condition written by the USER_MODE update must be read back');
                Assert.areEqual('checked', f.get('conditionValue'),
                    'The condition value must round-trip too');
                foundCondition = true;
            }
        }
        Assert.isTrue(foundCondition, 'The dependent field must be in the result');
    }

    // ═════════════════════════════════════════════════════════════════════
    //  Signer search
    // ═════════════════════════════════════════════════════════════════════

    @isTest
    static void searchExistingSigners_worksForPackageUser() {
        Agreement__c agr = TestDataFactory.createDraftAgreement('Restricted Search');
        TestDataFactory.createSignerWithToken(agr.Id, 'searchhit@example.com');
        User u = buildPackageUser();

        List<Map<String, Object>> results;
        Test.startTest();
        System.runAs(u) {
            results = AgreementController.searchExistingSigners('searchhit');
        }
        Test.stopTest();

        Assert.areEqual(1, results.size(),
            'The signer must be findable by a package user. An empty result is the '
            + 'signature of USER_MODE silently denying access.');
        Assert.areEqual('searchhit@example.com', (String) results[0].get('email'),
            'and it must be the right signer');
    }
}