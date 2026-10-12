/**
* AgreementServiceGuestTest — coverage for AgreementServiceGuest, the guest-facing half of
* AgreementService (token validation, mark signed, declines, next-signer / confirmation /
* completion emails, S3 URL refresh, document bytes).
*
* These are the AgreementServiceTest cases that exercise those methods, repointed at
* AgreementServiceGuest. Fixtures, mocks and assertions are unchanged.
* Cases for the methods that stayed in AgreementService remain in AgreementServiceTest.
**/
@isTest
private class AgreementServiceGuestTest {
    
    // ═══════════════════════════════════════════════════════
    // Test Data Factories
    // ═══════════════════════════════════════════════════════
    
    /**
* Creates a Draft Agreement__c via the service so all defaults are applied.
* OwnerId is explicitly the running user so Owner.Email is never null.
*/
    private static Agreement__c makeAgreement() {
        Agreement__c agr = AgreementService.createAgreement(
            'Test Agreement', 'Contract', 'Sequential',
            'Please sign by EOD', null
        );
        // FIX-2: ensure Owner.Email is always a real address in test context
        agr.OwnerId = UserInfo.getUserId();
        update agr;
        return agr;
    }
    
    /** Overload for tests that need to control Signing_Order__c. */
    private static Agreement__c makeAgreement(String signingOrder) {
        Agreement__c agr = AgreementService.createAgreement(
            'Test Agreement', 'Contract', signingOrder,
            'Please sign.', null
        );
        agr.OwnerId = UserInfo.getUserId();
        update agr;
        return agr;
    }
    
    /**
* Inserts a Signer__c directly (bypasses email sending).
* Token format mirrors reference class: 'tok_' prefix + 28-char hex.
*/
    private static Signer__c makeSigner(Id agreementId, String email, Integer order) {
        Signer__c s = new Signer__c(
            Agreement__c          = agreementId,
            Email__c              = email,
            Role__c               = 'Signer',
            Signing_Order__c      = order,
            Status__c             = 'Pending',
            Access_Token__c       = 'tok_' + EncodingUtil.convertToHex(
                Crypto.generateAesKey(128)).substring(0, 28),
            Token_Created_Date__c = DateTime.now(),
            Token_Expired__c      = false,
            Token_View_Count__c   = 0
        );
        insert s;
        return s;
    }
    /**
* Creates a completed Signature_Field__c for the stamp handler.
* Required by all markSigned tests (FIX-1 extension).
*/
    private static Signature_Field__c makeSignatureField(Id agreementId, Id signerId) {
        Signature_Field__c sf = new Signature_Field__c(
            Agreement__c      = agreementId,
            Assigned_Signer__c = signerId,
            Field_Type__c     = 'Signature',
            Field_Value__c    = 'Test Signature',
            Page_Number__c    = 1,
            X_Position__c     = 100,
            Y_Position__c     = 100,
            Width__c          = 200,
            Height__c         = 50,
            Page_Width__c     = 762,
            Is_Completed__c   = true
        );
        insert sf;
        return sf;
    }
    
    /** Overload for tests that need an explicit role (Signer / Approver / CC). */
    private static Signer__c makeSigner(Id agreementId, String email, String role, Integer order) {
        Signer__c s = new Signer__c(
            Agreement__c          = agreementId,
            Email__c              = email,
            Role__c               = role,
            Signing_Order__c      = order,
            Status__c             = 'Pending',
            Access_Token__c       = 'tok_' + EncodingUtil.convertToHex(
                Crypto.generateAesKey(128)).substring(0, 28),
            Token_Created_Date__c = DateTime.now(),
            Token_Expired__c      = false,
            Token_View_Count__c   = 0
        );
        insert s;
        return s;
    }
    
    /**
* Creates an Agreement_Document__c backed by a real ContentVersion so
* getDocumentBytes() resolves without any callout, AND so the stamp
* handler (triggered by markSigned → checkAgreementCompletion) finds a
* document and doesn't throw SignForceStampException. (FIX-1)
*/
    private static Agreement_Document__c makeDocument(Id agreementId, String docType) {
        ContentVersion cv = new ContentVersion(
            Title          = 'Test ' + docType,
            PathOnClient   = 'test.pdf',
            VersionData    = Blob.valueOf('%PDF-1.4 test placeholder'),
            IsMajorVersion = true
        );
        insert cv;
        cv = [SELECT Id FROM ContentVersion WHERE Id = :cv.Id WITH USER_MODE LIMIT 1];
        
        Agreement_Document__c doc = new Agreement_Document__c(
            Agreement__c          = agreementId,
            Document_Type__c      = docType,
            Name                  = 'Test ' + docType + ' Document',
            Content_Version_ID__c = cv.Id,
            File_Size_Bytes__c    = 25
        );
        insert doc;
        return doc;
    }
    
    // ═══════════════════════════════════════════════════════
    // validateToken — all branches
    // ═══════════════════════════════════════════════════════
    
    @isTest
    static void validateToken_blankAndShortInputs_returnError() {
        TestDataFactory.suppressCompletionStamp();
        System.assertEquals('Invalid signing link.',
                            AgreementServiceGuest.validateToken('').get('error'));
        System.assertNotEquals(null,
                               AgreementServiceGuest.validateToken(null).get('error'));
        System.assertNotEquals(null,
                               AgreementServiceGuest.validateToken('short').get('error'));
    }
    
    @isTest
    static void validateToken_unknownToken_returnsError() {
        TestDataFactory.suppressCompletionStamp();
        Map<String, Object> got = AgreementServiceGuest.validateToken('tok_unknown_unknown_unknown_xx');
        System.assertEquals('Invalid or expired signing link.', got.get('error'));
    }
    
    @isTest
    static void validateToken_manuallyRevoked_returnsError() {
        TestDataFactory.suppressCompletionStamp();
        Agreement__c agr = makeAgreement();
        Signer__c s = makeSigner(agr.Id, 'rev@test.com', 1);
        s.Token_Expired__c = true;
        update s;
        
        Map<String, Object> got = AgreementServiceGuest.validateToken(s.Access_Token__c);
        System.assertNotEquals(null, got.get('error'));
        System.assert(((String) got.get('error')).containsIgnoreCase('revoked'));
    }
    
    @isTest
    static void validateToken_alreadySigned_returnsError() {
        TestDataFactory.suppressCompletionStamp();
        Agreement__c agr = makeAgreement();
        Signer__c s = makeSigner(agr.Id, 'signed@test.com', 1);
        s.Status__c = 'Signed';
        update s;
        
        Map<String, Object> got = AgreementServiceGuest.validateToken(s.Access_Token__c);
        System.assert(((String) got.get('error')).containsIgnoreCase('already signed'));
    }
    
    @isTest
    static void validateToken_declined_returnsError() {
        TestDataFactory.suppressCompletionStamp();
        Agreement__c agr = makeAgreement();
        Signer__c s = makeSigner(agr.Id, 'dec@test.com', 1);
        s.Status__c = 'Declined';
        update s;
        
        Map<String, Object> got = AgreementServiceGuest.validateToken(s.Access_Token__c);
        System.assert(((String) got.get('error')).containsIgnoreCase('declined'));
    }
    
    @isTest
    static void validateToken_expired48h_returnsError() {
        TestDataFactory.suppressCompletionStamp();
        Agreement__c agr = makeAgreement();
        Signer__c s = makeSigner(agr.Id, 'old@test.com', 1);
        s.Token_Created_Date__c = DateTime.now().addHours(-49);
        update s;
        
        Map<String, Object> got = AgreementServiceGuest.validateToken(s.Access_Token__c);
        System.assert(((String) got.get('error')).containsIgnoreCase('expired'));
    }
    
    @isTest
    static void validateToken_rateLimitExceeded_returnsError() {
        TestDataFactory.suppressCompletionStamp();
        Agreement__c agr = makeAgreement();
        Signer__c s = makeSigner(agr.Id, 'rate@test.com', 1);
        s.Token_View_Count__c = 50; // equals MAX_TOKEN_VIEWS constant
        update s;
        
        Map<String, Object> got = AgreementServiceGuest.validateToken(s.Access_Token__c);
        System.assert(((String) got.get('error')).containsIgnoreCase('too many times'));
    }
    
    @isTest
    static void validateToken_voidedAgreement_returnsError() {
        TestDataFactory.suppressCompletionStamp();
        Agreement__c agr = makeAgreement();
        Signer__c s = makeSigner(agr.Id, 'v@test.com', 1);
        agr.Status__c      = 'Voided';
        agr.Void_Reason__c = 'No longer needed';
        update agr;
        
        Map<String, Object> got = AgreementServiceGuest.validateToken(s.Access_Token__c);
        System.assert(((String) got.get('error')).containsIgnoreCase('voided'));
    }
    
    @isTest
    static void validateToken_completedAgreement_returnsError() {
        TestDataFactory.suppressCompletionStamp();
        Agreement__c agr = makeAgreement();
        makeDocument(agr.Id, 'Original');
        Signer__c s = makeSigner(agr.Id, 'done@test.com', 1);
        makeSignatureField(agr.Id, s.Id);
        agr.Status__c = 'Completed';
        update agr;
        
        Map<String, Object> got = AgreementServiceGuest.validateToken(s.Access_Token__c);
        System.assert(((String) got.get('error')).containsIgnoreCase('completed'));
    }
    
    @isTest
    static void validateToken_pastExpiryDate_autoVoidsAgreementAndReturnsError() {
        TestDataFactory.suppressCompletionStamp();
        Agreement__c agr = makeAgreement();
        Signer__c s = makeSigner(agr.Id, 'exp@test.com', 1);
        agr.Expiry_Date__c = DateTime.now().addHours(-1);
        update agr;
        
        Test.startTest();
        Map<String, Object> got = AgreementServiceGuest.validateToken(s.Access_Token__c);
        Test.stopTest();
        
        System.assert(((String) got.get('error')).containsIgnoreCase('expired'));
        
        agr = [SELECT Status__c, Void_Reason__c FROM Agreement__c WHERE Id = :agr.Id WITH USER_MODE];
        System.assertEquals('Voided',  agr.Status__c,    'Expired agreement must be auto-voided.');
        System.assertEquals('Expired', agr.Void_Reason__c);
    }
    
    @isTest
    static void validateToken_happyPath_returnsSignerDataAndIncrementsViewCount() {
        TestDataFactory.suppressCompletionStamp();
        // FIX-3: set Envelope_ID__c explicitly so the happy-path assertion
        // on envelopeId doesn't fail for agreements not yet sent.
        Agreement__c agr = makeAgreement();
        agr.Status__c    = 'Sent';
        agr.Envelope_ID__c = AgreementService.generateUUID();
        update agr;
        
        Signer__c s = makeSigner(agr.Id, 'happy@test.com', 1);
        // Name drives the signing viewer's auto-populated Full Name on the
        // signature adopt sheet, so assert validateToken returns it.
        s.Name = 'Happy Tester';
        update s;

        Test.startTest();
        Map<String, Object> got = AgreementServiceGuest.validateToken(s.Access_Token__c);
        Test.stopTest();

        System.assertEquals(null, got.get('error'),
                            'Valid token must produce no error. Got: ' + got.get('error'));
        System.assertEquals(s.Id,             got.get('signerId'));
        System.assertEquals('happy@test.com', got.get('signerEmail'));
        System.assertEquals('Happy Tester',   got.get('signerName'),
                            'signerName must be returned so the adopt sheet can pre-fill the Full Name.');
        System.assertEquals(agr.Id,           got.get('agreementId'));
        System.assertNotEquals(null,           got.get('envelopeId'),
                               'envelopeId must be present when Envelope_ID__c is set on the agreement.');
        
        Signer__c reloaded = [SELECT Token_View_Count__c FROM Signer__c WHERE Id = :s.Id WITH USER_MODE];
        System.assertEquals(1, (Integer) reloaded.Token_View_Count__c,
                            'View count must increment on each valid access.');
    }

    // ═══════════════════════════════════════════════════════
    // markSigned
    // ═══════════════════════════════════════════════════════
    
    @isTest
    static void markSigned_setsAllSignedFields() {
        TestDataFactory.suppressCompletionStamp();
        Agreement__c agr = makeAgreement();
        agr.Status__c = 'Sent';
        update agr;
        makeDocument(agr.Id, 'Original');
        Signer__c s = makeSigner(agr.Id, 'sign@test.com', 1);
        makeSignatureField(agr.Id, s.Id);
        
        Test.startTest();
        AgreementServiceGuest.markSigned(s.Id, '1.2.3.4', 'TestBrowser/1.0');
        Test.stopTest();
        
        s = [SELECT Status__c, Signed_Date__c, Signing_IP_Address__c,
             Signing_User_Agent__c, Signature_Certificate_ID__c
             FROM Signer__c WHERE Id = :s.Id WITH USER_MODE];
        System.assertEquals('Signed',          s.Status__c);
        System.assertNotEquals(null,            s.Signed_Date__c);
        System.assertEquals('1.2.3.4',         s.Signing_IP_Address__c);
        System.assertEquals('TestBrowser/1.0', s.Signing_User_Agent__c);
        System.assertNotEquals(null,            s.Signature_Certificate_ID__c);
        
        Integer auditCount = [
            SELECT COUNT() FROM Signing_Event__c
            WHERE Agreement__c = :agr.Id AND Action__c = 'Document Signed' WITH USER_MODE
        ];
        System.assert(auditCount >= 1, '"Document Signed" audit entry must exist.');
    }
    @isTest
    static void markSigned_singleSigner_triggersAgreementCompletion() {
        TestDataFactory.suppressCompletionStamp();
        Agreement__c agr = makeAgreement('Parallel');
        agr.Status__c = 'Sent';
        update agr;
        makeDocument(agr.Id, 'Original');
        Signer__c s = makeSigner(agr.Id, 'only@test.com', 1);
        makeSignatureField(agr.Id, s.Id);
        
        Test.startTest();
        AgreementServiceGuest.markSigned(s.Id, '10.0.0.1', 'UA');
        Test.stopTest();
        
        agr = [SELECT Status__c, Completed_Date__c FROM Agreement__c WHERE Id = :agr.Id WITH USER_MODE];
        System.assertEquals('Completed', agr.Status__c,
                            'Agreement must flip to Completed when sole signer signs.');
        System.assertNotEquals(null, agr.Completed_Date__c);
    }
    
    @isTest
    static void markSigned_completion_finalizesPendingCcRecipient() {
        TestDataFactory.suppressCompletionStamp();
        // BUG-061: when the last Signer signs and the agreement completes,
        // any CC recipient still sitting in a non-terminal status must be
        // advanced to a terminal status (no more "Pending forever").
        Agreement__c agr = makeAgreement('Parallel');
        agr.Status__c = 'Sent';
        update agr;
        makeDocument(agr.Id, 'Original');
        Signer__c signer = makeSigner(agr.Id, 'onlysigner@test.com', 'Signer', 1);
        Signer__c cc      = makeSigner(agr.Id, 'cc@test.com',         'CC',     2);
        makeSignatureField(agr.Id, signer.Id);

        // Sanity: CC starts Pending.
        System.assertEquals('Pending',
            [SELECT Status__c FROM Signer__c WHERE Id = :cc.Id WITH USER_MODE].Status__c,
            'CC must start Pending before completion.');

        Test.startTest();
        AgreementServiceGuest.markSigned(signer.Id, '10.0.0.5', 'UA');
        Test.stopTest();

        agr = [SELECT Status__c FROM Agreement__c WHERE Id = :agr.Id WITH USER_MODE];
        System.assertEquals('Completed', agr.Status__c,
            'Agreement must complete once the sole Signer signs (CC does not block).');

        Signer__c ccReloaded = [SELECT Status__c FROM Signer__c WHERE Id = :cc.Id WITH USER_MODE];
        System.assertNotEquals('Pending', ccReloaded.Status__c,
            'CC recipient must be advanced out of Pending on completion.');
        System.assertEquals('Signed', ccReloaded.Status__c,
            'CC recipient must reach the terminal status used at completion.');
    }

    @isTest
    static void markSigned_partialSigners_agreementStaysInProgress() {
        TestDataFactory.suppressCompletionStamp();
        Agreement__c agr = makeAgreement('Parallel');
        agr.Status__c = 'Sent';
        update agr;
        makeDocument(agr.Id, 'Original');
        Signer__c s1 = makeSigner(agr.Id, 's1@test.com', 1);
        Signer__c s2 = makeSigner(agr.Id, 's2@test.com', 2);
        makeSignatureField(agr.Id, s1.Id);
        
        Test.startTest();
        AgreementServiceGuest.markSigned(s1.Id, '1.1.1.1', 'UA');
        Test.stopTest();
        
        agr = [SELECT Status__c FROM Agreement__c WHERE Id = :agr.Id WITH USER_MODE];
        System.assertNotEquals('Completed', agr.Status__c,
                               'Agreement must NOT complete while a signer is still pending.');
    }
    
    // ═══════════════════════════════════════════════════════
    // declineAgreement / declineAgreementGuest
    // ═══════════════════════════════════════════════════════
    
    @isTest
    static void declineAgreement_setsSignerAndAgreementStatus() {
        TestDataFactory.suppressCompletionStamp();
        Agreement__c agr = makeAgreement();
        agr.Status__c = 'Sent';
        update agr;
        Signer__c s = makeSigner(agr.Id, 'dec@test.com', 1);
        
        Test.startTest();
        AgreementServiceGuest.declineAgreement(s.Id, 'Wrong terms', '9.9.9.9');
        Test.stopTest();
        
        s   = [SELECT Status__c, Decline_Reason__c FROM Signer__c WHERE Id = :s.Id WITH USER_MODE];
        agr = [SELECT Status__c FROM Agreement__c WHERE Id = :agr.Id WITH USER_MODE];
        System.assertEquals('Declined',    s.Status__c);
        System.assertEquals('Wrong terms', s.Decline_Reason__c);
        System.assertEquals('Declined',    agr.Status__c,
                            'Agreement must also flip to Declined.');
    }
    
    @isTest
    static void declineAgreementGuest_delegatesToDeclineAgreement() {
        TestDataFactory.suppressCompletionStamp();
        Agreement__c agr = makeAgreement();
        agr.Status__c = 'Sent';
        update agr;
        Signer__c s = makeSigner(agr.Id, 'guest@test.com', 1);
        
        Test.startTest();
        AgreementServiceGuest.declineAgreementGuest(s.Id, 'Guest reason');
        Test.stopTest();
        
        s = [SELECT Status__c, Decline_Reason__c FROM Signer__c WHERE Id = :s.Id WITH USER_MODE];
        System.assertEquals('Declined',    s.Status__c);
        System.assertEquals('Guest reason', s.Decline_Reason__c);
    }
    
    // ═══════════════════════════════════════════════════════
    // sendCompletionEmailsPublic — BUG-030 all-roles coverage
    // ═══════════════════════════════════════════════════════
    
   @isTest
static void sendCompletionEmailsPublic_allRolesReceiveEmail() {
        TestDataFactory.suppressCompletionStamp();
    User testOwner = new User(
        FirstName    = 'Test',
        LastName     = 'Owner',
        Email        = 'testowner@example.com',
        Username     = 'testowner_' + Datetime.now().getTime() + '@example.com',
        Alias        = 'towner',
        TimeZoneSidKey    = 'America/New_York',
        LocaleSidKey      = 'en_US',
        EmailEncodingKey  = 'UTF-8',
        LanguageLocaleKey = 'en_US',
        ProfileId    = UserInfo.getProfileId()
    );
    insert testOwner;

    // Give the fixture user the package permission set, because every real user
    // of this package has it. createAgreement now inserts WITH USER_MODE, so a
    // bare user without SignForce_User fails FLS on Agreement__c fields — a
    // condition that cannot occur in a subscriber org, where the set is what
    // grants access to the package's own fields in the first place.
    List<PermissionSet> pkgPs = [
        SELECT Id FROM PermissionSet WHERE Name = 'SignForce_User' LIMIT 1
    ];
    if (!pkgPs.isEmpty()) {
        insert new PermissionSetAssignment(
            AssigneeId = testOwner.Id, PermissionSetId = pkgPs[0].Id
        );
    }

    System.runAs(testOwner) {
        Agreement__c agr = makeAgreement();
        agr.Status__c = 'Completed';
        update agr;

        makeSigner(agr.Id, 'signer@test.com',   'Signer',   1);
        makeSigner(agr.Id, 'approver@test.com', 'Approver', 2);
        makeSigner(agr.Id, 'cc@test.com',       'CC',       3);

        makeDocument(agr.Id, 'Stamped');
        makeDocument(agr.Id, 'Signed');

        Test.startTest();
        AgreementServiceGuest.sendCompletionEmailsPublic(agr.Id);
        Integer emails = Limits.getEmailInvocations();
        Test.stopTest();

        System.assert(emails >= 1,
            'Completion must email owner plus Signer/Approver/CC recipients.');
    }
}
    
    // ═══════════════════════════════════════════════════════
    // getDocumentBytes — ContentVersion (Tier1) path
    // ═══════════════════════════════════════════════════════
    
    @isTest
    static void getDocumentBytes_contentVersionPath_returnsBlob() {
        TestDataFactory.suppressCompletionStamp();
        Agreement__c agr = makeAgreement();
        Agreement_Document__c doc = makeDocument(agr.Id, 'Original');
        
        Test.startTest();
        Blob bytes = AgreementServiceGuest.getDocumentBytes(doc);
        Test.stopTest();
        
        System.assertNotEquals(null, bytes, 'Must return bytes for a doc with a ContentVersion ID.');
        System.assert(bytes.size() > 0, 'Blob must have content.');
    }
    
    @isTest
    static void getDocumentBytes_nullDocument_returnsNull() {
        TestDataFactory.suppressCompletionStamp();
        Blob bytes = AgreementServiceGuest.getDocumentBytes(null);
        System.assertEquals(null, bytes, 'Null document must return null.');
    }
    
    @isTest
    static void getDocumentBytes_noStorageReference_returnsNull() {
        TestDataFactory.suppressCompletionStamp();
        Agreement__c agr = makeAgreement();
        Agreement_Document__c doc = new Agreement_Document__c(
            Agreement__c     = agr.Id,
            Document_Type__c = 'Original',
            Name             = 'Empty Doc'
        );
        insert doc;
        
        Blob bytes = AgreementServiceGuest.getDocumentBytes(doc);
        System.assertEquals(null, bytes, 'Doc with no storage reference must return null.');
    }
    
    // ═══════════════════════════════════════════════════════
    // getS3PresignedUrlForDoc
    // ═══════════════════════════════════════════════════════
    
    @isTest
    static void getS3PresignedUrlForDoc_blankId_returnsNull() {
        TestDataFactory.suppressCompletionStamp();
        System.assertEquals(null, AgreementServiceGuest.getS3PresignedUrlForDoc(null),
                            'Null S3 doc ID must return null without a callout.');
        System.assertEquals(null, AgreementServiceGuest.getS3PresignedUrlForDoc(''),
                            'Blank S3 doc ID must return null without a callout.');
    }


    // ═══════════════════════════════════════════════════════
    // Coverage: previously-dark branches of the completion-email,
    // branded-template and document-resolution paths.
    // ═══════════════════════════════════════════════════════

    // ═══════════════════════════════════════════════════════
    // Branded email helpers — getEmailHeader / getEmailFooter /
    // buildDownloadLinksHtml with a SignForce_Branding__c record present
    // ═══════════════════════════════════════════════════════

    /**
* Every other test in this class runs with NO SignForce_Branding__c record, so
* the email helpers only ever emit the seeded default palette. This one inserts
* an org-default branding record first (and clears BrandingService's static
* caches, which would otherwise serve the defaults loaded earlier in the
* transaction), which drives the branded side of getEmailHeader() /
* getEmailFooter().
*
* It also gives the Stamped document a CLOUD file far larger than the 3 MB
* single-attachment cap, so tryAttachOrLink short-circuits on the declared size
* BEFORE fetchCloudBytes — no callout, therefore no HttpCalloutMock needed — and
* falls through to the provider's shareable URL. That puts one entry in
* downloadLinks, which is the only condition under which
* buildDownloadLinksHtml() runs and injects its branded "Available for download"
* row at the <!--SF_BODY_END--> sentinel of every completion email.
*/
    @isTest
    static void sendCompletionEmails_brandedOrgWithOversizeCloudDoc_rendersBrandedDownloadRow() {
        TestDataFactory.suppressCompletionStamp();
        insert new SignForce_Branding__c(
            Company_Name__c       = 'Acme Legal Group',
            Primary_Color__c      = '#4c1d95',
            Accent_Color__c       = '#1d9e75',
            Email_Header_Color__c = '#123456',
            Email_Footer_Text__c  = 'Acme Legal Group - Confidential',
            Signing_Page_Title__c = 'Acme Signing'
        );
        BrandingServiceGuest.clearCache();

        Agreement__c agr = makeAgreement();
        // Two signers, so the agreement is not "sole signer" and the owner gets
        // the "all parties have signed" email as well as the two signer emails.
        makeSigner(agr.Id, 'branded.signer1@test.com', 'Signer', 1);
        makeSigner(agr.Id, 'branded.signer2@test.com', 'Signer', 2);

        // Cloud-stored Stamped document declared at 8 MB — over the 3 MB single
        // attachment cap, so the cloud branch never attempts the Lambda fetch and
        // returns S3_Preview_URL__c as the download link instead.
        insert new Agreement_Document__c(
            Agreement__c       = agr.Id,
            Document_Type__c   = 'Stamped',
            Name               = 'Acme Master Services Agreement.pdf',
            Storage_Type__c    = 'Cloud',
            Cloud_Provider__c  = 'OneDrive',
            Cloud_File_Id__c   = 'cloudfile-branded-001',
            S3_Preview_URL__c  = 'https://example.com/share/branded-stamped',
            File_Size_Bytes__c = 8388608
        );

        agr.Status__c = 'Completed';
        update agr;

        String failure = null;
        Integer emailsSent = 0;

        Test.startTest();
        try {
            AgreementServiceGuest.sendCompletionEmailsPublic(agr.Id);
        } catch (AgreementService.AgreementException e) {
            failure = e.getMessage();
        }
        emailsSent = Limits.getEmailInvocations();
        Test.stopTest();

        System.assertEquals(null, failure,
            'Branded completion emails must send; every recipient was rejected instead: ' + failure);
        System.assert(emailsSent >= 1,
            'Owner plus both signers must be emailed — got ' + emailsSent + ' email invocation(s).');

        // The three helpers under test read their markup straight off the branding
        // record via BrandingService, so what they emitted for those emails must
        // carry the record's values rather than the seeded SignForce defaults.
        Map<String, String> t = BrandingServiceGuest.getEmailTokens();
        System.assertEquals('Acme Legal Group', t.get('companyName'),
            'The branding record must drive the company name the email helpers print.');
        System.assertEquals('#4c1d95', t.get('brandPrimary'),
            'The branding record must drive the primary colour the email helpers paint with.');
        System.assertNotEquals('#2563eb', t.get('link'),
            'A branded primary must recolour the link token buildDownloadLinksHtml puts on every download URL.');
        System.assertNotEquals('#0a1628', t.get('headerBg'),
            'An explicit Email_Header_Color__c must move the header band off the default navy.');

        String header = BrandingServiceGuest.getEmailHeader();
        String footer = BrandingServiceGuest.getEmailFooter();
        System.assert(header.contains('Acme Legal Group'),
            'The branded header must carry the company name from the branding record.');
        System.assert(header.contains('#4c1d95'),
            'The branded header wordmark must use the branding record primary colour.');
        System.assert(footer.contains('Acme Legal Group - Confidential'),
            'The branded footer must carry Email_Footer_Text__c from the branding record.');
        System.assert(footer.contains('<!--SF_BODY_END-->'),
            'The footer must still emit the sentinel buildDownloadLinksHtml injects its row at.');
    }

    @isTest
    static void sendCompletionEmails_multiSignerWithCc_ownerCopyAndOriginalFallback() {
        TestDataFactory.suppressCompletionStamp();
        // Two Signer-role recipients + a CC, on an agreement whose owner is NOT a
        // signer. That shape is what switches on the branches a single-signer
        // agreement never reaches:
        //   - checkAgreementCompletion's Sequential group advance (signer 2 is
        //     invited the moment signer 1 signs),
        //   - the owner's "All parties have signed" copy, which is skipped whenever
        //     soleSigner is true,
        //   - the "All parties have signed" per-signer wording (not the sole-signer
        //     "You have signed" wording),
        //   - the Original-document fallback in the attachment builder, because no
        //     'Stamped' record exists here.
        // Mock is defensive: the ContentVersion-backed documents resolve without a
        // callout, but a stray S3/Lambda fetch must not fail the run.
        Test.setMock(HttpCalloutMock.class, DocGenLambdaMock.alwaysOk());

        Agreement__c agr = makeAgreement();          // Sequential, owner = running user
        agr.Status__c = 'Sent';
        update agr;

        makeDocument(agr.Id, 'Original');            // no 'Stamped' → Original fallback
        makeDocument(agr.Id, 'Signed');              // signing certificate

        Signer__c s1 = makeSigner(agr.Id, 's1multi@test.com', 'Signer', 1);
        Signer__c s2 = makeSigner(agr.Id, 's2multi@test.com', 'Signer', 2);
        Signer__c cc = makeSigner(agr.Id, 'ccmulti@test.com', 'CC',     3);
        makeSignatureField(agr.Id, s1.Id);
        makeSignatureField(agr.Id, s2.Id);

        Test.startTest();
        AgreementServiceGuest.markSigned(s1.Id, '1.1.1.1', 'UA');  // Sequential → invites signer 2
        AgreementServiceGuest.markSigned(s2.Id, '2.2.2.2', 'UA');  // last signer → completes
        AgreementServiceGuest.sendCompletionEmailsPublic(agr.Id);  // owner + 2 signers + CC
        Integer emails = Limits.getEmailInvocations();
        Test.stopTest();

        // Sequential group advance: signer 2 must have been invited by signer 1's
        // signature, not left waiting.
        List<Signing_Event__c> invite = [
            SELECT Id FROM Signing_Event__c
            WHERE Agreement__c = :agr.Id
            AND Action__c = 'Email Delivered'
            AND Signer_Email__c = 's2multi@test.com' WITH USER_MODE
        ];
        System.assertEquals(1, invite.size(),
            'Signer 2 must be invited exactly once, when signer 1 signs a Sequential agreement.');

        agr = [SELECT Status__c, Completed_Date__c FROM Agreement__c
               WHERE Id = :agr.Id WITH USER_MODE];
        System.assertEquals('Completed', agr.Status__c,
            'Agreement must complete once BOTH signers have signed.');
        System.assertNotEquals(null, agr.Completed_Date__c,
            'Completed_Date__c must be stamped at completion.');

        System.assertEquals('Signed',
            [SELECT Status__c FROM Signer__c WHERE Id = :cc.Id WITH USER_MODE].Status__c,
            'CC recipient must be advanced to the terminal status at completion.');

        System.assertEquals('Signed',
            [SELECT Status__c FROM Signer__c WHERE Id = :s2.Id WITH USER_MODE].Status__c,
            'Signer 2 must be recorded as Signed.');

        // 1 sequential invite to signer 2, 1 "you have signed" confirmation to
        // signer 1 (not the last signer), 1 completion batch.
        System.assert(emails >= 3,
            'Expected the sequential invite, signer 1s confirmation and the completion '
            + 'batch — got ' + emails + ' email invocations.');

        // The completion batch is sent per-recipient (allOrNone = false) and every
        // rejected address is audited. No rows means the owner copy, both signer
        // copies and the CC copy were all accepted.
        Integer failed = [
            SELECT COUNT() FROM Signing_Event__c
            WHERE Agreement__c = :agr.Id
            AND Action__c = 'Completion Email Failed' WITH USER_MODE
        ];
        System.assertEquals(0, failed,
            'Owner, both signers and the CC must all be accepted by the completion send.');
    }

    @isTest
    static void getDocumentBytes_s3Backed_usesCachedUrlThenAsksLambdaForFreshOne() {
        TestDataFactory.suppressCompletionStamp();
        // Path 2 of getDocumentBytes(): the document has NO ContentVersion, so
        // the bytes have to come out of S3. Two sub-branches live there and
        // neither was exercised before:
        //   (a) S3_Preview_URL__c populated — the cached presigned URL is
        //       fetched directly, with NO Lambda round-trip at all.
        //   (b) S3_Preview_URL__c blank — getS3PresignedUrlForDoc() is called
        //       to mint a fresh URL. The Lambda answers without a "url" key,
        //       so the resolver must degrade to null rather than throw.
        // Both branches are callouts, so DocGenLambdaMock stands in for the
        // S3 GET (no JSON body -> mock returns image bytes) and for the
        // Lambda POST (action=getUrl -> mock returns "{}").
        SignForceConfigService.lambdaEndpointOverride = 'https://lambda.test/signforce';
        SignForceConfigServiceGuest.lambdaEndpointOverride = 'https://lambda.test/signforce';

        Agreement__c agr = makeAgreement();

        Agreement_Document__c cachedDoc = new Agreement_Document__c(
            Agreement__c       = agr.Id,
            Document_Type__c   = 'Stamped',
            Name               = 'S3 Stamped Doc',
            S3_Document_ID__c  = 'orgs/testorg/stamped-cached.pdf',
            S3_Preview_URL__c  = 'https://s3.amazonaws.com/signforce/stamped-cached.pdf?sig=abc123',
            File_Size_Bytes__c = 68
        );
        Agreement_Document__c freshDoc = new Agreement_Document__c(
            Agreement__c       = agr.Id,
            Document_Type__c   = 'Signed',
            Name               = 'S3 Signed Doc',
            S3_Document_ID__c  = 'orgs/testorg/signed-no-cached-url.pdf',
            File_Size_Bytes__c = 68
        );
        insert new List<Agreement_Document__c>{ cachedDoc, freshDoc };

        Test.setMock(HttpCalloutMock.class, DocGenLambdaMock.alwaysOk());

        Test.startTest();
        Blob   cachedBytes = AgreementServiceGuest.getDocumentBytes(cachedDoc);
        Blob   freshBytes  = AgreementServiceGuest.getDocumentBytes(freshDoc);
        String mintedUrl   = AgreementServiceGuest.getS3PresignedUrlForDoc(freshDoc.S3_Document_ID__c);
        Test.stopTest();

        // (a) Cached-URL branch: a doc with no ContentVersion still resolves,
        //     and the bytes are whatever the presigned URL served.
        System.assertNotEquals(null, cachedBytes,
            'A doc with no ContentVersion must resolve its bytes from the cached S3 presigned URL.');
        System.assert(cachedBytes.size() > 0,
            'Bytes fetched from the cached S3 URL must be non-empty. Got size: ' + cachedBytes.size());

        // (b) No cached URL: the Lambda is asked for a fresh one. This response
        //     carries no "url", so the resolver returns null instead of
        //     throwing or handing back an empty Blob.
        System.assertEquals(null, freshBytes,
            'With no cached URL and a Lambda response that carries no "url", getDocumentBytes must degrade to null.');
        System.assertEquals(null, mintedUrl,
            'getS3PresignedUrlForDoc must return null when the Lambda payload contains no "url" key.');
    }

@isTest
    static void sendCompletionEmailsPublic_cloudDocs_smallInlinedLargeLinked() {
        TestDataFactory.suppressCompletionStamp();
        Agreement__c agr = makeAgreement();
        agr.Status__c = 'Completed';
        update agr;

        makeSigner(agr.Id, 'cloudattach@test.com', 1);

        // Small cloud Stamped doc — comfortably under the 3 MB single-attachment
        // cap, so tryAttachOrLink must pull the bytes back through the Lambda and
        // inline-attach them rather than fall back to the share link.
        insert new Agreement_Document__c(
            Agreement__c       = agr.Id,
            Name               = 'Cloud Stamped Small',
            Document_Type__c   = 'Stamped',
            Storage_Type__c    = 'Cloud',
            Cloud_Provider__c  = 'GoogleDrive',
            Cloud_File_Id__c   = 'cloud-stamped-small',
            S3_Preview_URL__c  = 'https://drive.google.com/file/d/cloud-stamped-small/view',
            File_Size_Bytes__c = 200
        );

        // Oversized cloud certificate — above the same cap, so the bytes fetch
        // must be skipped entirely and the provider's share link used instead.
        insert new Agreement_Document__c(
            Agreement__c       = agr.Id,
            Name               = 'Cloud Certificate Large',
            Document_Type__c   = 'Signed',
            Storage_Type__c    = 'Cloud',
            Cloud_Provider__c  = 'GoogleDrive',
            Cloud_File_Id__c   = 'cloud-cert-large',
            S3_Preview_URL__c  = 'https://drive.google.com/file/d/cloud-cert-large/view',
            File_Size_Bytes__c = 5000000
        );

        // All DML is done BEFORE startTest so the completion email's cloud fetch
        // is a real, mockable callout instead of "uncommitted work pending".
        CloudFetchMock mock = new CloudFetchMock();
        Test.setMock(HttpCalloutMock.class, mock);

        Test.startTest();
        AgreementServiceGuest.sendCompletionEmailsPublic(agr.Id);
        Integer emailsSent = Limits.getEmailInvocations();
        Test.stopTest();

        System.assertEquals(1, emailsSent,
            'The completion email must still go out when the documents live in cloud storage.');
        System.assertEquals(1, mock.calls,
            'Exactly one cloud fetch is allowed: the small Stamped doc is pulled back to be attached, '
            + 'while the oversized certificate must skip the fetch and go straight to a download link.');
        System.assertNotEquals(null, mock.lastBody,
            'fetchCloudBytes must have issued a request body to the Lambda.');
        System.assert(mock.lastBody.contains('downloadFromCloud'),
            'fetchCloudBytes must ask the Lambda for the downloadFromCloud action. Body: ' + mock.lastBody);
        System.assert(mock.lastBody.contains('cloud-stamped-small'),
            'The fetch must target the small Stamped document\'s cloud file id. Body: ' + mock.lastBody);
        System.assert(mock.lastBody.contains('GoogleDrive'),
            'The document\'s cloud provider must be forwarded to the Lambda. Body: ' + mock.lastBody);
        System.assert(!mock.lastBody.contains('cloud-cert-large'),
            'The oversized certificate must never be fetched back for inline attachment.');
    }

    /**
     * Lambda mock for the completion email's cloud-document fetch.
     *
     * Returns a genuinely attachable payload (success + a small pdfBase64) so the
     * inline-attach branch of tryAttachOrLink is reached, and records every request
     * so a test can prove WHICH documents triggered a fetch.
     */
    private class CloudFetchMock implements HttpCalloutMock {
        public Integer calls = 0;
        public String  lastBody;

        public HttpResponse respond(HttpRequest req) {
            calls++;
            lastBody = req.getBody();
            HttpResponse res = new HttpResponse();
            res.setStatusCode(200);
            res.setHeader('Content-Type', 'application/json');
            res.setBody(JSON.serialize(new Map<String, Object>{
                'success'   => true,
                'size'      => 8,
                'pdfBase64' => EncodingUtil.base64Encode(Blob.valueOf('mock pdf'))
            }));
            return res;
        }
    }
}
