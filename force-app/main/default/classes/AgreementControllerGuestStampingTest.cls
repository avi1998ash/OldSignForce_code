/**
 * AgreementControllerGuestStampingTest — covers AgreementControllerGuest.generateStampedPDFServerGuest
 * and its private helpers (stampViaS3, stampOriginalToSalesforce, convertOriginalToPdfBase64,
 * stampViaCloud, stampedFileName, stampedFileTitle, truncateTitle, buildStampFieldList).
 *
 * Those helpers are a deliberate full copy of the AgreementController stamping path, so the
 * scenarios here mirror AgreementControllerStampingTest / AgreementControllerCloudTest but drive
 * the guest-side entry point.
 *
 * Strategy: every Lambda callout is mocked. Each test asserts on side effects (the Stamped
 * Agreement_Document__c row, the ContentVersion title, the number of callouts made) or on the
 * exception the method raises.
 */
@isTest(SeeAllData=false)
private class AgreementControllerGuestStampingTest {

    // Callout capture shared with the mock classes below.
    private static Integer calls = 0;
    private static String lastBody = '';

    // ═════════════════════════════════════════════════════════════════════
    //  HTTP callout mocks
    // ═════════════════════════════════════════════════════════════════════

    /** One body that satisfies every Lambda action the stamping path uses. */
    private class OkMock implements HttpCalloutMock {
        public HttpResponse respond(HttpRequest req) {
            calls++;
            lastBody = req.getBody();
            HttpResponse res = new HttpResponse();
            res.setStatusCode(200);
            res.setHeader('Content-Type', 'application/json');
            res.setBody(JSON.serialize(new Map<String, Object>{
                'success'    => true,
                'url'        => 'https://example.s3.amazonaws.com/test/presigned?sig=abc',
                'pdfBase64'  => EncodingUtil.base64Encode(Blob.valueOf('mock pdf bytes')),
                'docId'      => 'test_doc_id',
                'status'     => 'OK',
                'fileId'     => 'drive-file-1',
                'externalId' => 'drive-file-1',
                'previewUrl' => 'https://drive.google.com/file/d/drive-file-1/view',
                'size'       => 8
            }));
            return res;
        }
    }

    private class FailMock implements HttpCalloutMock {
        public HttpResponse respond(HttpRequest req) {
            calls++;
            HttpResponse res = new HttpResponse();
            res.setStatusCode(500);
            res.setBody('{"success":false,"message":"boom"}');
            return res;
        }
    }

    private class ThrowMock implements HttpCalloutMock {
        public HttpResponse respond(HttpRequest req) {
            calls++;
            throw new CalloutException('simulated network failure');
        }
    }

    // ═════════════════════════════════════════════════════════════════════
    //  Data helpers
    // ═════════════════════════════════════════════════════════════════════

    private static void reset() {
        calls = 0;
        lastBody = '';
        AgreementControllerGuest.suppressCloudStampUpload = false;
    }

    private static Signature_Field__c completedField(Id agrId, Id signerId, String value) {
        Signature_Field__c f = TestDataFactory.createSignatureField(agrId, signerId, 1, 100, 200);
        f.Field_Value__c = value;
        f.Is_Completed__c = true;
        update f;
        return f;
    }

    private static Agreement__c cloudAgreement(String name) {
        Agreement__c agr = TestDataFactory.createSentAgreement(name);
        agr.Cloud_Provider__c          = 'GoogleDrive';
        agr.Cloud_Stamped_Folder_Id__c = 'stamp-1';
        update agr;
        return agr;
    }

    private static Agreement_Document__c cloudOriginal(Id agreementId) {
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

    /** Tier1 original whose file is a DOCX, so the stamper has to convert it first. */
    private static Agreement_Document__c docxOriginal(Id agreementId) {
        ContentVersion cv = new ContentVersion();
        cv.Title = 'Test Docx';
        cv.PathOnClient = 'test.docx';
        cv.VersionData = Blob.valueOf('fake-docx-bytes');
        cv.FirstPublishLocationId = agreementId;
        insert cv;

        Agreement_Document__c doc = new Agreement_Document__c();
        doc.Agreement__c = agreementId;
        doc.Name = 'Test Docx';
        doc.Content_Version_ID__c = cv.Id;
        doc.Document_Type__c = 'Original';
        doc.Storage_Tier__c = 'Tier1';
        doc.File_Size_Bytes__c = 15;
        insert doc;
        return doc;
    }

    private static List<Agreement_Document__c> stampedDocs(Id agrId) {
        return [
            SELECT Id, Name, Storage_Type__c, Storage_Tier__c, Cloud_File_Id__c, Cloud_Provider__c,
                   S3_Document_ID__c, Content_Version_ID__c
            FROM Agreement_Document__c
            WHERE Agreement__c = :agrId AND Document_Type__c = 'Stamped'
        ];
    }

    private static String stampedTitle(Id agrId) {
        List<Agreement_Document__c> docs = stampedDocs(agrId);
        Assert.areEqual(1, docs.size(), 'Exactly one Stamped doc expected');
        ContentVersion cv = [SELECT Title FROM ContentVersion WHERE Id = :docs[0].Content_Version_ID__c];
        return cv.Title;
    }

    // ═════════════════════════════════════════════════════════════════════
    //  Storage routing: S3, Salesforce (PDF and DOCX) and Cloud
    // ═════════════════════════════════════════════════════════════════════

    @isTest
    static void s3Original_callsLambdaAndCreatesStamped() {
        TestDataFactory.suppressCompletionStamp();
        reset();
        Agreement__c agr = TestDataFactory.createSentAgreement('Guest Stamp S3');
        Signer__c signer = TestDataFactory.createSignerWithToken(agr.Id, 'gs3@example.com');
        TestDataFactory.createS3OriginalDoc(agr.Id, 'Tier2');
        completedField(agr.Id, signer.Id, 'John Doe');

        Test.setMock(HttpCalloutMock.class, new OkMock());
        Test.startTest();
        AgreementControllerGuest.generateStampedPDFServerGuest(agr.Id);
        Test.stopTest();

        List<Agreement_Document__c> stamped = stampedDocs(agr.Id);
        Assert.areEqual(1, stamped.size(), 'One Stamped doc should exist');
        Assert.isNotNull(stamped[0].S3_Document_ID__c, 'Stamped doc should be S3-backed');
        Assert.isTrue(calls >= 2, 'stampS3 callout plus the stamped PDF fetch');
    }

    @isTest
    static void s3Original_http500_throws() {
        TestDataFactory.suppressCompletionStamp();
        reset();
        Agreement__c agr = TestDataFactory.createSentAgreement('Guest Stamp S3 500');
        Signer__c signer = TestDataFactory.createSignerWithToken(agr.Id, 'gs3f@example.com');
        TestDataFactory.createS3OriginalDoc(agr.Id, 'Tier2');
        completedField(agr.Id, signer.Id, 'X');

        Test.setMock(HttpCalloutMock.class, new FailMock());
        Boolean threw = false;
        Test.startTest();
        try {
            AgreementControllerGuest.generateStampedPDFServerGuest(agr.Id);
        } catch (AgreementControllerGuest.SignForceStampException e) {
            threw = true;
            Assert.isTrue(e.getMessage().contains('Stamping failed'), 'Got: ' + e.getMessage());
        }
        Test.stopTest();
        Assert.isTrue(threw, 'Lambda HTTP 500 must surface as SignForceStampException');
        Assert.areEqual(0, stampedDocs(agr.Id).size(), 'A failed stamp must not leave a Stamped row');
    }

    @isTest
    static void tier1PdfOriginal_storesStampedInSalesforce() {
        TestDataFactory.suppressCompletionStamp();
        reset();
        Agreement__c agr = TestDataFactory.createSentAgreement('Guest Stamp Tier1');
        Signer__c signer = TestDataFactory.createSignerWithToken(agr.Id, 'gt1@example.com');
        TestDataFactory.createTier1OriginalDoc(agr.Id);
        completedField(agr.Id, signer.Id, 'Jane Doe');

        Test.setMock(HttpCalloutMock.class, new OkMock());
        Test.startTest();
        AgreementControllerGuest.generateStampedPDFServerGuest(agr.Id);
        Test.stopTest();

        List<Agreement_Document__c> stamped = stampedDocs(agr.Id);
        Assert.areEqual(1, stamped.size(), 'One Stamped doc should exist');
        Assert.areEqual('Salesforce', stamped[0].Storage_Type__c);
        Assert.areEqual('Tier1', stamped[0].Storage_Tier__c);
        Assert.isNotNull(stamped[0].Content_Version_ID__c, 'Stamped PDF must be saved as a file');
        Assert.areEqual(1, calls, 'A PDF original is stamped directly, with no conversion call');
        Assert.isTrue(lastBody.contains('pdfBase64'), 'Stamp request carries the PDF bytes');
    }

    @isTest
    static void tier1DocxOriginal_convertsThenStamps() {
        TestDataFactory.suppressCompletionStamp();
        reset();
        Agreement__c agr = TestDataFactory.createSentAgreement('Guest Stamp Docx');
        Signer__c signer = TestDataFactory.createSignerWithToken(agr.Id, 'gdocx@example.com');
        docxOriginal(agr.Id);
        completedField(agr.Id, signer.Id, 'Docx Signer');

        Test.setMock(HttpCalloutMock.class, new OkMock());
        Test.startTest();
        AgreementControllerGuest.generateStampedPDFServerGuest(agr.Id);
        Test.stopTest();

        Assert.areEqual(1, stampedDocs(agr.Id).size(), 'One Stamped doc should exist');
        Assert.areEqual(3, calls, 'convertToPdf, proxy fetch of the converted PDF, then the stamp call');
    }

    @isTest
    static void tier1Original_http500_throws() {
        TestDataFactory.suppressCompletionStamp();
        reset();
        Agreement__c agr = TestDataFactory.createSentAgreement('Guest Stamp T1 500');
        Signer__c signer = TestDataFactory.createSignerWithToken(agr.Id, 'gt1f@example.com');
        TestDataFactory.createTier1OriginalDoc(agr.Id);
        completedField(agr.Id, signer.Id, 'X');

        Test.setMock(HttpCalloutMock.class, new FailMock());
        Boolean threw = false;
        Test.startTest();
        try {
            AgreementControllerGuest.generateStampedPDFServerGuest(agr.Id);
        } catch (AgreementControllerGuest.SignForceStampException e) {
            threw = true;
            Assert.isTrue(e.getMessage().contains('HTTP 500'), 'Got: ' + e.getMessage());
        }
        Test.stopTest();
        Assert.isTrue(threw, 'Lambda HTTP 500 must surface as SignForceStampException');
        Assert.areEqual(0, stampedDocs(agr.Id).size());
    }

    @isTest
    static void tier1Original_calloutException_throws() {
        TestDataFactory.suppressCompletionStamp();
        reset();
        Agreement__c agr = TestDataFactory.createSentAgreement('Guest Stamp T1 Net');
        Signer__c signer = TestDataFactory.createSignerWithToken(agr.Id, 'gt1n@example.com');
        TestDataFactory.createTier1OriginalDoc(agr.Id);
        completedField(agr.Id, signer.Id, 'X');

        Test.setMock(HttpCalloutMock.class, new ThrowMock());
        Boolean threw = false;
        Test.startTest();
        try {
            AgreementControllerGuest.generateStampedPDFServerGuest(agr.Id);
        } catch (AgreementControllerGuest.SignForceStampException e) {
            threw = true;
            Assert.isTrue(e.getMessage().contains('callout failed'), 'Got: ' + e.getMessage());
        }
        Test.stopTest();
        Assert.isTrue(threw, 'A callout exception must surface as SignForceStampException');
    }

    @isTest
    static void tier1Original_replacesPriorStamped() {
        TestDataFactory.suppressCompletionStamp();
        reset();
        Agreement__c agr = TestDataFactory.createSentAgreement('Guest Restamp T1');
        Signer__c signer = TestDataFactory.createSignerWithToken(agr.Id, 'grs@example.com');
        TestDataFactory.createTier1OriginalDoc(agr.Id);
        insert new Agreement_Document__c(
            Agreement__c = agr.Id, Name = 'Old Stamped', Document_Type__c = 'Stamped',
            Storage_Tier__c = 'Tier1', Storage_Type__c = 'Salesforce'
        );
        completedField(agr.Id, signer.Id, 'Restamp');

        Test.setMock(HttpCalloutMock.class, new OkMock());
        Test.startTest();
        AgreementControllerGuest.generateStampedPDFServerGuest(agr.Id);
        Test.stopTest();

        Assert.areEqual(1, stampedDocs(agr.Id).size(), 'The old Stamped row is replaced, not duplicated');
    }

    @isTest
    static void cloudOriginal_createsCloudStamped() {
        TestDataFactory.suppressCompletionStamp();
        reset();
        Agreement__c agr = cloudAgreement('Guest Cloud Stamp');
        Signer__c signer = TestDataFactory.createSignerWithToken(agr.Id, 'gcloud@example.com');
        cloudOriginal(agr.Id);
        completedField(agr.Id, signer.Id, 'Cloud Signer');

        Test.setMock(HttpCalloutMock.class, new OkMock());
        Test.startTest();
        AgreementControllerGuest.generateStampedPDFServerGuest(agr.Id);
        Test.stopTest();

        List<Agreement_Document__c> stamped = stampedDocs(agr.Id);
        Assert.areEqual(1, stamped.size(), 'One cloud Stamped doc should exist');
        Assert.areEqual('Cloud', stamped[0].Storage_Type__c);
        Assert.areEqual('drive-file-1', stamped[0].Cloud_File_Id__c);
        Assert.areEqual('GoogleDrive', stamped[0].Cloud_Provider__c);
        Assert.isTrue(lastBody.contains('stampCloud'), 'Cloud stamping uses the stampCloud action');
    }

    @isTest
    static void cloudOriginal_replacesOldStamped() {
        TestDataFactory.suppressCompletionStamp();
        reset();
        Agreement__c agr = cloudAgreement('Guest Cloud Restamp');
        Signer__c signer = TestDataFactory.createSignerWithToken(agr.Id, 'gcrs@example.com');
        cloudOriginal(agr.Id);
        insert new Agreement_Document__c(
            Agreement__c = agr.Id, Name = 'Old Stamped', Document_Type__c = 'Stamped',
            Storage_Type__c = 'Cloud', Cloud_File_Id__c = 'old-stamped', Cloud_Provider__c = 'GoogleDrive'
        );
        completedField(agr.Id, signer.Id, 'Cloud Signer');

        Test.setMock(HttpCalloutMock.class, new OkMock());
        Test.startTest();
        AgreementControllerGuest.generateStampedPDFServerGuest(agr.Id);
        Test.stopTest();

        List<Agreement_Document__c> stamped = stampedDocs(agr.Id);
        Assert.areEqual(1, stamped.size(), 'Old Stamped should be replaced, not duplicated');
        Assert.areEqual('drive-file-1', stamped[0].Cloud_File_Id__c);
    }

    @isTest
    static void cloudOriginal_midFlowSuppressed_skipsStamp() {
        TestDataFactory.suppressCompletionStamp();
        reset();
        Agreement__c agr = cloudAgreement('Guest Cloud Mid');
        Signer__c signer = TestDataFactory.createSignerWithToken(agr.Id, 'gmid@example.com');
        cloudOriginal(agr.Id);
        completedField(agr.Id, signer.Id, 'Mid Signer');

        Test.setMock(HttpCalloutMock.class, new OkMock());
        AgreementControllerGuest.suppressCloudStampUpload = true;
        Test.startTest();
        try {
            AgreementControllerGuest.generateStampedPDFServerGuest(agr.Id);
        } finally {
            AgreementControllerGuest.suppressCloudStampUpload = false;
        }
        Test.stopTest();

        Assert.areEqual(0, stampedDocs(agr.Id).size(), 'A mid-flow stamp is not published to the cloud folder');
        Assert.areEqual(0, calls, 'No Lambda call is made when the mid-flow stamp is suppressed');
    }

    @isTest
    static void cloudOriginal_noStampedFolder_throws() {
        TestDataFactory.suppressCompletionStamp();
        reset();
        Agreement__c agr = TestDataFactory.createSentAgreement('Guest Cloud No Folder');
        Signer__c signer = TestDataFactory.createSignerWithToken(agr.Id, 'gnofolder@example.com');
        cloudOriginal(agr.Id);
        completedField(agr.Id, signer.Id, 'X');

        Test.setMock(HttpCalloutMock.class, new OkMock());
        Boolean threw = false;
        Test.startTest();
        try {
            AgreementControllerGuest.generateStampedPDFServerGuest(agr.Id);
        } catch (AgreementControllerGuest.SignForceStampException e) {
            threw = true;
            Assert.isTrue(e.getMessage().contains('Stamped folder'), 'Got: ' + e.getMessage());
        }
        Test.stopTest();
        Assert.isTrue(threw, 'Missing stamped folder id must fail loudly');
    }

    @isTest
    static void cloudOriginal_http500_throws() {
        TestDataFactory.suppressCompletionStamp();
        reset();
        Agreement__c agr = cloudAgreement('Guest Cloud 500');
        Signer__c signer = TestDataFactory.createSignerWithToken(agr.Id, 'gc500@example.com');
        cloudOriginal(agr.Id);
        completedField(agr.Id, signer.Id, 'X');

        Test.setMock(HttpCalloutMock.class, new FailMock());
        Boolean threw = false;
        Test.startTest();
        try {
            AgreementControllerGuest.generateStampedPDFServerGuest(agr.Id);
        } catch (AgreementControllerGuest.SignForceStampException e) {
            threw = true;
            Assert.isTrue(e.getMessage().contains('HTTP 500'), 'Got: ' + e.getMessage());
        }
        Test.stopTest();
        Assert.isTrue(threw, 'Lambda HTTP 500 must surface as SignForceStampException');
        Assert.areEqual(0, stampedDocs(agr.Id).size());
    }

    @isTest
    static void cloudOriginal_calloutException_throws() {
        TestDataFactory.suppressCompletionStamp();
        reset();
        Agreement__c agr = cloudAgreement('Guest Cloud Net');
        Signer__c signer = TestDataFactory.createSignerWithToken(agr.Id, 'gcnet@example.com');
        cloudOriginal(agr.Id);
        completedField(agr.Id, signer.Id, 'X');

        Test.setMock(HttpCalloutMock.class, new ThrowMock());
        Boolean threw = false;
        Test.startTest();
        try {
            AgreementControllerGuest.generateStampedPDFServerGuest(agr.Id);
        } catch (AgreementControllerGuest.SignForceStampException e) {
            threw = true;
            Assert.isTrue(e.getMessage().contains('callout failed'), 'Got: ' + e.getMessage());
        }
        Test.stopTest();
        Assert.isTrue(threw, 'A callout exception must surface as SignForceStampException');
    }

    // ═════════════════════════════════════════════════════════════════════
    //  Guards and early exits
    // ═════════════════════════════════════════════════════════════════════

    @isTest
    static void finalStampAlreadyPresent_skipsDuplicate() {
        TestDataFactory.suppressCompletionStamp();
        reset();
        Agreement__c agr = TestDataFactory.createSentAgreement('Guest Final Exists');
        Signer__c signer = TestDataFactory.createSignerWithToken(agr.Id, 'gfinal@example.com');
        TestDataFactory.createTier1OriginalDoc(agr.Id);
        completedField(agr.Id, signer.Id, 'Done');

        agr.Status__c = 'Completed';
        agr.Completed_Date__c = DateTime.now().addHours(-1);
        update agr;
        // A Stamped row created after completion is a stamp that carries every signature.
        insert new Agreement_Document__c(
            Agreement__c = agr.Id, Name = 'Final Stamped', Document_Type__c = 'Stamped',
            Storage_Tier__c = 'Tier1', Storage_Type__c = 'Salesforce'
        );

        Test.setMock(HttpCalloutMock.class, new OkMock());
        Test.startTest();
        AgreementControllerGuest.generateStampedPDFServerGuest(agr.Id);
        Test.stopTest();

        Assert.areEqual(0, calls, 'The duplicate final stamp must not call the Lambda');
        Assert.areEqual(1, stampedDocs(agr.Id).size(), 'The existing final stamp is left untouched');
    }

    @isTest
    static void noOriginalDocument_throws() {
        TestDataFactory.suppressCompletionStamp();
        reset();
        Agreement__c agr = TestDataFactory.createSentAgreement('Guest No Original');

        Boolean threw = false;
        Test.startTest();
        try {
            AgreementControllerGuest.generateStampedPDFServerGuest(agr.Id);
        } catch (AgreementControllerGuest.SignForceStampException e) {
            threw = true;
            Assert.isTrue(e.getMessage().contains('No original document'), 'Got: ' + e.getMessage());
        }
        Test.stopTest();
        Assert.isTrue(threw, 'A missing original document must fail loudly');
    }

    @isTest
    static void noCompletedFields_throws() {
        TestDataFactory.suppressCompletionStamp();
        reset();
        Agreement__c agr = TestDataFactory.createSentAgreement('Guest No Fields');
        TestDataFactory.createTier1OriginalDoc(agr.Id);

        Boolean threw = false;
        Test.startTest();
        try {
            AgreementControllerGuest.generateStampedPDFServerGuest(agr.Id);
        } catch (AgreementControllerGuest.SignForceStampException e) {
            threw = true;
            Assert.isTrue(e.getMessage().contains('No completed signature fields'), 'Got: ' + e.getMessage());
        }
        Test.stopTest();
        Assert.isTrue(threw, 'No completed fields must fail loudly');
    }

    @isTest
    static void completedFieldsWithBlankValues_returnsWithoutStamping() {
        TestDataFactory.suppressCompletionStamp();
        reset();
        Agreement__c agr = TestDataFactory.createSentAgreement('Guest Blank Values');
        Signer__c signer = TestDataFactory.createSignerWithToken(agr.Id, 'gblank@example.com');
        TestDataFactory.createTier1OriginalDoc(agr.Id);
        Signature_Field__c f = TestDataFactory.createSignatureField(agr.Id, signer.Id, 1, 100, 200);
        f.Is_Completed__c = true;
        update f;

        Test.setMock(HttpCalloutMock.class, new OkMock());
        Test.startTest();
        AgreementControllerGuest.generateStampedPDFServerGuest(agr.Id);
        Test.stopTest();

        Assert.areEqual(0, calls, 'Nothing to draw, so no Lambda call');
        Assert.areEqual(0, stampedDocs(agr.Id).size());
    }

    // ═════════════════════════════════════════════════════════════════════
    //  Stamped file title (stampedFileTitle / truncateTitle)
    // ═════════════════════════════════════════════════════════════════════

    @isTest
    static void title_singleSigner_isSignedDocument() {
        TestDataFactory.suppressCompletionStamp();
        reset();
        Agreement__c agr = TestDataFactory.createSentAgreement('Title Single');
        Signer__c signer = TestDataFactory.createSignerWithToken(agr.Id, 'tsingle@example.com');
        TestDataFactory.createTier1OriginalDoc(agr.Id);
        completedField(agr.Id, signer.Id, 'Only Signer');

        Test.setMock(HttpCalloutMock.class, new OkMock());
        Test.startTest();
        AgreementControllerGuest.generateStampedPDFServerGuest(agr.Id);
        Test.stopTest();

        Assert.areEqual('Title Single - Signed Document', stampedTitle(agr.Id));
    }

    @isTest
    static void title_partiallySigned_showsProgressAndLatestSigner() {
        TestDataFactory.suppressCompletionStamp();
        reset();
        Agreement__c agr = TestDataFactory.createSentAgreement('Title Partial');
        Signer__c s1 = TestDataFactory.createSignerWithToken(agr.Id, 'tp1@example.com');
        TestDataFactory.createSignerWithToken(agr.Id, 'tp2@example.com');
        TestDataFactory.createTier1OriginalDoc(agr.Id);
        s1.Status__c = 'Signed';
        s1.Signed_Date__c = DateTime.now().addMinutes(-5);
        update s1;
        completedField(agr.Id, s1.Id, 'First Signer');

        Test.setMock(HttpCalloutMock.class, new OkMock());
        Test.startTest();
        AgreementControllerGuest.generateStampedPDFServerGuest(agr.Id);
        Test.stopTest();

        String title = stampedTitle(agr.Id);
        Assert.isTrue(title.startsWith('Title Partial - Signed 1 of 2'), 'Got: ' + title);
        Assert.isTrue(title.contains('tp1'), 'The latest signer is named, got: ' + title);
    }

    @isTest
    static void title_allSigned_isFinalSignedDocument() {
        TestDataFactory.suppressCompletionStamp();
        reset();
        Agreement__c agr = TestDataFactory.createSentAgreement('Title Final');
        Signer__c s1 = TestDataFactory.createSignerWithToken(agr.Id, 'tf1@example.com');
        Signer__c s2 = TestDataFactory.createSignerWithToken(agr.Id, 'tf2@example.com');
        TestDataFactory.createTier1OriginalDoc(agr.Id);
        s1.Status__c = 'Signed';
        s1.Signed_Date__c = DateTime.now().addMinutes(-10);
        update s1;
        s2.Status__c = 'Signed';
        s2.Signed_Date__c = DateTime.now().addMinutes(-5);
        update s2;
        completedField(agr.Id, s1.Id, 'First');

        Test.setMock(HttpCalloutMock.class, new OkMock());
        Test.startTest();
        AgreementControllerGuest.generateStampedPDFServerGuest(agr.Id);
        Test.stopTest();

        Assert.areEqual('Title Final - Final Signed Document', stampedTitle(agr.Id));
    }

    @isTest
    static void title_longAgreementName_staysWithinTitleLimit() {
        TestDataFactory.suppressCompletionStamp();
        reset();
        String longName = 'L'.repeat(70);
        Agreement__c agr = TestDataFactory.createSentAgreement(longName);
        Signer__c signer = TestDataFactory.createSignerWithToken(agr.Id, 'tlong@example.com');
        TestDataFactory.createTier1OriginalDoc(agr.Id);
        completedField(agr.Id, signer.Id, 'Long');

        Test.setMock(HttpCalloutMock.class, new OkMock());
        Test.startTest();
        AgreementControllerGuest.generateStampedPDFServerGuest(agr.Id);
        Test.stopTest();

        Assert.isTrue(stampedTitle(agr.Id).length() <= 255, 'ContentVersion titles are capped at 255 characters');
        // Agreement names stop at 80 characters, so truncateTitle's >255 branch cannot be reached from here.
    }

    @isTest
    static void fileName_reservedCharactersAreCleaned() {
        TestDataFactory.suppressCompletionStamp();
        reset();
        Agreement__c agr = TestDataFactory.createSentAgreement('Name: with / bad * chars?');
        Signer__c signer = TestDataFactory.createSignerWithToken(agr.Id, 'tname@example.com');
        TestDataFactory.createTier1OriginalDoc(agr.Id);
        completedField(agr.Id, signer.Id, 'Name');

        Test.setMock(HttpCalloutMock.class, new OkMock());
        Test.startTest();
        AgreementControllerGuest.generateStampedPDFServerGuest(agr.Id);
        Test.stopTest();

        List<Agreement_Document__c> stamped = stampedDocs(agr.Id);
        Assert.areEqual(1, stamped.size());
        ContentVersion cv = [SELECT PathOnClient FROM ContentVersion WHERE Id = :stamped[0].Content_Version_ID__c];
        Assert.isTrue(cv.PathOnClient.endsWith('.pdf'), 'Got: ' + cv.PathOnClient);
        Assert.isFalse(cv.PathOnClient.contains('/') || cv.PathOnClient.contains('*') || cv.PathOnClient.contains('?'),
            'Reserved characters must be replaced, got: ' + cv.PathOnClient);
    }

    // ═════════════════════════════════════════════════════════════════════
    //  Field payload (buildStampFieldList)
    // ═════════════════════════════════════════════════════════════════════

    @isTest
    static void fieldList_typedSignatureInitialsAndCheckbox_areEncodedForTheStamper() {
        TestDataFactory.suppressCompletionStamp();
        reset();
        Agreement__c agr = TestDataFactory.createSentAgreement('Guest Field Payload');
        Signer__c signer = TestDataFactory.createSignerWithToken(agr.Id, 'gfields@example.com');
        signer.Signed_Date__c = DateTime.now();
        signer.Signing_IP_Address__c = '203.0.113.7';
        update signer;
        TestDataFactory.createTier1OriginalDoc(agr.Id);

        Signature_Field__c sig = TestDataFactory.createSignatureField(agr.Id, signer.Id, 1, 100, 200);
        sig.Field_Value__c = 'typed:John Doe:Dancing Script';
        sig.Is_Completed__c = true;
        Signature_Field__c ini = TestDataFactory.createSignatureField(agr.Id, signer.Id, 1, 100, 300);
        ini.Field_Type__c = 'Initial';
        ini.Field_Value__c = 'typed:JD:Pacifico';
        ini.Is_Completed__c = true;
        Signature_Field__c chk = TestDataFactory.createSignatureField(agr.Id, signer.Id, 1, 100, 400);
        chk.Field_Type__c = 'Checkbox';
        chk.Field_Value__c = 'true';
        chk.Is_Completed__c = true;
        Signature_Field__c unchk = TestDataFactory.createSignatureField(agr.Id, signer.Id, 1, 100, 500);
        unchk.Field_Type__c = 'Checkbox';
        unchk.Field_Value__c = 'false';
        unchk.Is_Completed__c = true;
        update new List<Signature_Field__c>{ sig, ini, chk, unchk };

        Test.setMock(HttpCalloutMock.class, new OkMock());
        Test.startTest();
        AgreementControllerGuest.generateStampedPDFServerGuest(agr.Id);
        Test.stopTest();

        Assert.areEqual(1, stampedDocs(agr.Id).size(), 'One Stamped doc should exist');
        Assert.isTrue(lastBody.contains('"parsedValue":"John Doe"'), 'Typed signature name is extracted');
        Assert.isTrue(lastBody.contains('"fontFamily":"Dancing Script"'), 'Typed signature font is extracted');
        Assert.isTrue(lastBody.contains('"parsedValue":"JD"'), 'Typed initials are extracted');
        Assert.isTrue(lastBody.contains('"checkboxChecked":true'), 'A checked box is flagged');
        Assert.isTrue(lastBody.contains('"checkboxChecked":false'), 'An unchecked box is flagged');
        Assert.isTrue(lastBody.contains('UTC'), 'The signed timestamp is sent as UTC');
        Assert.isTrue(lastBody.contains('203.0.113.7'), 'The signer IP is sent');
    }

    // ═════════════════════════════════════════════════════════════════════
    //  Exception type: the guest class throws its own
    // ═════════════════════════════════════════════════════════════════════

    @isTest
    static void failures_useTheGuestStampException() {
        TestDataFactory.suppressCompletionStamp();
        reset();
        Agreement__c agr = TestDataFactory.createSentAgreement('Guest Exception Type');
        Boolean sharedType = false;
        Test.startTest();
        try {
            AgreementControllerGuest.generateStampedPDFServerGuest(agr.Id);
        } catch (Exception e) {
            sharedType = e instanceof AgreementControllerGuest.SignForceStampException;
        }
        Test.stopTest();
        Assert.isTrue(sharedType, 'Callers that catch AgreementControllerGuest.SignForceStampException must keep working');
    }
}
