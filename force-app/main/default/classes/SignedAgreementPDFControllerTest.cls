/**
 * SignedAgreementPDFControllerTest — exhaustive tests for the signing
 * certificate VF controller + Apex entry point.
 *
 * Two surfaces:
 *
 *   1. SignedAgreementPDFController() constructor — runs when the VF page
 *      Page.SignedAgreementPDF is rendered. Reads agreementId from URL
 *      params, loads Agreement + Owner + Signers + Signature_Field__c
 *      (primary path) + Saved_Signature__c (fallback path) + Audit Events.
 *
 *   2. generateAndAttachPDF(agreementId) — @AuraEnabled static. Triggers
 *      Page.SignedAgreementPDF.getContentAsPDF() and stores the result as
 *      a ContentVersion + Agreement_Document__c.
 *
 * Fix notes (v2):
 *   - buildSigField() now includes Page_Number__c, X_Position__c,
 *     Y_Position__c — all required fields on Signature_Field__c.
 *   - generateAndAttachPDF tests now call createOriginalDocument() which
 *     inserts a ContentVersion + Agreement_Document__c (type='Original')
 *     so AgreementControllerGuest.generateStampedPDFServerGuest() can find the doc.
 *   - constructor_noAgreementIdParam now checks hasData=false +
 *     diagnosticMessage instead of Assert.isNull on initialized collections.
 */
@isTest(SeeAllData=false)
private class SignedAgreementPDFControllerTest {

    // ─────────────────────────────────────────────────────────────────────
    //  Helper: insert a completed Signature_Field__c with all required fields
    // ─────────────────────────────────────────────────────────────────────
    private static Signature_Field__c buildSigField(
            Id agreementId, Id signerId, String fieldValue, String fieldType) {
        Signature_Field__c sf = new Signature_Field__c();
        sf.Agreement__c       = agreementId;
        sf.Assigned_Signer__c = signerId;
        sf.Field_Value__c     = fieldValue;
        sf.Field_Type__c      = fieldType;    // 'Signature' or 'Initial'
        sf.Is_Completed__c    = true;
        // Required fields — use sensible defaults for test data
        sf.Page_Number__c     = 1;
        sf.X_Position__c      = 100;
        sf.Y_Position__c      = 200;
        return sf;
    }

    // ─────────────────────────────────────────────────────────────────────
    //  Helper: create an 'Original' Agreement_Document__c so stamping works
    //  AgreementControllerGuest.generateStampedPDFServerGuest() requires at least one
    //  Agreement_Document__c with Document_Type__c = 'Original' linked to
    //  a real ContentVersion.
    // ─────────────────────────────────────────────────────────────────────
    private static void createOriginalDocument(Id agreementId) {
        // 1. Insert a minimal PDF blob as ContentVersion
        ContentVersion cv = new ContentVersion();
        cv.Title          = 'Original Agreement';
        cv.PathOnClient   = 'OriginalAgreement.pdf';
        cv.VersionData    = Blob.valueOf('%PDF-1.4 test placeholder');
        cv.FirstPublishLocationId = agreementId;
        insert cv;

        // Re-query to get the auto-assigned Id after insert
        ContentVersion inserted = [SELECT Id FROM ContentVersion WHERE Id = :cv.Id];

        // 2. Link it as the Original document record
        Agreement_Document__c doc = new Agreement_Document__c();
        doc.Agreement__c          = agreementId;
        doc.Content_Version_ID__c = inserted.Id;
        doc.Document_Type__c      = 'Original';
        insert doc;
    }

    // ═════════════════════════════════════════════════════════════════════
    //  Constructor — no-param early-return branch
    // ═════════════════════════════════════════════════════════════════════

    @isTest
    static void constructor_noAgreementIdParam_hasDataFalseAndDiagnosticSet() {
        TestDataFactory.suppressCompletionStamp();
        // Simulate the VF page being hit without ?agreementId=...
        PageReference pg = Page.SignedAgreementPDF;
        Test.setCurrentPage(pg);

        Test.startTest();
        SignedAgreementPDFController ctrl = new SignedAgreementPDFController();
        Test.stopTest();

        // Constructor initializes collections to empty (never null),
        // but hasData must stay false and diagnosticMessage must explain why.
        Assert.isFalse(ctrl.hasData,
            'No agreementId param → hasData should be false');
        Assert.isTrue(String.isNotBlank(ctrl.diagnosticMessage),
            'No agreementId param → diagnosticMessage should explain missing param');
        Assert.isNotNull(ctrl.signers,
            'signers list should be initialized (empty), not null');
        Assert.areEqual(0, ctrl.signers.size(),
            'signers list should be empty when no param passed');
        Assert.isNotNull(ctrl.auditEvents,
            'auditEvents list should be initialized (empty), not null');
    }

    // ═════════════════════════════════════════════════════════════════════
    //  Constructor — valid agreement, basic load
    // ═════════════════════════════════════════════════════════════════════

    @isTest
    static void constructor_validAgreement_loadsData() {
        TestDataFactory.suppressCompletionStamp();
        Agreement__c agr = TestDataFactory.createSentAgreement('Cert Basic');
        Signer__c signer = TestDataFactory.createSignerInState(
            agr.Id, 'cert@example.com', 'Signed',
            DateTime.now(), false, 1
        );
        signer.Signed_Date__c              = DateTime.now();
        signer.Signature_Certificate_ID__c = 'CERT-12345-ABCDE';
        signer.Signing_IP_Address__c       = '127.0.0.1';
        update signer;

        PageReference pg = Page.SignedAgreementPDF;
        pg.getParameters().put('agreementId', agr.Id);
        Test.setCurrentPage(pg);

        Test.startTest();
        SignedAgreementPDFController ctrl = new SignedAgreementPDFController();
        Test.stopTest();

        Assert.isTrue(ctrl.hasData, 'hasData must be true when agreement loads successfully');
        Assert.isNotNull(ctrl.agreement, 'Agreement should be loaded');
        Assert.areEqual(agr.Id, ctrl.agreement.Id);
        Assert.areEqual(1, ctrl.signers.size(), 'One signer expected');
        Assert.isTrue(ctrl.signers[0].isSigned,  'Signer should be marked isSigned');
        Assert.areEqual('CERT-12345-ABCDE', ctrl.signers[0].certificateId);
        Assert.areEqual('127.0.0.1',         ctrl.signers[0].signingIpAddress);
        Assert.isTrue(String.isNotBlank(ctrl.signers[0].signedDateStr),
            'signedDateStr should be formatted');
        Assert.isNotNull(ctrl.generatedDate, 'generatedDate must be set');
        Assert.isNotNull(ctrl.sentByName,    'sentByName must be set');
    }

    @isTest
    static void constructor_validAgreementNoSigners_hasDataTrueEmptySigners() {
        TestDataFactory.suppressCompletionStamp();
        Agreement__c agr = TestDataFactory.createSentAgreement('Cert No Signers');

        PageReference pg = Page.SignedAgreementPDF;
        pg.getParameters().put('agreementId', agr.Id);
        Test.setCurrentPage(pg);

        Test.startTest();
        SignedAgreementPDFController ctrl = new SignedAgreementPDFController();
        Test.stopTest();

        Assert.isTrue(ctrl.hasData, 'hasData must be true even with zero signers');
        Assert.areEqual(0, ctrl.signers.size(),    'Signer list should be empty');
        Assert.areEqual(0, ctrl.auditEvents.size(),'Audit list should be empty');
    }

    // ═════════════════════════════════════════════════════════════════════
    //  Constructor — Signature_Field__c PRIMARY PATH
    // ═════════════════════════════════════════════════════════════════════

    @isTest
    static void constructor_sigFieldDraw_setsIsDrawFlag() {
        TestDataFactory.suppressCompletionStamp();
        Agreement__c agr = TestDataFactory.createSentAgreement('Cert SigField Draw');
        Signer__c signer = TestDataFactory.createSignerWithToken(agr.Id, 'sfdraw@example.com');

        insert buildSigField(agr.Id, signer.Id,
            '[{"id":1,"d":"M 10 20 L 30 40"}]', 'Signature');

        PageReference pg = Page.SignedAgreementPDF;
        pg.getParameters().put('agreementId', agr.Id);
        Test.setCurrentPage(pg);

        Test.startTest();
        SignedAgreementPDFController ctrl = new SignedAgreementPDFController();
        Test.stopTest();

        Assert.areEqual(1, ctrl.signers.size());
        Assert.isTrue(ctrl.signers[0].hasSignature,    'hasSignature must be true');
        Assert.isTrue(ctrl.signers[0].isDrawSignature, 'isDrawSignature must be true');
        Assert.isFalse(ctrl.signers[0].isTypeSignature);
        Assert.isFalse(ctrl.signers[0].isUploadSignature);
        Assert.areEqual('Draw', ctrl.signers[0].signatureType);
    }

    @isTest
    static void constructor_sigFieldTyped_parsesNameAndFont() {
        TestDataFactory.suppressCompletionStamp();
        Agreement__c agr = TestDataFactory.createSentAgreement('Cert SigField Type');
        Signer__c signer = TestDataFactory.createSignerWithToken(agr.Id, 'sftype@example.com');

        insert buildSigField(agr.Id, signer.Id,
            'typed:Jane Doe:Great Vibes', 'Signature');

        PageReference pg = Page.SignedAgreementPDF;
        pg.getParameters().put('agreementId', agr.Id);
        Test.setCurrentPage(pg);

        Test.startTest();
        SignedAgreementPDFController ctrl = new SignedAgreementPDFController();
        Test.stopTest();

        Assert.areEqual(1, ctrl.signers.size());
        Assert.isTrue(ctrl.signers[0].isTypeSignature, 'isTypeSignature must be true');
        Assert.areEqual('Jane Doe',    ctrl.signers[0].typedName,
            'Should parse name from typed:Name:Font format');
        Assert.areEqual('Great Vibes', ctrl.signers[0].typedFont,
            'Should parse font from typed:Name:Font format');
        Assert.areEqual('Great Vibes', ctrl.signers[0].fontFamily,
            'fontFamily should mirror typedFont');
        Assert.areEqual('Type', ctrl.signers[0].signatureType);
    }

    @isTest
    static void constructor_sigFieldUpload_setsIsUploadFlag() {
        TestDataFactory.suppressCompletionStamp();
        Agreement__c agr = TestDataFactory.createSentAgreement('Cert SigField Upload');
        Signer__c signer = TestDataFactory.createSignerWithToken(agr.Id, 'sfupload@example.com');

        insert buildSigField(agr.Id, signer.Id,
            'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAUA', 'Signature');

        PageReference pg = Page.SignedAgreementPDF;
        pg.getParameters().put('agreementId', agr.Id);
        Test.setCurrentPage(pg);

        Test.startTest();
        SignedAgreementPDFController ctrl = new SignedAgreementPDFController();
        Test.stopTest();

        Assert.areEqual(1, ctrl.signers.size());
        Assert.isTrue(ctrl.signers[0].isUploadSignature, 'isUploadSignature must be true');
        Assert.isFalse(ctrl.signers[0].isDrawSignature);
        Assert.isFalse(ctrl.signers[0].isTypeSignature);
        Assert.areEqual('Upload', ctrl.signers[0].signatureType);
    }

    @isTest
    static void constructor_sigFieldInitialType_alsoPickedUp() {
        TestDataFactory.suppressCompletionStamp();
        // Field_Type__c = 'Initial' should also be picked up by the controller query
        Agreement__c agr = TestDataFactory.createSentAgreement('Cert SigField Initial');
        Signer__c signer = TestDataFactory.createSignerWithToken(agr.Id, 'sfinitial@example.com');

        insert buildSigField(agr.Id, signer.Id,
            'typed:John Smith:Dancing Script', 'Initial');

        PageReference pg = Page.SignedAgreementPDF;
        pg.getParameters().put('agreementId', agr.Id);
        Test.setCurrentPage(pg);

        Test.startTest();
        SignedAgreementPDFController ctrl = new SignedAgreementPDFController();
        Test.stopTest();

        Assert.isTrue(ctrl.signers[0].hasSignature,
            'Initial-type Signature_Field__c should still populate hasSignature');
        Assert.isTrue(ctrl.signers[0].isTypeSignature);
        Assert.areEqual('John Smith', ctrl.signers[0].typedName);
    }

    @isTest
    static void constructor_sigFieldTakesPriorityOverSavedSignature() {
        TestDataFactory.suppressCompletionStamp();
        // Both Signature_Field__c (typed) AND Saved_Signature__c (draw) exist
        // for the same signer — Signature_Field__c must win.
        Agreement__c agr = TestDataFactory.createSentAgreement('Cert Priority');
        Signer__c signer = TestDataFactory.createSignerWithToken(agr.Id, 'priority@example.com');

        // Primary path
        insert buildSigField(agr.Id, signer.Id,
            'typed:Primary Name:Dancing Script', 'Signature');

        // Fallback path (should be ignored)
        Saved_Signature__c saved = new Saved_Signature__c();
        saved.Email__c          = 'priority@example.com';
        saved.Signature_Type__c = 'Draw';
        saved.Signature_Data__c = '[{"id":1,"d":"M 0 0"}]';
        insert saved;

        PageReference pg = Page.SignedAgreementPDF;
        pg.getParameters().put('agreementId', agr.Id);
        Test.setCurrentPage(pg);

        Test.startTest();
        SignedAgreementPDFController ctrl = new SignedAgreementPDFController();
        Test.stopTest();

        Assert.isTrue(ctrl.signers[0].isTypeSignature,
            'Signature_Field__c (typed) should take priority over Saved_Signature__c (draw)');
        Assert.isFalse(ctrl.signers[0].isDrawSignature,
            'Saved_Signature__c draw must NOT override Signature_Field__c typed value');
        Assert.areEqual('Primary Name', ctrl.signers[0].typedName);
    }

    // ═════════════════════════════════════════════════════════════════════
    //  Constructor — Saved_Signature__c FALLBACK PATH
    // ═════════════════════════════════════════════════════════════════════

    @isTest
    static void constructor_signerWithDrawSignature_setsIsDrawFlag() {
        TestDataFactory.suppressCompletionStamp();
        Agreement__c agr = TestDataFactory.createSentAgreement('Cert Draw Sig');
        Signer__c signer = TestDataFactory.createSignerWithToken(agr.Id, 'draw@example.com');
        // No Signature_Field__c → falls through to Saved_Signature__c

        Saved_Signature__c sig = new Saved_Signature__c();
        sig.Email__c          = 'draw@example.com';
        sig.Signature_Type__c = 'Draw';
        sig.Signature_Data__c = '[{"id":1,"d":"M 10 20 L 30 40"}]';
        insert sig;

        PageReference pg = Page.SignedAgreementPDF;
        pg.getParameters().put('agreementId', agr.Id);
        Test.setCurrentPage(pg);

        Test.startTest();
        SignedAgreementPDFController ctrl = new SignedAgreementPDFController();
        Test.stopTest();

        Assert.areEqual(1, ctrl.signers.size());
        Assert.isTrue(ctrl.signers[0].hasSignature,
            'Should detect saved signature for this email');
        Assert.isTrue(ctrl.signers[0].isDrawSignature,
            'Draw signature type → isDrawSignature=true');
        Assert.isFalse(ctrl.signers[0].isTypeSignature);
        Assert.isFalse(ctrl.signers[0].isUploadSignature);
    }

    @isTest
    static void constructor_signerWithTypeSignature_parsesNameAndFont() {
        TestDataFactory.suppressCompletionStamp();
        Agreement__c agr = TestDataFactory.createSentAgreement('Cert Type Sig');
        Signer__c signer = TestDataFactory.createSignerWithToken(agr.Id, 'type@example.com');

        Saved_Signature__c sig = new Saved_Signature__c();
        sig.Email__c          = 'type@example.com';
        sig.Signature_Type__c = 'Type';
        sig.Signature_Data__c = 'typed:Jane Doe:Great Vibes';
        insert sig;

        PageReference pg = Page.SignedAgreementPDF;
        pg.getParameters().put('agreementId', agr.Id);
        Test.setCurrentPage(pg);

        Test.startTest();
        SignedAgreementPDFController ctrl = new SignedAgreementPDFController();
        Test.stopTest();

        Assert.areEqual(1, ctrl.signers.size());
        Assert.isTrue(ctrl.signers[0].isTypeSignature);
        Assert.areEqual('Jane Doe',    ctrl.signers[0].typedName,
            'Should parse name from typed:Name:Font format');
        Assert.areEqual('Great Vibes', ctrl.signers[0].typedFont,
            'Should parse font from typed:Name:Font format');
    }

    @isTest
    static void constructor_signerWithUploadSignature_setsIsUploadFlag() {
        TestDataFactory.suppressCompletionStamp();
        Agreement__c agr = TestDataFactory.createSentAgreement('Cert Upload Sig');
        Signer__c signer = TestDataFactory.createSignerWithToken(agr.Id, 'upload@example.com');

        Saved_Signature__c sig = new Saved_Signature__c();
        sig.Email__c          = 'upload@example.com';
        sig.Signature_Type__c = 'Upload';
        sig.Signature_Data__c = 'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAA';
        insert sig;

        PageReference pg = Page.SignedAgreementPDF;
        pg.getParameters().put('agreementId', agr.Id);
        Test.setCurrentPage(pg);

        Test.startTest();
        SignedAgreementPDFController ctrl = new SignedAgreementPDFController();
        Test.stopTest();

        Assert.areEqual(1, ctrl.signers.size());
        Assert.isTrue(ctrl.signers[0].isUploadSignature);
        Assert.isFalse(ctrl.signers[0].isDrawSignature);
        Assert.isFalse(ctrl.signers[0].isTypeSignature);
    }

    @isTest
    static void constructor_signerWithoutSavedSignature_hasSignatureFalse() {
        TestDataFactory.suppressCompletionStamp();
        Agreement__c agr = TestDataFactory.createSentAgreement('Cert No Sig');
        Signer__c signer = TestDataFactory.createSignerWithToken(agr.Id, 'nosig@example.com');

        PageReference pg = Page.SignedAgreementPDF;
        pg.getParameters().put('agreementId', agr.Id);
        Test.setCurrentPage(pg);

        Test.startTest();
        SignedAgreementPDFController ctrl = new SignedAgreementPDFController();
        Test.stopTest();

        Assert.areEqual(1, ctrl.signers.size());
        Assert.isFalse(ctrl.signers[0].hasSignature,
            'No signature anywhere → hasSignature should be false');
        Assert.isFalse(ctrl.signers[0].isDrawSignature);
        Assert.isFalse(ctrl.signers[0].isTypeSignature);
        Assert.isFalse(ctrl.signers[0].isUploadSignature);
    }

    // ═════════════════════════════════════════════════════════════════════
    //  Constructor — signer status & ordering
    // ═════════════════════════════════════════════════════════════════════

    @isTest
    static void constructor_pendingSigner_signedDateStrIsPending() {
        TestDataFactory.suppressCompletionStamp();
        Agreement__c agr = TestDataFactory.createSentAgreement('Cert Pending');
        TestDataFactory.createSignerWithToken(agr.Id, 'pending@example.com');

        PageReference pg = Page.SignedAgreementPDF;
        pg.getParameters().put('agreementId', agr.Id);
        Test.setCurrentPage(pg);

        Test.startTest();
        SignedAgreementPDFController ctrl = new SignedAgreementPDFController();
        Test.stopTest();

        Assert.areEqual('Pending', ctrl.signers[0].signedDateStr,
            'Signer with no Signed_Date__c should show "Pending"');
        Assert.isFalse(ctrl.signers[0].isSigned,
            'Pending status → isSigned should be false');
    }

    @isTest
    static void constructor_multipleSigners_loadsAllInOrder() {
        TestDataFactory.suppressCompletionStamp();
        Agreement__c agr = TestDataFactory.createSentAgreement('Cert Multi Sig');
        TestDataFactory.createSignerWithToken(agr.Id, 'a@example.com');
        Signer__c s2 = TestDataFactory.createSignerWithToken(agr.Id, 'b@example.com');
        s2.Signing_Order__c = 2; update s2;
        Signer__c s3 = TestDataFactory.createSignerWithToken(agr.Id, 'c@example.com');
        s3.Signing_Order__c = 3; update s3;

        PageReference pg = Page.SignedAgreementPDF;
        pg.getParameters().put('agreementId', agr.Id);
        Test.setCurrentPage(pg);

        Test.startTest();
        SignedAgreementPDFController ctrl = new SignedAgreementPDFController();
        Test.stopTest();

        Assert.areEqual(3, ctrl.signers.size(), 'All three signers should load');
        Assert.isTrue(ctrl.hasData);
    }

    // ═════════════════════════════════════════════════════════════════════
    //  Constructor — signerCount excludes CC recipients (BUG-058)
    // ═════════════════════════════════════════════════════════════════════

    @isTest
    static void constructor_ccRecipient_excludedFromSignerCount() {
        TestDataFactory.suppressCompletionStamp();
        Agreement__c agr = TestDataFactory.createSentAgreement('Cert CC Count');

        // One true signer
        TestDataFactory.createSignerWithToken(agr.Id, 'signer@example.com');

        // One CC recipient (Role__c = 'CC') — must NOT inflate signerCount
        Signer__c cc = TestDataFactory.createSignerWithToken(agr.Id, 'cc@example.com');
        cc.Role__c = 'CC';
        cc.Signing_Order__c = 2;
        update cc;

        PageReference pg = Page.SignedAgreementPDF;
        pg.getParameters().put('agreementId', agr.Id);
        Test.setCurrentPage(pg);

        Test.startTest();
        SignedAgreementPDFController ctrl = new SignedAgreementPDFController();
        Test.stopTest();

        // Both recipients still load as per-signer cards...
        Assert.areEqual(2, ctrl.signers.size(),
            'Both signer + CC rows should still load for the per-signer cards');
        // ...but the stat-card count ("Total Signers" / "Signatures") must
        // count the true signer only, not the CC recipient.
        Assert.areEqual(1, ctrl.signerCount,
            'signerCount must exclude CC recipients (1 signer + 1 CC → 1)');
    }

    @isTest
    static void constructor_legacyNullRoleSigner_countedInSignerCount() {
        TestDataFactory.suppressCompletionStamp();
        Agreement__c agr = TestDataFactory.createSentAgreement('Cert Null Role');

        // Legacy signer with no Role__c → must still count as a signer
        Signer__c s = TestDataFactory.createSignerWithToken(agr.Id, 'legacy@example.com');
        s.Role__c = null;
        update s;

        PageReference pg = Page.SignedAgreementPDF;
        pg.getParameters().put('agreementId', agr.Id);
        Test.setCurrentPage(pg);

        Test.startTest();
        SignedAgreementPDFController ctrl = new SignedAgreementPDFController();
        Test.stopTest();

        Assert.areEqual(1, ctrl.signerCount,
            'Legacy signer with null Role__c must be counted as a signer');
    }

    // ═════════════════════════════════════════════════════════════════════
    //  Constructor — date formatting
    // ═════════════════════════════════════════════════════════════════════

    @isTest
    static void constructor_withCompletedDate_formatsDateString() {
        TestDataFactory.suppressCompletionStamp();
        Agreement__c agr = TestDataFactory.createSentAgreement('Cert Completed Date');
        agr.Status__c         = 'Completed';
        agr.Completed_Date__c = DateTime.newInstance(2026, 1, 15, 10, 30, 0);
        update agr;

        PageReference pg = Page.SignedAgreementPDF;
        pg.getParameters().put('agreementId', agr.Id);
        Test.setCurrentPage(pg);

        Test.startTest();
        SignedAgreementPDFController ctrl = new SignedAgreementPDFController();
        Test.stopTest();

        Assert.isTrue(ctrl.completedDateStr.contains('2026'),
            'completedDateStr should reflect Completed_Date__c year');
        // BUG-056: month is standardized on the abbreviated 'MMM' token, so
        // January renders as 'Jan' (not 'January').
        Assert.isTrue(ctrl.completedDateStr.contains('Jan'),
            'completedDateStr should include the abbreviated month name (MMM)');
    }

    @isTest
    static void constructor_noCompletedDate_completedDateStrStillPopulated() {
        TestDataFactory.suppressCompletionStamp();
        Agreement__c agr = TestDataFactory.createSentAgreement('Cert No CompDate');

        PageReference pg = Page.SignedAgreementPDF;
        pg.getParameters().put('agreementId', agr.Id);
        Test.setCurrentPage(pg);

        Test.startTest();
        SignedAgreementPDFController ctrl = new SignedAgreementPDFController();
        Test.stopTest();

        Assert.isTrue(String.isNotBlank(ctrl.completedDateStr),
            'completedDateStr should always be non-blank (falls back to DateTime.now)');
    }

    // ═════════════════════════════════════════════════════════════════════
    //  Constructor — audit events
    // ═════════════════════════════════════════════════════════════════════

    @isTest
    static void constructor_withAuditEvents_loadsAllOrdered() {
        TestDataFactory.suppressCompletionStamp();
        Agreement__c agr = TestDataFactory.createSentAgreement('Cert Audit Events');

        AuditTrailService.log(agr.Id, 'Event A', 'a@example.com', '1.1.1.1', null);
        AuditTrailService.log(agr.Id, 'Event B', 'b@example.com', '2.2.2.2', null);
        AuditTrailService.log(agr.Id, 'Event C', 'c@example.com', '3.3.3.3', null);

        PageReference pg = Page.SignedAgreementPDF;
        pg.getParameters().put('agreementId', agr.Id);
        Test.setCurrentPage(pg);

        Test.startTest();
        SignedAgreementPDFController ctrl = new SignedAgreementPDFController();
        Test.stopTest();

        Assert.areEqual(3, ctrl.auditEvents.size(),
            'All three audit events should load');
        Assert.areEqual('Event A', ctrl.auditEvents[0].Action__c,
            'First event chronologically should be Event A');

        // auditRows mirrors auditEvents but with the timestamp pre-formatted
        // in the org default timezone (with zone label) — this is what the
        // VF audit table binds to, so all cert timestamps match.
        Assert.isNotNull(ctrl.auditRows, 'auditRows should be initialized');
        Assert.areEqual(3, ctrl.auditRows.size(),
            'auditRows should mirror auditEvents one-to-one');
        Assert.areEqual('Event A', ctrl.auditRows[0].action,
            'auditRows action should mirror the event action');
        Assert.areEqual('a@example.com', ctrl.auditRows[0].signerEmail,
            'auditRows signerEmail should mirror the event signer email');
        Assert.areEqual('1.1.1.1', ctrl.auditRows[0].ipAddress,
            'auditRows ipAddress should mirror the event IP');
        Assert.isTrue(String.isNotBlank(ctrl.auditRows[0].timestampStr),
            'auditRows timestamp should be formatted (org tz + zone label)');
    }

    // ═════════════════════════════════════════════════════════════════════
    //  generateAndAttachPDF — @AuraEnabled entry point
    //  NOTE: createOriginalDocument() is called before each test because
    //  AgreementControllerGuest.generateStampedPDFServerGuest() requires an
    //  Agreement_Document__c with Document_Type__c = 'Original'.
    // ═════════════════════════════════════════════════════════════════════

    @isTest
    static void generateAndAttachPDF_validAgreement_createsCertificate() {
        TestDataFactory.suppressCompletionStamp();
        Agreement__c agr = TestDataFactory.createSentAgreement('Cert Gen Happy');
        TestDataFactory.createSignerInState(
            agr.Id, 'gen@example.com', 'Signed',
            DateTime.now(), false, 1
        );
        createOriginalDocument(agr.Id);   // required so stamping doesn't throw

        Test.startTest();
        SignedAgreementPDFController.generateAndAttachPDF(agr.Id);
        Test.stopTest();

        List<Agreement_Document__c> signedDocs = [
            SELECT Id, Document_Type__c, Content_Version_ID__c
            FROM Agreement_Document__c
            WHERE Agreement__c = :agr.Id AND Document_Type__c = 'Signed'
        ];
        Assert.areEqual(1, signedDocs.size(),
            'One Signed-type Agreement_Document__c should be created');
        Assert.isNotNull(signedDocs[0].Content_Version_ID__c,
            'Content_Version_ID__c should be populated');

        List<ContentVersion> cvs = [
            SELECT Id, Title FROM ContentVersion
            WHERE Id = :signedDocs[0].Content_Version_ID__c
        ];
        Assert.areEqual(1, cvs.size(), 'Underlying ContentVersion should exist');
        Assert.isTrue(cvs[0].Title.contains('Signing Certificate'),
            'CV title should follow the "<name> - Signing Certificate" pattern');
    }

    @isTest
    static void generateAndAttachPDF_existingCertificate_replacesOld() {
        TestDataFactory.suppressCompletionStamp();
        Agreement__c agr = TestDataFactory.createSentAgreement('Cert Replace');
        createOriginalDocument(agr.Id);

        Test.startTest();
        SignedAgreementPDFController.generateAndAttachPDF(agr.Id);

        List<Agreement_Document__c> first = [
            SELECT Id FROM Agreement_Document__c
            WHERE Agreement__c = :agr.Id AND Document_Type__c = 'Signed'
        ];
        Id firstCertId = first[0].Id;

        SignedAgreementPDFController.generateAndAttachPDF(agr.Id);
        Test.stopTest();

        List<Agreement_Document__c> second = [
            SELECT Id FROM Agreement_Document__c
            WHERE Agreement__c = :agr.Id AND Document_Type__c = 'Signed'
        ];
        Assert.areEqual(1, second.size(),
            'Still only one Signed-type doc after regeneration');
        Assert.areNotEqual(firstCertId, second[0].Id,
            'Old certificate should be deleted, new one created with different Id');
    }

    @isTest
    static void generateAndAttachPDF_nullAgreementId_throws() {
        TestDataFactory.suppressCompletionStamp();
        Boolean threw = false;
        Test.startTest();
        try {
            SignedAgreementPDFController.generateAndAttachPDF(null);
        } catch (Exception e) {
            threw = true;
        }
        Test.stopTest();

        Assert.isTrue(threw, 'null agreementId should throw (SOQL list out of bounds)');
    }
}