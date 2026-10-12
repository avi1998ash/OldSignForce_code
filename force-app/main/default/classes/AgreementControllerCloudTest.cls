/**
 * AgreementControllerCloudTest — covers the >4MB cloud-document paths added for
 * Google Drive / OneDrive storage: prepareCloudUpload, createAgreementDocumentCloud,
 * pushCloudChunk, getCloudDocChunk, stampViaCloud routing, the cloud branch of the
 * completion email, and IntegrationService folder reuse/naming.
 *
 * Strategy mirrors AgreementControllerStampingTest: one universal Lambda mock,
 * each test exercises one entry point and asserts on side effects.
 */
@isTest(SeeAllData=false)
private class AgreementControllerCloudTest {

    // ═════════════════════════════════════════════════════════════════════
    //  Universal Lambda mock — satisfies every cloud action in one body
    // ═════════════════════════════════════════════════════════════════════

    private class CloudLambdaMock implements HttpCalloutMock {
        public HttpResponse respond(HttpRequest req) {
            HttpResponse res = new HttpResponse();
            res.setStatusCode(200);
            res.setHeader('Content-Type', 'application/json');
            res.setBody(JSON.serialize(new Map<String, Object>{
                'success'          => true,
                'fileId'           => 'drive-file-1',
                'externalId'       => 'drive-file-1',
                'previewUrl'       => 'https://drive.google.com/file/d/drive-file-1/view',
                'mainFolderId'     => 'main-1',
                'originalFolderId' => 'orig-1',
                'stampedFolderId'  => 'stamp-1',
                'certFolderId'     => 'cert-1',
                'pdfBase64'        => EncodingUtil.base64Encode(Blob.valueOf('mock pdf')),
                'size'             => 8,
                'url'              => 'https://example.com/x',
                'docId'            => 'doc-1',
                'status'           => 'OK'
            }));
            return res;
        }
    }

    private class CloudLambdaFailMock implements HttpCalloutMock {
        public HttpResponse respond(HttpRequest req) {
            HttpResponse res = new HttpResponse();
            res.setStatusCode(500);
            res.setBody('{"success":false,"message":"boom"}');
            return res;
        }
    }

    // ═════════════════════════════════════════════════════════════════════
    //  Data helpers
    // ═════════════════════════════════════════════════════════════════════

    private static void enableGoogleDrive() {
        SignForce_Admin_Config__c cfg = SignForce_Admin_Config__c.getOrgDefaults();
        cfg.Integration_GoogleDrive_Enabled__c = true;
        cfg.Integration_GoogleDrive_Target__c  = 'root-1';
        upsert cfg;
    }

    private static Agreement_Document__c createCloudOriginal(Id agreementId) {
        Agreement_Document__c doc = new Agreement_Document__c(
            Agreement__c       = agreementId,
            Name               = 'Cloud Original',
            Document_Type__c   = 'Original',
            Storage_Type__c    = 'Cloud',
            Cloud_Provider__c  = 'GoogleDrive',
            Cloud_File_Id__c   = 'cloud-orig-1',
            Cloud_Folder_Id__c = 'orig-1',
            Storage_Tier__c    = 'Tier2',
            File_Size_Bytes__c = 6000000
        );
        insert doc;
        return doc;
    }

    // ═════════════════════════════════════════════════════════════════════
    //  stampViaCloud via generateStampedPDFServerInternal routing
    // ═════════════════════════════════════════════════════════════════════

    @isTest
    static void generateStampedPDFServer_cloudOriginal_createsCloudStamped() {
        TestDataFactory.suppressCompletionStamp();
        Agreement__c agr = TestDataFactory.createSentAgreement('Cloud Stamp Path');
        agr.Cloud_Provider__c          = 'GoogleDrive';
        agr.Cloud_Stamped_Folder_Id__c = 'stamp-1';
        update agr;

        Signer__c signer = TestDataFactory.createSignerWithToken(agr.Id, 'cloud@example.com');
        createCloudOriginal(agr.Id);

        Signature_Field__c f = TestDataFactory.createSignatureField(agr.Id, signer.Id, 1, 100, 200);
        f.Field_Value__c = 'Cloud Signer';
        f.Is_Completed__c = true;
        update f;

        Test.setMock(HttpCalloutMock.class, new CloudLambdaMock());

        Test.startTest();
        AgreementController.generateStampedPDFServerInternal(agr.Id);
        Test.stopTest();

        List<Agreement_Document__c> stamped = [
            SELECT Storage_Type__c, Cloud_File_Id__c, Cloud_Provider__c, S3_Preview_URL__c
            FROM Agreement_Document__c
            WHERE Agreement__c = :agr.Id AND Document_Type__c = 'Stamped' WITH USER_MODE
        ];
        Assert.areEqual(1, stamped.size(), 'One cloud Stamped doc should exist');
        Assert.areEqual('Cloud', stamped[0].Storage_Type__c);
        Assert.areEqual('drive-file-1', stamped[0].Cloud_File_Id__c);
        Assert.areEqual('GoogleDrive', stamped[0].Cloud_Provider__c);
        Assert.isNotNull(stamped[0].S3_Preview_URL__c, 'Shareable link should be stored');
    }

    @isTest
    static void generateStampedPDFServer_cloudOriginal_replacesOldStamped() {
        TestDataFactory.suppressCompletionStamp();
        Agreement__c agr = TestDataFactory.createSentAgreement('Cloud Restamp');
        agr.Cloud_Provider__c          = 'GoogleDrive';
        agr.Cloud_Stamped_Folder_Id__c = 'stamp-1';
        update agr;

        Signer__c signer = TestDataFactory.createSignerWithToken(agr.Id, 'restamp@example.com');
        createCloudOriginal(agr.Id);
        insert new Agreement_Document__c(
            Agreement__c = agr.Id, Name = 'Old Stamped',
            Document_Type__c = 'Stamped', Storage_Type__c = 'Cloud',
            Cloud_File_Id__c = 'old-stamped', Cloud_Provider__c = 'GoogleDrive'
        );

        Signature_Field__c f = TestDataFactory.createSignatureField(agr.Id, signer.Id, 1, 100, 200);
        f.Field_Value__c = 'Cloud Signer';
        f.Is_Completed__c = true;
        update f;

        Test.setMock(HttpCalloutMock.class, new CloudLambdaMock());

        Test.startTest();
        AgreementController.generateStampedPDFServerInternal(agr.Id);
        Test.stopTest();

        List<Agreement_Document__c> stamped = [
            SELECT Cloud_File_Id__c FROM Agreement_Document__c
            WHERE Agreement__c = :agr.Id AND Document_Type__c = 'Stamped' WITH USER_MODE
        ];
        Assert.areEqual(1, stamped.size(), 'Old Stamped should be replaced, not duplicated');
        Assert.areEqual('drive-file-1', stamped[0].Cloud_File_Id__c);
    }

    @isTest
    static void generateStampedPDFServer_cloudNoStampedFolder_throws() {
        TestDataFactory.suppressCompletionStamp();
        Agreement__c agr = TestDataFactory.createSentAgreement('Cloud No Folder');
        Signer__c signer = TestDataFactory.createSignerWithToken(agr.Id, 'nofolder@example.com');
        createCloudOriginal(agr.Id);

        Signature_Field__c f = TestDataFactory.createSignatureField(agr.Id, signer.Id, 1, 100, 200);
        f.Field_Value__c = 'X';
        f.Is_Completed__c = true;
        update f;

        Test.setMock(HttpCalloutMock.class, new CloudLambdaMock());

        Boolean threw = false;
        Test.startTest();
        try {
            AgreementController.generateStampedPDFServerInternal(agr.Id);
        } catch (Exception e) {
            threw = true;
            Assert.isTrue(e.getMessage().contains('Stamped folder'),
                'Should explain the missing folder, got: ' + e.getMessage());
        }
        Test.stopTest();
        Assert.isTrue(threw, 'Missing stamped folder id must fail loudly');
    }

    @isTest
    static void generateStampedPDFServer_cloudLambdaHttp500_throws() {
        TestDataFactory.suppressCompletionStamp();
        Agreement__c agr = TestDataFactory.createSentAgreement('Cloud Stamp 500');
        agr.Cloud_Provider__c          = 'GoogleDrive';
        agr.Cloud_Stamped_Folder_Id__c = 'stamp-1';
        update agr;

        Signer__c signer = TestDataFactory.createSignerWithToken(agr.Id, 'fail@example.com');
        createCloudOriginal(agr.Id);

        Signature_Field__c f = TestDataFactory.createSignatureField(agr.Id, signer.Id, 1, 100, 200);
        f.Field_Value__c = 'X';
        f.Is_Completed__c = true;
        update f;

        Test.setMock(HttpCalloutMock.class, new CloudLambdaFailMock());

        Boolean threw = false;
        Test.startTest();
        try {
            AgreementController.generateStampedPDFServerInternal(agr.Id);
        } catch (Exception e) {
            threw = true;
        }
        Test.stopTest();
        Assert.isTrue(threw, 'Lambda HTTP 500 must surface as an exception');
        Assert.areEqual(0, [
            SELECT COUNT() FROM Agreement_Document__c
            WHERE Agreement__c = :agr.Id AND Document_Type__c = 'Stamped' WITH USER_MODE
        ], 'No Stamped row on failure');
    }

    // ═════════════════════════════════════════════════════════════════════
    //  prepareCloudUpload
    // ═════════════════════════════════════════════════════════════════════

    @isTest
    static void prepareCloudUpload_noProvider_throws() {
        TestDataFactory.suppressCompletionStamp();
        Agreement__c agr = TestDataFactory.createDraftAgreement('No Provider');
        Boolean threw = false;
        try {
            AgreementController.prepareCloudUpload(agr.Id);
        } catch (AuraHandledException e) {
            threw = true;
        }
        Assert.isTrue(threw, 'No connected provider must reject the >4MB upload');
    }

    @isTest
    static void prepareCloudUpload_createsAndPersistsFolders() {
        TestDataFactory.suppressCompletionStamp();
        enableGoogleDrive();
        Agreement__c agr = TestDataFactory.createDraftAgreement('Folder Setup');
        Test.setMock(HttpCalloutMock.class, new CloudLambdaMock());

        Test.startTest();
        Map<String, Object> prep = AgreementController.prepareCloudUpload(agr.Id);
        Test.stopTest();

        Assert.areEqual('GoogleDrive', prep.get('provider'));
        Assert.areEqual('orig-1', prep.get('originalFolderId'));

        Agreement__c saved = [
            SELECT Cloud_Provider__c, Cloud_Main_Folder_Id__c, Cloud_Stamped_Folder_Id__c
            FROM Agreement__c WHERE Id = :agr.Id WITH USER_MODE
        ];
        Assert.areEqual('main-1', saved.Cloud_Main_Folder_Id__c, 'Folder ids persisted');
        Assert.areEqual('stamp-1', saved.Cloud_Stamped_Folder_Id__c);
    }

    @isTest
    static void prepareCloudUpload_reusesExistingFolders() {
        TestDataFactory.suppressCompletionStamp();
        enableGoogleDrive();
        Agreement__c agr = TestDataFactory.createDraftAgreement('Folder Reuse');
        agr.Cloud_Provider__c           = 'GoogleDrive';
        agr.Cloud_Main_Folder_Id__c     = 'existing-main';
        agr.Cloud_Original_Folder_Id__c = 'existing-orig';
        agr.Cloud_Stamped_Folder_Id__c  = 'existing-stamp';
        agr.Cloud_Cert_Folder_Id__c     = 'existing-cert';
        update agr;

        Test.startTest();
        Map<String, Object> prep = AgreementController.prepareCloudUpload(agr.Id);
        Test.stopTest();

        Assert.areEqual('existing-orig', prep.get('originalFolderId'),
            'Existing folder tree must be reused — no duplicate folders');
    }

    // ═════════════════════════════════════════════════════════════════════
    //  createAgreementDocumentCloud
    // ═════════════════════════════════════════════════════════════════════

    @isTest
    static void createAgreementDocumentCloud_insertsThenReuses() {
        TestDataFactory.suppressCompletionStamp();
        Agreement__c agr = TestDataFactory.createDraftAgreement('Cloud Doc Record');

        Id first = AgreementController.createAgreementDocumentCloud(
            agr.Id, 'file-a', 'GoogleDrive', 'orig-1', 'big.pdf', 6000000);
        Id second = AgreementController.createAgreementDocumentCloud(
            agr.Id, 'file-b', 'GoogleDrive', 'orig-1', 'big2.pdf', 7000000);

        List<Agreement_Document__c> originals = [
            SELECT Cloud_File_Id__c, Storage_Type__c FROM Agreement_Document__c
            WHERE Agreement__c = :agr.Id AND Document_Type__c = 'Original' WITH USER_MODE
        ];
        Assert.areEqual(1, originals.size(), 'Re-upload must reuse the Original row');
        Assert.areEqual(first, second, 'Same row updated on re-upload');
        Assert.areEqual('file-b', originals[0].Cloud_File_Id__c);
        Assert.areEqual('Cloud', originals[0].Storage_Type__c);
    }

    @isTest
    static void createAgreementDocumentCloud_validates() {
        TestDataFactory.suppressCompletionStamp();
        Agreement__c agr = TestDataFactory.createDraftAgreement('Cloud Doc Invalid');
        Boolean threw = false;
        try {
            AgreementController.createAgreementDocumentCloud(agr.Id, '', 'GoogleDrive', 'f', 'x.pdf', 1);
        } catch (AuraHandledException e) {
            threw = true;
        }
        Assert.isTrue(threw, 'Blank cloudFileId must be rejected');
    }

    // ═════════════════════════════════════════════════════════════════════
    //  pushCloudChunk / getCloudDocChunk proxies
    // ═════════════════════════════════════════════════════════════════════

    @isTest
    static void pushCloudChunk_returnsExternalIdOnSuccess() {
        TestDataFactory.suppressCompletionStamp();
        Test.setMock(HttpCalloutMock.class, new CloudLambdaMock());
        Test.startTest();
        String fileId = AgreementController.pushCloudChunk(
            'sess-1', 0, 1, 'QUJDRA==', 'GoogleDrive', 'orig-1', 'big.pdf');
        Test.stopTest();
        Assert.areEqual('drive-file-1', fileId);
    }

    @isTest
    static void getCloudDocChunk_returnsBase64AndSize() {
        TestDataFactory.suppressCompletionStamp();
        Agreement__c agr = TestDataFactory.createDraftAgreement('Cloud Fetch');
        Agreement_Document__c orig = createCloudOriginal(agr.Id);
        Test.setMock(HttpCalloutMock.class, new CloudLambdaMock());

        Test.startTest();
        Map<String, Object> chunk = AgreementController.getCloudDocChunk(agr.Id, 0, 1200000, null);
        // Specific-document variant (record-page preview of a Stamped cloud doc).
        Map<String, Object> byId = AgreementController.getCloudDocChunk(agr.Id, 0, 1200000, orig.Id);
        Test.stopTest();

        Assert.isNotNull(chunk.get('base64'), 'Chunk base64 returned');
        Assert.areEqual(8, chunk.get('size'));
        Assert.isNotNull(byId.get('base64'), 'documentId variant returns bytes');
    }

    @isTest
    static void getCloudDocChunk_nullWhenNoCloudDoc() {
        TestDataFactory.suppressCompletionStamp();
        Agreement__c agr = TestDataFactory.createDraftAgreement('No Cloud Doc');
        TestDataFactory.createTier1OriginalDoc(agr.Id);
        Assert.areEqual(null, AgreementController.getCloudDocChunk(agr.Id, 0, 100, null));
    }

    // ═════════════════════════════════════════════════════════════════════
    //  Completion email — cloud stamped doc becomes a download link
    // ═════════════════════════════════════════════════════════════════════

    @isTest
    static void completionEmail_cloudStamped_sendsWithLink() {
        TestDataFactory.suppressCompletionStamp();
        Agreement__c agr = TestDataFactory.createSentAgreement('Cloud Email');
        agr.Status__c = 'Completed';
        update agr;
        TestDataFactory.createSignerWithToken(agr.Id, 'signer1@example.com');

        insert new Agreement_Document__c(
            Agreement__c = agr.Id,
            Name = 'Cloud Email - Stamped Signed Document',
            Document_Type__c = 'Stamped',
            Storage_Type__c = 'Cloud',
            Cloud_Provider__c = 'GoogleDrive',
            Cloud_File_Id__c = 'stamped-1',
            S3_Preview_URL__c = 'https://drive.google.com/file/d/stamped-1/view'
        );

        Test.startTest();
        AgreementService.sendCompletionEmailsPublic(agr.Id);
        Integer sent = Limits.getEmailInvocations();
        Test.stopTest();

        Assert.isTrue(sent > 0, 'Completion email must be sent for cloud-stamped agreement');
    }

    @isTest
    static void completionEmail_cloudStampedNoUrl_stillSends() {
        TestDataFactory.suppressCompletionStamp();
        Agreement__c agr = TestDataFactory.createSentAgreement('Cloud Email NoUrl');
        agr.Status__c = 'Completed';
        update agr;
        TestDataFactory.createSignerWithToken(agr.Id, 'signer2@example.com');

        insert new Agreement_Document__c(
            Agreement__c = agr.Id,
            Name = 'NoUrl - Stamped',
            Document_Type__c = 'Stamped',
            Storage_Type__c = 'Cloud',
            Cloud_Provider__c = 'GoogleDrive',
            Cloud_File_Id__c = 'stamped-2'
        );

        Test.startTest();
        AgreementService.sendCompletionEmailsPublic(agr.Id);
        Integer sent = Limits.getEmailInvocations();
        Test.stopTest();

        Assert.isTrue(sent > 0, 'Missing share URL must not block the email');
    }

    // ═════════════════════════════════════════════════════════════════════
    //  IntegrationService — folder naming + reuse on completion push
    // ═════════════════════════════════════════════════════════════════════

    @isTest
    static void cloudFolderName_sanitizesAndFallsBack() {
        TestDataFactory.suppressCompletionStamp();
        Agreement__c agr = TestDataFactory.createDraftAgreement('Names');
        String cleaned = IntegrationService.cloudFolderName('Bad/Name:With*Chars?', agr.Id);
        Assert.isFalse(cleaned.contains('/') || cleaned.contains(':') || cleaned.contains('*')
            || cleaned.contains('?'), 'Invalid folder chars stripped: ' + cleaned);

        String fallback = IntegrationService.cloudFolderName('   ', agr.Id);
        Assert.isTrue(fallback.startsWith('Agreement_'), 'Blank name falls back to id');
    }

    @isTest
    static void pushAgreementDocuments_reusesExistingFolderTree() {
        TestDataFactory.suppressCompletionStamp();
        enableGoogleDrive();
        Agreement__c agr = TestDataFactory.createSentAgreement('Push Reuse');
        agr.Cloud_Provider__c           = 'GoogleDrive';
        agr.Cloud_Main_Folder_Id__c     = 'main-keep';
        agr.Cloud_Original_Folder_Id__c = 'orig-keep';
        agr.Cloud_Stamped_Folder_Id__c  = 'stamp-keep';
        agr.Cloud_Cert_Folder_Id__c     = 'cert-keep';
        update agr;
        TestDataFactory.createTier1OriginalDoc(agr.Id);

        Test.setMock(HttpCalloutMock.class, new CloudLambdaMock());

        Test.startTest();
        IntegrationService.pushAgreementDocuments(agr.Id);
        Test.stopTest();

        Agreement__c after = [
            SELECT Cloud_Main_Folder_Id__c FROM Agreement__c WHERE Id = :agr.Id WITH USER_MODE
        ];
        Assert.areEqual('main-keep', after.Cloud_Main_Folder_Id__c,
            'Existing folder ids must be reused, never replaced');
        Assert.isTrue([
            SELECT COUNT() FROM Task WHERE WhatId = :agr.Id AND Subject LIKE 'Cloud Upload:%' WITH USER_MODE
        ] > 0, 'Status Task should be logged');
    }

    @isTest
    static void pushAgreementDocuments_firstTime_persistsFolderIds() {
        TestDataFactory.suppressCompletionStamp();
        enableGoogleDrive();
        Agreement__c agr = TestDataFactory.createSentAgreement('Push First');
        TestDataFactory.createTier1OriginalDoc(agr.Id);

        Test.setMock(HttpCalloutMock.class, new CloudLambdaMock());

        Test.startTest();
        IntegrationService.pushAgreementDocuments(agr.Id);
        Test.stopTest();

        Agreement__c after = [
            SELECT Cloud_Main_Folder_Id__c, Cloud_Stamped_Folder_Id__c
            FROM Agreement__c WHERE Id = :agr.Id WITH USER_MODE
        ];
        Assert.areEqual('main-1', after.Cloud_Main_Folder_Id__c,
            'First-time folder tree ids must be persisted for reuse');
    }
}