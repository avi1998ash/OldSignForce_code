/**
 * ServiceLayerRestrictedUserTest — proves the service-layer classes whose SOQL and DML were
 * just moved to user mode still work for a NON-ADMIN user.
 *
 * Why this exists: every other test in the suite runs as the test-executing user, who is a
 * System Administrator. An admin passes every FLS, CRUD and sharing check, so a green suite
 * says nothing about whether a subscriber's ordinary user can still use the product. Since
 * WITH USER_MODE / AccessLevel.USER_MODE enforce exactly those checks, that is the one thing
 * worth proving here. Companion to DocumentEditorRestrictedUserTest, which did the same job
 * for DocumentEditorController.
 *
 * Scope — one test per converted entry point a real package user actually reaches:
 *
 *   DocumentService      Every method here is @AuraEnabled and imported by the
 *                        agreementDocumentUpload LWC, which sits on the Agreement record
 *                        page. This is the class an ordinary user hits most.
 *   IntegrationService   setupFoldersForAgreement is reached from
 *                        AgreementController.prepareCloudUpload, called by createAgreement
 *                        when a >4MB file needs a cloud destination. Both converted sites
 *                        (the SELECT and the five-field Cloud_* update) are covered.
 *   PDFGenerationService generateCertificateOnly is reached from
 *                        AgreementController.sendCompletionEmailsWithPDF. The class's other
 *                        methods — generateSignedPDF, getPDFAttachment, getAllAttachments,
 *                        diagnosePDF — have NO production caller anywhere in the repo (the
 *                        only references are its own test class and the commented-out body
 *                        of the retired AgreementCompletionHandler), so there is no user
 *                        entry point to exercise and none is invented here.
 *
 * The user is created inside the test and rolled back with it — no licence is consumed and
 * nothing persists in the org.
 *
 * If a converted statement ever starts touching a field or object the SignForce_User
 * permission set does not grant, these tests fail with an access error rather than the
 * subscriber finding out.
 */
@isTest(SeeAllData=false)
private class ServiceLayerRestrictedUserTest {

    // ═════════════════════════════════════════════════════════════════════
    //  Lambda mock — only the folder-setup response is needed here
    // ═════════════════════════════════════════════════════════════════════

    private class CloudLambdaMock implements HttpCalloutMock {
        public HttpResponse respond(HttpRequest req) {
            HttpResponse res = new HttpResponse();
            res.setStatusCode(200);
            res.setHeader('Content-Type', 'application/json');
            res.setBody(JSON.serialize(new Map<String, Object>{
                'success'          => true,
                'mainFolderId'     => 'main-1',
                'originalFolderId' => 'orig-1',
                'stampedFolderId'  => 'stamp-1',
                'certFolderId'     => 'cert-1'
            }));
            return res;
        }
    }

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
            FirstName         = 'Svc',
            LastName          = 'User' + uniq,
            Email             = 'svc' + uniq + '@example.com',
            Username          = 'svc' + uniq + '@esignforce.test',
            Alias             = 'svcu',
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
     * converted method as getAgreementDocuments_worksForPackageUser, as the same kind of
     * Standard User, with exactly one difference: no SignForce_User permission set. It must
     * be refused.
     *
     * If this test ever starts passing silently — i.e. the call succeeds for a user with no
     * object access — then System.runAs or the user-mode enforcement has stopped working and
     * every other assertion in this class has quietly become a no-op.
     */
    @isTest
    static void control_withoutPermissionSet_accessIsRefused() {
        Agreement__c agr = TestDataFactory.createDraftAgreement('Svc Control');
        TestDataFactory.createTier1OriginalDoc(agr.Id);
        User bare = buildBareUser();

        Boolean refused = false;
        Test.startTest();
        System.runAs(bare) {
            try {
                DocumentService.getAgreementDocuments(agr.Id);
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
    //  Shared data helpers (run as the admin, before runAs)
    // ═════════════════════════════════════════════════════════════════════

    private static ContentVersion newContentVersion(Id agreementId, String title) {
        ContentVersion cv = new ContentVersion(
            Title                  = title,
            PathOnClient           = title + '.pdf',
            VersionData            = Blob.valueOf('fake-pdf-bytes'),
            FirstPublishLocationId = agreementId
        );
        insert cv;
        return [SELECT Id, ContentDocumentId FROM ContentVersion WHERE Id = :cv.Id];
    }

    private static void enableGoogleDrive() {
        SignForce_Admin_Config__c cfg = SignForce_Admin_Config__c.getOrgDefaults();
        cfg.Integration_GoogleDrive_Enabled__c = true;
        cfg.Integration_GoogleDrive_Target__c  = 'root-1';
        upsert cfg;
    }

    // ═════════════════════════════════════════════════════════════════════
    //  DocumentService — reads
    // ═════════════════════════════════════════════════════════════════════

    @isTest
    static void getAgreementDocuments_worksForPackageUser() {
        Agreement__c agr = TestDataFactory.createDraftAgreement('Svc Read');
        TestDataFactory.createTier1OriginalDoc(agr.Id);
        User u = buildPackageUser();

        List<DocumentService.DocWrapper> docs;
        Test.startTest();
        System.runAs(u) {
            docs = DocumentService.getAgreementDocuments(agr.Id);
        }
        Test.stopTest();

        Assert.areEqual(1, docs.size(),
            'A package user must see the agreement documents. An empty list here is the '
            + 'signature of USER_MODE denying access - it returns no rows rather than throwing.');
        Assert.areEqual('Original', docs[0].documentType, 'Document_Type__c must be readable');
        Assert.areEqual('Test Document', docs[0].Name,
            'The title comes from the second converted query, on ContentVersion - a blank or '
            + 'fallback name would mean that query came back empty for this user');
        Assert.areEqual('PDF', docs[0].fileType,
            'FileType also comes from the ContentVersion query, so it proves the same thing');
    }

    @isTest
    static void getContentVersionSize_worksForPackageUser() {
        Agreement__c agr = TestDataFactory.createDraftAgreement('Svc Size');
        User u = buildPackageUser();

        Integer size;
        Test.startTest();
        System.runAs(u) {
            // The user uploads the file themselves in production, so create it as them.
            ContentVersion cv = newContentVersion(agr.Id, 'Uploaded By User');
            size = DocumentService.getContentVersionSize(cv.ContentDocumentId);
        }
        Test.stopTest();

        Assert.isNotNull(size, 'The post-upload size check must work for a package user');
        Assert.isTrue(size > 0, 'ContentSize must be readable, not zero/denied');
    }

    // ═════════════════════════════════════════════════════════════════════
    //  DocumentService — writes
    // ═════════════════════════════════════════════════════════════════════

    @isTest
    static void linkDocumentToAgreement_worksForPackageUser() {
        Agreement__c agr = TestDataFactory.createDraftAgreement('Svc Link');
        User u = buildPackageUser();

        Test.startTest();
        System.runAs(u) {
            ContentVersion cv = newContentVersion(agr.Id, 'User Upload');
            DocumentService.linkDocumentToAgreement(agr.Id, cv.ContentDocumentId, 'Original');
        }
        Test.stopTest();

        List<Agreement_Document__c> created = [
            SELECT Id, Name, Document_Type__c, Content_Version_ID__c
            FROM Agreement_Document__c WHERE Agreement__c = :agr.Id
        ];
        Assert.areEqual(1, created.size(),
            'A package user must be able to link an uploaded document to the agreement');
        Assert.areEqual('Original', created[0].Document_Type__c);
        Assert.areEqual('User Upload', created[0].Name,
            'The name comes from the converted ContentVersion query; a blank means it was denied');
    }

    @isTest
    static void replaceOriginal_purgesPriorAsPackageUser() {
        Agreement__c agr = TestDataFactory.createDraftAgreement('Svc Replace');
        Agreement_Document__c prior = TestDataFactory.createTier1OriginalDoc(agr.Id);
        User u = buildPackageUser();

        Test.startTest();
        System.runAs(u) {
            ContentVersion replacement = newContentVersion(agr.Id, 'Replacement');
            DocumentService.linkDocumentToAgreement(agr.Id, replacement.ContentDocumentId, 'Original');
        }
        Test.stopTest();

        List<Agreement_Document__c> after = [
            SELECT Id, Name FROM Agreement_Document__c WHERE Agreement__c = :agr.Id
        ];
        // Two things are proven at once: the converted SELECT found the prior Original for
        // this user, and the converted Database.delete actually removed it. Had the SELECT
        // been denied it would have returned an empty list, the delete would have been
        // skipped, and we would be looking at two rows here.
        Assert.areEqual(1, after.size(),
            'Replacing the Original must leave exactly one document, not accumulate duplicates');
        Assert.areEqual('Replacement', after[0].Name, 'The surviving row must be the new upload');
        Assert.areEqual(0, [SELECT COUNT() FROM Agreement_Document__c WHERE Id = :prior.Id],
            'The prior Original must actually be gone');
    }

    @isTest
    static void deleteAgreementDocument_worksForPackageUser() {
        Agreement__c agr = TestDataFactory.createDraftAgreement('Svc Delete Doc');
        Agreement_Document__c doc = TestDataFactory.createTier1OriginalDoc(agr.Id);
        User u = buildPackageUser();

        Test.startTest();
        System.runAs(u) {
            DocumentService.deleteAgreementDocument(doc.Id);
        }
        Test.stopTest();

        Assert.areEqual(0, [SELECT COUNT() FROM Agreement_Document__c WHERE Id = :doc.Id],
            'A package user must be able to remove a document row they can see');
    }

    @isTest
    static void deleteContentDocument_worksForPackageUser() {
        Agreement__c agr = TestDataFactory.createDraftAgreement('Svc Oversize');
        User u = buildPackageUser();

        Id contentDocId;
        Test.startTest();
        System.runAs(u) {
            // BUG-024 cleanup path: the file is already uploaded by the user when the size
            // check rejects it, so the user is also the one deleting it.
            ContentVersion cv = newContentVersion(agr.Id, 'Oversize');
            contentDocId = cv.ContentDocumentId;
            DocumentService.deleteContentDocument(contentDocId);
        }
        Test.stopTest();

        Assert.areEqual(0, [SELECT COUNT() FROM ContentDocument WHERE Id = :contentDocId],
            'The over-size cleanup must not leave an orphan file behind for a package user');
    }

    // ═════════════════════════════════════════════════════════════════════
    //  DocumentService — public link provisioning
    //  This is the ContentDistribution path. Guest signing reads the URL it
    //  writes, so a silent failure here would break signing for everyone the
    //  restricted user invites, not just the restricted user.
    // ═════════════════════════════════════════════════════════════════════

    @isTest
    static void createPublicUrlForAgreement_worksForPackageUser() {
        Agreement__c agr = TestDataFactory.createDraftAgreement('Svc PubUrl');
        Agreement_Document__c doc = TestDataFactory.createTier1OriginalDoc(agr.Id);
        User u = buildPackageUser();

        Test.startTest();
        System.runAs(u) {
            DocumentService.createPublicUrlForAgreement(agr.Id);
        }
        Test.stopTest();

        Agreement_Document__c after = [
            SELECT External_URL__c FROM Agreement_Document__c WHERE Id = :doc.Id
        ];
        Assert.isTrue(String.isNotBlank(after.External_URL__c),
            'A package user sending for signature must be able to provision the public link - '
            + 'the ContentDistribution insert and the External_URL__c write both run in user mode');
    }

    @isTest
    static void getDocumentPublicUrl_viaControllerWorksForPackageUser() {
        Agreement__c agr = TestDataFactory.createDraftAgreement('Svc PubUrl Entry');
        TestDataFactory.createTier1OriginalDoc(agr.Id);
        User u = buildPackageUser();

        String url;
        Test.startTest();
        System.runAs(u) {
            url = AgreementController.getDocumentPublicUrl(agr.Id);
        }
        Test.stopTest();

        // This entry point swallows any exception from createPublicUrlForAgreement and
        // returns null, so a null here is exactly the silent failure mode that a
        // user-mode conversion could introduce. Assert on it explicitly.
        Assert.isTrue(String.isNotBlank(url),
            'getDocumentPublicUrl must return a link for a package user. Null means the '
            + 'create path threw and was swallowed by the controller catch block.');
    }

    // ═════════════════════════════════════════════════════════════════════
    //  IntegrationService — both converted sites
    // ═════════════════════════════════════════════════════════════════════

    @isTest
    static void setupFolders_reusesExistingTreeForPackageUser() {
        enableGoogleDrive();
        Agreement__c agr = TestDataFactory.createDraftAgreement('Svc Folder Reuse');
        agr.Cloud_Provider__c           = 'GoogleDrive';
        agr.Cloud_Main_Folder_Id__c     = 'existing-main';
        agr.Cloud_Original_Folder_Id__c = 'existing-orig';
        agr.Cloud_Stamped_Folder_Id__c  = 'existing-stamp';
        agr.Cloud_Cert_Folder_Id__c     = 'existing-cert';
        update agr;
        User u = buildPackageUser();

        Map<String, Object> folders;
        Test.startTest();
        System.runAs(u) {
            folders = IntegrationService.setupFoldersForAgreement(agr.Id);
        }
        Test.stopTest();

        // The converted SELECT is a single-row assignment, so a sharing or FLS denial would
        // throw QueryException here rather than return the wrong answer. Reaching this
        // assertion at all proves the five Cloud_* fields are readable for a package user.
        Assert.areEqual('existing-orig', folders.get('originalFolderId'),
            'The existing folder tree must be reused - re-creating it would duplicate folders');
        Assert.areEqual('existing-main', folders.get('mainFolderId'));
        Assert.areEqual('existing-cert', folders.get('certFolderId'));
    }

    @isTest
    static void setupFolders_persistsIdsForPackageUser() {
        enableGoogleDrive();
        Agreement__c agr = TestDataFactory.createDraftAgreement('Svc Folder Create');
        User u = buildPackageUser();
        Test.setMock(HttpCalloutMock.class, new CloudLambdaMock());

        Test.startTest();
        System.runAs(u) {
            IntegrationService.setupFoldersForAgreement(agr.Id);
        }
        Test.stopTest();

        Agreement__c saved = [
            SELECT Cloud_Provider__c, Cloud_Main_Folder_Id__c, Cloud_Original_Folder_Id__c,
                   Cloud_Stamped_Folder_Id__c, Cloud_Cert_Folder_Id__c
            FROM Agreement__c WHERE Id = :agr.Id
        ];
        // The converted Database.update writes five Cloud_* fields. If any were readable but
        // not editable for SignForce_User this would have thrown, and if the update were
        // silently skipped the next upload would spawn a duplicate folder tree in Drive.
        Assert.areEqual('main-1', saved.Cloud_Main_Folder_Id__c,
            'Folder ids must persist for a package user, or every re-upload duplicates the tree');
        Assert.areEqual('orig-1', saved.Cloud_Original_Folder_Id__c);
        Assert.areEqual('stamp-1', saved.Cloud_Stamped_Folder_Id__c);
        Assert.areEqual('cert-1', saved.Cloud_Cert_Folder_Id__c);
        Assert.areEqual('GoogleDrive', saved.Cloud_Provider__c);
    }

    // ═════════════════════════════════════════════════════════════════════
    //  PDFGenerationService — the one method with a user entry point
    // ═════════════════════════════════════════════════════════════════════

    @isTest
    static void generateCertificateOnly_worksForPackageUser() {
        Agreement__c agr = TestDataFactory.createSentAgreement('Svc Cert');
        TestDataFactory.createSignerWithToken(agr.Id, 'svccert@example.com');
        User u = buildPackageUser();

        Id certContentDocId;
        Test.startTest();
        System.runAs(u) {
            certContentDocId = PDFGenerationService.generateCertificateOnly(agr.Id);
        }
        Test.stopTest();

        // Exercises, in user mode: the Agreement__c read, the stale-certificate SELECT and
        // delete, the ContentVersion insert, the ContentDocumentLink insert and the
        // Agreement_Document__c insert.
        Assert.isNotNull(certContentDocId,
            'A package user completing an agreement must be able to produce the certificate');
        List<Agreement_Document__c> certs = [
            SELECT Id, Content_Version_ID__c FROM Agreement_Document__c
            WHERE Agreement__c = :agr.Id AND Document_Type__c = 'Signed'
        ];
        Assert.areEqual(1, certs.size(), 'Exactly one certificate row must be recorded');
        Assert.isTrue(String.isNotBlank(certs[0].Content_Version_ID__c),
            'The certificate row must point at the ContentVersion the user just created');
    }

    @isTest
    static void generateCertificateOnly_replacesPriorCertForPackageUser() {
        Agreement__c agr = TestDataFactory.createSentAgreement('Svc Cert Replace');
        TestDataFactory.createSignerWithToken(agr.Id, 'svccert2@example.com');
        // A stale certificate from an earlier run, which the converted delete must purge.
        insert new Agreement_Document__c(
            Agreement__c     = agr.Id,
            Name             = 'Stale Certificate',
            Document_Type__c = 'Signed'
        );
        User u = buildPackageUser();

        Test.startTest();
        System.runAs(u) {
            PDFGenerationService.generateCertificateOnly(agr.Id);
        }
        Test.stopTest();

        List<Agreement_Document__c> certs = [
            SELECT Id, Name FROM Agreement_Document__c
            WHERE Agreement__c = :agr.Id AND Document_Type__c = 'Signed'
        ];
        Assert.areEqual(1, certs.size(),
            'The stale certificate must be deleted, not accumulated. Two rows here would mean '
            + 'the converted SELECT came back empty for this user and the delete was skipped.');
        Assert.areNotEqual('Stale Certificate', certs[0].Name,
            'The surviving certificate must be the freshly generated one');
    }
}